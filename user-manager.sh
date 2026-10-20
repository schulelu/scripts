#!/usr/bin/env bash
#
# user-manager.sh — SSH user provisioning with scoped sudo grants
#
# Creates login users from a supplied public key, generates a random password
# whose only job is authenticating sudo, confines users to their own data by
# permissions, wires them into a shared /home/shared workspace, and manages
# reusable sudo capability-groups (e.g. "sudo nginx -t" without full sudo).
#
set -euo pipefail

SCRIPT_NAME="user-manager"
SCRIPT_VERSION="1.1.0"

# --- Configuration ---
# Overridable so one host can carry several shares (e.g. shared + shared-dev):
#   UM_SHARED_USER=shared-dev UM_SHARED_DIR=/home/shared-dev ./user-manager.sh setup
SHARED_USER="${UM_SHARED_USER:-shared}"
SHARED_DIR="${UM_SHARED_DIR:-/home/shared}"
MANAGED_GROUP="sshusers"
CAP_PREFIX="sudogrp-"
ALIAS_PREFIX="SUDOGRP_"
SUDOERS_D="/etc/sudoers.d"
SSHD_DROPIN="/etc/ssh/sshd_config.d/60-user-manager.conf"
FSTAB="/etc/fstab"
LOCK_FILE="/run/${SCRIPT_NAME}.lock"
MARKER="# managed-by: ${SCRIPT_NAME}/${SCRIPT_VERSION} - DO NOT EDIT BY HAND"   # ASCII: some parsers (ufw) choke on UTF-8
MARKER_KEY="# managed-by: ${SCRIPT_NAME}/"

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
    # Unlike the sibling scripts, read from /dev/tty so a piped stdin does not
    # silently auto-answer. No tty at all means "no".
    # bootstrap.sh applies grants from its reviewed config (grant_plan): it
    # answers for itself instead of a person at a terminal.
    if [[ "${UM_ASSUME_YES:-}" == 1 ]]; then
        log_msg INFO "UM_ASSUME_YES: yes to: $prompt"
        return 0
    fi
    # /dev/tty always exists; without a controlling terminal it cannot be opened.
    if [[ ! -t 0 ]] && ! { : </dev/tty; } 2>/dev/null; then
        log_msg WARN "No terminal available — declining: $prompt"
        return 1
    fi
    echo -n "${YELLOW}${prompt} [y/N]${RESET} "
    local answer=""
    read -r answer </dev/tty || return 1
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
        die "Missing required commands: ${missing[*]} — install with: apt-get install openssh-server acl sudo openssl"
    fi
}

# --- Cleanup / locking ---

TMPFILES=()

# Set by sudo-add while a group it just created has no sudoers file yet.
ROLLBACK_GROUP=""; ROLLBACK_FILE=""

function cleanup() {
    local f
    for f in "${TMPFILES[@]+"${TMPFILES[@]}"}"; do
        [[ -n "$f" && -e "$f" ]] && rm -f -- "$f"
    done
    # A half-created capability (group without its file) would block every
    # later attempt as "collides with something this script did not create".
    if [[ -n "$ROLLBACK_GROUP" && ! -e "$ROLLBACK_FILE" ]]; then
        groupdel "$ROLLBACK_GROUP" 2>/dev/null && log_msg WARN "Rolled back group $ROLLBACK_GROUP (capability not created)"
    fi
    return 0
}

function acquire_lock() {
    # Serialise mutations. Two concurrent runs could each pass their own
    # whole-tree validation and still leave /etc/sudoers.d inconsistent.
    exec {LOCK_FD}>"$LOCK_FILE" || die "Cannot open lock file $LOCK_FILE"
    flock -w 15 "$LOCK_FD" || die "Another $SCRIPT_NAME instance holds $LOCK_FILE"
}

# --- Name validation ---

function validate_user_name() {
    local name="$1"
    # Debian's NAME_REGEX, minus the trailing '$' form used by Samba machine accounts.
    if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        die "Invalid user name '$name' — lowercase letter or underscore first, then [a-z0-9_-], max 32 chars"
    fi
}

function validate_cap_name() {
    local cap="$1"
    if [[ ! "$cap" =~ ^[a-z][a-z0-9-]{1,19}$ ]]; then
        die "Invalid capability name '$cap'
     Rules: 2-20 chars, start with a lowercase letter, then [a-z0-9-] only."
    fi
    # No dots: @includedir SILENTLY skips any file in /etc/sudoers.d whose name
    # contains a '.' or ends in '~'. The grant would exist, validate, and do
    # nothing at all — the worst kind of failure.
    #
    # No underscores: the Cmnd_Alias is derived by uppercasing and mapping
    # '-' -> '_', so allowing '_' would map both "foo-bar" and "foo_bar" to
    # SUDOGRP_FOO_BAR. Two files defining the same alias is a hard syntax error
    # that breaks sudo system-wide, and `visudo -cf <file>` cannot detect it.
    # Banning '_' makes the mapping injective by construction.
    [[ "$cap" == *--* ]] && die "Invalid capability name '$cap' — no consecutive hyphens"
    [[ "$cap" == *- ]]   && die "Invalid capability name '$cap' — must not end with a hyphen"
    return 0
}

function cap_group() { printf '%s%s\n' "$CAP_PREFIX" "$1"; }
function cap_file()  { printf '%s/%s%s\n' "$SUDOERS_D" "$CAP_PREFIX" "$1"; }
function cap_alias() { printf '%s%s\n' "$ALIAS_PREFIX" "$(tr 'a-z-' 'A-Z_' <<<"$1")"; }

function cap_file_is_managed() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    head -n 1 -- "$f" 2>/dev/null | grep -qF "$MARKER_KEY"
}

function cap_is_managed() {
    # Managed iff BOTH the marked file and the Unix group exist. The prefix alone
    # is not enough — an admin could hand-create a group named sudogrp-foo, and
    # we must never groupdel something we did not create.
    local cap="$1"
    cap_file_is_managed "$(cap_file "$cap")" || return 1
    getent group "$(cap_group "$cap")" >/dev/null 2>&1
}

function cap_exists_any() {
    local cap="$1"
    [[ -e "$(cap_file "$cap")" ]] || getent group "$(cap_group "$cap")" >/dev/null 2>&1
}

# --- sudoers rendering / parsing ---

function render_cap_file() {
    # Pure function of (cap, commands, allow_exec). Deterministic: no timestamps,
    # so an unchanged capability renders byte-identically and we skip the write.
    local cap="$1" allow_exec="$2"
    shift 2
    local cmds=("$@")
    local grp alias tag i
    grp="$(cap_group "$cap")"
    alias="$(cap_alias "$cap")"

    tag="NOEXEC:PASSWD:"
    [[ "$allow_exec" == "true" ]] && tag="PASSWD:"

    printf '%s\n' "$MARKER"
    printf '# %s-cap: %s\n' "$SCRIPT_NAME" "$cap"
    printf '# %s-group: %s\n' "$SCRIPT_NAME" "$grp"
    printf '#\n'
    printf '# Add:    %s.sh sudo-add %s "/abs/path args"\n' "$SCRIPT_NAME" "$cap"
    printf '# Remove: %s.sh sudo-del %s\n' "$SCRIPT_NAME" "$cap"
    printf '\n'

    # A capability with no commands renders as comments only. An empty
    # "Cmnd_Alias X =" is a syntax error, so it must not be emitted.
    if [[ ${#cmds[@]} -eq 0 ]]; then
        printf '# (no commands granted yet)\n'
        return 0
    fi

    printf 'Cmnd_Alias %s = \\\n' "$alias"
    for (( i = 0; i < ${#cmds[@]}; i++ )); do
        if (( i == ${#cmds[@]} - 1 )); then
            printf '    %s\n' "${cmds[$i]}"
        else
            printf '    %s, \\\n' "${cmds[$i]}"
        fi
    done
    printf '\n'

    # Ubuntu builds sudo with --with-timeout=15, so one successful sudo buys 15
    # password-free minutes on that tty. The password exists precisely to gate
    # these commands, so re-authenticate every time.
    printf 'Defaults:%%%s timestamp_timeout=0\n' "$grp"
    printf '\n'
    # PASSWD: is written explicitly even though it is the default, so a later
    # global "Defaults !authenticate" cannot silently disarm these grants.
    printf '%%%s ALL=(root) %s %s\n' "$grp" "$tag" "$alias"
}

function cap_read_commands() {
    # Echo one granted command per line. Parses only the exact shape
    # render_cap_file writes; anything else means the file was hand-edited.
    local file="$1"
    [[ -f "$file" ]] || return 0
    awk '
        /^Cmnd_Alias[[:space:]]/ { inblock = 1; next }
        inblock {
            if ($0 !~ /^    /) { inblock = 0; next }
            line = $0
            sub(/^    /, "", line)
            sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
            sub(/,[[:space:]]*$/, "", line)
            if (line != "") print line
        }
    ' "$file"
}

function cap_allow_exec() {
    local file="$1"
    [[ -f "$file" ]] || { echo "false"; return 0; }
    if grep -q 'ALL=(root) NOEXEC:' -- "$file"; then echo "false"; else echo "true"; fi
}

function sudoers_name_ok() {
    # @includedir skips files whose NAME contains a dot or ends in '~'. The name
    # only: the directory itself is /etc/sudoers.d.
    local n="${1##*/}"
    [[ -n "$n" && "$n" != *.* && "$n" != *~ ]]
}

function sudoers_install() {
    # Install validated sudoers content atomically. Never leaves a partial or
    # wrong-mode file visible to sudo, and rolls the whole tree back if it breaks.
    local target="$1" content="$2"

    [[ "$target" == "$SUDOERS_D"/* ]] || die "Refusing to write outside $SUDOERS_D: $target"
    sudoers_name_ok "$target" || die "Internal error: '$target' would be silently ignored by @includedir"

    local tmp backup=""
    # The temp file lives INSIDE /etc/sudoers.d so the final move is a
    # same-filesystem rename(2), which is atomic. Its leading '.' means sudo
    # skips it while it exists.
    tmp="$(mktemp "${SUDOERS_D}/.${SCRIPT_NAME}.tmp.XXXXXX")" || die "mktemp failed in $SUDOERS_D"
    TMPFILES+=("$tmp")
    printf '%s\n' "$content" > "$tmp"

    # Phase 1 — syntax check in isolation, before it can affect anything.
    if ! visudo -c -q -f "$tmp" 2>/dev/null; then
        log_msg ERROR "Generated sudoers content failed validation:"
        visudo -c -f "$tmp" 2>&1 | sed 's/^/    /' || true
        log_msg ERROR "Rejected content was:"
        sed 's/^/    /' "$tmp"
        rm -f -- "$tmp"
        die "Nothing was written — $SUDOERS_D is unchanged"
    fi

    if [[ -f "$target" ]] && cmp -s -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        log_msg INFO "$target already up to date — no change"
        return 0
    fi

    if [[ -e "$target" ]]; then
        backup="$(mktemp "${SUDOERS_D}/.${SCRIPT_NAME}.bak.XXXXXX")"
        TMPFILES+=("$backup")
        cat -- "$target" > "$backup"
    fi

    chown root:root "$tmp"
    chmod 0440 "$tmp"
    # rename(2), not install(1): install truncates and rewrites in place, so an
    # interrupt leaves a half-written file whose last line may be a broken
    # Cmnd_Alias — a syntax error that breaks sudo for everyone.
    mv -f -- "$tmp" "$target"

    # Phase 2 — whole-tree check. This is the one that matters: sudoers(5) states
    # that `visudo -f <file>` "will not catch the redefinition of an alias that is
    # also present in a different file", and alias redefinition is a hard syntax
    # error. Only a bare `visudo -c`, which follows @includedir, sees it.
    if ! visudo -c -q >/dev/null 2>&1; then
        log_msg ERROR "Installing $target broke the global sudoers policy — rolling back"
        if [[ -n "$backup" ]]; then
            chown root:root "$backup"; chmod 0440 "$backup"
            mv -f -- "$backup" "$target"
        else
            rm -f -- "$target"
        fi
        if visudo -c -q >/dev/null 2>&1; then
            die "Rolled back cleanly; $SUDOERS_D is as it was.
     Most likely cause: a Cmnd_Alias defined in another file.
     Check with: grep -rn Cmnd_Alias /etc/sudoers /etc/sudoers.d"
        fi
        log_msg ERROR "ROLLBACK FAILED — sudo may be broken system-wide."
        log_msg ERROR "Fix NOW from your already-open root shell:  visudo -c ; visudo"
        die "Aborting."
    fi

    [[ -n "$backup" ]] && rm -f -- "$backup"
    log_msg INFO "Installed $target (0440 root:root, validated standalone + whole-tree)"
    return 0
}

# --- Command validation: the security core ---

# Two tiers, because "arguments are mandatory" already does most of the work.
#
# TIER 1 — unsafe even with exact arguments, so refused unconditionally.
# Either the argument IS the code (shells, interpreters), or the escape happens
# after launch and no argument can prevent it (editors, pagers), or the pinned
# arguments already name the target of an arbitrary root write.
# Deliberately not exhaustive — GTFOBins grows. The primary control is exact
# argument pinning; this list blocks what pinning cannot save you from.
SUDO_DENY_ALWAYS=(
    # shells and shell-alikes
    sh bash dash zsh ksh csh tcsh fish rbash busybox toybox screen tmux script
    # interpreters — the argument is the program
    python python2 python3 perl ruby irb node nodejs lua tclsh expect php
    gawk awk mawk nawk sed jq
    # editors and pagers — the escape is interactive, after launch
    vi vim view nvim ex emacs nano pico joe less more most pg man info bat batcat
    # "run this program" wrappers — `sudo env /bin/sh` is the whole exploit
    env nice ionice nohup setsid timeout stdbuf setarch taskset chrt flock
    xargs watch parallel unshare nsenter capsh chroot setpriv su sudo sudoedit
    pkexec doas runuser login systemd-run at batch crontab
    # archivers with exec hooks
    tar bsdtar cpio pax zip unzip 7z 7za rsync
    # arbitrary write / ownership primitives: one root write into
    # /etc/sudoers.d and the user grants themselves everything
    tee dd cp mv install ln chmod chown chgrp truncate shred rm mknod mkfifo
    setfacl mount umount losetup fdisk parted mkfs debugfs
    # network fetchers that can write anywhere
    curl wget ssh scp sftp nc ncat netcat socat ftp tftp
    # package and container managers — hooks are command execution by design
    apt apt-get aptitude dpkg pip pip3 gem npm npx yarn snap
    docker podman ctr lxc kubectl helm
    # debuggers and tracers
    gdb strace ltrace perf valgrind
    # config-is-code
    find git make cmake nmap rpm yum dnf
)

# TIER 2 — dangerous in their general form, but a specific pinned invocation is
# legitimate and is exactly what this tool is for. `systemctl reload nginx`
# produces no output, so no pager, so no escape; `systemctl status ssh` would
# page and hand over a root shell. Exact-argument matching is what separates
# them, so these warn and confirm rather than refuse.
SUDO_CAUTION=(
    systemctl journalctl service ip iptables nft openssl mysql psql sqlite3
    logrotate
)

function caution_note() {
    case "$1" in
        systemctl|journalctl|service)
            echo "in its general form this pages output; '!sh' at the pager prompt is a root shell (and 'systemctl link' loads an attacker-written unit)" ;;
        ip)       echo "'ip netns exec x /bin/sh' is a root shell in the general form" ;;
        iptables|nft)
                  echo "'iptables --modprobe=/tmp/x -L' runs /tmp/x as root in the general form" ;;
        openssl)  echo "openssl can read and write arbitrary files as root in the general form" ;;
        mysql|psql|sqlite3)
                  echo "database clients have shell escapes ('\\!', '.shell') and file write in the general form" ;;
        logrotate)
                  echo "a logrotate config runs prerotate/postrotate scripts as root" ;;
        *)        echo "dangerous in its general form" ;;
    esac
}

function why_denied() {
    # One-line explanation per denied basename, so the refusal teaches rather
    # than just blocking.
    case "$1" in
        find)        echo "find . -exec /bin/sh \\; -quit" ;;
        tar|bsdtar)  echo "tar --checkpoint=1 --checkpoint-action=exec=/bin/sh" ;;
        less|more|man|pg|most|bat|batcat)
                     echo "'!sh' at the pager prompt" ;;
        git)         echo "git -c core.pager='!/bin/sh' log" ;;
        awk|gawk|mawk|nawk)
                     echo "awk 'BEGIN{system(\"/bin/sh\")}'" ;;
        sed)         echo "sed -e '1e /bin/sh' /etc/hostname  (GNU sed's 'e' command executes)" ;;
        perl|python|python2|python3|ruby|lua|php|node|nodejs)
                     echo "an interpreter: exec \"/bin/sh\" in one line" ;;
        env|nice|nohup|setsid|timeout|stdbuf|setarch|taskset|chrt|ionice|flock|unshare)
                     echo "it execs whatever you hand it: sudo $1 /bin/sh" ;;
        xargs)       echo "xargs -a /dev/null sh" ;;
        vi|vim|view|nvim|ex|emacs)
                     echo ":!/bin/sh  (use sudoedit instead)" ;;
        nano|pico|joe)
                     echo "^R then ^X executes a command  (use sudoedit instead)" ;;
        apt|apt-get) echo "apt-get update -o APT::Update::Pre-Invoke::=/bin/sh" ;;
        docker|podman|lxc)
                     echo "docker run -v /:/mnt --rm -it alpine chroot /mnt sh" ;;
        tee|dd|cp|mv|install|ln|chmod|chown|chgrp|truncate)
                     echo "arbitrary root file write: echo '...' | sudo $1 into /etc/sudoers.d/ is a self-granted NOPASSWD: ALL" ;;
        sh|bash|dash|zsh|ksh|csh|tcsh|fish|rbash|busybox|toybox)
                     echo "it is a shell" ;;
        *)           echo "a documented shell-escape or root-write path (see GTFOBins)" ;;
    esac
}

function path_is_root_safe() {
    # Every component — the binary AND every parent directory — must be owned by
    # root and not writable by group (unless gid 0) or other.
    #
    # Whoever can write the binary chooses what runs as root. Whoever can write
    # any parent DIRECTORY can rename the binary away and drop their own file at
    # that path. Both are silent full escalation, and sudo checks neither.
    local cur="$1" owner group mode
    while :; do
        owner="$(stat -c '%u' -- "$cur")" || return 1
        group="$(stat -c '%g' -- "$cur")" || return 1
        mode="$(stat -c '%a' -- "$cur")"  || return 1
        # Diagnostics to stderr: the caller captures this function's stdout.
        if [[ "$owner" != "0" ]]; then
            log_msg ERROR "  $cur is owned by UID $owner, not root" >&2
            return 1
        fi
        if (( 8#$mode & 8#0002 )); then
            log_msg ERROR "  $cur is mode $mode — world-writable" >&2
            return 1
        fi
        if (( 8#$mode & 8#0020 )) && [[ "$group" != "0" ]]; then
            log_msg ERROR "  $cur is mode $mode and group-owned by GID $group — group-writable by non-root" >&2
            return 1
        fi
        [[ "$cur" == "/" ]] && break
        cur="$(dirname -- "$cur")"
    done
    return 0
}

function validate_arg() {
    local arg="$1"

    if [[ "$arg" =~ [[:cntrl:]] ]]; then
        die "Argument contains a control character or newline — refused (it could inject a sudoers line)"
    fi
    # sudoers(5) requires ',' ':' '=' '\' to be backslash-escaped inside command
    # arguments; '#' starts a comment and would truncate the line; '!' negates.
    # Refusing beats escaping — getting it right through the sudoers parser and
    # then fnmatch/regexec is a bug factory.
    if [[ "$arg" == *,* || "$arg" == *:* || "$arg" == *=* || "$arg" == *\\* \
       || "$arg" == *\#* || "$arg" == *\"* || "$arg" == *\'* || "$arg" == *\!* ]]; then
        die "Argument '$arg' contains a sudoers metacharacter ( , : = \\ # \" ' ! ) — refused"
    fi
    if [[ "$arg" == *[*?]* || "$arg" == *\[* || "$arg" == *\]* ]]; then
        die "Argument '$arg' contains a glob wildcard — refused.
     sudoers wildcards match ANY character INCLUDING whitespace, so
     '/bin/cat /var/log/messages*' also permits 'cat /var/log/messages /etc/shadow'.
     A wildcard grant is a bare grant wearing a disguise. List each exact
     invocation as its own sudo-add instead."
    fi
    if [[ "$arg" == ^* ]]; then
        die "Argument '$arg' starts with '^' — sudoers would parse it as a regular expression"
    fi
}

function validate_command() {
    # Takes the full 'path arg arg' string, echoes the canonical form to stdout.
    local spec="$1" force="$2"
    local -a parts
    read -r -a parts <<<"$spec"

    [[ ${#parts[@]} -ge 1 ]] || die "Empty command specification"

    local path="${parts[0]}"
    local real base deny arg

    [[ "$path" == /* ]] || die "Command path must be absolute: '$path'
     A relative path is a sudoers syntax error, and a bare command name would be
     resolved through whatever PATH the user controls."

    real="$(realpath -e -- "$path" 2>/dev/null)" \
        || die "Command path does not resolve to an existing file: '$path'"
    [[ -f "$real" ]] || die "'$real' is not a regular file"
    [[ -x "$real" ]] || die "'$real' is not executable"

    # Everything below logs to stderr: this function returns the canonical
    # command on stdout, and the caller captures it.
    if [[ "$real" != "$path" ]]; then
        log_msg WARN "'$path' is a symlink to '$real' — granting the canonical path." >&2
        log_msg WARN "  Beware update-alternatives links: the grant follows whatever the link points at." >&2
    fi

    # Both tiers match the CANONICAL basename, so `cp /bin/bash /usr/local/sbin/helper`
    # does not evade them.
    base="$(basename -- "$real")"
    for deny in "${SUDO_DENY_ALWAYS[@]}"; do
        if [[ "$base" == "$deny" ]]; then
            log_msg ERROR "Refusing to grant '$real'." >&2
            log_msg ERROR "  '$base' yields a root shell or an arbitrary root file write:" >&2
            log_msg ERROR "      $(why_denied "$base")" >&2
            log_msg ERROR "  Pinning arguments does not help here, so this is not overridable." >&2
            log_msg ERROR "  If you need a narrow slice of what it does, write a root-owned" >&2
            log_msg ERROR "  wrapper script in /usr/local/sbin and grant that instead." >&2
            exit 1
        fi
    done

    if ! path_is_root_safe "$real"; then
        die "'$real' fails the root-ownership check above.
     Granting it is a privilege escalation, not a restriction — whoever can
     write that path (or any parent directory) chooses what runs as root."
    fi

    # Arguments are mandatory. sudoers(5): "If no command line arguments are
    # specified, the user may run the command with any arguments they choose."
    # So a bare /usr/sbin/nginx permits `nginx -c /tmp/evil.conf` — root.
    if [[ ${#parts[@]} -eq 1 ]]; then
        if [[ "$force" != "true" ]]; then
            die "'$real' was given with no arguments, which permits ANY arguments.
     For example '/usr/sbin/nginx' also permits: sudo nginx -c /tmp/evil.conf
     Specify the exact invocation:  '$real -t'
     Or, to permit the command with no arguments at all:  '$real \"\"'
     Or pass --force to grant any-arguments deliberately."
        fi
        log_msg WARN "--force: granting '$real' with ANY arguments. This is usually root." >&2
    fi

    local i
    for (( i = 1; i < ${#parts[@]}; i++ )); do
        arg="${parts[$i]}"
        # The literal "" is the sudoers form meaning "no arguments allowed".
        [[ "$arg" == '""' ]] && continue
        validate_arg "$arg"
    done

    # Tier 2: legitimate when pinned, dangerous in general. Confirm rather than refuse.
    local caution
    for caution in "${SUDO_CAUTION[@]}"; do
        if [[ "$base" == "$caution" ]]; then
            log_msg WARN "'$base' is only safe because the arguments are pinned:" >&2
            log_msg WARN "      $(caution_note "$base")" >&2
            log_msg WARN "  Granting exactly:  $real ${parts[*]:1}" >&2
            if [[ "$force" != "true" ]]; then
                confirm "Grant this pinned invocation?" >&2 || die "Aborted"
            fi
            break
        fi
    done

    if [[ ${#parts[@]} -eq 1 ]]; then
        printf '%s\n' "$real"
    else
        printf '%s %s\n' "$real" "${parts[*]:1}"
    fi
}

# --- Helpers ---

function gen_password() {
    openssl rand -base64 18
}

function key_fingerprint() {
    local keyline="$1" tmp fp
    tmp="$(mktemp)"
    TMPFILES+=("$tmp")
    printf '%s\n' "$keyline" > "$tmp"
    fp="$(ssh-keygen -l -f "$tmp" 2>/dev/null)" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    printf '%s\n' "$fp"
}

function validate_pubkey() {
    local keyline="$1" fp
    fp="$(key_fingerprint "$keyline")" \
        || die "That does not parse as an SSH public key.
     Expected one line like: ssh-ed25519 AAAAC3Nza... user@host"
    case "$keyline" in
        ssh-dss*)
            die "DSA keys are refused — OpenSSH disabled them by default in 7.0." ;;
        ssh-rsa*)
            local bits; bits="$(awk '{print $1}' <<<"$fp")"
            if [[ "$bits" -lt 3072 ]]; then
                log_msg WARN "RSA key is only ${bits} bits. ed25519 or RSA >= 3072 is preferred." >&2
            fi ;;
    esac
    printf '%s\n' "$fp"
}

function read_pubkey() {
    # Echoes the key line to stdout; all prompting goes to stderr so the caller
    # can capture the key cleanly.
    local key_file="$1" key_str="$2"
    local keyline=""

    if [[ -n "$key_str" ]]; then
        keyline="$key_str"
    elif [[ -n "$key_file" ]]; then
        [[ -r "$key_file" ]] || die "Cannot read key file: $key_file"
        keyline="$(head -n 1 -- "$key_file")"
    else
        [[ -e /dev/tty ]] || die "No terminal to prompt on — use --key-file or --key"
        echo "${BOLD}Paste the user's SSH public key${RESET} (one line, e.g. 'ssh-ed25519 AAAA... alice@laptop'):" >&2
        read -r keyline </dev/tty
    fi

    keyline="${keyline#"${keyline%%[![:space:]]*}"}"
    keyline="${keyline%"${keyline##*[![:space:]]}"}"
    [[ -n "$keyline" ]] || die "No public key given"
    printf '%s\n' "$keyline"
}

function is_managed_user() {
    id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qxF "$MANAGED_GROUP"
}

function list_managed_users() {
    getent group "$MANAGED_GROUP" 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^$' | sort || true
}

function user_caps() {
    local user="$1"
    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep "^${CAP_PREFIX}" | sed "s/^${CAP_PREFIX}//" | sort || true
}

function show_effective_grants() {
    local user="$1"
    log_msg INFO "Effective sudo privileges for '$user':"
    # sudo -l -U is root-only, which we are. Exit 1 just means "nothing allowed".
    sudo -l -U "$user" 2>&1 | sed 's/^/    /' || true
}

function require_usable_password() {
    # The password IS the control here. A locked account cannot authenticate to
    # sudo, so the grant would be dead on arrival.
    local user="$1" pw
    pw="$(getent shadow "$user" 2>/dev/null | cut -d: -f2)" || pw=""
    case "$pw" in
        ""|'*'|'!'|'!!'|'!'*|'*'*)
            die "User '$user' has no usable password (shadow field: '${pw:-<empty>}').
     sudo cannot authenticate them, so the grant would never work.
     Set one with:  $SCRIPT_NAME.sh passwd $user" ;;
    esac
}

# Membership in any of these is already root by other means, so a narrowly
# scoped sudo grant on top is security theatre.
ROOT_EQUIV_GROUPS=(root sudo admin docker lxd disk shadow staff libvirt kvm)

function warn_if_root_equivalent() {
    local user="$1" g hits=()
    for g in "${ROOT_EQUIV_GROUPS[@]}"; do
        getent group "$g" >/dev/null 2>&1 || continue
        if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qxF "$g"; then
            hits+=("$g")
        fi
    done
    [[ ${#hits[@]} -eq 0 ]] && return 0
    log_msg WARN "'$user' is already in root-equivalent group(s): ${hits[*]}"
    log_msg WARN "  sudo/admin/root : unrestricted sudo already"
    log_msg WARN "  docker/lxd      : 'docker run -v /:/mnt ... chroot /mnt sh' is a root shell"
    log_msg WARN "  disk            : raw block device access -> read/write /etc/shadow"
    log_msg WARN "  shadow          : read every password hash"
    log_msg WARN "  staff           : writable /usr/local, which is on root's secure_path"
    log_msg WARN "  libvirt/kvm     : define a VM with the host disk attached"
    log_msg WARN "  A scoped grant adds nothing while this holds."
    confirm "Attach anyway?" || die "Aborted"
}

# --- setup ---

function cmd_setup() {
    check_root
    local do_hidepid=false service_account=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hidepid)         do_hidepid=true; shift ;;
            --service-account) service_account=true; shift ;;
            *) die "Unknown option for setup: $1" ;;
        esac
    done
    validate_user_name "$SHARED_USER"
    [[ "$SHARED_DIR" == /* && "$SHARED_DIR" != *..* ]] || die "Shared dir must be an absolute path: $SHARED_DIR"

    log_msg PHASE "Installing dependencies"
    if ! dpkg -s openssh-server >/dev/null 2>&1 || ! command -v setfacl >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server acl
    else
        log_msg INFO "openssh-server and acl already installed"
    fi
    # Ubuntu 24.04 socket-activates sshd.
    systemctl enable --now ssh.socket >/dev/null 2>&1 || systemctl enable --now ssh >/dev/null 2>&1 || true

    log_msg PHASE "Creating managed group and shared account"
    groupadd -f "$MANAGED_GROUP"

    if ! id -u "$SHARED_USER" >/dev/null 2>&1; then
        if [[ "$service_account" == "true" ]]; then
            # A share that services run from must not double as a login. Its home
            # is group-writable, so any member could plant a .bashrc that runs as
            # the account; and StrictModes refuses keys under a g+w home anyway.
            # No password, no shell, no skel dotfiles (-M).
            useradd -r -M -d "$SHARED_DIR" -s /usr/sbin/nologin "$SHARED_USER"
            log_msg INFO "Created service account '$SHARED_USER' (no login, no password)"
        else
            useradd -m -d "$SHARED_DIR" -s /bin/bash -G "$MANAGED_GROUP" "$SHARED_USER"
            local pw; pw="$(gen_password)"
            printf '%s:%s\n' "$SHARED_USER" "$pw" | chpasswd
            log_msg INFO "Created shared account '$SHARED_USER'"
            log_msg WARN "Password for '$SHARED_USER': ${BOLD}${pw}${RESET}   (shown once)"
            log_msg INFO "Add a key for it with:  $SCRIPT_NAME.sh key $SHARED_USER <keyfile>"
        fi
    else
        log_msg INFO "Account '$SHARED_USER' already exists"
        if [[ "$service_account" == "true" && "$(getent passwd "$SHARED_USER" | cut -d: -f7)" != "/usr/sbin/nologin" ]]; then
            log_msg WARN "'$SHARED_USER' has a login shell — not converting an existing account automatically"
        fi
    fi

    log_msg PHASE "Configuring shared workspace $SHARED_DIR"
    mkdir -p "$SHARED_DIR"
    chown "$SHARED_USER:$SHARED_USER" "$SHARED_DIR"
    # setgid so new files inherit the share's group; 2770 (not 2775) keeps
    # non-members out entirely.
    chmod 2770 "$SHARED_DIR"
    setfacl -R    -m "g:${SHARED_USER}:rwX" "$SHARED_DIR"
    # The DEFAULT ACL is the part that actually matters: UMASK is 022, so without
    # it every new file lands group-read-only and users cannot edit each other's
    # work. setgid alone fixes the group, not the write bit.
    setfacl -R -d -m "g:${SHARED_USER}:rwX" "$SHARED_DIR"
    log_msg INFO "$SHARED_DIR is 2770 with a default ACL for group '$SHARED_USER'"

    log_msg PHASE "Hardening home directory permissions"
    # 751: traversal still works, but `ls /home` does not, so accounts are not
    # enumerable by other logged-in users.
    chmod 751 /home
    local u
    while read -r u; do
        [[ -n "$u" && "$u" != "$SHARED_USER" && -d "/home/$u" ]] && chmod 700 "/home/$u"
    done < <(list_managed_users)
    log_msg INFO "/home is 751; managed homes are 700"

    log_msg PHASE "Writing sshd drop-in"
    mkdir -p "$(dirname "$SSHD_DROPIN")"
    # Scoped to Match Group on purpose: a global PasswordAuthentication no would
    # silently change the posture of every pre-existing account on this box.
    cat > "$SSHD_DROPIN" <<EOF
$MARKER
# Managed SSH users are key-only. Their password exists solely for sudo.
Match Group $MANAGED_GROUP
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
EOF
    chmod 644 "$SSHD_DROPIN"
    if ! sshd -t; then
        rm -f "$SSHD_DROPIN"
        die "sshd rejected the generated config — drop-in removed, sshd untouched"
    fi
    systemctl reload ssh >/dev/null 2>&1 || systemctl restart ssh.socket >/dev/null 2>&1 || true
    log_msg INFO "Wrote and validated $SSHD_DROPIN"

    if [[ "$do_hidepid" == "true" ]]; then
        log_msg PHASE "Enabling hidepid=2 on /proc"
        groupadd -f proc
        local line="proc /proc proc defaults,nosuid,nodev,noexec,relatime,hidepid=2,gid=proc 0 0"
        if ! grep -qF "hidepid=2" "$FSTAB"; then
            printf '\n%s\n%s\n' "$MARKER" "$line" >> "$FSTAB"
            log_msg INFO "Added hidepid=2 to $FSTAB"
        else
            log_msg INFO "hidepid already present in $FSTAB"
        fi
        mount -o remount /proc || log_msg WARN "Could not remount /proc — takes effect at next boot"
        if [[ -n "${SUDO_USER:-}" ]]; then
            usermod -a -G proc "$SUDO_USER"
            log_msg INFO "Added '$SUDO_USER' to group 'proc' (log out and back in to take effect)"
        fi
        log_msg WARN "hidepid=2 can upset desktop session tooling. Remove the $FSTAB line to revert."
    fi

    log_msg PHASE "Checking global sudo policy"
    if sudo -V 2>/dev/null | grep -q 'env_reset'; then :; fi
    if ! grep -qE '^\s*Defaults\s+env_reset' /etc/sudoers 2>/dev/null; then
        log_msg WARN "'Defaults env_reset' is not set in /etc/sudoers."
        log_msg WARN "  Without it, LD_PRELOAD from the user's environment reaches the root process"
        log_msg WARN "  and every grant this script makes is bypassable. Fix it with: visudo"
    else
        log_msg INFO "Defaults env_reset is set"
    fi
    if ! grep -qE '^\s*Defaults\s+secure_path=' /etc/sudoers 2>/dev/null; then
        log_msg WARN "'Defaults secure_path=' is not set in /etc/sudoers — child processes of a"
        log_msg WARN "  granted command would resolve PATH from the user's environment."
    fi

    echo
    log_msg PHASE "Setup complete"
    echo "  Add a user:      sudo ./$SCRIPT_NAME.sh add alice"
    echo "  Grant a command: sudo ./$SCRIPT_NAME.sh sudo-add nginx '/usr/sbin/nginx -t'"
    echo "                   sudo ./$SCRIPT_NAME.sh sudo-grant nginx alice"
}

function cmd_harden_ssh() {
    check_root
    log_msg WARN "This disables password SSH for ALL accounts on this host, not just managed ones."
    log_msg WARN "Existing accounts that rely on password login will be locked out."
    getent passwd | awk -F: '$3>=1000 && $3<65000 {print "    " $1}'
    confirm "Disable password authentication globally?" || die "Aborted"

    local f="/etc/ssh/sshd_config.d/59-user-manager-global.conf"
    cat > "$f" <<EOF
$MARKER
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
    chmod 644 "$f"
    if ! sshd -t; then
        rm -f "$f"
        die "sshd rejected the config — removed, nothing changed"
    fi
    systemctl reload ssh >/dev/null 2>&1 || true
    log_msg INFO "Password authentication disabled globally ($f)"
}

# --- user lifecycle ---

function cmd_add() {
    check_root
    [[ $# -ge 1 ]] || die "Usage: $SCRIPT_NAME.sh add <user> [--key-file F | --key 'S'] [--no-share]"
    local user="$1"; shift
    local key_file="" key_str="" share=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --key-file) key_file="${2:-}"; shift 2 ;;
            --key)      key_str="${2:-}";  shift 2 ;;
            # For people who belong to another project on the same host: the
            # share holds that project's data and must stay closed to them.
            --no-share) share=false; shift ;;
            *) die "Unknown option for add: $1" ;;
        esac
    done

    validate_user_name "$user"
    id -u "$user" >/dev/null 2>&1 && die "User '$user' already exists"
    getent group "$user" >/dev/null 2>&1 && die "Group '$user' already exists"
    getent group "$MANAGED_GROUP" >/dev/null 2>&1 || die "Run '$SCRIPT_NAME.sh setup' first"
    id -u "$SHARED_USER" >/dev/null 2>&1 || die "Run '$SCRIPT_NAME.sh setup' first"

    local keyline fp
    keyline="$(read_pubkey "$key_file" "$key_str")"
    fp="$(validate_pubkey "$keyline")"

    log_msg PHASE "Creating '$user'"
    if [[ "$share" == "true" ]]; then
        useradd -m -s /bin/bash -G "$MANAGED_GROUP,$SHARED_USER" "$user"
    else
        useradd -m -s /bin/bash -G "$MANAGED_GROUP" "$user"
    fi

    local pw; pw="$(gen_password)"
    printf '%s:%s\n' "$user" "$pw" | chpasswd

    chmod 700 "/home/$user"
    install -d -m 700 -o "$user" -g "$user" "/home/$user/.ssh"
    printf '%s\n' "$keyline" > "/home/$user/.ssh/authorized_keys"
    chmod 600 "/home/$user/.ssh/authorized_keys"
    chown "$user:$user" "/home/$user/.ssh/authorized_keys"

    # No chroot means no bind mount: a plain symlink is enough, and userdel -r
    # will remove the link rather than the shared data behind it.
    if [[ "$share" == "true" ]]; then
        ln -sfn "$SHARED_DIR" "/home/$user/$SHARED_USER"
        chown -h "$user:$user" "/home/$user/$SHARED_USER"
    fi

    local host; host="$(hostname -f 2>/dev/null || hostname)"
    echo
    echo "${BOLD}${CYAN}════════════════════════════════════════════════════════════${RESET}"
    echo "${BOLD}  User created: ${user}${RESET}"
    echo "${BOLD}${CYAN}════════════════════════════════════════════════════════════${RESET}"
    echo "  Login:       ssh ${user}@${host}"
    echo "  Key:         ${fp}"
    echo "  Password:    ${BOLD}${pw}${RESET}"
    [[ "$share" == "true" ]] && echo "  Shared dir:  /home/${user}/${SHARED_USER}  ->  ${SHARED_DIR}"
    echo "  Groups:      $(id -nG "$user")"
    echo
    echo "  ${YELLOW}The password is shown once and is NOT used for SSH — it only"
    echo "  authenticates this user's sudo calls.${RESET}"
    echo "${BOLD}${CYAN}════════════════════════════════════════════════════════════${RESET}"
}

function cmd_delete() {
    check_root
    [[ $# -ge 1 ]] || die "Usage: $SCRIPT_NAME.sh delete <user> [--purge]"
    local user="$1"; shift
    local purge=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge) purge=true; shift ;;
            *) die "Unknown option for delete: $1" ;;
        esac
    done

    id -u "$user" >/dev/null 2>&1 || die "No such user: '$user'"
    is_managed_user "$user" || die "'$user' is not in group '$MANAGED_GROUP' — this script did not create it, refusing"

    log_msg WARN "About to delete user '$user'"
    [[ "$purge" == "true" ]] && log_msg WARN "  --purge: /home/$user will be REMOVED"
    show_effective_grants "$user"
    confirm "Delete '$user'?" || die "Aborted"

    local cap
    while read -r cap; do
        [[ -n "$cap" ]] && gpasswd -d "$user" "$(cap_group "$cap")" >/dev/null 2>&1 || true
    done < <(user_caps "$user")

    if [[ "$purge" == "true" ]]; then
        # /home/$user/$SHARED_USER is a symlink; rm -r removes the link, never the
        # target. This is exactly the failure a chroot bind mount would have had.
        userdel -r "$user"
        log_msg INFO "Deleted '$user' and removed /home/$user"
    else
        userdel "$user"
        log_msg INFO "Deleted '$user'; /home/$user kept"
    fi
    [[ -d "$SHARED_DIR" ]] && log_msg INFO "$SHARED_DIR is intact"
}

function cmd_passwd() {
    check_root
    [[ $# -eq 1 ]] || die "Usage: $SCRIPT_NAME.sh passwd <user>"
    local user="$1"
    id -u "$user" >/dev/null 2>&1 || die "No such user: '$user'"
    # Same boundary as delete: this tool resets passwords of accounts it
    # created, never root's or a service account's.
    is_managed_user "$user" || die "'$user' is not in group '$MANAGED_GROUP' — this script did not create it, refusing"
    local pw; pw="$(gen_password)"
    printf '%s:%s\n' "$user" "$pw" | chpasswd
    log_msg INFO "New sudo password for '$user': ${BOLD}${pw}${RESET}   (shown once)"
}

function cmd_key() {
    check_root
    [[ $# -ge 1 ]] || die "Usage: $SCRIPT_NAME.sh key <user> [<keyfile>|-]"
    local user="$1"; shift
    id -u "$user" >/dev/null 2>&1 || die "No such user: '$user'"
    # A key on root or a service account is a login nobody asked for.
    is_managed_user "$user" || die "'$user' is not in group '$MANAGED_GROUP' — this script did not create it, refusing"
    local ak; ak="$(getent passwd "$user" | cut -d: -f6)/.ssh/authorized_keys"

    if [[ $# -eq 0 ]]; then
        [[ -f "$ak" ]] || { log_msg INFO "No keys for '$user'"; return 0; }
        log_msg INFO "Keys for '$user':"
        local n=0 line
        while read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            n=$((n + 1))
            echo "    $n. $(key_fingerprint "$line" 2>/dev/null || echo "unparseable: $line")"
        done < "$ak"
        return 0
    fi

    local keyline fp
    if [[ "$1" == "-" ]]; then
        keyline="$(read_pubkey "" "")"
    else
        keyline="$(read_pubkey "$1" "")"
    fi
    fp="$(validate_pubkey "$keyline")"

    install -d -m 700 -o "$user" -g "$user" "$(dirname "$ak")"
    if [[ -f "$ak" ]] && grep -qxF "$keyline" "$ak"; then
        log_msg INFO "Key already present for '$user'"
        return 0
    fi
    printf '%s\n' "$keyline" >> "$ak"
    chmod 600 "$ak"
    chown "$user:$user" "$ak"
    log_msg INFO "Added key to '$user': $fp"
}

function cmd_list() {
    check_root
    if [[ $# -eq 1 ]]; then
        local user="$1"
        id -u "$user" >/dev/null 2>&1 || die "No such user: '$user'"
        echo "${BOLD}User:${RESET}        $user"
        echo "${BOLD}Home:${RESET}        $(getent passwd "$user" | cut -d: -f6)"
        echo "${BOLD}Groups:${RESET}      $(id -nG "$user")"
        echo "${BOLD}Capabilities:${RESET} $(user_caps "$user" | tr '\n' ' ')"
        echo
        show_effective_grants "$user"
        return 0
    fi

    printf '%s%-16s %-30s %s%s\n' "$BOLD" "USER" "CAPABILITIES" "KEYS" "$RESET"
    local u caps ak nkeys
    while read -r u; do
        [[ -z "$u" ]] && continue
        caps="$(user_caps "$u" | tr '\n' ',' | sed 's/,$//')"
        ak="$(getent passwd "$u" | cut -d: -f6)/.ssh/authorized_keys"
        nkeys=0
        [[ -f "$ak" ]] && nkeys="$(grep -cvE '^\s*(#|$)' "$ak" || true)"
        printf '%-16s %-30s %s\n' "$u" "${caps:--}" "$nkeys"
    done < <(list_managed_users)

    echo
    printf '%s%-16s %-8s %s%s\n' "$BOLD" "CAPABILITY" "MEMBERS" "COMMANDS" "$RESET"
    local f cap n first line
    for f in "$SUDOERS_D"/"$CAP_PREFIX"*; do
        [[ -e "$f" ]] || continue
        cap_file_is_managed "$f" || continue
        cap="$(basename "$f" | sed "s/^${CAP_PREFIX}//")"
        n="$(getent group "$(cap_group "$cap")" 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -c . || true)"
        first=true
        while read -r line; do
            if [[ "$first" == "true" ]]; then
                printf '%-16s %-8s %s\n' "$cap" "$n" "$line"
                first=false
            else
                printf '%-16s %-8s %s\n' "" "" "$line"
            fi
        done < <(cap_read_commands "$f")
        [[ "$first" == "true" ]] && printf '%-16s %-8s %s\n' "$cap" "$n" "(none)"
    done
}

# --- sudo capability management ---

function write_cap() {
    local cap="$1" allow_exec="$2"
    shift 2
    local content
    content="$(render_cap_file "$cap" "$allow_exec" "$@")"
    sudoers_install "$(cap_file "$cap")" "$content"
}

function cmd_sudo_add() {
    check_root
    acquire_lock
    [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME.sh sudo-add <capability> '<abs-path args>' [--force] [--allow-exec]"
    local cap="$1" spec="$2"; shift 2
    local force=false allow_exec=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)      force=true; shift ;;
            --allow-exec) allow_exec="true"; shift ;;
            *) die "Unknown option for sudo-add: $1" ;;
        esac
    done

    validate_cap_name "$cap"

    local file grp alias
    file="$(cap_file "$cap")"
    grp="$(cap_group "$cap")"
    alias="$(cap_alias "$cap")"

    if cap_exists_any "$cap" && ! cap_is_managed "$cap"; then
        die "'$cap' collides with something this script did not create
     (file: $file, group: $grp). Pick a different capability name."
    fi

    local canonical
    canonical="$(validate_command "$spec" "$force")"

    local -a cmds=()
    local line
    if [[ -f "$file" ]]; then
        while read -r line; do [[ -n "$line" ]] && cmds+=("$line"); done < <(cap_read_commands "$file")
        [[ -z "$allow_exec" ]] && allow_exec="$(cap_allow_exec "$file")"
    else
        # Pre-flight courtesy: produce a good error rather than relying on the
        # phase-2 rollback. Alias redefinition across files is a hard syntax error.
        if grep -rslE "^[[:space:]]*Cmnd_Alias[[:space:]]+${alias}[[:space:]]*=" \
             /etc/sudoers "$SUDOERS_D" 2>/dev/null | grep -qv "^${file}$"; then
            die "Cmnd_Alias '$alias' is already defined elsewhere.
     Redefining an alias is a sudoers syntax error that breaks sudo system-wide.
     Pick a different capability name."
        fi
        log_msg INFO "Creating capability '$cap' (group $grp)"
        # System group: infrastructure, not a user group. Keeps GIDs out of the
        # 1000+ range where user-private groups live.
        if ! getent group "$grp" >/dev/null 2>&1; then
            groupadd -r "$grp"; ROLLBACK_GROUP="$grp"; ROLLBACK_FILE="$file"
        fi
    fi
    [[ -z "$allow_exec" ]] && allow_exec="false"

    local c
    for c in "${cmds[@]+"${cmds[@]}"}"; do
        if [[ "$c" == "$canonical" ]]; then
            if [[ "$allow_exec" != "$(cap_allow_exec "$file")" ]]; then
                write_cap "$cap" "$allow_exec" "${cmds[@]}"
                log_msg WARN "--allow-exec: NOEXEC is now off for '$cap'. Its commands may spawn children, including a shell."
            else
                log_msg INFO "Already granted to '$cap': $canonical"
            fi
            return 0
        fi
    done
    cmds+=("$canonical")

    write_cap "$cap" "$allow_exec" "${cmds[@]}"
    ROLLBACK_GROUP=""
    log_msg INFO "Granted to '$cap': ${BOLD}${canonical}${RESET}"
    [[ "$allow_exec" == "true" ]] \
        && log_msg WARN "--allow-exec: NOEXEC is off for this capability. The command may spawn children, including a shell."
    log_msg INFO "Attach a user with:  $SCRIPT_NAME.sh sudo-grant $cap <user>"
}

function cmd_sudo_del() {
    check_root
    acquire_lock
    [[ $# -ge 1 ]] || die "Usage: $SCRIPT_NAME.sh sudo-del <capability> ['<abs-path args>']"
    local cap="$1"; shift
    validate_cap_name "$cap"
    cap_is_managed "$cap" || die "'$cap' is not a $SCRIPT_NAME capability — refusing to touch it"

    local file grp
    file="$(cap_file "$cap")"
    grp="$(cap_group "$cap")"

    if [[ $# -eq 0 ]]; then
        log_msg WARN "About to delete capability '$cap' entirely."
        getent group "$grp" | cut -d: -f4 | tr ',' '\n' | grep . | sed 's/^/    member: /' || true
        cap_read_commands "$file" | sed 's/^/    command: /'
        confirm "Delete capability '$cap'?" || die "Aborted"

        # Order matters. Removing a self-contained file cannot break the tree.
        # The reverse order risks leaving a sudoers file that references a dead
        # GID — not a syntax error, so nothing warns — until groupadd recycles
        # that GID and an unrelated group silently inherits these root grants.
        rm -f -- "$file"
        visudo -c -q >/dev/null 2>&1 || log_msg WARN "visudo -c reports problems, but they predate this removal"
        groupdel "$grp" 2>/dev/null || log_msg WARN "Could not remove group '$grp' (still a user's primary group?)"
        log_msg INFO "Deleted capability '$cap'"
        return 0
    fi

    local spec="$1"
    local -a cmds=() keep=()
    local line
    while read -r line; do [[ -n "$line" ]] && cmds+=("$line"); done < <(cap_read_commands "$file")

    local c found=false
    for c in "${cmds[@]+"${cmds[@]}"}"; do
        if [[ "$c" == "$spec" ]]; then found=true; else keep+=("$c"); fi
    done
    if [[ "$found" != "true" ]]; then
        log_msg WARN "'$spec' is not granted to '$cap'. Current commands:"
        cap_read_commands "$file" | sed 's/^/    /'
        return 0
    fi

    write_cap "$cap" "$(cap_allow_exec "$file")" "${keep[@]+"${keep[@]}"}"
    log_msg INFO "Revoked from '$cap': $spec"
}

function cmd_sudo_grant() {
    check_root
    [[ $# -eq 2 ]] || die "Usage: $SCRIPT_NAME.sh sudo-grant <capability> <user>"
    local cap="$1" user="$2"
    validate_cap_name "$cap"
    id -u "$user" >/dev/null 2>&1 || die "No such user: '$user'"
    cap_is_managed "$cap" || die "'$cap' is not a $SCRIPT_NAME capability"

    warn_if_root_equivalent "$user"
    require_usable_password "$user"

    local grp; grp="$(cap_group "$cap")"
    if getent group "$grp" | cut -d: -f4 | tr ',' '\n' | grep -qxF "$user"; then
        log_msg INFO "'$user' already has capability '$cap'"
    else
        usermod -a -G "$grp" "$user"
        log_msg INFO "Granted '$cap' to '$user'"
    fi

    # sudo resolves the invoking user's groups from the kernel group vector of
    # their process, which does not change until they log in again.
    log_msg WARN "'$user' must open a NEW session before this takes effect."
    log_msg WARN "  'sudo -l -U $user' below reads the policy, not their live shell,"
    log_msg WARN "  so it will look correct while their current session still fails."
    show_effective_grants "$user"
}

function cmd_sudo_revoke() {
    check_root
    [[ $# -eq 2 ]] || die "Usage: $SCRIPT_NAME.sh sudo-revoke <capability> <user>"
    local cap="$1" user="$2"
    validate_cap_name "$cap"
    id -u "$user" >/dev/null 2>&1 || die "No such user: '$user'"
    local grp; grp="$(cap_group "$cap")"
    getent group "$grp" >/dev/null 2>&1 || die "No such capability: '$cap'"

    if ! getent group "$grp" | cut -d: -f4 | tr ',' '\n' | grep -qxF "$user"; then
        log_msg INFO "'$user' does not have capability '$cap'"
        return 0
    fi
    gpasswd -d "$user" "$grp" >/dev/null
    log_msg INFO "Revoked '$cap' from '$user'"

    # Revocation does not reach live sessions either: the group is still in the
    # kernel group vector of any already-running login shell.
    log_msg WARN "Existing sessions of '$user' KEEP this capability until they exit."
    if confirm "Terminate all sessions of '$user' now?"; then
        loginctl terminate-user "$user" 2>/dev/null || pkill -u "$user" 2>/dev/null || true
        log_msg INFO "Sessions of '$user' terminated"
    fi
}

function cmd_verify() {
    check_root
    [[ $# -ge 1 ]] || die "Usage: $SCRIPT_NAME.sh verify <user> [-- /abs/path args...]"
    local user="$1"; shift
    id -u "$user" >/dev/null 2>&1 || die "No such user: '$user'"
    [[ "${1:-}" == "--" ]] && shift

    if [[ $# -eq 0 ]]; then
        show_effective_grants "$user"
        return 0
    fi

    # Ask sudo's own policy engine rather than trusting our parser. This is the
    # authoritative oracle and it catches sudoers subtleties we would not.
    if sudo -l -U "$user" -- "$@" >/dev/null 2>&1; then
        log_msg INFO "ALLOWED: '$user' may run: $*"
        return 0
    fi
    log_msg WARN "DENIED:  '$user' may NOT run: $*"
    log_msg INFO "  Arguments are matched exactly — '/usr/sbin/nginx -t' does not permit 'nginx -q -t'."
    log_msg INFO "  See what is pinned with:  $SCRIPT_NAME.sh list"
    return 1
}

# --- usage / dispatch ---

function usage() {
    cat <<EOF
${BOLD}$SCRIPT_NAME.sh${RESET} v$SCRIPT_VERSION — SSH user provisioning with scoped sudo grants

${BOLD}USAGE${RESET}
    sudo ./$SCRIPT_NAME.sh <command> [args]

${BOLD}SETUP${RESET}
    setup [--hidepid] [--service-account]
                                Install sshd, create the '$SHARED_USER' account and
                                shared workspace, harden home permissions, write
                                the sshd drop-in. --hidepid also hides other
                                users' processes (may upset desktop tooling).
                                --service-account makes '$SHARED_USER' a no-login
                                system account (for shares that services run from).
                                Another share: UM_SHARED_USER=x UM_SHARED_DIR=/home/x
    harden-ssh                  Disable password SSH for ALL accounts (asks first).

${BOLD}USERS${RESET}
    add <user> [--key-file F|--key 'S'] [--no-share]
                                Create a user from a public key. Generates a
                                random password, prints it once. --no-share keeps
                                them out of '$SHARED_USER'.
    delete <user> [--purge]     Remove a user. --purge also removes their home.
    passwd <user>               Generate and print a new sudo password.
    key <user> [<keyfile>|-]    List keys, or append one ('-' reads a paste).
    list [user]                 Show managed users, capabilities and grants.

${BOLD}SUDO CAPABILITIES${RESET}
    sudo-add <cap> '<abs-path args>' [--force] [--allow-exec]
                                Grant a command to capability <cap>, creating it
                                if needed. The path must be absolute and the
                                arguments exact.
    sudo-del <cap> ['<abs-path args>']
                                Revoke one command, or delete <cap> entirely.
    sudo-grant  <cap> <user>    Give a user the capability.
    sudo-revoke <cap> <user>    Take it away.
    verify <user> [-- cmd args] Ask sudo whether the user may run something.

${BOLD}HOW SUDO GRANTS WORK${RESET}
    One Unix group per capability (${CAP_PREFIX}<cap>), one file per capability in
    $SUDOERS_D. Grants always require the user's password — never NOPASSWD,
    and the credential cache is disabled, so every call re-authenticates.

    ${BOLD}Arguments are matched exactly.${RESET} '/usr/sbin/nginx -t' permits only that
    invocation, not 'nginx -q -t'. Add each accepted form separately; do not
    reach for a wildcard, because sudoers wildcards match whitespace too.

    A command given with ${BOLD}no${RESET} arguments permits ${BOLD}any${RESET} arguments — that is what
    sudoers means by a bare path, and it is usually root. Use '<path> ""' to
    permit the command with no arguments at all.

${BOLD}BEFORE YOUR FIRST RUN${RESET}
    Open a second terminal and run 'sudo -i', then leave it open. A malformed
    file in $SUDOERS_D disables sudo for everyone. This script validates and
    rolls back, but a spare root shell costs nothing.

${BOLD}EXAMPLES${RESET}
    sudo ./$SCRIPT_NAME.sh setup
    sudo ./$SCRIPT_NAME.sh add alice --key-file alice.pub
    sudo ./$SCRIPT_NAME.sh sudo-add web '/usr/sbin/nginx -t'
    sudo ./$SCRIPT_NAME.sh sudo-add web '/usr/bin/systemctl reload nginx'
    sudo ./$SCRIPT_NAME.sh sudo-grant web alice
    sudo ./$SCRIPT_NAME.sh verify alice -- /usr/sbin/nginx -t
    sudo ./$SCRIPT_NAME.sh list
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
        setup|help|--help|-h|--version) ;;
        add|key)        require_deps ssh-keygen openssl useradd chpasswd install ;;
        sudo-add|sudo-del)
                        require_deps visudo sudo groupadd realpath stat flock ;;
        sudo-grant|sudo-revoke)
                        require_deps sudo usermod gpasswd getent ;;
        *)              require_deps getent ;;
    esac

    case "$cmd" in
        setup)          cmd_setup "$@" ;;
        harden-ssh)     cmd_harden_ssh "$@" ;;
        add)            cmd_add "$@" ;;
        delete)         cmd_delete "$@" ;;
        passwd)         cmd_passwd "$@" ;;
        key)            cmd_key "$@" ;;
        list)           cmd_list "$@" ;;
        sudo-add)       cmd_sudo_add "$@" ;;
        sudo-del)       cmd_sudo_del "$@" ;;
        sudo-grant)     cmd_sudo_grant "$@" ;;
        sudo-revoke)    cmd_sudo_revoke "$@" ;;
        verify)         cmd_verify "$@" ;;
        help|--help|-h) usage ;;
        --version)      echo "$SCRIPT_NAME $SCRIPT_VERSION" ;;
        *)              log_msg ERROR "Unknown command: $cmd"; usage; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
