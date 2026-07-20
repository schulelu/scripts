#!/usr/bin/env bash
# Self-check for kvm-manager GPU selector parsing (resolve_gpu_selector).
# No hardware needed — gpu_enumerate is stubbed with a fixed GPU list.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# main() is guarded in kvm-manager.sh, so sourcing only loads the functions.
source ./kvm-manager.sh
set +e   # allow negative tests (non-zero returns) without aborting

# Stub hardware enumeration with three known GPU heads
gpu_enumerate() { printf '%s\n' "01:00.0" "02:00.0" "03:00.0"; }

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

check "index 0 -> first GPU"        "01:00.0"          "$(resolve_gpu_selector 0)"
check "index 2 -> third GPU"        "03:00.0"          "$(resolve_gpu_selector 2)"
check "valid BDF passes through"    "02:00.0"          "$(resolve_gpu_selector 02:00.0)"
check "domain-prefixed BDF norm'd"  "02:00.0"          "$(resolve_gpu_selector 0000:02:00.0)"
check "comma list of indices"       $'01:00.0\n03:00.0' "$(resolve_gpu_selector 0,2)"
check "mixed index + BDF"           $'02:00.0\n03:00.0' "$(resolve_gpu_selector 1,03:00.0)"

# Negative cases: non-zero exit and no stdout
out=$(resolve_gpu_selector 9 2>/dev/null);        check "index out of range -> rc1" "1" "$?"
check "  ...and no output"          ""                 "$out"
out=$(resolve_gpu_selector 09:00.0 2>/dev/null);  check "unknown BDF -> rc1"        "1" "$?"
out=$(resolve_gpu_selector foo 2>/dev/null);      check "garbage -> rc1"            "1" "$?"

echo "----"
if [[ $fail -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit $fail
