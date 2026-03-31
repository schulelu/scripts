#!/usr/bin/env bash
#
# desktop-lag-doctor.sh — Diagnose and fix micro-lags on Linux desktops
#
# Usage: desktop-lag-doctor.sh [OPTIONS] [COMMAND]
#
# Commands:
#   diagnose    Run all diagnostic checks (prompts to fix interactively)
#   fix         Apply all safe performance tuning at once (respects --dry-run)
#   monitor     Live monitoring loop for lag sources
#   rollback    Restore previous settings from a saved snapshot
#
# Options:
#   -d, --dry-run     Show what fix would do without applying
#   -v, --verbose     Enable verbose/debug output
#   -q, --quiet       Suppress non-error output
#   -y, --yes         Auto-confirm all fix prompts (non-interactive)
#       --json        Machine-readable JSON output
#   -h, --help        Show this help message
#       --version     Show version information
#
# Environment:
#   LOG_LEVEL         Log level: DEBUG, INFO, WARN, ERROR (default: INFO)
#
# Author:  Lukas / Script & Automation Engineer
# Version: 1.1.0
# Date:    2026-03-14

set -euo pipefail
IFS=$'\n\t'

# --- Constants ---
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="1.1.0"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
readonly STATE_DIR="${HOME}/.config/lag-doctor"
readonly ROLLBACK_DIR="${STATE_DIR}/rollback"

# --- Color Support ---
if [[ -t 1 ]]; then
    readonly C_RED=$'\033[1;31m'
    readonly C_YEL=$'\033[1;33m'
    readonly C_GRN=$'\033[1;32m'
    readonly C_CYN=$'\033[1;36m'
    readonly C_BLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RST=$'\033[0m'
else
    readonly C_RED='' C_YEL='' C_GRN='' C_CYN='' C_BLD='' C_DIM='' C_RST=''
fi

# --- Defaults ---
DRY_RUN=false
VERBOSE=false
QUIET=false
JSON_OUTPUT=false
AUTO_YES=false
LOG_LEVEL="${LOG_LEVEL:-INFO}"
COMMAND="diagnose"

# --- Result Storage ---
declare -a CHECK_NAMES=()
declare -a CHECK_STATUSES=()
declare -a CHECK_DETAILS=()
declare -a CHECK_FIXES=()
declare -a JSON_RESULTS=()

# Current rollback snapshot file (created on first fix in a session)
SNAPSHOT_FILE=""
SNAPSHOT_STARTED=false
INTERACTIVE_FIX_COUNT=0

# --- Logging ---
log() {
    local level="$1"; shift
    local level_num
    case "$level" in
        DEBUG) level_num=0 ;; INFO) level_num=1 ;;
        WARN)  level_num=2 ;; ERROR) level_num=3 ;; *) level_num=1 ;;
    esac

    local current_level_num
    case "$LOG_LEVEL" in
        DEBUG) current_level_num=0 ;; INFO) current_level_num=1 ;;
        WARN)  current_level_num=2 ;; ERROR) current_level_num=3 ;; *) current_level_num=1 ;;
    esac

    if (( level_num >= current_level_num )); then
        local timestamp
        timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '%s [%-5s] %s: %s\n' "$timestamp" "$level" "$SCRIPT_NAME" "$*" >&2
    fi
}

die() { log ERROR "$@"; exit 1; }

# --- Cleanup ---
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    if [[ -n "${START_TIME:-}" ]]; then
        local end_time
        end_time="$(date +%s)"
        log DEBUG "Finished with exit code $exit_code (duration: $(( end_time - START_TIME ))s)"
    fi
    # Re-enable cursor if monitor mode hid it
    [[ "${CURSOR_HIDDEN:-}" == "true" ]] && printf '\033[?25h' 2>/dev/null
    exit "$exit_code"
}
trap cleanup EXIT
trap 'die "Received SIGINT"' INT
trap 'die "Received SIGTERM"' TERM

# --- Argument Parsing ---
usage() {
    sed -n '3,/^[^#]/{ /^#/s/^# \{0,1\}//p; }' "$0" >&2
    exit 2
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -d|--dry-run)  DRY_RUN=true ;;
            -v|--verbose)  VERBOSE=true; LOG_LEVEL="DEBUG" ;;
            -q|--quiet)    QUIET=true; LOG_LEVEL="ERROR" ;;
            -y|--yes)      AUTO_YES=true ;;
            --json)        JSON_OUTPUT=true ;;
            -h|--help)     usage ;;
            --version)     echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            --)            shift; break ;;
            -*)            die "Unknown option: $1 (use --help for usage)" ;;
            *)             break ;;
        esac
        shift
    done

    if (( $# >= 1 )); then
        COMMAND="$1"
        shift
    fi

    case "$COMMAND" in
        diagnose|fix|monitor|rollback) ;;
        *) die "Unknown command: $COMMAND (use diagnose, fix, monitor, or rollback)" ;;
    esac
}

# --- Locking ---
acquire_lock() {
    if ! (set -o noclobber; echo $$ > "$LOCK_FILE") 2>/dev/null; then
        local existing_pid
        existing_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")"
        die "Another instance is running (PID: $existing_pid, lock: $LOCK_FILE)"
    fi
}

# --- Helper Functions ---

# Read a value from a file, return empty string if not readable
read_sysfs() {
    local path="$1"
    if [[ -r "$path" ]]; then
        cat "$path" 2>/dev/null || true
    fi
}

# Get a sysctl value
get_sysctl() {
    local key="$1"
    sysctl -n "$key" 2>/dev/null || echo ""
}

# Parse /proc/meminfo value in kB
get_meminfo() {
    local key="$1"
    awk -v k="$key" '$1 == k":" { print $2 }' /proc/meminfo 2>/dev/null || echo "0"
}

# =====================================================================
# ROLLBACK STATE MANAGEMENT
# =====================================================================

# Initialize rollback snapshot for this session
init_snapshot() {
    if [[ "$SNAPSHOT_STARTED" == true ]]; then
        return
    fi
    mkdir -p "$ROLLBACK_DIR"
    SNAPSHOT_FILE="${ROLLBACK_DIR}/$(date '+%Y%m%d-%H%M%S').snapshot"
    {
        echo "# Lag Doctor rollback snapshot"
        echo "# Created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "# Kernel: $(uname -r)"
        echo "# Host: $(hostname)"
        echo ""
    } > "$SNAPSHOT_FILE"
    SNAPSHOT_STARTED=true
    log DEBUG "Rollback snapshot: $SNAPSHOT_FILE"
}

# Save a setting's current value before changing it
# Usage: save_state "type" "key" "current_value" "description"
#   type: sysctl | sysfs | file | service
save_state() {
    local type="$1" key="$2" value="$3" desc="${4:-}"
    init_snapshot
    printf '%s|%s|%s|%s\n' "$type" "$key" "$value" "$desc" >> "$SNAPSHOT_FILE"
    log DEBUG "Saved state: $type $key=$value"
}

# =====================================================================
# INTERACTIVE FIX PROMPT
# =====================================================================

# Ask user whether to apply a fix. Returns 0 if yes, 1 if no.
ask_fix() {
    local _check_name="$1"  # used for logging context
    log DEBUG "Fix prompt for: $_check_name"

    # Skip prompt in non-interactive modes
    if [[ "$JSON_OUTPUT" == true || "$QUIET" == true ]]; then
        return 1
    fi
    if [[ "$AUTO_YES" == true ]]; then
        return 0
    fi
    # Need a terminal for interactive prompts
    if [[ ! -t 0 ]]; then
        return 1
    fi

    local answer
    printf '       %s→ Fix now? [y/N]:%s ' "$C_CYN" "$C_RST"
    read -r answer </dev/tty
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# =====================================================================
# INDIVIDUAL FIX FUNCTIONS (used by both diagnose and fix commands)
# =====================================================================

fix_swappiness() {
    local current
    current=$(get_sysctl vm.swappiness)
    if [[ -z "$current" ]] || (( current <= 10 )); then
        return 1  # nothing to fix
    fi
    save_state "sysctl" "vm.swappiness" "$current" "Swappiness"
    if [[ "$DRY_RUN" == true ]]; then
        printf '       %s[DRY RUN] Would set vm.swappiness: %s → 10%s\n' "$C_DIM" "$current" "$C_RST"
    else
        sudo sysctl -w vm.swappiness=10 >/dev/null 2>&1
        printf '       %s✓ Applied: vm.swappiness: %s → 10%s\n' "$C_GRN" "$current" "$C_RST"
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

fix_thp() {
    local thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
    [[ -r "$thp_file" ]] || return 1
    local current
    current=$(grep -oP '\[\K[^\]]+' "$thp_file")
    [[ "$current" == "always" ]] || return 1
    save_state "sysfs" "$thp_file" "$current" "Transparent Huge Pages"
    if [[ "$DRY_RUN" == true ]]; then
        printf '       %s[DRY RUN] Would set THP: %s → madvise%s\n' "$C_DIM" "$current" "$C_RST"
    else
        echo madvise | sudo tee "$thp_file" >/dev/null 2>&1
        printf '       %s✓ Applied: THP: %s → madvise%s\n' "$C_GRN" "$current" "$C_RST"
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

fix_compaction() {
    local current
    current=$(get_sysctl vm.compaction_proactiveness)
    if [[ -z "$current" ]] || (( current <= 0 )); then
        return 1
    fi
    save_state "sysctl" "vm.compaction_proactiveness" "$current" "Proactive compaction"
    if [[ "$DRY_RUN" == true ]]; then
        printf '       %s[DRY RUN] Would set vm.compaction_proactiveness: %s → 0%s\n' "$C_DIM" "$current" "$C_RST"
    else
        sudo sysctl -w vm.compaction_proactiveness=0 >/dev/null 2>&1
        printf '       %s✓ Applied: vm.compaction_proactiveness: %s → 0%s\n' "$C_GRN" "$current" "$C_RST"
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

fix_dirty_bg_ratio() {
    local current
    current=$(get_sysctl vm.dirty_background_ratio)
    if [[ -z "$current" ]] || (( current <= 5 )); then
        return 1
    fi
    save_state "sysctl" "vm.dirty_background_ratio" "$current" "Dirty background ratio"
    if [[ "$DRY_RUN" == true ]]; then
        printf '       %s[DRY RUN] Would set vm.dirty_background_ratio: %s → 5%s\n' "$C_DIM" "$current" "$C_RST"
    else
        sudo sysctl -w vm.dirty_background_ratio=5 >/dev/null 2>&1
        printf '       %s✓ Applied: vm.dirty_background_ratio: %s → 5%s\n' "$C_GRN" "$current" "$C_RST"
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

fix_dirty_ratio() {
    local current
    current=$(get_sysctl vm.dirty_ratio)
    if [[ -z "$current" ]] || (( current <= 15 )); then
        return 1
    fi
    save_state "sysctl" "vm.dirty_ratio" "$current" "Dirty ratio"
    if [[ "$DRY_RUN" == true ]]; then
        printf '       %s[DRY RUN] Would set vm.dirty_ratio: %s → 15%s\n' "$C_DIM" "$current" "$C_RST"
    else
        sudo sysctl -w vm.dirty_ratio=15 >/dev/null 2>&1
        printf '       %s✓ Applied: vm.dirty_ratio: %s → 15%s\n' "$C_GRN" "$current" "$C_RST"
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

fix_journal_vacuum() {
    if ! command -v journalctl &>/dev/null; then
        return 1
    fi
    local usage_str
    usage_str=$(journalctl --disk-usage 2>/dev/null | grep -oP '[0-9.]+[KMGT]' | head -1 || echo "0M")
    save_state "service" "journald-vacuum" "$usage_str" "Journal disk usage before vacuum"
    if [[ "$DRY_RUN" == true ]]; then
        printf '       %s[DRY RUN] Would vacuum journal from %s to 500M%s\n' "$C_DIM" "$usage_str" "$C_RST"
    else
        sudo journalctl --vacuum-size=500M >/dev/null 2>&1
        printf '       %s✓ Applied: journalctl --vacuum-size=500M (was %s)%s\n' "$C_GRN" "$usage_str" "$C_RST"
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

fix_journal_cap() {
    local journal_conf="/etc/systemd/journald.conf"
    [[ -r "$journal_conf" ]] || return 1
    if grep -q '^SystemMaxUse=' "$journal_conf" 2>/dev/null; then
        return 1  # already configured
    fi
    save_state "file" "$journal_conf" "NO_SystemMaxUse" "Journald max usage cap"
    if [[ "$DRY_RUN" == true ]]; then
        printf '       %s[DRY RUN] Would add SystemMaxUse=500M to %s%s\n' "$C_DIM" "$journal_conf" "$C_RST"
    else
        echo -e '\n# Added by desktop-lag-doctor\nSystemMaxUse=500M' | sudo tee -a "$journal_conf" >/dev/null
        sudo systemctl restart systemd-journald 2>/dev/null || true
        printf '       %s✓ Applied: SystemMaxUse=500M in %s%s\n' "$C_GRN" "$journal_conf" "$C_RST"
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

fix_cpu_governor() {
    local gov_file="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
    [[ -r "$gov_file" ]] || return 1
    local current
    current=$(cat "$gov_file")
    [[ "$current" == "powersave" ]] || return 1
    save_state "sysfs" "/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor" "$current" "CPU governor"
    if [[ "$DRY_RUN" == true ]]; then
        printf '       %s[DRY RUN] Would set governor: %s → performance%s\n' "$C_DIM" "$current" "$C_RST"
    else
        echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1
        printf '       %s✓ Applied: governor: %s → performance%s\n' "$C_GRN" "$current" "$C_RST"
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

fix_cpu_boost() {
    local boost_file="/sys/devices/system/cpu/cpufreq/boost"
    [[ -r "$boost_file" ]] || return 1
    local current
    current=$(cat "$boost_file")
    [[ "$current" == "0" ]] || return 1
    save_state "sysfs" "$boost_file" "$current" "CPU boost"
    if [[ "$DRY_RUN" == true ]]; then
        printf '       %s[DRY RUN] Would enable CPU boost%s\n' "$C_DIM" "$C_RST"
    else
        echo 1 | sudo tee "$boost_file" >/dev/null 2>&1
        printf '       %s✓ Applied: CPU boost enabled%s\n' "$C_GRN" "$C_RST"
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

fix_io_scheduler() {
    local dev="$1"
    local blk_dir="/sys/block/${dev}/"
    [[ -r "${blk_dir}queue/scheduler" ]] || return 1
    local current
    current=$(grep -oP '\[\K[^\]]+' "${blk_dir}queue/scheduler" || echo "?")
    [[ "$current" =~ ^(cfq|bfq)$ ]] || return 1
    save_state "sysfs" "${blk_dir}queue/scheduler" "$current" "I/O scheduler for $dev"
    if [[ "$DRY_RUN" == true ]]; then
        printf '       %s[DRY RUN] Would set %s scheduler: %s → mq-deadline%s\n' "$C_DIM" "$dev" "$current" "$C_RST"
    else
        echo mq-deadline | sudo tee "${blk_dir}queue/scheduler" >/dev/null 2>&1
        printf '       %s✓ Applied: %s scheduler: %s → mq-deadline%s\n' "$C_GRN" "$dev" "$current" "$C_RST"
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

fix_mask_avahi() {
    local avahi_active
    avahi_active=$(systemctl is-active avahi-daemon 2>/dev/null || echo "inactive")
    [[ "$avahi_active" == "active" ]] || return 1
    save_state "service" "avahi-daemon" "active" "Avahi daemon state"
    if [[ "$DRY_RUN" == true ]]; then
        printf '       %s[DRY RUN] Would mask avahi-daemon%s\n' "$C_DIM" "$C_RST"
    else
        sudo systemctl stop avahi-daemon 2>/dev/null || true
        sudo systemctl mask avahi-daemon 2>/dev/null || true
        printf '       %s✓ Applied: avahi-daemon stopped and masked%s\n' "$C_GRN" "$C_RST"
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

fix_disable_baloo() {
    if command -v balooctl6 &>/dev/null; then
        save_state "service" "baloo" "enabled" "Baloo file indexer"
        if [[ "$DRY_RUN" == true ]]; then
            printf '       %s[DRY RUN] Would disable baloo%s\n' "$C_DIM" "$C_RST"
        else
            balooctl6 disable 2>/dev/null || balooctl disable 2>/dev/null || true
            printf '       %s✓ Applied: baloo disabled%s\n' "$C_GRN" "$C_RST"
        fi
    elif command -v balooctl &>/dev/null; then
        save_state "service" "baloo" "enabled" "Baloo file indexer"
        if [[ "$DRY_RUN" == true ]]; then
            printf '       %s[DRY RUN] Would disable baloo%s\n' "$C_DIM" "$C_RST"
        else
            balooctl disable 2>/dev/null || true
            printf '       %s✓ Applied: baloo disabled%s\n' "$C_GRN" "$C_RST"
        fi
    else
        return 1
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

fix_mask_tracker() {
    save_state "service" "tracker-miner-fs-3" "active" "GNOME Tracker miner"
    if [[ "$DRY_RUN" == true ]]; then
        printf '       %s[DRY RUN] Would mask tracker-miner-fs-3%s\n' "$C_DIM" "$C_RST"
    else
        systemctl --user mask tracker-miner-fs-3.service 2>/dev/null || true
        systemctl --user stop tracker-miner-fs-3.service 2>/dev/null || true
        printf '       %s✓ Applied: tracker-miner-fs-3 masked%s\n' "$C_GRN" "$C_RST"
    fi
    (( INTERACTIVE_FIX_COUNT++ ))
    return 0
}

# Generate persistent sysctl config from current snapshot
persist_sysctl_fixes() {
    [[ "$SNAPSHOT_STARTED" == true && -f "$SNAPSHOT_FILE" ]] || return 0
    local sysctl_entries
    sysctl_entries=$(grep '^sysctl|' "$SNAPSHOT_FILE" 2>/dev/null || true)
    [[ -n "$sysctl_entries" ]] || return 0

    local sysctl_conf="/etc/sysctl.d/99-lag-doctor.conf"
    printf '\n  %sPersistent sysctl config → %s%s\n' "$C_CYN" "$sysctl_conf" "$C_RST"

    local lines=()
    while IFS='|' read -r _ key _ _; do
        local new_val
        new_val=$(get_sysctl "$key")
        lines+=("$key = $new_val")
        printf '    %s\n' "$key = $new_val"
    done <<< "$sysctl_entries"

    if [[ "$DRY_RUN" != true ]] && (( ${#lines[@]} > 0 )); then
        {
            echo "# Generated by desktop-lag-doctor.sh v${SCRIPT_VERSION} on $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            echo "# Safe desktop performance tuning — revert with: $SCRIPT_NAME rollback"
            for line in "${lines[@]}"; do
                echo "$line"
            done
        } | sudo tee "$sysctl_conf" >/dev/null
    fi
}

# Record a check result
record_result() {
    local name="$1" status="$2" details="$3" fix="${4:-}"
    CHECK_NAMES+=("$name")
    CHECK_STATUSES+=("$status")
    CHECK_DETAILS+=("$details")
    CHECK_FIXES+=("$fix")

    if [[ "$JSON_OUTPUT" == true ]]; then
        local fix_json=""
        if [[ -n "$fix" ]]; then
            fix_json=$(printf '%s' "$fix" | sed 's/"/\\"/g; s/\t/\\t/g')
        fi
        local det_json
        det_json=$(printf '%s' "$details" | sed 's/"/\\"/g; s/\t/\\t/g')
        JSON_RESULTS+=("{\"check\":\"$name\",\"status\":\"$status\",\"details\":\"$det_json\",\"fix\":\"$fix_json\"}")
    fi

    if [[ "$QUIET" == true && "$status" == "OK" ]]; then
        return
    fi

    local color="$C_GRN"
    local icon="✓"
    case "$status" in
        WARN)     color="$C_YEL"; icon="⚠" ;;
        CRITICAL) color="$C_RED"; icon="✗" ;;
    esac

    if [[ "$JSON_OUTPUT" != true ]]; then
        printf '  %s[%s]%s %-22s %s\n' "$color" "$icon" "$C_RST" "$name" "$details"
        if [[ -n "$fix" && "$status" != "OK" ]]; then
            printf '       %s→ Fix: %s%s\n' "$C_DIM" "$fix" "$C_RST"
        fi
    fi
}

# Print a section header
section() {
    [[ "$JSON_OUTPUT" == true ]] && return
    printf '\n%s━━━ %s ━━━%s\n' "$C_BLD" "$1" "$C_RST"
}

# =====================================================================
# DIAGNOSTIC CHECKS (with interactive fix support)
# =====================================================================

check_memory_thp() {
    local details="" status="OK" fix="" fix_id=""

    # Swap usage
    local swap_total swap_free swap_pct
    swap_total=$(get_meminfo SwapTotal)
    swap_free=$(get_meminfo SwapFree)

    if (( swap_total > 0 )); then
        swap_pct=$(( (swap_total - swap_free) * 100 / swap_total ))
    else
        swap_pct=0
    fi

    if (( swap_pct > 70 )); then
        status="CRITICAL"
        fix="Increase RAM or reduce memory usage; check for leaking processes"
    elif (( swap_pct > 30 )); then
        status="WARN"
        fix="sysctl vm.swappiness=10"
        fix_id="swappiness"
    fi
    details="swap=${swap_pct}%"

    # THP status
    local thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
    if [[ -r "$thp_file" ]]; then
        local thp_raw thp_active
        thp_raw=$(cat "$thp_file")
        thp_active=$(echo "$thp_raw" | grep -oP '\[\K[^\]]+')
        details+=", THP=$thp_active"
        if [[ "$thp_active" == "always" ]]; then
            [[ "$status" == "OK" ]] && status="WARN"
            fix="echo madvise | sudo tee $thp_file"
            fix_id="thp"
        fi
    fi

    # Compaction stalls
    local compact_stall
    compact_stall=$(awk '/^compact_stall / { print $2 }' /proc/vmstat 2>/dev/null || echo "0")
    if (( compact_stall > 100 )); then
        [[ "$status" == "OK" ]] && status="WARN"
        details+=", compact_stalls=$compact_stall"
        fix="sysctl vm.compaction_proactiveness=0"
        fix_id="compaction"
    fi
    log DEBUG "compact_stall=$compact_stall"

    # Memory available
    local mem_avail_kb mem_total_kb mem_avail_pct
    mem_avail_kb=$(get_meminfo MemAvailable)
    mem_total_kb=$(get_meminfo MemTotal)
    if (( mem_total_kb > 0 )); then
        mem_avail_pct=$(( mem_avail_kb * 100 / mem_total_kb ))
        details+=", avail=${mem_avail_pct}%"
        if (( mem_avail_pct < 10 )); then
            status="CRITICAL"
            fix="System critically low on memory — find and stop leaking processes"
            fix_id=""  # no auto-fix for this
        fi
    fi

    record_result "Memory/THP" "$status" "$details" "$fix"

    # Interactive fix prompt
    if [[ "$status" != "OK" && -n "$fix_id" ]] && ask_fix "Memory/THP"; then
        case "$fix_id" in
            swappiness) fix_swappiness || true ;;
            thp)        fix_thp || true ;;
            compaction) fix_compaction || true ;;
        esac
        # Apply all memory-related fixes if compaction is the issue
        if [[ "$fix_id" == "compaction" ]]; then
            fix_swappiness 2>/dev/null || true
            fix_thp 2>/dev/null || true
        fi
    fi
}

check_journald() {
    local details="" status="OK" fix="" fix_id=""

    # Journal disk usage
    if command -v journalctl &>/dev/null; then
        local journal_usage
        journal_usage=$(journalctl --disk-usage 2>/dev/null | grep -oP '[0-9.]+[KMGT]' | head -1 || echo "unknown")
        details="disk=$journal_usage"

        local journal_mb=0
        if [[ "$journal_usage" =~ ^([0-9.]+)G ]]; then
            journal_mb=$(awk "BEGIN { printf \"%d\", ${BASH_REMATCH[1]} * 1024 }")
        elif [[ "$journal_usage" =~ ^([0-9.]+)M ]]; then
            journal_mb=$(awk "BEGIN { printf \"%d\", ${BASH_REMATCH[1]} }")
        fi

        if (( journal_mb > 2048 )); then
            status="CRITICAL"
            fix="sudo journalctl --vacuum-size=500M; set SystemMaxUse=500M in /etc/systemd/journald.conf"
            fix_id="journal"
        elif (( journal_mb > 500 )); then
            status="WARN"
            fix="sudo journalctl --vacuum-size=500M"
            fix_id="journal"
        fi
    else
        details="journalctl not found"
    fi

    # Journald RSS
    local jd_pid
    jd_pid=$(pgrep -x systemd-journald 2>/dev/null | head -1 || true)
    if [[ -n "$jd_pid" && -r "/proc/$jd_pid/status" ]]; then
        local jd_rss_kb
        jd_rss_kb=$(awk '/^VmRSS:/ { print $2 }' "/proc/$jd_pid/status" 2>/dev/null || echo "0")
        local jd_rss_mb=$(( jd_rss_kb / 1024 ))
        details+=", rss=${jd_rss_mb}MB"
        if (( jd_rss_mb > 200 )); then
            [[ "$status" == "OK" ]] && status="WARN"
        fi
    fi

    # Active unit count
    if command -v systemctl &>/dev/null; then
        local unit_count
        unit_count=$(systemctl list-units --no-pager --no-legend --state=active 2>/dev/null | wc -l || echo "?")
        details+=", units=$unit_count"
    fi

    record_result "Journald" "$status" "$details" "$fix"

    if [[ "$status" != "OK" && -n "$fix_id" ]] && ask_fix "Journald"; then
        fix_journal_vacuum || true
        fix_journal_cap || true
    fi
}

check_filesystem() {
    local details="" status="OK" fix=""
    local fs_notes=()

    local ext4_dir
    for ext4_dir in /proc/fs/ext4/*/; do
        [[ -d "$ext4_dir" ]] || continue
        local dev_name
        dev_name=$(basename "$ext4_dir")
        if [[ -r "${ext4_dir}options" ]]; then
            local commit_val
            commit_val=$(grep -oP 'commit=\K\d+' "${ext4_dir}options" 2>/dev/null || echo "5")
            fs_notes+=("ext4:${dev_name}:commit=${commit_val}s")
            log DEBUG "ext4 $dev_name commit=$commit_val"
        fi
    done

    if command -v btrfs &>/dev/null; then
        while IFS= read -r mnt; do
            [[ -z "$mnt" ]] && continue
            local bal_status
            bal_status=$(btrfs balance status "$mnt" 2>/dev/null || true)
            if echo "$bal_status" | grep -qi "in progress"; then
                status="WARN"
                fs_notes+=("btrfs:${mnt}:balance running!")
                fix="Wait for balance to complete or: sudo btrfs balance cancel $mnt"
            else
                fs_notes+=("btrfs:${mnt}:idle")
            fi
        done < <(awk '$3 == "btrfs" { print $2 }' /proc/mounts 2>/dev/null)
    fi

    if (( ${#fs_notes[@]} > 0 )); then
        details=$(printf '%s; ' "${fs_notes[@]}")
        details="${details%; }"
    else
        details="no ext4/btrfs detected or not readable"
    fi

    record_result "Filesystem" "$status" "$details" "$fix"
    # No auto-fix for filesystem — too risky
}

check_gpu() {
    local details="" status="OK" fix=""

    if ! command -v lspci &>/dev/null; then
        record_result "GPU" "OK" "lspci not available, skipped" ""
        return
    fi

    local gpu_info
    gpu_info=$(lspci 2>/dev/null | grep -i 'vga\|3d\|display' | head -3 || true)

    if [[ -z "$gpu_info" ]]; then
        record_result "GPU" "OK" "No GPU detected" ""
        return
    fi

    if echo "$gpu_info" | grep -qi nvidia; then
        details="NVIDIA"
        if command -v nvidia-smi &>/dev/null; then
            local nv_driver nv_throttle nv_temp
            nv_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "?")
            nv_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 || echo "?")
            nv_throttle=$(nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv,noheader 2>/dev/null | head -1 || echo "")
            details+=" driver=$nv_driver temp=${nv_temp}°C"
            if [[ -n "$nv_throttle" && "$nv_throttle" != "0x0000000000000000" && "$nv_throttle" != "" ]]; then
                status="CRITICAL"
                details+=", THROTTLING($nv_throttle)"
                fix="Check GPU cooling; nvidia-settings → PowerMizer → Prefer Maximum Performance"
            fi
        else
            status="WARN"
            details+=", nvidia-smi not found"
            fix="Install nvidia-utils for monitoring: sudo apt install nvidia-utils-*"
        fi
    elif echo "$gpu_info" | grep -qi 'amd\|radeon'; then
        details="AMD/Radeon"
        if [[ -r /sys/class/drm/card0/device/power_dpm_force_performance_level ]]; then
            local amd_perf
            amd_perf=$(cat /sys/class/drm/card0/device/power_dpm_force_performance_level 2>/dev/null || echo "?")
            details+=", perf_level=$amd_perf"
        fi
        if [[ "${XDG_SESSION_TYPE:-}" == "x11" ]]; then
            status="WARN"
            details+=", using X11"
            fix="Switch to Wayland session for better AMD performance"
        fi
    elif echo "$gpu_info" | grep -qi intel; then
        details="Intel"
        if [[ -d /sys/class/drm/card0 ]]; then
            local i915_rc6
            i915_rc6=$(read_sysfs /sys/class/drm/card0/power/rc6_enable)
            [[ -n "$i915_rc6" ]] && details+=", rc6=$i915_rc6"
        fi
    else
        details="Unknown: $(echo "$gpu_info" | head -1 | cut -c1-60)"
    fi

    record_result "GPU" "$status" "$details" "$fix"
    # No auto-fix for GPU — requires driver/session changes
}

check_cpu_governor() {
    local details="" status="OK" fix="" fix_id=""

    local gov_file="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
    if [[ -r "$gov_file" ]]; then
        local governor
        governor=$(cat "$gov_file")
        details="governor=$governor"

        if [[ "$governor" == "powersave" ]]; then
            status="WARN"
            fix="echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
            fix_id="governor"
        fi
    else
        details="cpufreq not available (fixed frequency?)"
    fi

    local boost_file="/sys/devices/system/cpu/cpufreq/boost"
    if [[ -r "$boost_file" ]]; then
        local boost
        boost=$(cat "$boost_file")
        details+=", boost=$boost"
        if [[ "$boost" == "0" ]]; then
            [[ "$status" == "OK" ]] && status="WARN"
            fix="echo 1 | sudo tee $boost_file"
            fix_id="boost"
        fi
    fi

    local cur_freq max_freq
    cur_freq=$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
    max_freq=$(read_sysfs /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)
    if [[ -n "$cur_freq" && -n "$max_freq" && "$max_freq" -gt 0 ]] 2>/dev/null; then
        local freq_pct=$(( cur_freq * 100 / max_freq ))
        details+=", cur_freq=${freq_pct}%_of_max"
    fi

    record_result "CPU Governor" "$status" "$details" "$fix"

    if [[ "$status" != "OK" && -n "$fix_id" ]] && ask_fix "CPU Governor"; then
        case "$fix_id" in
            governor) fix_cpu_governor || true ;;
            boost)    fix_cpu_boost || true ;;
        esac
    fi
}

check_kernel_memory() {
    local details="" status="OK" fix="" fix_id=""

    local swappiness
    swappiness=$(get_sysctl vm.swappiness)
    details="swappiness=$swappiness"
    if [[ -n "$swappiness" ]] && (( swappiness > 30 )); then
        status="WARN"
        fix="sysctl vm.swappiness=10"
        fix_id="swappiness"
    fi

    local dirty_ratio dirty_bg_ratio
    dirty_ratio=$(get_sysctl vm.dirty_ratio)
    dirty_bg_ratio=$(get_sysctl vm.dirty_background_ratio)
    details+=", dirty=${dirty_ratio}/${dirty_bg_ratio}"

    local compaction
    compaction=$(get_sysctl vm.compaction_proactiveness)
    if [[ -n "$compaction" ]]; then
        details+=", compaction_proact=$compaction"
        if (( compaction > 0 )); then
            [[ "$status" == "OK" ]] && status="WARN"
            fix="sysctl vm.compaction_proactiveness=0"
            fix_id="kernel_mem"
        fi
    fi

    local wb_count
    wb_count=$(pgrep -c 'writeback' 2>/dev/null || echo "0")
    details+=", writeback_threads=$wb_count"

    record_result "Kernel Memory" "$status" "$details" "$fix"

    if [[ "$status" != "OK" && -n "$fix_id" ]] && ask_fix "Kernel Memory"; then
        fix_compaction || true
        fix_swappiness || true
        fix_dirty_bg_ratio || true
        fix_dirty_ratio || true
    fi
}

check_desktop_indexers() {
    local details="" status="OK" fix="" fix_id=""
    local found_any=false

    local baloo_pid
    baloo_pid=$(pgrep -f baloo_file 2>/dev/null | head -1 || true)
    if [[ -n "$baloo_pid" ]]; then
        found_any=true
        local baloo_cpu baloo_rss
        baloo_cpu=$(ps -p "$baloo_pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
        baloo_rss=$(ps -p "$baloo_pid" -o rss= 2>/dev/null | tr -d ' ' || echo "0")
        local baloo_rss_mb=$(( baloo_rss / 1024 ))
        details+="baloo: cpu=${baloo_cpu}% rss=${baloo_rss_mb}MB"

        if awk "BEGIN { exit ($baloo_cpu > 5.0 ? 0 : 1) }" 2>/dev/null || (( baloo_rss_mb > 200 )); then
            status="WARN"
            fix="balooctl6 disable  # or: balooctl disable"
            fix_id="baloo"
        fi
    fi

    local tracker_pid
    tracker_pid=$(pgrep -f 'tracker-miner' 2>/dev/null | head -1 || true)
    if [[ -n "$tracker_pid" ]]; then
        found_any=true
        local tracker_cpu tracker_rss
        tracker_cpu=$(ps -p "$tracker_pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
        tracker_rss=$(ps -p "$tracker_pid" -o rss= 2>/dev/null | tr -d ' ' || echo "0")
        local tracker_rss_mb=$(( tracker_rss / 1024 ))
        [[ -n "$details" ]] && details+="; "
        details+="tracker: cpu=${tracker_cpu}% rss=${tracker_rss_mb}MB"

        if awk "BEGIN { exit ($tracker_cpu > 5.0 ? 0 : 1) }" 2>/dev/null || (( tracker_rss_mb > 200 )); then
            status="WARN"
            fix="systemctl --user mask tracker-miner-fs-3.service"
            fix_id="tracker"
        fi
    fi

    if [[ "$found_any" == false ]]; then
        details="none running"
    fi

    record_result "Desktop Indexers" "$status" "$details" "$fix"

    if [[ "$status" != "OK" && -n "$fix_id" ]] && ask_fix "Desktop Indexers"; then
        case "$fix_id" in
            baloo)   fix_disable_baloo || true ;;
            tracker) fix_mask_tracker || true ;;
        esac
    fi
}

check_irq_rate() {
    local details="" status="OK" fix=""

    local sample1 sample2
    sample1=$(cat /proc/interrupts)
    sleep 1
    sample2=$(cat /proc/interrupts)

    local max_irq_name="" max_irq_rate=0

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*CPU ]] && continue
        local irq_id
        irq_id=$(echo "$line" | awk '{ print $1 }' | tr -d ':')
        local total1=0
        local nums1
        nums1=$(echo "$line" | grep -oP '\d+' || true)
        for n in $nums1; do
            total1=$(( total1 + n ))
        done

        local line2
        line2=$(echo "$sample2" | grep "^[[:space:]]*${irq_id}:" 2>/dev/null | head -1 || true)
        [[ -z "$line2" ]] && continue

        local total2=0
        local nums2
        nums2=$(echo "$line2" | grep -oP '\d+' || true)
        for n in $nums2; do
            total2=$(( total2 + n ))
        done

        local delta=$(( total2 - total1 ))
        if (( delta > max_irq_rate )); then
            max_irq_rate=$delta
            max_irq_name="$irq_id"
        fi
    done <<< "$sample1"

    details="peak=${max_irq_rate}/s (IRQ $max_irq_name)"
    if (( max_irq_rate > 100000 )); then
        status="CRITICAL"
        fix="Investigate IRQ $max_irq_name — check driver/firmware for that device"
    elif (( max_irq_rate > 50000 )); then
        status="WARN"
        fix="Monitor IRQ $max_irq_name — may indicate driver issue"
    fi

    record_result "IRQ Rate" "$status" "$details" "$fix"
    # No auto-fix for IRQ — requires manual investigation
}

check_disk_io() {
    local details="" status="OK" fix="" fix_id=""
    local disk_notes=()
    local fixable_devs=()

    for blk_dir in /sys/block/*/; do
        local dev
        dev=$(basename "$blk_dir")
        [[ "$dev" =~ ^(loop|ram|dm-|zram) ]] && continue
        [[ ! -r "${blk_dir}queue/scheduler" ]] && continue

        local rotational sched queue_depth
        rotational=$(read_sysfs "${blk_dir}queue/rotational")
        sched=$(cat "${blk_dir}queue/scheduler" 2>/dev/null || echo "?")
        local active_sched
        active_sched=$(echo "$sched" | grep -oP '\[\K[^\]]+' || echo "?")
        queue_depth=$(read_sysfs "${blk_dir}device/queue_depth")

        local disk_type="HDD"
        [[ "$rotational" == "0" ]] && disk_type="SSD"

        local note="${dev}(${disk_type}):sched=${active_sched}"
        [[ -n "$queue_depth" ]] && note+=",ncq=${queue_depth}"

        if [[ "$disk_type" == "SSD" && "$active_sched" =~ ^(cfq|bfq)$ ]]; then
            [[ "$status" == "OK" ]] && status="WARN"
            fix="echo mq-deadline | sudo tee /sys/block/${dev}/queue/scheduler"
            fix_id="io_sched"
            fixable_devs+=("$dev")
        fi

        disk_notes+=("$note")
    done

    if command -v systemctl &>/dev/null; then
        local trim_active
        trim_active=$(systemctl is-active fstrim.timer 2>/dev/null || echo "inactive")
        disk_notes+=("fstrim.timer=$trim_active")
    fi

    if (( ${#disk_notes[@]} > 0 )); then
        details=$(printf '%s; ' "${disk_notes[@]}")
        details="${details%; }"
    else
        details="no block devices found"
    fi

    record_result "Disk I/O" "$status" "$details" "$fix"

    if [[ "$status" != "OK" && -n "$fix_id" ]] && ask_fix "Disk I/O"; then
        for dev in "${fixable_devs[@]}"; do
            fix_io_scheduler "$dev" || true
        done
    fi
}

check_network_dns() {
    local details="" status="OK" fix="" fix_id=""

    local dns_ms=0
    if command -v dig &>/dev/null; then
        local dig_out
        dig_out=$(dig +noall +stats google.com 2>/dev/null || true)
        dns_ms=$(echo "$dig_out" | grep -oP 'Query time: \K\d+' || echo "0")
        details="dns=${dns_ms}ms"
    elif command -v getent &>/dev/null; then
        local start_ns end_ns
        start_ns=$(date +%s%N)
        getent hosts google.com &>/dev/null || true
        end_ns=$(date +%s%N)
        dns_ms=$(( (end_ns - start_ns) / 1000000 ))
        details="dns=${dns_ms}ms"
    else
        details="no dig/getent available"
    fi

    if (( dns_ms > 1000 )); then
        status="CRITICAL"
        fix="Check DNS resolver: resolvectl status; consider switching to 1.1.1.1 or 8.8.8.8"
    elif (( dns_ms > 500 )); then
        status="WARN"
        fix="Slow DNS — check /etc/systemd/resolved.conf"
    fi

    local avahi_active resolved_active
    avahi_active=$(systemctl is-active avahi-daemon 2>/dev/null || echo "inactive")
    resolved_active=$(systemctl is-active systemd-resolved 2>/dev/null || echo "inactive")
    if [[ "$avahi_active" == "active" && "$resolved_active" == "active" ]]; then
        [[ "$status" == "OK" ]] && status="WARN"
        details+=", avahi+resolved BOTH active"
        fix="sudo systemctl mask avahi-daemon  # if not needed for mDNS"
        fix_id="avahi"
    else
        details+=", resolver=${resolved_active}"
    fi

    record_result "Network/DNS" "$status" "$details" "$fix"

    if [[ "$status" != "OK" && "$fix_id" == "avahi" ]] && ask_fix "Network/DNS"; then
        fix_mask_avahi || true
    fi
}

check_scheduler() {
    local details="" status="OK" fix=""

    local sched_gran sched_lat
    sched_gran=$(get_sysctl kernel.sched_min_granularity_ns)
    sched_lat=$(get_sysctl kernel.sched_latency_ns)
    if [[ -n "$sched_gran" && -n "$sched_lat" ]]; then
        local gran_ms=$(( sched_gran / 1000000 ))
        local lat_ms=$(( sched_lat / 1000000 ))
        details="sched=CFS, gran=${gran_ms}ms, lat=${lat_ms}ms"
    else
        details="sched=EEVDF"
    fi

    local preempt="unknown"
    local kconfig
    kconfig="/boot/config-$(uname -r)"
    if [[ -r "$kconfig" ]]; then
        if grep -q 'CONFIG_PREEMPT_RT=y' "$kconfig" 2>/dev/null; then
            preempt="PREEMPT_RT"
        elif grep -q 'CONFIG_PREEMPT=y' "$kconfig" 2>/dev/null; then
            preempt="PREEMPT"
        elif grep -q 'CONFIG_PREEMPT_VOLUNTARY=y' "$kconfig" 2>/dev/null; then
            preempt="VOLUNTARY"
        elif grep -q 'CONFIG_PREEMPT_NONE=y' "$kconfig" 2>/dev/null; then
            preempt="NONE"
            status="WARN"
            fix="Install a desktop/lowlatency kernel: sudo apt install linux-lowlatency"
        fi
    elif [[ -r /proc/config.gz ]]; then
        if zcat /proc/config.gz 2>/dev/null | grep -q 'CONFIG_PREEMPT_VOLUNTARY=y'; then
            preempt="VOLUNTARY"
        elif zcat /proc/config.gz 2>/dev/null | grep -q 'CONFIG_PREEMPT=y'; then
            preempt="PREEMPT"
        fi
    fi
    if [[ -n "$details" ]]; then
        details+=", preempt=$preempt"
    else
        details="preempt=$preempt"
    fi

    if [[ -r "$kconfig" ]]; then
        local hz
        hz=$(grep -oP 'CONFIG_HZ=\K\d+' "$kconfig" 2>/dev/null || echo "?")
        details+=", HZ=$hz"
    fi

    record_result "Scheduler" "$status" "$details" "$fix"
    # No auto-fix — requires kernel change
}

# =====================================================================
# COMMANDS
# =====================================================================

cmd_diagnose() {
    if [[ "$JSON_OUTPUT" != true ]]; then
        printf '\n%s%s Desktop Lag Doctor v%s — Diagnostic Report%s\n' "$C_BLD" "$C_CYN" "$SCRIPT_VERSION" "$C_RST"
        printf '%sHost: %s | Kernel: %s | Uptime: %s%s\n' \
            "$C_DIM" "$(hostname)" "$(uname -r)" "$(uptime -p 2>/dev/null || uptime | sed 's/.*up/up/')" "$C_RST"
    fi

    section "Memory & Hugepages"
    check_memory_thp

    section "Journald & Systemd"
    check_journald

    section "Filesystem"
    check_filesystem

    section "GPU"
    check_gpu

    section "CPU Frequency"
    check_cpu_governor

    section "Kernel Memory Management"
    check_kernel_memory

    section "Desktop Indexers"
    check_desktop_indexers

    section "IRQ Rate (sampling 1s...)"
    check_irq_rate

    section "Disk I/O"
    check_disk_io

    section "Network & DNS"
    check_network_dns

    section "Scheduler & Preemption"
    check_scheduler

    # Persist sysctl changes if any fixes were applied
    if (( INTERACTIVE_FIX_COUNT > 0 )); then
        persist_sysctl_fixes
    fi

    # Summary
    if [[ "$JSON_OUTPUT" == true ]]; then
        printf '[\n'
        local first=true
        for entry in "${JSON_RESULTS[@]}"; do
            [[ "$first" == true ]] && first=false || printf ',\n'
            printf '  %s' "$entry"
        done
        printf '\n]\n'
    else
        local warn_count=0 crit_count=0 ok_count=0
        for s in "${CHECK_STATUSES[@]}"; do
            case "$s" in
                OK) (( ok_count++ )) ;;
                WARN) (( warn_count++ )) ;;
                CRITICAL) (( crit_count++ )) ;;
            esac
        done

        printf '\n%s═══ Summary ═══════════════════════════════════════════%s\n' "$C_BLD" "$C_RST"
        printf '  %s%d OK%s  |  %s%d WARN%s  |  %s%d CRITICAL%s\n' \
            "$C_GRN" "$ok_count" "$C_RST" \
            "$C_YEL" "$warn_count" "$C_RST" \
            "$C_RED" "$crit_count" "$C_RST"

        if (( INTERACTIVE_FIX_COUNT > 0 )); then
            printf '\n  %s%d fix(es) applied this session.%s\n' "$C_GRN" "$INTERACTIVE_FIX_COUNT" "$C_RST"
            if [[ "$SNAPSHOT_STARTED" == true ]]; then
                printf '  Rollback snapshot: %s%s%s\n' "$C_DIM" "$SNAPSHOT_FILE" "$C_RST"
                printf '  To undo: %s%s rollback%s\n' "$C_BLD" "$SCRIPT_NAME" "$C_RST"
            fi
        elif (( crit_count > 0 || warn_count > 0 )); then
            printf '\n  Run %s%s fix --dry-run%s to preview safe auto-tuning.\n' "$C_BLD" "$SCRIPT_NAME" "$C_RST"
            printf '  Or re-run %s%s diagnose%s to fix issues interactively.\n' "$C_BLD" "$SCRIPT_NAME" "$C_RST"
        else
            printf '\n  %sAll checks passed — system looks healthy.%s\n' "$C_GRN" "$C_RST"
        fi
        printf '\n'
    fi
}

cmd_fix() {
    if [[ "$JSON_OUTPUT" != true ]]; then
        printf '\n%s%s Desktop Lag Doctor v%s — Auto-Tuning%s\n' "$C_BLD" "$C_CYN" "$SCRIPT_VERSION" "$C_RST"
        if [[ "$DRY_RUN" == true ]]; then
            printf '%s[DRY RUN] No changes will be made%s\n\n' "$C_YEL" "$C_RST"
        fi
    fi

    local changes=0

    # Fix 1: Swappiness
    local current_swappiness
    current_swappiness=$(get_sysctl vm.swappiness)
    if [[ -n "$current_swappiness" ]] && (( current_swappiness > 10 )); then
        printf '  [FIX] vm.swappiness: %s → 10\n' "$current_swappiness"
        if fix_swappiness; then (( changes++ )); fi
    else
        printf '  [OK]  vm.swappiness=%s (already optimal)\n' "$current_swappiness"
    fi

    # Fix 2: THP to madvise
    local thp_file="/sys/kernel/mm/transparent_hugepage/enabled"
    if [[ -r "$thp_file" ]]; then
        local thp_active
        thp_active=$(grep -oP '\[\K[^\]]+' "$thp_file")
        if [[ "$thp_active" == "always" ]]; then
            printf '  [FIX] THP: %s → madvise\n' "$thp_active"
            if fix_thp; then (( changes++ )); fi
        else
            printf '  [OK]  THP=%s (already optimal)\n' "$thp_active"
        fi
    fi

    # Fix 3: Proactive compaction
    local compaction
    compaction=$(get_sysctl vm.compaction_proactiveness)
    if [[ -n "$compaction" ]] && (( compaction > 0 )); then
        printf '  [FIX] vm.compaction_proactiveness: %s → 0\n' "$compaction"
        if fix_compaction; then (( changes++ )); fi
    else
        printf '  [OK]  vm.compaction_proactiveness=%s (already optimal)\n' "${compaction:-N/A}"
    fi

    # Fix 4: Dirty writeback tuning
    local dirty_bg
    dirty_bg=$(get_sysctl vm.dirty_background_ratio)
    if [[ -n "$dirty_bg" ]] && (( dirty_bg > 5 )); then
        printf '  [FIX] vm.dirty_background_ratio: %s → 5\n' "$dirty_bg"
        if fix_dirty_bg_ratio; then (( changes++ )); fi
    else
        printf '  [OK]  vm.dirty_background_ratio=%s (already optimal)\n' "${dirty_bg:-N/A}"
    fi

    local dirty_ratio
    dirty_ratio=$(get_sysctl vm.dirty_ratio)
    if [[ -n "$dirty_ratio" ]] && (( dirty_ratio > 15 )); then
        printf '  [FIX] vm.dirty_ratio: %s → 15\n' "$dirty_ratio"
        if fix_dirty_ratio; then (( changes++ )); fi
    else
        printf '  [OK]  vm.dirty_ratio=%s (already optimal)\n' "${dirty_ratio:-N/A}"
    fi

    # Fix 5: I/O scheduler for SSDs
    for blk_dir in /sys/block/*/; do
        local dev
        dev=$(basename "$blk_dir")
        [[ "$dev" =~ ^(loop|ram|dm-|zram) ]] && continue
        [[ ! -r "${blk_dir}queue/scheduler" ]] && continue

        local rotational
        rotational=$(read_sysfs "${blk_dir}queue/rotational")
        [[ "$rotational" != "0" ]] && continue

        local active_sched
        active_sched=$(grep -oP '\[\K[^\]]+' "${blk_dir}queue/scheduler" || echo "?")
        if [[ "$active_sched" =~ ^(cfq|bfq)$ ]]; then
            printf '  [FIX] %s I/O scheduler: %s → mq-deadline\n' "$dev" "$active_sched"
            if fix_io_scheduler "$dev"; then (( changes++ )); fi
        else
            printf '  [OK]  %s sched=%s (optimal for SSD)\n' "$dev" "$active_sched"
        fi
    done

    # Fix 6: Journal size cap
    local journal_conf="/etc/systemd/journald.conf"
    if [[ -r "$journal_conf" ]]; then
        if ! grep -q '^SystemMaxUse=' "$journal_conf" 2>/dev/null; then
            printf '  [FIX] Journald: adding SystemMaxUse=500M\n'
            if fix_journal_cap; then (( changes++ )); fi
        else
            local current_max
            current_max=$(grep '^SystemMaxUse=' "$journal_conf" | cut -d= -f2)
            printf '  [OK]  Journald SystemMaxUse=%s (already set)\n' "$current_max"
        fi
    fi

    # Persist sysctl config
    persist_sysctl_fixes

    printf '\n  %s%d fix(es) applied%s%s\n' "$C_BLD" "$changes" \
        "$( [[ "$DRY_RUN" == true ]] && echo " (dry run)" )" "$C_RST"
    if [[ "$SNAPSHOT_STARTED" == true ]]; then
        printf '  Rollback snapshot: %s%s%s\n' "$C_DIM" "$SNAPSHOT_FILE" "$C_RST"
        printf '  To undo: %s%s rollback%s\n' "$C_BLD" "$SCRIPT_NAME" "$C_RST"
    fi
    printf '\n'
}

cmd_rollback() {
    mkdir -p "$ROLLBACK_DIR"

    # List available snapshots
    local snapshots=()
    while IFS= read -r f; do
        snapshots+=("$f")
    done < <(find "$ROLLBACK_DIR" -name '*.snapshot' -type f 2>/dev/null | sort -r)

    if (( ${#snapshots[@]} == 0 )); then
        printf '\n  %sNo rollback snapshots found.%s\n' "$C_YEL" "$C_RST"
        printf '  Snapshots are created when fixes are applied.\n\n'
        return 0
    fi

    printf '\n%s%s Desktop Lag Doctor v%s — Rollback%s\n\n' "$C_BLD" "$C_CYN" "$SCRIPT_VERSION" "$C_RST"
    printf '  Available snapshots:\n\n'

    local i=1
    for snap in "${snapshots[@]}"; do
        local snap_name snap_entries snap_created
        snap_name=$(basename "$snap" .snapshot)
        snap_created=$(head -2 "$snap" | grep '# Created:' | sed 's/# Created: //' || echo "")
        snap_entries=$(grep -cv '^#\|^$' "$snap" 2>/dev/null || echo "0")
        printf '    %s%d)%s %s  %s(%d settings saved, %s)%s\n' \
            "$C_BLD" "$i" "$C_RST" "$snap_name" "$C_DIM" "$snap_entries" "$snap_created" "$C_RST"

        # Show contents
        while IFS='|' read -r type key value desc; do
            [[ "$type" =~ ^# ]] && continue
            [[ -z "$type" ]] && continue
            printf '       %s%s: %s = %s%s\n' "$C_DIM" "$type" "$key" "$value" "$C_RST"
        done < "$snap"

        (( i++ ))
    done

    printf '\n    %s0)%s Cancel\n' "$C_BLD" "$C_RST"

    # Prompt for selection
    local choice
    printf '\n  Select snapshot to restore [0-%d]: ' "${#snapshots[@]}"
    if [[ "$AUTO_YES" == true ]]; then
        choice=1
        printf '1 (auto)\n'
    elif [[ -t 0 ]]; then
        read -r choice </dev/tty
    else
        printf '\n  %sNon-interactive mode — use -y to auto-select latest snapshot%s\n\n' "$C_YEL" "$C_RST"
        return 0
    fi

    if [[ "$choice" == "0" || -z "$choice" ]]; then
        printf '  Cancelled.\n\n'
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#snapshots[@]} )); then
        die "Invalid selection: $choice"
    fi

    local selected="${snapshots[$((choice - 1))]}"
    printf '\n  %sRestoring from: %s%s\n\n' "$C_CYN" "$(basename "$selected")" "$C_RST"

    local restored=0
    while IFS='|' read -r type key value desc; do
        [[ "$type" =~ ^# ]] && continue
        [[ -z "$type" ]] && continue

        printf '  Restoring %s (%s)...' "$desc" "$key"

        if [[ "$DRY_RUN" == true ]]; then
            printf ' %s[DRY RUN] would set %s=%s%s\n' "$C_DIM" "$key" "$value" "$C_RST"
            (( restored++ ))
            continue
        fi

        case "$type" in
            sysctl)
                if sudo sysctl -w "${key}=${value}" >/dev/null 2>&1; then
                    printf ' %s✓ %s=%s%s\n' "$C_GRN" "$key" "$value" "$C_RST"
                    (( restored++ ))
                else
                    printf ' %s✗ failed%s\n' "$C_RED" "$C_RST"
                fi
                ;;
            sysfs)
                # Handle glob patterns in key (e.g., cpu*/cpufreq/scaling_governor)
                local wrote=false
                # shellcheck disable=SC2086
                for target in $key; do
                    if [[ -w "$target" ]] || sudo test -w "$target" 2>/dev/null; then
                        echo "$value" | sudo tee "$target" >/dev/null 2>&1 && wrote=true
                    fi
                done
                if [[ "$wrote" == true ]]; then
                    printf ' %s✓ %s%s\n' "$C_GRN" "$value" "$C_RST"
                    (( restored++ ))
                else
                    printf ' %s✗ failed%s\n' "$C_RED" "$C_RST"
                fi
                ;;
            file)
                if [[ "$value" == "NO_SystemMaxUse" ]]; then
                    # Remove the lines we added
                    sudo sed -i '/# Added by desktop-lag-doctor/d; /^SystemMaxUse=500M$/d' "$key" 2>/dev/null
                    printf ' %s✓ removed SystemMaxUse line%s\n' "$C_GRN" "$C_RST"
                    (( restored++ ))
                else
                    printf ' %sskipped (manual restore needed)%s\n' "$C_YEL" "$C_RST"
                fi
                ;;
            service)
                case "$key" in
                    avahi-daemon)
                        sudo systemctl unmask avahi-daemon 2>/dev/null || true
                        sudo systemctl start avahi-daemon 2>/dev/null || true
                        printf ' %s✓ unmasked and started%s\n' "$C_GRN" "$C_RST"
                        (( restored++ ))
                        ;;
                    baloo)
                        if command -v balooctl6 &>/dev/null; then
                            balooctl6 enable 2>/dev/null || true
                        elif command -v balooctl &>/dev/null; then
                            balooctl enable 2>/dev/null || true
                        fi
                        printf ' %s✓ re-enabled%s\n' "$C_GRN" "$C_RST"
                        (( restored++ ))
                        ;;
                    tracker-miner-fs-3)
                        systemctl --user unmask tracker-miner-fs-3.service 2>/dev/null || true
                        systemctl --user start tracker-miner-fs-3.service 2>/dev/null || true
                        printf ' %s✓ unmasked and started%s\n' "$C_GRN" "$C_RST"
                        (( restored++ ))
                        ;;
                    journald-vacuum)
                        printf ' %s(journal vacuum cannot be undone — logs were already deleted)%s\n' "$C_YEL" "$C_RST"
                        ;;
                    *)
                        printf ' %sskipped (unknown service)%s\n' "$C_YEL" "$C_RST"
                        ;;
                esac
                ;;
            *)
                printf ' %sskipped (unknown type: %s)%s\n' "$C_YEL" "$type" "$C_RST"
                ;;
        esac
    done < "$selected"

    # Remove persistent sysctl config if it exists
    local sysctl_conf="/etc/sysctl.d/99-lag-doctor.conf"
    if [[ -f "$sysctl_conf" ]]; then
        printf '\n  Removing persistent config %s...' "$sysctl_conf"
        if [[ "$DRY_RUN" == true ]]; then
            printf ' %s[DRY RUN]%s\n' "$C_DIM" "$C_RST"
        else
            sudo rm -f "$sysctl_conf"
            printf ' %s✓ removed%s\n' "$C_GRN" "$C_RST"
        fi
    fi

    # Archive the used snapshot
    if [[ "$DRY_RUN" != true ]]; then
        mv "$selected" "${selected}.restored"
    fi

    printf '\n  %s%d setting(s) restored.%s%s\n\n' "$C_BLD" "$restored" \
        "$( [[ "$DRY_RUN" == true ]] && echo " (dry run)" )" "$C_RST"
}

cmd_monitor() {
    if [[ "$JSON_OUTPUT" != true ]]; then
        printf '%s%s Desktop Lag Doctor v%s — Live Monitor%s\n' "$C_BLD" "$C_CYN" "$SCRIPT_VERSION" "$C_RST"
        printf '%sPress Ctrl+C to stop%s\n\n' "$C_DIM" "$C_RST"
    fi

    CURSOR_HIDDEN=true
    printf '\033[?25h' 2>/dev/null
    printf '\033[?25l' 2>/dev/null

    local prev_total_irq=0 prev_ctx=0 prev_time_ns=0

    while true; do
        local swap_total swap_free swap_pct
        swap_total=$(get_meminfo SwapTotal)
        swap_free=$(get_meminfo SwapFree)
        (( swap_total > 0 )) && swap_pct=$(( (swap_total - swap_free) * 100 / swap_total )) || swap_pct=0

        local kswapd_cpu="0"
        local kswapd_pid
        kswapd_pid=$(pgrep kswapd 2>/dev/null | head -1 || true)
        if [[ -n "$kswapd_pid" ]]; then
            kswapd_cpu=$(ps -p "$kswapd_pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
        fi

        local kcompactd_cpu="0"
        local kcompactd_pid
        kcompactd_pid=$(pgrep kcompactd 2>/dev/null | head -1 || true)
        if [[ -n "$kcompactd_pid" ]]; then
            kcompactd_cpu=$(ps -p "$kcompactd_pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
        fi

        local total_irq
        total_irq=$(awk '/^[[:space:]]*[0-9]+:/ { for(i=2;i<=NF;i++) { if($i ~ /^[0-9]+$/) s+=$i } } END { print s+0 }' /proc/interrupts)

        local ctx
        ctx=$(awk '/^ctxt / { print $2 }' /proc/stat)

        local now_ns
        now_ns=$(date +%s%N)
        local irq_rate=0 ctx_rate=0
        if (( prev_time_ns > 0 )); then
            local elapsed_s=$(( (now_ns - prev_time_ns) / 1000000000 ))
            (( elapsed_s < 1 )) && elapsed_s=1
            irq_rate=$(( (total_irq - prev_total_irq) / elapsed_s ))
            ctx_rate=$(( (ctx - prev_ctx) / elapsed_s ))
        fi
        prev_total_irq=$total_irq
        prev_ctx=$ctx
        prev_time_ns=$now_ns

        local irq_str ctx_str
        if (( irq_rate > 1000000 )); then
            irq_str="$(( irq_rate / 1000000 ))M"
        elif (( irq_rate > 1000 )); then
            irq_str="$(( irq_rate / 1000 ))k"
        else
            irq_str="$irq_rate"
        fi
        if (( ctx_rate > 1000000 )); then
            ctx_str="$(( ctx_rate / 1000000 ))M"
        elif (( ctx_rate > 1000 )); then
            ctx_str="$(( ctx_rate / 1000 ))k"
        else
            ctx_str="$ctx_rate"
        fi

        local swap_c="$C_GRN" kswapd_c="$C_GRN" kcompactd_c="$C_GRN" irq_c="$C_GRN" ctx_c="$C_GRN"
        (( swap_pct > 30 )) && swap_c="$C_YEL"
        (( swap_pct > 70 )) && swap_c="$C_RED"
        awk "BEGIN { exit (${kswapd_cpu} > 5.0 ? 0 : 1) }" 2>/dev/null && kswapd_c="$C_YEL"
        awk "BEGIN { exit (${kswapd_cpu} > 20.0 ? 0 : 1) }" 2>/dev/null && kswapd_c="$C_RED"
        awk "BEGIN { exit (${kcompactd_cpu} > 5.0 ? 0 : 1) }" 2>/dev/null && kcompactd_c="$C_YEL"
        (( irq_rate > 50000 )) && irq_c="$C_YEL"
        (( irq_rate > 100000 )) && irq_c="$C_RED"

        local gpu_str=""
        if command -v nvidia-smi &>/dev/null; then
            local gpu_temp
            gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 || true)
            [[ -n "$gpu_temp" ]] && gpu_str=" | gpu:${gpu_temp}°C"
        fi

        local ts
        ts=$(date '+%H:%M:%S')

        if [[ "$JSON_OUTPUT" == true ]]; then
            printf '{"time":"%s","swap_pct":%d,"kswapd_cpu":"%s","kcompactd_cpu":"%s","irq_rate":%d,"ctx_rate":%d}\n' \
                "$ts" "$swap_pct" "$kswapd_cpu" "$kcompactd_cpu" "$irq_rate" "$ctx_rate"
        else
            printf '\r\033[K[%s] %sswap:%d%%%s | %skswapd:%s%%%s | %skcompactd:%s%%%s | %sirq/s:%s%s | %sctx/s:%s%s%s' \
                "$ts" \
                "$swap_c" "$swap_pct" "$C_RST" \
                "$kswapd_c" "$kswapd_cpu" "$C_RST" \
                "$kcompactd_c" "$kcompactd_cpu" "$C_RST" \
                "$irq_c" "$irq_str" "$C_RST" \
                "$ctx_c" "$ctx_str" "$C_RST" \
                "$gpu_str"
        fi

        sleep 2
    done
}

# --- Main ---
main() {
    START_TIME="$(date +%s)"
    readonly START_TIME
    parse_args "$@"
    acquire_lock

    log INFO "Command=$COMMAND dry_run=$DRY_RUN verbose=$VERBOSE"

    case "$COMMAND" in
        diagnose) cmd_diagnose ;;
        fix)      cmd_fix ;;
        monitor)  cmd_monitor ;;
        rollback) cmd_rollback ;;
    esac
}

main "$@"
