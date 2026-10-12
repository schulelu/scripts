#!/usr/bin/env bash
# Self-check for mount-manager.sh target parsing, option building, and fstab
# rendering/removal. No root, no system changes — every function tested here is
# pure or operates on a temp file.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# main() is guarded in mount-manager.sh, so sourcing only loads the functions.
source ./mount-manager.sh
set +e   # allow negative tests (non-zero returns) without aborting

fail=0
check() {
    local desc="$1" expected="$2" got="$3"
    if [[ "$got" == "$expected" ]]; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc — expected [$expected], got [$got]"
        fail=1
    fi
}

# --- target parsing ---
check "target splits"        "app storage.example /srv/data" "$(parse_target app@storage.example:/srv/data)"
check "remote path with dir" "u h /mnt/bigdisk"              "$(parse_target u@h:/mnt/bigdisk)"
check "user with dot/dash"   "app-1.x h /d"                  "$(parse_target app-1.x@h:/d)"

( parse_target "app@host/srv" ) >/dev/null 2>&1;   check "missing colon rejected"   "1" "$?"
( parse_target "host:/srv" ) >/dev/null 2>&1;      check "missing user rejected"    "1" "$?"
( parse_target "@host:/srv" ) >/dev/null 2>&1;     check "empty user rejected"      "1" "$?"
( parse_target "app@:/srv" ) >/dev/null 2>&1;      check "empty host rejected"      "1" "$?"
# A relative remote path is resolved against the SSH user's home by sshfs, which
# silently mounts somewhere other than where the caller thinks.
( parse_target "app@host:srv" ) >/dev/null 2>&1;   check "relative path rejected"   "1" "$?"
# fstab splits fields on whitespace — an unescaped space would corrupt the table.
( parse_target "app@host:/sr v" ) >/dev/null 2>&1; check "whitespace rejected"      "1" "$?"

# --- mountpoint validation ---
check "trailing slash stripped" "/mnt/data" "$(validate_mountpoint /mnt/data/)"
( validate_mountpoint "mnt/data" ) >/dev/null 2>&1;  check "relative mp rejected"   "1" "$?"
( validate_mountpoint "/mnt/da ta" ) >/dev/null 2>&1; check "mp whitespace rejected" "1" "$?"
( validate_mountpoint "/" ) >/dev/null 2>&1;          check "root mp rejected"       "1" "$?"

# --- option building ---
opts="$(build_opts /root/.ssh/k 22 1000 1000 false false false)"
check "key in options"        "1" "$(grep -c 'IdentityFile=/root/.ssh/k' <<<"$opts")"
check "uid/gid in options"    "1" "$(grep -c 'uid=1000,gid=1000' <<<"$opts")"
check "allow_other by default" "0" "$(opts_have "$opts" allow_other; echo $?)"
check "not read-only"          "1" "$(opts_have "$opts" ro; echo $?)"
# 'reconnect' alone never notices a link that died without an RST.
check "keepalive present"      "0" "$(opts_have "$opts" ServerAliveInterval=15; echo $?)"
# A temporary mount must not carry fstab-only options — mount(8) would reject them.
check "no fstab opts on mount" "1" "$(opts_have "$opts" x-systemd.automount; echo $?)"

ro_opts="$(build_opts /k 22 0 0 true false false)"
check "--ro adds ro"           "0" "$(opts_have "$ro_opts" ro; echo $?)"
priv_opts="$(build_opts /k 22 0 0 false true false)"
check "--private drops allow_other" "1" "$(opts_have "$priv_opts" allow_other; echo $?)"
fstab_opts="$(build_opts /k 2222 0 0 false false true)"
check "fstab gets automount"   "0" "$(opts_have "$fstab_opts" x-systemd.automount; echo $?)"
check "fstab gets _netdev"     "0" "$(opts_have "$fstab_opts" _netdev; echo $?)"
check "port honoured"          "0" "$(opts_have "$fstab_opts" Port=2222; echo $?)"
# opts_have must match whole options: 'ro' is a substring of 'reconnect'.
check "opts_have is exact"     "1" "$(opts_have "reconnect,uid=0" ro; echo $?)"

# --- fstab render / parse / remove round trip ---
tmp=$(mktemp)
cat > "$tmp" <<'EOF'
UUID=1111 / ext4 defaults 0 1
UUID=2222 /boot ext4 defaults 0 2
EOF
original="$(cat "$tmp")"

{ cat "$tmp"; render_fstab_line "app@storage:/srv/data" "/mnt/data" "$fstab_opts"; } > "$tmp.new"
check "entry parsed back" "app@storage:/srv/data	/mnt/data	$fstab_opts" "$(fstab_managed_entries "$tmp.new")"
check "add then remove restores original" "$original" "$(fstab_remove "$tmp.new" /mnt/data)"

# Two managed entries: removing one must leave the other and its marker intact.
{ cat "$tmp.new"; render_fstab_line "app@storage:/srv/logs" "/mnt/logs" "$fstab_opts"; } > "$tmp.two"
check "two entries listed" "2" "$(fstab_managed_entries "$tmp.two" | wc -l | tr -d ' ')"
check "removing one keeps the other" "app@storage:/srv/logs	/mnt/logs	$fstab_opts" \
      "$(fstab_remove "$tmp.two" /mnt/data > "$tmp.one"; fstab_managed_entries "$tmp.one")"
check "marker not orphaned" "1" "$(grep -c "$MARKER_KEY" "$tmp.one" | tr -d ' ')"

# Mountpoint matching is exact: /mnt/data must not take /mnt/data-old with it.
{ cat "$tmp.new"; render_fstab_line "app@storage:/srv/old" "/mnt/data-old" "$fstab_opts"; } > "$tmp.pfx"
check "prefix mountpoint survives" "app@storage:/srv/old	/mnt/data-old	$fstab_opts" \
      "$(fstab_remove "$tmp.pfx" /mnt/data > "$tmp.pfx2"; fstab_managed_entries "$tmp.pfx2")"

# Removing something we never added is a no-op, not a mangled table.
check "removing absent mp is a no-op" "$original" "$(fstab_remove "$tmp" /mnt/nothing)"

rm -f "$tmp" "$tmp.new" "$tmp.two" "$tmp.one" "$tmp.pfx" "$tmp.pfx2"

# --- bad input aborts the command, not just the subshell ---
# die() inside $( ) exits only the subshell, so a caller that reads a parsed
# value out of a command substitution must check the status explicitly or it
# carries on with empty variables. Exit status alone would not prove that (the
# run fails later anyway), so assert the side effect: a rejected target must
# never reach preflight, which is what creates the mountpoint directory.
fakekey=$(mktemp)
nodir="${TMPDIR:-/tmp}/mm-must-not-exist-$$"
( check_root() { :; }; require_deps() { :; }; sshfs() { :; }
  cmd_mount "app@host:relative" "$nodir" --key "$fakekey" ) >/dev/null 2>&1
check "bad target aborts before mkdir"     "1" "$?"
check "  ...mountpoint not created"        "absent" "$([[ -e $nodir ]] && echo present || echo absent)"

( check_root() { :; }; require_deps() { :; }; sshfs() { :; }
  cmd_mount "app@host:/srv" "relative/path" --key "$fakekey" ) >/dev/null 2>&1
check "bad mountpoint aborts"              "1" "$?"

( check_root() { :; }; require_deps() { :; }; acquire_lock() { :; }
  cmd_add "nouser-host" "$nodir" --key "$fakekey" ) >/dev/null 2>&1
check "cmd_add aborts on bad target"       "1" "$?"
check "  ...mountpoint still not created"  "absent" "$([[ -e $nodir ]] && echo present || echo absent)"
rm -f "$fakekey"

echo "----"
if [[ $fail -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $fail
