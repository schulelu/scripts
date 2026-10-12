#!/usr/bin/env bash
#
# mount-manager.sh — mount remote directories over SSH (sshfs)
#
# Mounts a directory (or a whole drive: just name its mountpoint) from another
# machine onto a local path, either for this boot only or permanently via
# /etc/fstab + systemd automount. Intended for the case where an app writes
# files that belong on a different box: mount the remote directory where the
# app already writes and change no application code.
#
set -euo pipefail

SCRIPT_NAME="mount-manager"
SCRIPT_VERSION="1.0.0"

# --- Configuration ---
FSTAB="/etc/fstab"
FSTAB_BACKUP="/etc/fstab.${SCRIPT_NAME}.bak"
FUSE_CONF="/etc/fuse.conf"
DEFAULT_KEY="/root/.ssh/id_ed25519_mount"
DEFAULT_PORT="22"
KNOWN_HOSTS="/root/.ssh/known_hosts"
LOCK_FILE="/run/${SCRIPT_NAME}.lock"
MARKER="# managed-by: ${SCRIPT_NAME}/${SCRIPT_VERSION} — DO NOT EDIT BY HAND"
MARKER_KEY="# managed-by: ${SCRIPT_NAME}/"
PROBE_NAME=".${SCRIPT_NAME}-probe"

# Keep-alive settings. 'reconnect' alone never notices a link that went away
# without an RST — sshfs waits forever on a socket nobody is answering. The
# ServerAlive pair is what turns a dead link into an error, so they ship together.
SSH_ALIVE_OPTS="reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,ConnectTimeout=10"

# fstab-only options. x-systemd.automount is the reason to prefer fstab over a
# plain _netdev line: the mount happens on first access, so a storage box that
# is down at boot gives the app an I/O error on its first write instead of
# hanging this machine's boot for 90 seconds.
FSTAB_OPTS="_netdev,noauto,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.mount-timeout=30"

# --- Color Output ---
RED=""
GREEN=""
YELLOW=""
CYAN=""
BOLD=""
RESET=""

function color_init() {
    if [ -t 1 ]; then
        RED=$(tput setaf 1)
        GREEN=$(tput setaf 2)
        YELLOW=$(tput setaf 3)
        CYAN=$(tput setaf 6)
        BOLD=$(tput bold)
        RESET=$(tput sgr0)
    fi
}

function log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local color=""

    case "$level" in
        INFO)   color="$GREEN" ;;
        WARN)   color="$YELLOW" ;;
        ERROR)  color="$RED" ;;
        PHASE)  color="${BOLD}${CYAN}" ;;
    esac

    echo "${color}[${level}]${RESET} ${msg}"
}

function die() {
    # stderr, not stdout: several functions return their value via stdout inside
    # $( ), and an error written there would be silently captured instead of shown.
    log_msg ERROR "$@" >&2
    exit 1
}

function check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)"
    fi
}

function confirm() {
    local prompt="$1"
    # Read from /dev/tty so a piped stdin does not silently auto-answer.
    if [[ ! -t 0 && ! -e /dev/tty ]]; then
        log_msg WARN "No terminal available — declining: $prompt"
        return 1
    fi
    echo -n "${YELLOW}${prompt} [y/N]${RESET} "
    local answer
    read -r answer </dev/tty
    [[ "$answer" =~ ^[Yy]$ ]]
}

function require_deps() {
    local dep missing=()
    for dep in "$@"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]} — install with: apt-get install sshfs openssh-client util-linux"
    fi
}

# --- Cleanup / locking ---

TMPFILES=()

function cleanup() {
    local f
    for f in "${TMPFILES[@]+"${TMPFILES[@]}"}"; do
        [[ -n "$f" && -e "$f" ]] && rm -f -- "$f"
    done
    return 0
}

function acquire_lock() {
    # /etc/fstab is shared mutable state: two concurrent runs would each read it,
    # each write their own version, and one edit would vanish.
    exec {LOCK_FD}>"$LOCK_FILE" || die "Cannot open lock file $LOCK_FILE"
    flock -w 15 "$LOCK_FD" || die "Another $SCRIPT_NAME instance holds $LOCK_FILE"
}

# --- Target parsing / validation ---

function parse_target() {
    # "user@host:/remote/path" -> "user host /remote/path" on stdout.
    local target="$1"

    [[ "$target" == *:* ]] || die "Invalid target '$target' — expected user@host:/remote/path"
    local userhost="${target%%:*}"
    local rpath="${target#*:}"

    [[ "$userhost" == *@* ]] || die "Invalid target '$target' — missing 'user@' (the SSH login on the remote host)"
    local ruser="${userhost%%@*}"
    local rhost="${userhost#*@}"

    [[ -n "$ruser" ]] || die "Invalid target '$target' — empty user"
    [[ -n "$rhost" ]] || die "Invalid target '$target' — empty host"
    [[ "$rpath" == /* ]] || die "Invalid target '$target' — remote path must be absolute (got '$rpath')"

    # ponytail: fstab splits fields on whitespace, so a path with a space needs
    # \040 escaping on write and unescaping on read. Reject it instead — add the
    # escaping when someone actually has such a path.
    [[ "$target" =~ [[:space:]] ]] && die "Invalid target '$target' — whitespace is not supported"

    printf '%s %s %s\n' "$ruser" "$rhost" "$rpath"
}

function validate_mountpoint() {
    local mp="$1"
    [[ "$mp" == /* ]] || die "Mountpoint must be an absolute path (got '$mp')"
    [[ "$mp" =~ [[:space:]] ]] && die "Mountpoint '$mp' contains whitespace — not supported (fstab splits on whitespace)"
    [[ "$mp" == "/" ]] && die "Refusing to use / as a mountpoint"
    # Strip a trailing slash so /mnt/x and /mnt/x/ are the same fstab entry.
    mp="${mp%/}"
    printf '%s\n' "$mp"
}

# --- Option building ---

function build_opts() {
    # Pure function. One builder for both paths so a temporary mount and a
    # permanent one behave identically — the fstab entry is the same mount.
    local key="$1" port="$2" uid="$3" gid="$4" ro="$5" private="$6" for_fstab="$7"
    local opts="$SSH_ALIVE_OPTS"

    opts+=",IdentityFile=${key}"
    opts+=",Port=${port}"
    opts+=",uid=${uid},gid=${gid}"
    # default_permissions: without it FUSE lets the mount owner past the file
    # modes entirely, and the uid/gid above would be decoration.
    opts+=",default_permissions"
    [[ "$private" == "true" ]] || opts+=",allow_other"
    [[ "$ro" == "true" ]] && opts+=",ro"
    [[ "$for_fstab" == "true" ]] && opts+=",${FSTAB_OPTS}"

    printf '%s\n' "$opts"
}

function opts_have() {
    # Exact option match, not a substring: 'ro' must not match 'reconnect'.
    local opts="$1" want="$2" o
    local -a fields
    IFS=, read -ra fields <<<"$opts"
    for o in "${fields[@]}"; do
        [[ "$o" == "$want" ]] && return 0
    done
    return 1
}

# --- fstab rendering / parsing ---

function render_fstab_line() {
    # Deterministic: no timestamps, so re-adding an unchanged mount produces
    # byte-identical output and the diff stays reviewable.
    local source="$1" mp="$2" opts="$3"
    printf '%s\n%s %s fuse.sshfs %s 0 0\n' "$MARKER" "$source" "$mp" "$opts"
}

function fstab_remove() {
    # Print $1 with our entry for mountpoint $2 removed, plus the marker line
    # directly above it. A marker whose next line is not the target is kept —
    # it belongs to a different managed mount.
    local file="$1" mp="$2"
    awk -v mp="$mp" -v key="$MARKER_KEY" '
        function is_target(l,   a, n) {
            if (l ~ /^[ \t]*#/) return 0
            n = split(l, a, /[ \t]+/)
            return (n >= 2 && a[2] == mp)
        }
        {
            if (index($0, key) == 1) { if (pending != "") print pending; pending = $0; next }
            if (is_target($0)) { pending = ""; next }
            if (pending != "") { print pending; pending = "" }
            print
        }
        END { if (pending != "") print pending }
    ' "$file"
}

function fstab_managed_entries() {
    # "source<TAB>mountpoint<TAB>options" for every entry we own.
    local file="${1:-$FSTAB}"
    [[ -f "$file" ]] || return 0
    awk -v key="$MARKER_KEY" '
        index($0, key) == 1 { marked = 1; next }
        marked {
            marked = 0
            if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) next
            print $1 "\t" $2 "\t" $4
        }
    ' "$file"
}

function fstab_install() {
    # Validate before writing: a malformed /etc/fstab can stop this machine from
    # booting, and unlike a sudoers mistake nobody finds out until the reboot.
    local content="$1"
    local tmp
    tmp=$(mktemp) || die "mktemp failed"
    TMPFILES+=("$tmp")
    printf '%s\n' "$content" > "$tmp"

    # Only enforce what we did not already inherit: findmnt --verify also
    # complains about pre-existing entries (a missing mountpoint directory, a
    # swap file), and refusing to work because of someone else's warning is not
    # our call to make.
    local old_ok="false"
    findmnt --verify --tab-file "$FSTAB" >/dev/null 2>&1 && old_ok="true"
    if [[ "$old_ok" == "true" ]] && ! findmnt --verify --tab-file "$tmp" >/dev/null 2>&1; then
        findmnt --verify --tab-file "$tmp" >&2 || true
        die "Generated fstab failed validation — $FSTAB left untouched"
    fi

    cp -a "$FSTAB" "$FSTAB_BACKUP"
    install -m 644 -o root -g root "$tmp" "$FSTAB"
    systemctl daemon-reload 2>/dev/null || true
    log_msg INFO "Updated $FSTAB (previous version kept at $FSTAB_BACKUP)"
}

# --- Mount state ---

function automount_unit() {
    systemd-escape -p --suffix=automount "$1"
}

function is_mounted() {
    findmnt -M "$1" >/dev/null 2>&1
}

function is_stale() {
    # A dead sshfs mount still looks mounted to findmnt; only touching it tells
    # the truth ("Transport endpoint is not connected").
    is_mounted "$1" || return 1
    ! stat -- "$1" >/dev/null 2>&1
}

function mount_state() {
    local mp="$1"
    if is_stale "$mp"; then
        echo "stale"
    elif is_mounted "$mp"; then
        echo "mounted"
    elif systemctl is-active --quiet "$(automount_unit "$mp")" 2>/dev/null; then
        echo "automount-idle"
    else
        echo "not-mounted"
    fi
}

function do_umount() {
    local mp="$1"
    umount "$mp" 2>/dev/null && return 0
    fusermount3 -u "$mp" 2>/dev/null && return 0
    fusermount -u "$mp" 2>/dev/null && return 0
    # Lazy detach: the usual state after the remote host rebooted — the kernel
    # still holds the connection, nothing can complete on it.
    log_msg WARN "Normal unmount failed — forcing a lazy detach of '$mp'"
    fusermount3 -uz "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null
}

# --- Shared option parsing for mount / add ---

OPT_KEY=""
OPT_PORT=""
OPT_AS=""
OPT_RO="false"
OPT_PRIVATE="false"
OPT_FORCE="false"

function parse_mount_flags() {
    OPT_KEY="$DEFAULT_KEY"
    OPT_PORT="$DEFAULT_PORT"
    OPT_AS=""
    OPT_RO="false"
    OPT_PRIVATE="false"
    OPT_FORCE="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --as)      OPT_AS="${2:-}"; [[ -n "$OPT_AS" ]] || die "--as needs a local user name"; shift 2 ;;
            --key)     OPT_KEY="${2:-}"; [[ -n "$OPT_KEY" ]] || die "--key needs a path"; shift 2 ;;
            --port)    OPT_PORT="${2:-}"; [[ "$OPT_PORT" =~ ^[0-9]+$ ]] || die "--port needs a number"; shift 2 ;;
            --ro)      OPT_RO="true"; shift ;;
            --private) OPT_PRIVATE="true"; shift ;;
            --force)   OPT_FORCE="true"; shift ;;
            *)         die "Unknown option: $1" ;;
        esac
    done
}

function resolve_ids() {
    # "uid gid" for the mount. Everything on the mount appears owned by these.
    local mp="$1"
    if [[ -n "$OPT_AS" ]]; then
        id -u "$OPT_AS" >/dev/null 2>&1 || die "No such local user: '$OPT_AS'"
        printf '%s %s\n' "$(id -u "$OPT_AS")" "$(id -g "$OPT_AS")"
        return 0
    fi
    if [[ -d "$mp" ]]; then
        printf '%s %s\n' "$(stat -c %u "$mp")" "$(stat -c %g "$mp")"
        return 0
    fi
    printf '0 0\n'
}

function preflight_mountpoint() {
    local mp="$1" ruser="$2" rhost="$3" rpath="$4"

    if [[ ! -e "$mp" ]]; then
        mkdir -p -- "$mp" || die "Cannot create mountpoint '$mp'"
        log_msg INFO "Created mountpoint $mp"
    fi
    [[ -d "$mp" ]] || die "'$mp' exists and is not a directory"

    is_mounted "$mp" && die "'$mp' already has something mounted on it — unmount it first: $SCRIPT_NAME.sh umount $mp"

    # Mounting over a populated directory hides everything under it with no
    # warning at all, and the files stay hidden until the mount goes away.
    local count
    count=$(find "$mp" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 && "$OPT_FORCE" != "true" ]]; then
        log_msg ERROR "$mp is not empty ($count entries) — mounting would hide them."
        log_msg ERROR "        Copy them to the remote first:"
        log_msg ERROR "          rsync -a --info=progress2 ${mp}/ ${ruser}@${rhost}:${rpath}/"
        log_msg ERROR "        Then re-run, or pass --force to mount anyway."
        exit 1
    fi
    [[ "$count" -gt 0 ]] && log_msg WARN "$mp is not empty ($count entries) — --force given, those files will be hidden while mounted"
    return 0
}

function report_ownership() {
    local uid="$1" gid="$2"
    local uname_ gname_
    uname_=$(getent passwd "$uid" | cut -d: -f1) || true
    gname_=$(getent group "$gid" | cut -d: -f1) || true
    log_msg INFO "Files will appear as ${uname_:-$uid}:${gname_:-$gid} (uid=$uid gid=$gid)"
    if [[ "$uid" == "0" && -z "$OPT_AS" ]]; then
        log_msg WARN "  That is root — if your app runs as another user, remount with: --as <user>"
    fi
}

# --- Commands ---

function cmd_setup() {
    check_root
    [[ $# -ge 1 ]] || die "Usage: $SCRIPT_NAME.sh setup <user@host>[:/remote/path] [--key F] [--port N]"

    local target="$1"; shift
    local key="$DEFAULT_KEY" port="$DEFAULT_PORT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --key)  key="${2:-}";  [[ -n "$key" ]] || die "--key needs a path"; shift 2 ;;
            --port) port="${2:-}"; [[ "$port" =~ ^[0-9]+$ ]] || die "--port needs a number"; shift 2 ;;
            *)      die "Unknown option: $1" ;;
        esac
    done

    # The path is optional here: setup is about the connection, and checking the
    # remote directory too is free when it is given.
    local ruser rhost rpath="" parsed
    if [[ "$target" == *:* ]]; then
        # Two steps, not read <<<"$(parse_target ...)": die() inside a command
        # substitution only kills the subshell, so a bad target would sail on
        # with empty variables.
        parsed="$(parse_target "$target")" || exit 1
        read -r ruser rhost rpath <<<"$parsed"
    else
        [[ "$target" == *@* ]] || die "Expected user@host (optionally user@host:/remote/path)"
        ruser="${target%%@*}"
        rhost="${target#*@}"
        [[ -n "$ruser" && -n "$rhost" ]] || die "Expected user@host"
    fi

    require_deps ssh ssh-keygen ssh-keyscan

    log_msg PHASE "Checking sshfs"
    if ! command -v sshfs >/dev/null 2>&1; then
        log_msg INFO "Installing sshfs"
        DEBIAN_FRONTEND=noninteractive apt-get install -y sshfs >/dev/null || die "apt-get install sshfs failed"
    fi
    log_msg INFO "sshfs present: $(sshfs --version 2>&1 | head -n1)"

    log_msg PHASE "SSH key for root"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    if [[ ! -f "$key" ]]; then
        # No passphrase, on purpose: systemd mounts this at boot with no tty and
        # no agent to unlock anything. The protection is that the key is
        # root-owned and 0600 — if root is compromised the key is the least of it.
        ssh-keygen -t ed25519 -N '' -C "${SCRIPT_NAME}@$(hostname)" -f "$key" >/dev/null
        log_msg INFO "Generated $key (no passphrase — boot-time mounts cannot prompt for one)"
    else
        log_msg INFO "Using existing key $key"
    fi
    chmod 600 "$key"

    log_msg PHASE "Host key"
    local hostspec="$rhost"
    [[ "$port" != "22" ]] && hostspec="[$rhost]:$port"
    if ssh-keygen -F "$hostspec" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
        log_msg INFO "$hostspec is already in $KNOWN_HOSTS"
    else
        local scan
        scan=$(ssh-keyscan -p "$port" -T 10 "$rhost" 2>/dev/null) || true
        [[ -n "$scan" ]] || die "Could not fetch a host key from $rhost:$port — is it reachable?"

        # Trust-on-first-use is the one security decision this script makes, so
        # it is shown in full and confirmed by a human. Accepting the wrong key
        # here means every file the app writes goes to whoever answered.
        echo
        echo "The host key below will be added to $KNOWN_HOSTS and trusted permanently."
        echo "Verify these fingerprints against the storage server itself"
        echo "(run 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' there) before accepting:"
        echo
        printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null || true
        echo
        confirm "Trust this host key for $hostspec?" || die "Host key rejected — nothing was changed"
        printf '%s\n' "$scan" >> "$KNOWN_HOSTS"
        chmod 600 "$KNOWN_HOSTS"
        log_msg INFO "Added $hostspec to $KNOWN_HOSTS"
    fi

    log_msg PHASE "FUSE configuration"
    if grep -qE '^[[:space:]]*user_allow_other' "$FUSE_CONF" 2>/dev/null; then
        log_msg INFO "user_allow_other already enabled in $FUSE_CONF"
    else
        # Without this, allow_other is refused and only root can read the mount —
        # which means the app user cannot, and the whole point is lost.
        if grep -q '^#user_allow_other' "$FUSE_CONF" 2>/dev/null; then
            sed -i 's/^#user_allow_other/user_allow_other/' "$FUSE_CONF"
        else
            printf '\n%s\nuser_allow_other\n' "$MARKER" >> "$FUSE_CONF"
        fi
        log_msg INFO "Enabled user_allow_other in $FUSE_CONF"
    fi

    log_msg PHASE "Authenticating to ${ruser}@${rhost}:${port}"
    if ssh -i "$key" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 "${ruser}@${rhost}" true 2>/dev/null; then
        log_msg INFO "Key authentication already works"
    else
        log_msg INFO "Installing the public key on the remote (you will be asked for ${ruser}'s remote password once)"
        ssh-copy-id -i "${key}.pub" -p "$port" "${ruser}@${rhost}" || die "ssh-copy-id failed — copy ${key}.pub into ${ruser}@${rhost}:~/.ssh/authorized_keys by hand"
        ssh -i "$key" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 "${ruser}@${rhost}" true 2>/dev/null \
            || die "Key authentication still fails — check the remote sshd (PubkeyAuthentication, AuthorizedKeysFile, home permissions)"
        log_msg INFO "Key authentication works"
    fi

    if [[ -n "$rpath" ]]; then
        log_msg PHASE "Checking remote path $rpath"
        # Read-only: this script never creates or chowns anything on the remote.
        local probe
        probe=$(ssh -i "$key" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 "${ruser}@${rhost}" \
            "if [ ! -e '$rpath' ]; then echo missing; elif [ ! -d '$rpath' ]; then echo notdir; elif [ ! -w '$rpath' ]; then echo readonly; else echo ok; fi" 2>/dev/null) || probe="error"
        case "$probe" in
            ok)       log_msg INFO "$rpath exists and is writable by '$ruser'" ;;
            missing)  log_msg WARN "$rpath does not exist on $rhost — create it there: ssh ${ruser}@${rhost} 'mkdir -p $rpath'" ;;
            notdir)   log_msg WARN "$rpath exists on $rhost but is not a directory" ;;
            readonly) log_msg WARN "$rpath is not writable by '$ruser' — the mount will be read-only in practice" ;;
            *)        log_msg WARN "Could not check $rpath on $rhost" ;;
        esac
    fi

    echo
    log_msg PHASE "Setup complete"
    echo "  Mount now (temporary):  sudo ./$SCRIPT_NAME.sh mount ${ruser}@${rhost}:${rpath:-/remote/path} /local/path --as <app-user>"
    echo "  Mount permanently:      sudo ./$SCRIPT_NAME.sh add   ${ruser}@${rhost}:${rpath:-/remote/path} /local/path --as <app-user>"
}

function cmd_mount() {
    check_root
    [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME.sh mount <user@host:/remote> <local> [--as user] [--key F] [--port N] [--ro] [--private] [--force]"
    require_deps sshfs findmnt

    local target="$1" mp="$2"; shift 2
    parse_mount_flags "$@"

    local ruser rhost rpath parsed
    parsed="$(parse_target "$target")" || exit 1
    read -r ruser rhost rpath <<<"$parsed"
    mp="$(validate_mountpoint "$mp")" || exit 1
    [[ -f "$OPT_KEY" ]] || die "SSH key '$OPT_KEY' not found — run: $SCRIPT_NAME.sh setup ${ruser}@${rhost}"

    preflight_mountpoint "$mp" "$ruser" "$rhost" "$rpath"

    local uid gid opts ids
    ids="$(resolve_ids "$mp")" || exit 1
    read -r uid gid <<<"$ids"
    opts="$(build_opts "$OPT_KEY" "$OPT_PORT" "$uid" "$gid" "$OPT_RO" "$OPT_PRIVATE" false)"

    log_msg PHASE "Mounting ${ruser}@${rhost}:${rpath} on $mp"
    sshfs "${ruser}@${rhost}:${rpath}" "$mp" -o "$opts" || die "sshfs failed — try: sshfs ${ruser}@${rhost}:${rpath} $mp -o $opts -o debug,sshfs_debug"

    is_mounted "$mp" || die "sshfs returned success but nothing is mounted on $mp"
    log_msg INFO "Mounted $mp"
    report_ownership "$uid" "$gid"
    log_msg WARN "This mount is temporary — it is gone after a reboot. Use 'add' to make it permanent."
    probe_mount "$mp" "$OPT_RO"
}

function cmd_add() {
    check_root
    [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME.sh add <user@host:/remote> <local> [--as user] [--key F] [--port N] [--ro] [--private] [--force]"
    require_deps sshfs findmnt systemctl systemd-escape
    acquire_lock

    local target="$1" mp="$2"; shift 2
    parse_mount_flags "$@"

    local ruser rhost rpath parsed
    parsed="$(parse_target "$target")" || exit 1
    read -r ruser rhost rpath <<<"$parsed"
    mp="$(validate_mountpoint "$mp")" || exit 1
    [[ -f "$OPT_KEY" ]] || die "SSH key '$OPT_KEY' not found — run: $SCRIPT_NAME.sh setup ${ruser}@${rhost}"

    if fstab_managed_entries | cut -f2 | grep -qxF "$mp"; then
        die "$mp already has a managed entry in $FSTAB — remove it first: $SCRIPT_NAME.sh rm $mp"
    fi
    if awk '$0 !~ /^[ \t]*#/ && NF >= 2 { print $2 }' "$FSTAB" | grep -qxF "$mp"; then
        die "$mp already appears in $FSTAB in an entry we do not manage — resolve that by hand"
    fi

    preflight_mountpoint "$mp" "$ruser" "$rhost" "$rpath"

    local uid gid opts ids
    ids="$(resolve_ids "$mp")" || exit 1
    read -r uid gid <<<"$ids"
    opts="$(build_opts "$OPT_KEY" "$OPT_PORT" "$uid" "$gid" "$OPT_RO" "$OPT_PRIVATE" true)"

    log_msg PHASE "Adding $mp to $FSTAB"
    # Joined with an explicit newline: an /etc/fstab that does not end in one
    # would otherwise get our marker glued onto its last entry.
    local existing new_content
    existing="$(cat "$FSTAB")"
    new_content="${existing}"$'\n'"$(render_fstab_line "${ruser}@${rhost}:${rpath}" "$mp" "$opts")"
    fstab_install "$new_content"

    local unit
    unit="$(automount_unit "$mp")"
    systemctl start "$unit" || die "Could not start $unit — the fstab entry is written; check: systemctl status $unit"
    log_msg INFO "Armed $unit (mounts on first access, survives reboot)"

    # Trigger it now rather than discovering at 3am that the key or the remote
    # path was wrong.
    log_msg PHASE "Triggering the mount"
    ls -- "$mp" >/dev/null 2>&1 || true
    if is_mounted "$mp"; then
        log_msg INFO "Mounted $mp"
        report_ownership "$uid" "$gid"
        probe_mount "$mp" "$OPT_RO"
    else
        log_msg ERROR "Automount is armed but the mount did not come up."
        log_msg ERROR "  See why:  journalctl -u $(systemd-escape -p --suffix=mount "$mp") -n 30"
        log_msg ERROR "  Undo:     $SCRIPT_NAME.sh rm $mp"
        exit 1
    fi
}

function cmd_umount() {
    check_root
    [[ $# -ge 1 ]] || die "Usage: $SCRIPT_NAME.sh umount <local>"
    local mp
    mp="$(validate_mountpoint "$1")" || exit 1

    is_mounted "$mp" || { log_msg INFO "$mp is not mounted"; return 0; }
    do_umount "$mp" || true
    if is_mounted "$mp"; then
        die "Could not unmount $mp — something is still using it (check: lsof +D $mp)"
    fi
    log_msg INFO "Unmounted $mp"

    if fstab_managed_entries | cut -f2 | grep -qxF "$mp"; then
        log_msg WARN "$mp still has an fstab entry — it will come back on the next access or reboot."
        log_msg WARN "  Remove it for good with: $SCRIPT_NAME.sh rm $mp"
    fi
}

function cmd_rm() {
    check_root
    [[ $# -ge 1 ]] || die "Usage: $SCRIPT_NAME.sh rm <local>"
    require_deps findmnt systemctl systemd-escape
    acquire_lock

    local mp
    mp="$(validate_mountpoint "$1")" || exit 1
    fstab_managed_entries | cut -f2 | grep -qxF "$mp" \
        || die "No managed $FSTAB entry for '$mp' — see: $SCRIPT_NAME.sh list"

    systemctl stop "$(automount_unit "$mp")" 2>/dev/null || true
    if is_mounted "$mp"; then
        do_umount "$mp" || true
        is_mounted "$mp" && die "Could not unmount $mp — fstab entry left in place (check: lsof +D $mp)"
        log_msg INFO "Unmounted $mp"
    fi

    fstab_install "$(fstab_remove "$FSTAB" "$mp")"
    systemctl reset-failed "$(automount_unit "$mp")" 2>/dev/null || true
    log_msg INFO "Removed $mp from $FSTAB"
}

function cmd_list() {
    require_deps findmnt

    local entries live
    entries="$(fstab_managed_entries)"
    live="$(findmnt -rn -t fuse.sshfs -o TARGET,SOURCE 2>/dev/null || true)"

    printf '%s%-28s %-34s %-14s %s%s\n' "$BOLD" "LOCAL" "REMOTE" "STATE" "MODE" "$RESET"

    local src mp opts state
    while IFS=$'\t' read -r src mp opts; do
        [[ -n "$mp" ]] || continue
        state="$(mount_state "$mp")"
        local mode="permanent"
        opts_have "$opts" "ro" && mode="permanent,ro"
        printf '%-28s %-34s %-14s %s\n' "$mp" "$src" "$state" "$mode"
    done <<<"$entries"

    # Temporary mounts: live sshfs mounts with no fstab entry of ours.
    local t_target t_source
    while read -r t_target t_source; do
        [[ -n "$t_target" ]] || continue
        cut -f2 <<<"$entries" | grep -qxF "$t_target" && continue
        printf '%-28s %-34s %-14s %s\n' "$t_target" "$t_source" "$(mount_state "$t_target")" "temporary"
    done <<<"$live"

    if [[ -z "$entries" && -z "$live" ]]; then
        echo "(no sshfs mounts)"
    fi
}

function probe_mount() {
    # findmnt reporting "mounted" proves nothing: a dead sshfs mount looks
    # identical until you touch it. Read, then write, and time both.
    local mp="$1" ro="${2:-false}"
    local start end

    start=$(date +%s%N)
    if ! ls -- "$mp" >/dev/null 2>&1; then
        log_msg ERROR "Cannot read $mp — the transport is dead (fix: $SCRIPT_NAME.sh umount $mp, then mount again)"
        return 1
    fi
    end=$(date +%s%N)
    log_msg INFO "Read OK  ($(( (end - start) / 1000000 )) ms)"

    if [[ "$ro" == "true" ]]; then
        log_msg INFO "Write probe skipped (mounted read-only)"
        return 0
    fi

    local probe="${mp}/${PROBE_NAME}.$$"
    start=$(date +%s%N)
    if ! echo "$SCRIPT_NAME probe" > "$probe" 2>/dev/null; then
        log_msg ERROR "Cannot write to $mp — check the remote path's permissions for the SSH user"
        return 1
    fi
    rm -f -- "$probe"
    end=$(date +%s%N)
    log_msg INFO "Write OK ($(( (end - start) / 1000000 )) ms round trip)"
}

function cmd_check() {
    [[ $# -ge 1 ]] || die "Usage: $SCRIPT_NAME.sh check <local>"
    require_deps findmnt
    local mp
    mp="$(validate_mountpoint "$1")" || exit 1

    local state
    state="$(mount_state "$mp")"
    log_msg INFO "State: $state"

    case "$state" in
        not-mounted)
            log_msg WARN "$mp is not mounted"
            return 1 ;;
        automount-idle)
            log_msg INFO "Automount armed — touching $mp to bring it up"
            ls -- "$mp" >/dev/null 2>&1 || true
            is_mounted "$mp" || { log_msg ERROR "Mount did not come up — see: journalctl -u $(systemd-escape -p --suffix=mount "$mp") -n 30"; return 1; } ;;
        stale)
            log_msg ERROR "$mp is mounted but its transport is dead."
            log_msg ERROR "  Fix: $SCRIPT_NAME.sh umount $mp   (then re-mount, or just access it if it is an automount)"
            return 1 ;;
    esac

    local ro="false"
    findmnt -rn -o OPTIONS -M "$mp" 2>/dev/null | grep -qw ro && ro="true"
    probe_mount "$mp" "$ro"
}

# --- usage / dispatch ---

function usage() {
    cat <<EOF
${BOLD}$SCRIPT_NAME.sh${RESET} v$SCRIPT_VERSION — mount remote directories over SSH (sshfs)

${BOLD}USAGE${RESET}
    sudo ./$SCRIPT_NAME.sh <command> [args]

${BOLD}COMMANDS${RESET}
    setup <user@host>[:/path] [--key F] [--port N]
                                One-time prep: install sshfs, create a root SSH
                                key, trust the host key, enable user_allow_other,
                                verify login (and the remote path, if given).
    mount <user@host:/remote> <local> [opts]
                                Mount now. Gone after a reboot.
    add   <user@host:/remote> <local> [opts]
                                Mount now and every boot ($FSTAB entry +
                                systemd automount).
    umount <local>              Unmount (survives a dead transport endpoint).
    rm     <local>              Unmount and delete the fstab entry.
    list                        Show managed and live sshfs mounts.
    check  <local>              Probe a mount: read, write, report round trip.

${BOLD}OPTIONS${RESET} (mount / add)
    --as <user>     Local user the files should appear to belong to. Defaults to
                    the owner of the mountpoint directory. Set this to the user
                    your app runs as.
    --key <path>    SSH private key (default: $DEFAULT_KEY).
    --port <n>      SSH port (default: $DEFAULT_PORT).
    --ro            Mount read-only.
    --private       Drop allow_other — only root may enter the mount.
    --force         Mount over a non-empty directory, hiding what is in it.

${BOLD}A WHOLE DRIVE${RESET}
    There is no separate command: name the remote's mountpoint.
        sudo ./$SCRIPT_NAME.sh add backup@storage:/mnt/bigdisk /mnt/bigdisk

${BOLD}WHAT THIS IS AND IS NOT GOOD FOR${RESET}
    Every file operation is an SSH round trip. Writing generated files, serving
    static assets, moving archives around: fine. A database file, a git
    checkout, or anything doing many small random reads and fsyncs on the mount:
    use a real network filesystem instead.

    There is no cross-client file locking. Two machines writing the same file
    corrupt it; flock() on the mount only sees local processes.

    uid=/gid= is client-side cosmetics. On the remote host the files belong to
    the SSH user, and that host's permissions are the ones that actually apply.

${BOLD}EXAMPLES${RESET}
    # Move an app's output directory onto the storage box, no app changes
    sudo ./$SCRIPT_NAME.sh setup app@storage:/srv/data
    rsync -a --info=progress2 /home/user/data/ app@storage:/srv/data/
    rm -rf /home/user/data/*
    sudo ./$SCRIPT_NAME.sh add app@storage:/srv/data /home/user/data --as www-data

    sudo ./$SCRIPT_NAME.sh list
    sudo ./$SCRIPT_NAME.sh check /home/user/data
    sudo ./$SCRIPT_NAME.sh rm /home/user/data
EOF
}

function main() {
    color_init
    trap cleanup EXIT

    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local cmd="$1"; shift

    case "$cmd" in
        setup)          cmd_setup "$@" ;;
        mount)          cmd_mount "$@" ;;
        add)            cmd_add "$@" ;;
        umount|unmount) cmd_umount "$@" ;;
        rm|remove)      cmd_rm "$@" ;;
        list)           cmd_list "$@" ;;
        check)          cmd_check "$@" ;;
        help|--help|-h) usage ;;
        --version)      echo "$SCRIPT_NAME $SCRIPT_VERSION" ;;
        *)              log_msg ERROR "Unknown command: $cmd"; usage; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
