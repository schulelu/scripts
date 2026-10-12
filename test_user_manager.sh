#!/usr/bin/env bash
# Self-check for user-manager.sh name validation, sudoers rendering, and the
# command-grant security rules. No root, no system changes — every function
# tested here is pure or read-only.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# main() is guarded in user-manager.sh, so sourcing only loads the functions.
source ./user-manager.sh
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

# --- name mapping ---
check "cap group name"    "sudogrp-nginx"   "$(cap_group nginx)"
check "cap file path"     "/etc/sudoers.d/sudogrp-nginx" "$(cap_file nginx)"
check "sudoers name: real cap file ok (dir has a dot)" "0" "$(sudoers_name_ok "$(cap_file shared-svc)"; echo $?)"
check "sudoers name: dotted file refused"            "1" "$(sudoers_name_ok /etc/sudoers.d/x.conf; echo $?)"
check "sudoers name: backup~ refused"                "1" "$(sudoers_name_ok /etc/sudoers.d/x~; echo $?)"
check "cap alias"         "SUDOGRP_NGINX"   "$(cap_alias nginx)"
check "alias maps - to _" "SUDOGRP_WEB_TLS" "$(cap_alias web-tls)"

# --- capability name validation ---
( validate_cap_name "web" ) >/dev/null 2>&1;      check "plain name accepted"    "0" "$?"
( validate_cap_name "web-tls" ) >/dev/null 2>&1;  check "hyphen accepted"        "0" "$?"
# A '.' would make @includedir silently skip the file: grant exists, does nothing.
( validate_cap_name "web.tls" ) >/dev/null 2>&1;  check "dot rejected"           "1" "$?"
# '_' would let web-tls and web_tls both map to SUDOGRP_WEB_TLS — a duplicate
# Cmnd_Alias, which is a syntax error that breaks sudo system-wide.
( validate_cap_name "web_tls" ) >/dev/null 2>&1;  check "underscore rejected"    "1" "$?"
( validate_cap_name "Web" ) >/dev/null 2>&1;      check "uppercase rejected"     "1" "$?"
( validate_cap_name "web-" ) >/dev/null 2>&1;     check "trailing hyphen reject" "1" "$?"
( validate_cap_name "web--tls" ) >/dev/null 2>&1; check "double hyphen rejected" "1" "$?"
( validate_cap_name "9web" ) >/dev/null 2>&1;     check "leading digit rejected" "1" "$?"

# --- argument validation ---
( validate_arg "-t" ) >/dev/null 2>&1;            check "plain flag accepted"    "0" "$?"
# sudoers wildcards match whitespace, so 'cat /var/log/messages*' also permits
# 'cat /var/log/messages /etc/shadow'.
( validate_arg "*" ) >/dev/null 2>&1;             check "glob rejected"          "1" "$?"
( validate_arg "a,b" ) >/dev/null 2>&1;           check "comma rejected"         "1" "$?"
( validate_arg 'a#b' ) >/dev/null 2>&1;           check "hash rejected"          "1" "$?"
( validate_arg 'a=b' ) >/dev/null 2>&1;           check "equals rejected"        "1" "$?"
( validate_arg '^-t$' ) >/dev/null 2>&1;          check "regex form rejected"    "1" "$?"

# --- render / parse round trip ---
one="$(render_cap_file demo false "/usr/bin/true --flag")"
check "one command round-trips"  "/usr/bin/true --flag" \
      "$(printf '%s\n' "$one" > /tmp/.um_test_one; cap_read_commands /tmp/.um_test_one)"

three="$(render_cap_file demo false "/usr/bin/a 1" "/usr/bin/b 2" "/usr/bin/c 3")"
printf '%s\n' "$three" > /tmp/.um_test_three
check "three commands round-trip" $'/usr/bin/a 1\n/usr/bin/b 2\n/usr/bin/c 3' \
      "$(cap_read_commands /tmp/.um_test_three)"

# An empty "Cmnd_Alias X =" is a syntax error, so a command-less capability must
# render as comments only.
empty="$(render_cap_file demo false)"
check "empty cap emits no alias" "0" "$(grep -c '^Cmnd_Alias' <<<"$empty" | tr -d ' ')"

check "NOEXEC on by default"  "1" "$(grep -c 'ALL=(root) NOEXEC:PASSWD:' <<<"$one" | tr -d ' ')"
check "--allow-exec drops it" "0" \
      "$(grep -c 'NOEXEC' <<<"$(render_cap_file demo true '/usr/bin/true --flag')" | tr -d ' ')"
# Ubuntu builds sudo with --with-timeout=15; without this the password is asked
# once per 15 minutes, which defeats its purpose here.
check "cache disabled"        "1" "$(grep -c 'timestamp_timeout=0' <<<"$one" | tr -d ' ')"
check "never NOPASSWD"        "0" "$(grep -c 'NOPASSWD' <<<"$one" | tr -d ' ')"
check "allow-exec still asks for password" "1" \
      "$(grep -c 'ALL=(root) PASSWD:' <<<"$(render_cap_file demo true '/usr/bin/true --flag')" | tr -d ' ')"

# render(parse(render(x))) == render(x): the file is the only source of truth,
# so an unchanged capability must re-render byte-identically and skip the write.
mapfile -t _rt < <(cap_read_commands /tmp/.um_test_three)
check "render/parse/render is stable" "$three" "$(render_cap_file demo false "${_rt[@]}")"

rm -f /tmp/.um_test_one /tmp/.um_test_three

# --- path safety ---
path_is_root_safe /usr/bin/true >/dev/null 2>&1
check "root-owned path is safe" "0" "$?"
path_is_root_safe "$HOME" >/dev/null 2>&1
check "user-owned path unsafe"  "1" "$?"

# --- command grant rules ---
out="$(validate_command "usr/bin/true --flag" false 2>/dev/null)"
check "relative path rejected"   "1" "$?"
out="$(validate_command "/usr/bin/true --flag" false 2>/dev/null)"
check "good grant accepted"      "0" "$?"
check "  ...canonical returned"  "/usr/bin/true --flag" "$out"
check "  ...no log leaked to stdout" "1" "$(wc -l <<<"$out" | tr -d ' ')"

# A bare path permits ANY arguments — sudoers(5) says so explicitly.
out="$(validate_command "/usr/bin/true" false 2>/dev/null)"
check "bare path rejected"       "1" "$?"
out="$(validate_command "/usr/bin/true" true 2>/dev/null)"
check "bare path allowed w/force" "0" "$?"

# Tier 1: unsafe even with pinned arguments.
out="$(validate_command "/usr/bin/find /tmp -name x" false 2>/dev/null)"
check "find refused"             "1" "$?"
out="$(validate_command "/usr/bin/find /tmp -name x" true 2>/dev/null)"
check "find refused even w/force" "1" "$?"
out="$(validate_command "$(command -v tar) -tf /tmp/x" false 2>/dev/null)"
check "tar refused"              "1" "$?"
out="$(validate_command "/usr/bin/tee /tmp/x" false 2>/dev/null)"
check "tee refused (root write)" "1" "$?"

# Wildcards and metacharacters in arguments.
out="$(validate_command "/usr/bin/true *" false 2>/dev/null)"
check "wildcard arg refused"     "1" "$?"

# Shares are overridable per run; the default is "shared".
check "default share user"       "shared" "$SHARED_USER"
check "share override"           "shared-dev /home/shared-dev" \
      "$(UM_SHARED_USER=shared-dev UM_SHARED_DIR=/home/shared-dev bash -c 'source ./user-manager.sh; echo "$SHARED_USER $SHARED_DIR"')"

# passwd/key only touch accounts this script manages — never root. check_root is
# stubbed so the managed-user check is reached; it dies before any change.
out="$( (check_root() { :; }; cmd_passwd root) 2>&1 )"
check "passwd refuses root"      "1" "$(grep -c 'is not in group' <<< "$out")"
out="$( (check_root() { :; }; cmd_key root /dev/null) 2>&1 )"
check "key refuses root"         "1" "$(grep -c 'is not in group' <<< "$out")"
out="$( (check_root() { :; }; cmd_setup --bogus) 2>&1 )"
check "setup rejects unknown flag" "1" "$(grep -c 'Unknown option' <<< "$out")"

echo "----"
if [[ $fail -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $fail
