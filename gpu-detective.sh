#!/usr/bin/env bash
#
# gpu-detective.sh — Detect, diagnose, and resolve undetected GPU issues on Ubuntu
#
# Usage: gpu-detective.sh [OPTIONS] [COMMAND]
#
# Commands:
#   scan        Full hardware scan for all GPUs (default)
#   drivers     Check and fix driver issues
#   bios        Inspect UEFI/BIOS-related GPU settings and recent changes
#   fix         Attempt automatic resolution of common GPU issues (respects --dry-run)
#   report      Generate a full diagnostic report file
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
# Version: 1.0.0
# Date:    2026-03-23

set -euo pipefail
IFS=$'\n\t'

# --- Constants ---
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="1.0.0"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
readonly STATE_DIR="${HOME}/.config/gpu-detective"
readonly REPORT_DIR="${STATE_DIR}/reports"

# --- Color Support ---
if [[ -t 2 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    readonly C_RED=$'\033[0;31m'
    readonly C_GREEN=$'\033[0;32m'
    readonly C_YELLOW=$'\033[0;33m'
    readonly C_BLUE=$'\033[0;34m'
    readonly C_CYAN=$'\033[0;36m'
    readonly C_BOLD=$'\033[1m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_BOLD="" C_RESET=""
fi

# --- Defaults ---
DRY_RUN=false
VERBOSE=false
QUIET=false
YES=false
JSON_OUTPUT=false
LOG_LEVEL="${LOG_LEVEL:-INFO}"
COMMAND="scan"

# --- Counters ---
ISSUES_FOUND=0
ISSUES_FIXED=0
WARNINGS=0

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
        local timestamp color
        timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        case "$level" in
            DEBUG) color="$C_CYAN"   ;;
            INFO)  color="$C_GREEN"  ;;
            WARN)  color="$C_YELLOW" ;;
            ERROR) color="$C_RED"    ;;
            *)     color="$C_RESET"  ;;
        esac
        if [[ "$JSON_OUTPUT" == true ]]; then
            printf '{"ts":"%s","level":"%s","msg":"%s"}\n' "$timestamp" "$level" "$*" >&2
        else
            printf '%s %s[%-5s]%s %s: %s\n' "$timestamp" "$color" "$level" "$C_RESET" "$SCRIPT_NAME" "$*" >&2
        fi
    fi
}

die() { log ERROR "$@"; exit 1; }

section() {
    local title="$1"
    if [[ "$QUIET" != true && "$JSON_OUTPUT" != true ]]; then
        printf '\n%s══════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RESET" >&2
        printf '%s  %s%s\n' "$C_BOLD" "$title" "$C_RESET" >&2
        printf '%s══════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RESET" >&2
    fi
}

finding() {
    local severity="$1"; shift
    local msg="$*"
    case "$severity" in
        CRITICAL) printf '  %s[CRITICAL]%s %s\n' "$C_RED" "$C_RESET" "$msg" >&2; ((ISSUES_FOUND++)) || true ;;
        WARNING)  printf '  %s[WARNING]%s  %s\n' "$C_YELLOW" "$C_RESET" "$msg" >&2; ((WARNINGS++)) || true ;;
        OK)       printf '  %s[OK]%s       %s\n' "$C_GREEN" "$C_RESET" "$msg" >&2 ;;
        INFO)     printf '  %s[INFO]%s     %s\n' "$C_BLUE" "$C_RESET" "$msg" >&2 ;;
        FIX)      printf '  %s[FIXED]%s    %s\n' "$C_GREEN" "$C_RESET" "$msg" >&2; ((ISSUES_FIXED++)) || true ;;
    esac
}

# --- Cleanup ---
cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    local end_time
    end_time="$(date +%s)"
    if [[ -n "${START_TIME:-}" ]]; then
        log INFO "Finished with exit code $exit_code (duration: $(( end_time - START_TIME ))s)"
    fi
    exit "$exit_code"
}
trap cleanup EXIT
trap 'die "Received SIGINT"' INT
trap 'die "Received SIGTERM"' TERM

# --- Argument Parsing ---
usage() {
    sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \?//' >&2
    exit 2
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -d|--dry-run)  DRY_RUN=true ;;
            -v|--verbose)  VERBOSE=true; LOG_LEVEL="DEBUG" ;;
            -q|--quiet)    QUIET=true; LOG_LEVEL="ERROR" ;;
            -y|--yes)      YES=true ;;
            --json)        JSON_OUTPUT=true; QUIET=true ;;
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

    # Parse any trailing options after the command (e.g., "fix --dry-run")
    while (( $# > 0 )); do
        case "$1" in
            -d|--dry-run)  DRY_RUN=true ;;
            -v|--verbose)  VERBOSE=true; LOG_LEVEL="DEBUG" ;;
            -q|--quiet)    QUIET=true; LOG_LEVEL="ERROR" ;;
            -y|--yes)      YES=true ;;
            --json)        JSON_OUTPUT=true; QUIET=true ;;
            -*)            die "Unknown option: $1 (use --help for usage)" ;;
            *)             die "Unexpected argument: $1" ;;
        esac
        shift
    done

    case "$COMMAND" in
        scan|drivers|bios|fix|report) ;;
        *) die "Unknown command: $COMMAND (use --help for usage)" ;;
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

# --- Dependency Checks ---
check_dependencies() {
    local required_cmds=("lspci" "modinfo" "dmesg" "lsmod")
    local optional_cmds=("nvidia-smi" "vainfo" "glxinfo" "mokutil" "efivar" "fwupdmgr")
    local missing=()

    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        die "Required commands not found: ${missing[*]}. Install with: sudo apt install pciutils kmod"
    fi

    for cmd in "${optional_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log DEBUG "Optional command not available: $cmd"
        fi
    done
}

# --- Utility ---
confirm_action() {
    local prompt="$1"
    if [[ "$YES" == true ]]; then return 0; fi
    if [[ "$DRY_RUN" == true ]]; then
        log INFO "[DRY RUN] Would: $prompt"
        return 1
    fi
    printf '\n  %s⟫ %s [y/N]: %s' "$C_YELLOW" "$prompt" "$C_RESET" >&2
    local reply
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

run_privileged() {
    local description="$1"; shift
    if [[ "$DRY_RUN" == true ]]; then
        log INFO "[DRY RUN] Would run: $*"
        return 0
    fi
    log DEBUG "Running (sudo): $*"
    if ! sudo "$@" 2>&1; then
        log ERROR "Failed: $description"
        return 1
    fi
}

# ============================================================================
#  GPU HARDWARE SCAN
# ============================================================================

scan_pci_devices() {
    section "PCI Device Scan — All Graphics Controllers"

    local gpu_count=0
    local -a detected_gpus=()

    # Scan for VGA, 3D, and Display controllers
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            detected_gpus+=("$line")
            ((gpu_count++)) || true
        fi
    done < <(lspci -nn 2>/dev/null | grep -iE 'vga|3d controller|display controller' || true)

    if (( gpu_count == 0 )); then
        finding CRITICAL "No GPU devices found in PCI bus at all"
        log ERROR "This may indicate a hardware seating issue, dead slot, or BIOS disabling the device"
        return 1
    fi

    finding INFO "Found $gpu_count GPU device(s) on PCI bus:"
    for gpu in "${detected_gpus[@]}"; do
        local pci_addr vendor_id
        pci_addr="${gpu%% *}"
        printf '    %s• %s%s\n' "$C_CYAN" "$gpu" "$C_RESET" >&2

        # Detailed device info
        log DEBUG "Detailed PCI info for $pci_addr:"
        if [[ "$VERBOSE" == true ]]; then
            lspci -v -s "$pci_addr" 2>/dev/null | while IFS= read -r detail; do
                log DEBUG "  $detail"
            done
        fi
    done

    # Check for devices with driver binding issues
    section "Driver Binding Status"
    while IFS= read -r line; do
        local pci_addr="${line%% *}"
        local driver_info
        driver_info="$(lspci -k -s "$pci_addr" 2>/dev/null || true)"

        local kernel_driver=""
        kernel_driver="$(echo "$driver_info" | grep -i 'Kernel driver in use:' | awk -F': ' '{print $2}' | xargs || true)"

        local kernel_modules=""
        kernel_modules="$(echo "$driver_info" | grep -i 'Kernel modules:' | awk -F': ' '{print $2}' | xargs || true)"

        if [[ -z "$kernel_driver" ]]; then
            finding CRITICAL "GPU at $pci_addr has NO kernel driver loaded"
            printf '    Available modules: %s\n' "${kernel_modules:-none detected}" >&2
        else
            finding OK "GPU at $pci_addr using driver: $kernel_driver"
            log DEBUG "  Available modules: $kernel_modules"
        fi
    done < <(lspci -nn 2>/dev/null | grep -iE 'vga|3d controller|display controller' || true)
}

# ============================================================================
#  DRIVER ANALYSIS
# ============================================================================

check_nvidia_drivers() {
    section "NVIDIA Driver Analysis"

    # Check if any NVIDIA GPU is present
    if ! lspci -nn | grep -qi 'nvidia'; then
        finding INFO "No NVIDIA GPU detected — skipping NVIDIA checks"
        return 0
    fi

    finding INFO "NVIDIA GPU detected, checking driver stack..."

    # Check nvidia-smi
    if command -v nvidia-smi >/dev/null 2>&1; then
        local smi_output
        if smi_output="$(nvidia-smi --query-gpu=name,driver_version,temperature.gpu,power.draw --format=csv,noheader 2>&1)"; then
            finding OK "nvidia-smi operational"
            printf '    %s\n' "$smi_output" >&2
        else
            finding CRITICAL "nvidia-smi installed but FAILING: $smi_output"
        fi
    else
        finding WARNING "nvidia-smi not found — NVIDIA driver may not be installed"
    fi

    # Check loaded NVIDIA kernel modules
    local nvidia_modules
    nvidia_modules="$(lsmod | grep -i '^nvidia' || true)"
    if [[ -z "$nvidia_modules" ]]; then
        finding CRITICAL "No NVIDIA kernel modules are loaded"

        # Check if modules exist but aren't loaded
        if modinfo nvidia >/dev/null 2>&1; then
            finding WARNING "nvidia module EXISTS but is not loaded — possible Secure Boot, blacklist, or initramfs issue"
        else
            finding CRITICAL "nvidia kernel module not found on system — driver not installed"
        fi
    else
        finding OK "NVIDIA kernel modules loaded:"
        echo "$nvidia_modules" | while IFS= read -r mod; do
            printf '    %s\n' "$mod" >&2
        done
    fi

    # Check for nouveau conflict
    local nouveau_loaded
    nouveau_loaded="$(lsmod | grep -i '^nouveau' || true)"
    if [[ -n "$nouveau_loaded" ]]; then
        finding WARNING "nouveau (open-source) driver is loaded — conflicts with proprietary NVIDIA driver"
    else
        finding OK "nouveau driver is not loaded (good for proprietary NVIDIA)"
    fi

    # Check nouveau blacklist
    local blacklist_files
    blacklist_files="$(grep -rl 'blacklist nouveau' /etc/modprobe.d/ 2>/dev/null || true)"
    if [[ -z "$blacklist_files" ]]; then
        finding WARNING "nouveau is NOT blacklisted in /etc/modprobe.d/ — may interfere with NVIDIA driver"
    else
        finding OK "nouveau blacklisted in: $blacklist_files"
    fi

    # Check installed NVIDIA packages
    finding INFO "Installed NVIDIA packages:"
    local nvidia_pkgs
    nvidia_pkgs="$(dpkg -l 2>/dev/null | grep -i nvidia | awk '{printf "    %-40s %s\n", $2, $3}' || true)"
    if [[ -n "$nvidia_pkgs" ]]; then
        echo "$nvidia_pkgs" >&2
    else
        finding CRITICAL "No NVIDIA packages installed via apt"
    fi

    # Check ubuntu-drivers
    if command -v ubuntu-drivers >/dev/null 2>&1; then
        finding INFO "Recommended drivers (ubuntu-drivers):"
        local recommended
        recommended="$(ubuntu-drivers devices 2>/dev/null || echo "  (unable to query)")"
        echo "$recommended" | sed 's/^/    /' >&2
    fi

    # Check for version mismatch between kernel module and userspace
    local installed_version=""
    installed_version="$(dpkg -l 2>/dev/null | grep 'nvidia-driver-' | head -1 | awk '{print $3}' || true)"
    local loaded_version=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        loaded_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "$installed_version" && -n "$loaded_version" ]]; then
        log DEBUG "Installed package version: $installed_version"
        log DEBUG "Running driver version: $loaded_version"
    fi
}

check_amd_drivers() {
    section "AMD GPU Driver Analysis"

    if ! lspci -nn | grep -qi 'amd\|ati\|radeon'; then
        finding INFO "No AMD GPU detected — skipping AMD checks"
        return 0
    fi

    finding INFO "AMD GPU detected, checking driver stack..."

    # Check amdgpu module
    local amdgpu_loaded
    amdgpu_loaded="$(lsmod | grep -i '^amdgpu' || true)"
    if [[ -n "$amdgpu_loaded" ]]; then
        finding OK "amdgpu kernel module loaded"
    else
        finding CRITICAL "amdgpu kernel module NOT loaded"
        if modinfo amdgpu >/dev/null 2>&1; then
            finding WARNING "amdgpu module exists but isn't loaded — check dmesg for errors"
        else
            finding CRITICAL "amdgpu module not found — missing firmware or kernel support"
        fi
    fi

    # Check radeon (legacy) module
    local radeon_loaded
    radeon_loaded="$(lsmod | grep -i '^radeon' || true)"
    if [[ -n "$radeon_loaded" ]]; then
        finding INFO "Legacy radeon module loaded (expected for older AMD GPUs)"
    fi

    # Check firmware
    local amd_firmware
    amd_firmware="$(find /lib/firmware/amdgpu/ -name '*.bin' 2>/dev/null | wc -l || echo 0)"
    if (( amd_firmware > 0 )); then
        finding OK "AMD GPU firmware files present: $amd_firmware files in /lib/firmware/amdgpu/"
    else
        finding CRITICAL "No AMD GPU firmware found in /lib/firmware/amdgpu/ — install linux-firmware"
    fi

    # Check for AMDGPU PRO
    if dpkg -l 2>/dev/null | grep -qi 'amdgpu-pro'; then
        finding INFO "AMDGPU PRO (proprietary) components detected"
    fi
}

check_intel_drivers() {
    section "Intel GPU Driver Analysis"

    if ! lspci -nn | grep -qi 'intel.*\(vga\|display\|graphics\)'; then
        # Also check by device class for integrated GPUs
        if ! lspci -nn | grep -iE '(8086:).*(vga|3d|display)' >/dev/null 2>&1; then
            finding INFO "No Intel GPU detected — skipping Intel checks"
            return 0
        fi
    fi

    finding INFO "Intel GPU detected, checking driver stack..."

    # Check i915 module
    local i915_loaded
    i915_loaded="$(lsmod | grep -i '^i915' || true)"
    if [[ -n "$i915_loaded" ]]; then
        finding OK "i915 kernel module loaded"
    else
        finding WARNING "i915 module NOT loaded — Intel integrated GPU may be disabled"
        if modinfo i915 >/dev/null 2>&1; then
            finding INFO "i915 module exists — may be disabled in BIOS or kernel params"
        fi
    fi

    # Check xe module (newer Intel GPUs, kernel 6.8+)
    local xe_loaded
    xe_loaded="$(lsmod | grep -i '^xe ' || true)"
    if [[ -n "$xe_loaded" ]]; then
        finding OK "xe (Intel Xe) kernel module loaded (modern Intel GPU driver)"
    fi

    # Check firmware
    local intel_fw
    intel_fw="$(find /lib/firmware/i915/ -name '*.bin' 2>/dev/null | wc -l || echo 0)"
    if (( intel_fw > 0 )); then
        finding OK "Intel GPU firmware present: $intel_fw files"
    else
        finding WARNING "No Intel GPU firmware found — may need linux-firmware package update"
    fi
}

# ============================================================================
#  KERNEL & SYSTEM CHECKS
# ============================================================================

check_kernel_messages() {
    section "Kernel Messages — GPU Related Errors"

    local dmesg_output
    if ! dmesg_output="$(sudo dmesg 2>/dev/null || dmesg 2>/dev/null)"; then
        finding WARNING "Cannot read dmesg — run with sudo for full kernel log analysis"
        return 0
    fi

    # GPU-related errors
    local gpu_errors
    gpu_errors="$(echo "$dmesg_output" | grep -iE '(nvidia|amdgpu|radeon|i915|nouveau|drm|gpu)' | grep -iE '(error|fail|fatal|refused|timeout|firmware)' | tail -20 || true)"

    if [[ -n "$gpu_errors" ]]; then
        finding CRITICAL "GPU-related errors found in kernel log:"
        echo "$gpu_errors" | while IFS= read -r err; do
            printf '    %s%s%s\n' "$C_RED" "$err" "$C_RESET" >&2
        done
    else
        finding OK "No GPU errors found in kernel log"
    fi

    # Check for specific known issues
    if echo "$dmesg_output" | grep -qi 'NVRM: RmInitAdapter failed'; then
        finding CRITICAL "NVIDIA RmInitAdapter failed — driver/hardware init failure"
        finding INFO "  Common causes: driver version mismatch, GPU power issue, or Secure Boot"
    fi

    if echo "$dmesg_output" | grep -qi 'gpu is lost\|fallen off the bus'; then
        finding CRITICAL "GPU reported as LOST or fallen off the bus"
        finding INFO "  Common causes: insufficient PCIe power, overheating, or bad riser cable"
    fi

    if echo "$dmesg_output" | grep -qi 'direct firmware load.*failed'; then
        finding WARNING "Firmware loading failed for GPU — check linux-firmware package"
        local fw_fails
        fw_fails="$(echo "$dmesg_output" | grep -i 'direct firmware load.*failed' | grep -iE '(nvidia|amdgpu|radeon|i915)' | tail -5 || true)"
        if [[ -n "$fw_fails" ]]; then
            echo "$fw_fails" | sed 's/^/    /' >&2
        fi
    fi

    if echo "$dmesg_output" | grep -qi 'BAR.*collision\|BAR.*overlap\|can.*assign.*resource'; then
        finding CRITICAL "PCI BAR (Base Address Register) collision detected"
        finding INFO "  This means BIOS didn't properly allocate memory for the GPU"
        finding INFO "  Fix: Enable 'Above 4G Decoding' and 'Resizable BAR' in BIOS"
    fi

    if echo "$dmesg_output" | grep -qi 'AER.*error\|PCIe.*error\|aer:.*Corrected'; then
        finding WARNING "PCIe Advanced Error Reporting (AER) errors detected"
        local aer_errors
        aer_errors="$(echo "$dmesg_output" | grep -iE 'AER|PCIe.*error' | tail -5 || true)"
        echo "$aer_errors" | sed 's/^/    /' >&2
    fi
}

check_secure_boot() {
    section "Secure Boot & Module Signing"

    local sb_state="unknown"
    if command -v mokutil >/dev/null 2>&1; then
        sb_state="$(mokutil --sb-state 2>/dev/null || echo "unknown")"
        if echo "$sb_state" | grep -qi 'enabled'; then
            finding WARNING "Secure Boot is ENABLED"
            finding INFO "  Unsigned third-party GPU drivers (NVIDIA proprietary) may fail to load"
            finding INFO "  Solutions:"
            finding INFO "    1) Sign the kernel module with MOK (Machine Owner Key)"
            finding INFO "    2) Disable Secure Boot in BIOS (less secure)"
            finding INFO "    3) Use DKMS auto-signing (ubuntu enroll MOK during driver install)"

            # Check if NVIDIA DKMS signing is configured
            if [[ -f /var/lib/shim-signed/mok/MOK.priv ]]; then
                finding OK "MOK signing key found — DKMS should auto-sign modules"
            else
                finding WARNING "No MOK signing key found at /var/lib/shim-signed/mok/"
                finding INFO "  If NVIDIA driver won't load, this is likely the cause"
                finding INFO "  Run with 'fix' command to auto-generate and enroll a MOK key"
            fi

            # Check if NVIDIA modules are actually signed
            local nvidia_mod_path
            nvidia_mod_path="$(modinfo -n nvidia 2>/dev/null || true)"
            if [[ -n "$nvidia_mod_path" && -f "$nvidia_mod_path" ]]; then
                local signer
                signer="$(modinfo nvidia 2>/dev/null | grep -i 'signer:' || true)"
                if [[ -n "$signer" ]]; then
                    finding OK "NVIDIA module is signed: $(echo "$signer" | awk -F: '{print $2}' | xargs)"
                else
                    finding CRITICAL "NVIDIA module is NOT signed — will fail to load with Secure Boot"
                fi
            fi
        elif echo "$sb_state" | grep -qi 'disabled'; then
            finding OK "Secure Boot is DISABLED — unsigned drivers can load"
        else
            finding INFO "Secure Boot state: $sb_state"
        fi
    else
        finding INFO "mokutil not installed — cannot check Secure Boot state"
        finding INFO "  Install with: sudo apt install mokutil"
    fi
}

check_kernel_params() {
    section "Kernel Boot Parameters — GPU Related"

    local cmdline
    cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
    log DEBUG "Full cmdline: $cmdline"

    # Check for nomodeset (disables GPU drivers!)
    if echo "$cmdline" | grep -qw 'nomodeset'; then
        finding CRITICAL "'nomodeset' is set in kernel parameters — this DISABLES modern GPU drivers"
        finding INFO "  Remove 'nomodeset' from GRUB_CMDLINE_LINUX in /etc/default/grub"
        finding INFO "  Then run: sudo update-grub && sudo reboot"
    else
        finding OK "nomodeset is NOT set (GPU drivers can load normally)"
    fi

    # Check for module blacklisting via cmdline
    if echo "$cmdline" | grep -qiE 'modprobe\.blacklist=.*(nvidia|amdgpu|nouveau|i915|radeon)'; then
        finding WARNING "GPU module blacklisted via kernel command line:"
        echo "$cmdline" | grep -oE 'modprobe\.blacklist=[^ ]*' | sed 's/^/    /' >&2
    fi

    # Check for iommu (important for GPU passthrough)
    if echo "$cmdline" | grep -qi 'iommu'; then
        finding INFO "IOMMU parameters detected (GPU passthrough may be configured):"
        echo "$cmdline" | grep -oE '(intel_iommu|amd_iommu|iommu)=[^ ]*' | sed 's/^/    /' >&2
    fi

    # Check for specific NVIDIA params
    if echo "$cmdline" | grep -qiE 'nvidia|NVreg'; then
        finding INFO "NVIDIA kernel parameters:"
        echo "$cmdline" | grep -oiE '(nvidia|NVreg)[^ ]*' | sed 's/^/    /' >&2
    fi

    # Check for pci= parameters
    if echo "$cmdline" | grep -qE 'pci='; then
        finding INFO "PCI parameters set:"
        echo "$cmdline" | grep -oE 'pci=[^ ]*' | sed 's/^/    /' >&2
    fi

    # GRUB config check
    if [[ -f /etc/default/grub ]]; then
        local grub_cmdline
        grub_cmdline="$(grep '^GRUB_CMDLINE_LINUX' /etc/default/grub || true)"
        if [[ -n "$grub_cmdline" ]]; then
            finding INFO "GRUB default config:"
            echo "$grub_cmdline" | sed 's/^/    /' >&2
        fi
    fi
}

check_initramfs() {
    section "Initramfs — GPU Module Inclusion"

    local current_kernel
    current_kernel="$(uname -r)"
    local initrd="/boot/initrd.img-${current_kernel}"

    if [[ ! -f "$initrd" ]]; then
        finding WARNING "Initramfs not found at $initrd"
        return 0
    fi

    finding INFO "Checking initramfs for kernel $current_kernel..."

    # Check if GPU modules are in initramfs
    local initrd_modules
    if command -v lsinitramfs >/dev/null 2>&1; then
        initrd_modules="$(lsinitramfs "$initrd" 2>/dev/null || true)"

        for mod in nvidia amdgpu i915 nouveau radeon; do
            if echo "$initrd_modules" | grep -qi "$mod"; then
                finding OK "$mod module found in initramfs"
            else
                log DEBUG "$mod module NOT in initramfs (may load later from disk)"
            fi
        done
    else
        finding INFO "lsinitramfs not available — install initramfs-tools for deep analysis"
    fi

    # Check initramfs age
    local initrd_age
    initrd_age="$(stat -c %Y "$initrd" 2>/dev/null || echo 0)"
    local now
    now="$(date +%s)"
    local age_days=$(( (now - initrd_age) / 86400 ))

    if (( age_days > 90 )); then
        finding WARNING "Initramfs is $age_days days old — may be outdated after kernel/driver updates"
        finding INFO "  Rebuild with: sudo update-initramfs -u"
    else
        finding OK "Initramfs is $age_days days old"
    fi
}

# ============================================================================
#  BIOS/UEFI CHECKS
# ============================================================================

check_bios_settings() {
    section "BIOS/UEFI — GPU-Related Settings & Changes"

    # Check UEFI vs Legacy BIOS
    if [[ -d /sys/firmware/efi ]]; then
        finding OK "System booted in UEFI mode"
    else
        finding INFO "System booted in Legacy BIOS mode"
    fi

    # Check PCIe slot link speed/width
    finding INFO "PCIe Link Status for GPU devices:"
    while IFS= read -r line; do
        local pci_addr="${line%% *}"
        local link_info
        link_info="$(sudo lspci -vv -s "$pci_addr" 2>/dev/null | grep -iE 'LnkSta:|LnkCap:' || true)"
        if [[ -n "$link_info" ]]; then
            printf '    %s[%s]%s\n' "$C_BOLD" "$pci_addr" "$C_RESET" >&2
            echo "$link_info" | sed 's/^[[:space:]]*/    /' >&2

            # Parse link speed for degradation check
            local cap_speed cap_width sta_speed sta_width
            cap_speed="$(echo "$link_info" | grep 'LnkCap:' | grep -oP 'Speed \K[^,]+' || true)"
            cap_width="$(echo "$link_info" | grep 'LnkCap:' | grep -oP 'Width \K[^,]+' || true)"
            sta_speed="$(echo "$link_info" | grep 'LnkSta:' | grep -oP 'Speed \K[^,( ]+' || true)"
            sta_width="$(echo "$link_info" | grep 'LnkSta:' | grep -oP 'Width \K[^,( ]+' || true)"

            if [[ -n "$cap_width" && -n "$sta_width" && "$cap_width" != "$sta_width" ]]; then
                finding WARNING "GPU at $pci_addr running at $sta_width (capable of $cap_width)"
                finding INFO "  Possible causes: wrong slot, bad riser, BIOS PCIe config, or power saving"
            fi
            if [[ -n "$cap_speed" && -n "$sta_speed" && "$cap_speed" != "$sta_speed" ]]; then
                finding WARNING "GPU at $pci_addr running at $sta_speed (capable of $cap_speed)"
            fi
        fi
    done < <(lspci -nn 2>/dev/null | grep -iE 'vga|3d controller|display controller' || true)

    # Check IOMMU groups (relevant for BIOS VT-d/AMD-Vi)
    if [[ -d /sys/kernel/iommu_groups ]]; then
        local iommu_groups
        iommu_groups="$(find /sys/kernel/iommu_groups/ -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"
        if (( iommu_groups > 0 )); then
            finding OK "IOMMU active with $iommu_groups groups (VT-d/AMD-Vi enabled in BIOS)"
        else
            finding INFO "IOMMU directory exists but no groups — VT-d/AMD-Vi may be disabled in BIOS"
        fi
    fi

    # Firmware update check via fwupdmgr
    if command -v fwupdmgr >/dev/null 2>&1; then
        section "Firmware Updates (fwupd)"
        finding INFO "Checking for BIOS/UEFI firmware updates..."

        local fw_devices
        fw_devices="$(fwupdmgr get-devices 2>/dev/null || true)"
        if [[ -n "$fw_devices" ]] && echo "$fw_devices" | grep -qi 'UEFI\|BIOS\|system firmware'; then
            # Show BIOS/UEFI firmware info
            echo "$fw_devices" | grep -A5 -iE '(UEFI|BIOS|system firmware)' | head -20 | sed 's/^/    /' >&2

            # Check for pending updates
            local fw_updates
            fw_updates="$(fwupdmgr get-updates 2>/dev/null || echo "No updates available")"
            if echo "$fw_updates" | grep -qi 'update'; then
                finding WARNING "Firmware updates are available:"
                echo "$fw_updates" | head -15 | sed 's/^/    /' >&2
                finding INFO "  Apply with: sudo fwupdmgr update"
            else
                finding OK "System firmware is up to date"
            fi
        fi

        # Check firmware history for recent BIOS changes
        finding INFO "Recent firmware change history:"
        local fw_history
        fw_history="$(fwupdmgr get-history 2>/dev/null || true)"
        if [[ -n "$fw_history" ]]; then
            echo "$fw_history" | head -20 | sed 's/^/    /' >&2
        else
            finding INFO "  No firmware update history available"
        fi
    else
        finding INFO "fwupdmgr not available — install fwupd for BIOS/firmware analysis"
        finding INFO "  sudo apt install fwupd"
    fi

    # Check EFI variables for recent changes
    if [[ -d /sys/firmware/efi/efivars ]]; then
        finding INFO "Checking EFI variable activity..."
        local recent_efi
        recent_efi="$(find /sys/firmware/efi/efivars/ -maxdepth 1 -mtime -7 -name '*.efi' 2>/dev/null | head -10 || true)"
        if [[ -n "$recent_efi" ]]; then
            finding INFO "EFI variables modified in last 7 days:"
            echo "$recent_efi" | sed 's/^/    /' >&2
        else
            finding OK "No recent EFI variable changes detected"
        fi
    fi

    # DMI/SMBIOS BIOS info
    section "BIOS/UEFI Version Information"
    if [[ -f /sys/class/dmi/id/bios_vendor ]]; then
        local bios_vendor bios_version bios_date
        bios_vendor="$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null || echo "unknown")"
        bios_version="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo "unknown")"
        bios_date="$(cat /sys/class/dmi/id/bios_date 2>/dev/null || echo "unknown")"
        finding INFO "BIOS Vendor:  $bios_vendor"
        finding INFO "BIOS Version: $bios_version"
        finding INFO "BIOS Date:    $bios_date"
    fi

    # Recommended BIOS settings for GPU
    section "Recommended BIOS Settings for GPU Detection"
    printf '  %sCheck these settings in your BIOS/UEFI setup:%s\n' "$C_BOLD" "$C_RESET" >&2
    printf '    • %sPrimary Display / Init Display First%s: Set to PCIe (not onboard/iGPU)\n' "$C_CYAN" "$C_RESET" >&2
    printf '    • %sAbove 4G Decoding%s: ENABLED (required for modern GPUs with large BARs)\n' "$C_CYAN" "$C_RESET" >&2
    printf '    • %sResizable BAR (ReBAR/SAM)%s: ENABLED if supported\n' "$C_CYAN" "$C_RESET" >&2
    printf '    • %sCSM (Compatibility Support Module)%s: DISABLED (use pure UEFI)\n' "$C_CYAN" "$C_RESET" >&2
    printf '    • %sPCIe Generation%s: Set to Auto or match GPU capability\n' "$C_CYAN" "$C_RESET" >&2
    printf '    • %sIntegrated Graphics%s: Can be Auto or Disabled if discrete GPU only\n' "$C_CYAN" "$C_RESET" >&2
    printf '    • %sVT-d / AMD-Vi (IOMMU)%s: ENABLED for passthrough, optional otherwise\n' "$C_CYAN" "$C_RESET" >&2
    printf '    • %sSecure Boot%s: May need MOK enrollment for NVIDIA proprietary driver\n' "$C_CYAN" "$C_RESET" >&2
}

# ============================================================================
#  DISPLAY SERVER & RENDERING
# ============================================================================

check_display_stack() {
    section "Display Server & Rendering Pipeline"

    # Wayland vs X11
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        finding INFO "Display server: Wayland (${WAYLAND_DISPLAY})"
    elif [[ -n "${DISPLAY:-}" ]]; then
        finding INFO "Display server: X11 (${DISPLAY})"
    else
        finding INFO "No display server detected (headless or SSH session)"
    fi

    # DRM devices
    finding INFO "DRM render nodes:"
    local drm_count=0
    for card in /dev/dri/card*; do
        if [[ -e "$card" ]]; then
            local card_driver
            card_driver="$(udevadm info -q property "$card" 2>/dev/null | grep 'ID_PATH_TAG\|DRIVER' | head -3 || true)"
            printf '    %s — %s\n' "$card" "$card_driver" >&2
            ((drm_count++)) || true
        fi
    done
    if (( drm_count == 0 )); then
        finding CRITICAL "No DRM devices found at /dev/dri/ — GPU driver is not creating render nodes"
    fi

    # Render nodes
    for render in /dev/dri/renderD*; do
        if [[ -e "$render" ]]; then
            finding OK "Render node available: $render"
        fi
    done

    # Check OpenGL via glxinfo
    if command -v glxinfo >/dev/null 2>&1; then
        local gl_renderer gl_vendor gl_version
        gl_renderer="$(glxinfo 2>/dev/null | grep 'OpenGL renderer' | head -1 || true)"
        gl_vendor="$(glxinfo 2>/dev/null | grep 'OpenGL vendor' | head -1 || true)"
        gl_version="$(glxinfo 2>/dev/null | grep 'OpenGL version' | head -1 || true)"

        if [[ -n "$gl_renderer" ]]; then
            finding OK "OpenGL rendering active:"
            printf '    %s\n    %s\n    %s\n' "$gl_renderer" "$gl_vendor" "$gl_version" >&2

            if echo "$gl_renderer" | grep -qi 'llvmpipe\|swrast\|software'; then
                finding CRITICAL "OpenGL is using SOFTWARE rendering (llvmpipe/swrast)"
                finding INFO "  GPU hardware acceleration is NOT working"
            fi
        else
            finding WARNING "Could not query OpenGL info"
        fi
    else
        finding INFO "glxinfo not available — install with: sudo apt install mesa-utils"
    fi

    # Check VA-API (video acceleration)
    if command -v vainfo >/dev/null 2>&1; then
        if vainfo 2>/dev/null | grep -qi 'driver\|profile'; then
            finding OK "VA-API video acceleration is available"
        else
            finding INFO "VA-API not functioning"
        fi
    fi

    # Vulkan
    if command -v vulkaninfo >/dev/null 2>&1; then
        local vk_gpus
        vk_gpus="$(vulkaninfo --summary 2>/dev/null | grep -i 'deviceName\|driverName' | head -4 || true)"
        if [[ -n "$vk_gpus" ]]; then
            finding OK "Vulkan devices detected:"
            echo "$vk_gpus" | sed 's/^/    /' >&2
        fi
    fi
}

# ============================================================================
#  POWER & THERMAL
# ============================================================================

check_gpu_power() {
    section "GPU Power & Thermal Status"

    # NVIDIA power check
    if command -v nvidia-smi >/dev/null 2>&1; then
        local power_info
        power_info="$(nvidia-smi --query-gpu=name,power.draw,power.limit,temperature.gpu,fan.speed,pstate --format=csv,noheader 2>/dev/null || true)"
        if [[ -n "$power_info" ]]; then
            finding INFO "NVIDIA GPU status:"
            echo "$power_info" | while IFS=',' read -r name power limit temp fan pstate; do
                printf '    Name: %s\n' "$name" >&2
                printf '    Power: %s / %s (limit)\n' "$power" "$limit" >&2
                printf '    Temperature: %s°C | Fan: %s | P-State: %s\n' "$temp" "$fan" "$pstate" >&2
            done
        fi
    fi

    # Check GPU runtime PM status
    finding INFO "GPU runtime power management:"
    while IFS= read -r line; do
        local pci_addr="${line%% *}"
        local pm_status
        pm_status="$(cat "/sys/bus/pci/devices/0000:${pci_addr}/power/runtime_status" 2>/dev/null || echo "unknown")"
        local pm_control
        pm_control="$(cat "/sys/bus/pci/devices/0000:${pci_addr}/power/control" 2>/dev/null || echo "unknown")"
        printf '    %s: status=%s control=%s\n' "$pci_addr" "$pm_status" "$pm_control" >&2

        if [[ "$pm_status" == "suspended" ]]; then
            finding WARNING "GPU at $pci_addr is SUSPENDED — runtime PM may prevent detection"
        fi
    done < <(lspci -nn 2>/dev/null | grep -iE 'vga|3d controller|display controller' || true)
}

# ============================================================================
#  AUTOMATIC FIX ATTEMPTS
# ============================================================================

attempt_fixes() {
    section "Automatic Fix Attempts"

    if (( ISSUES_FOUND == 0 )); then
        finding OK "No critical issues detected — nothing to fix"
        return 0
    fi

    # Fix 1: nomodeset removal
    if grep -qw 'nomodeset' /proc/cmdline 2>/dev/null; then
        if confirm_action "Remove 'nomodeset' from GRUB config"; then
            if [[ -f /etc/default/grub ]]; then
                run_privileged "Remove nomodeset from GRUB" \
                    sed -i 's/nomodeset//g; s/  */ /g' /etc/default/grub
                run_privileged "Update GRUB" update-grub
                finding FIX "Removed nomodeset from GRUB — REBOOT REQUIRED"
            fi
        fi
    fi

    # Fix 2: Blacklist nouveau for NVIDIA
    if lspci -nn | grep -qi 'nvidia' && lsmod | grep -qi '^nouveau'; then
        if confirm_action "Blacklist nouveau and switch to NVIDIA proprietary driver"; then
            run_privileged "Create nouveau blacklist" \
                bash -c 'echo -e "blacklist nouveau\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf'
            run_privileged "Update initramfs" update-initramfs -u
            finding FIX "Blacklisted nouveau driver — REBOOT REQUIRED"
        fi
    fi

    # Fix 3: Install/upgrade NVIDIA driver (interactive version selection)
    if lspci -nn | grep -qi 'nvidia'; then
        if command -v ubuntu-drivers >/dev/null 2>&1; then
            # Detect current installed driver
            local current_pkg current_ver=""
            current_pkg="$(dpkg -l 2>/dev/null | grep -E '^ii\s+nvidia-driver-[0-9]' | head -1 || true)"
            if [[ -n "$current_pkg" ]]; then
                current_ver="$(echo "$current_pkg" | awk '{print $2}')"
                finding INFO "Currently installed: $current_ver"
            else
                finding INFO "No NVIDIA driver package currently installed"
            fi

            # Get available drivers and the recommended one
            local available recommended_line recommended_pkg=""
            available="$(ubuntu-drivers devices 2>/dev/null || true)"
            recommended_line="$(echo "$available" | grep 'recommended' || true)"
            if [[ -n "$recommended_line" ]]; then
                recommended_pkg="$(echo "$recommended_line" | awk '{print $3}')"
            fi

            # Build list of available driver versions
            local -a driver_list
            mapfile -t driver_list < <(echo "$available" | grep -oP 'nvidia-driver-\S+' | sort -t- -k3 -n -u)

            if [[ ${#driver_list[@]} -eq 0 ]]; then
                finding WARNING "No NVIDIA drivers found via ubuntu-drivers"
            else
                # Warn about potential downgrade
                if [[ -n "$current_ver" && -n "$recommended_pkg" && "$recommended_pkg" != "$current_ver" ]]; then
                    local rec_num cur_num
                    rec_num="$(echo "$recommended_pkg" | grep -oP '[0-9]+' | head -1)"
                    cur_num="$(echo "$current_ver" | grep -oP '[0-9]+' | head -1)"
                    if (( rec_num < cur_num )); then
                        finding WARNING "Recommended driver ($recommended_pkg) is OLDER than installed ($current_ver) — autoinstall would DOWNGRADE"
                    fi
                fi

                # In --yes mode, default to recommended (autoinstall) with warning
                if [[ "$YES" == true ]]; then
                    run_privileged "Install recommended NVIDIA driver" ubuntu-drivers autoinstall
                    finding FIX "Installed recommended driver ($recommended_pkg) — REBOOT REQUIRED"
                elif [[ "$DRY_RUN" == true ]]; then
                    log INFO "[DRY RUN] Would show driver selection menu"
                    printf '\n  Available NVIDIA drivers:\n' >&2
                    printf '    %s0)%s Recommended (%s) — ubuntu-drivers autoinstall\n' "$C_GREEN" "$C_RESET" "${recommended_pkg:-unknown}" >&2
                    local i=1
                    for drv in "${driver_list[@]}"; do
                        local marker=""
                        [[ "$drv" == "$current_ver" ]] && marker=" (installed)"
                        printf '    %d) %s%s\n' "$i" "$drv" "$marker" >&2
                        ((i++)) || true
                    done
                else
                    # Interactive menu
                    printf '\n  Available NVIDIA drivers:\n' >&2
                    printf '    %s0)%s Recommended (%s) — ubuntu-drivers autoinstall\n' "$C_GREEN" "$C_RESET" "${recommended_pkg:-unknown}" >&2
                    local i=1
                    for drv in "${driver_list[@]}"; do
                        local marker=""
                        [[ "$drv" == "$current_ver" ]] && marker=" (installed)"
                        printf '    %d) %s%s\n' "$i" "$drv" "$marker" >&2
                        ((i++)) || true
                    done
                    printf '    s) Skip\n\n' >&2
                    printf '  %s⟫ Select driver [0-%d/s]: %s' "$C_YELLOW" "${#driver_list[@]}" "$C_RESET" >&2

                    local choice
                    read -r choice
                    case "$choice" in
                        0)
                            run_privileged "Install recommended NVIDIA driver" ubuntu-drivers autoinstall
                            finding FIX "Installed recommended driver ($recommended_pkg) — REBOOT REQUIRED"
                            ;;
                        [1-9]*)
                            local idx=$((choice - 1))
                            if (( idx >= 0 && idx < ${#driver_list[@]} )); then
                                local selected="${driver_list[$idx]}"
                                run_privileged "Install $selected" apt install -y "$selected"
                                finding FIX "Installed $selected — REBOOT REQUIRED"
                            else
                                finding INFO "Invalid selection — skipping driver install"
                            fi
                            ;;
                        *)
                            finding INFO "Skipped driver installation"
                            ;;
                    esac
                fi
            fi
        fi
    fi

    # Fix 4: Rebuild initramfs (stale modules)
    local initrd_age
    initrd_age="$(stat -c %Y "/boot/initrd.img-$(uname -r)" 2>/dev/null || echo 0)"
    local now
    now="$(date +%s)"
    if (( (now - initrd_age) / 86400 > 90 )); then
        if confirm_action "Rebuild initramfs (stale, >90 days old)"; then
            run_privileged "Rebuild initramfs" update-initramfs -u
            finding FIX "Rebuilt initramfs"
        fi
    fi

    # Fix 5: Install missing firmware
    local fw_missing=false
    if lspci -nn | grep -qi 'amd\|radeon' && ! find /lib/firmware/amdgpu/ -name '*.bin' 2>/dev/null | grep -q .; then
        fw_missing=true
    fi
    if [[ "$fw_missing" == true ]]; then
        if confirm_action "Install/update linux-firmware package"; then
            run_privileged "Update firmware" apt install -y linux-firmware
            run_privileged "Rebuild initramfs" update-initramfs -u
            finding FIX "Updated linux-firmware package — REBOOT REQUIRED"
        fi
    fi

    # Fix 6: Secure Boot — generate MOK key and sign NVIDIA modules
    if command -v mokutil >/dev/null 2>&1 && lspci -nn | grep -qi 'nvidia'; then
        local sb_state
        sb_state="$(mokutil --sb-state 2>/dev/null || true)"
        if echo "$sb_state" | grep -qi 'enabled'; then
            local mok_dir="/var/lib/shim-signed/mok"

            # Helper: sign all unsigned NVIDIA modules
            _sign_nvidia_modules() {
                local sign_tool=""
                if [[ -x "/usr/src/linux-headers-$(uname -r)/scripts/sign-file" ]]; then
                    sign_tool="/usr/src/linux-headers-$(uname -r)/scripts/sign-file"
                elif command -v kmodsign >/dev/null 2>&1; then
                    sign_tool="kmodsign"
                fi

                if [[ -z "$sign_tool" ]]; then
                    finding WARNING "No signing tool found (need linux-headers-$(uname -r) or kmodsign)"
                    finding INFO "  Install with: sudo apt install linux-headers-$(uname -r)"
                    return 1
                fi

                local signed_count=0
                while IFS= read -r mod_path; do
                    [[ -f "$mod_path" ]] || continue
                    log DEBUG "Signing: $mod_path"
                    if run_privileged "Sign $(basename "$mod_path")" \
                        "$sign_tool" sha256 "$mok_dir/MOK.priv" "$mok_dir/MOK.der" "$mod_path"; then
                        ((signed_count++)) || true
                    fi
                done < <(find "/lib/modules/$(uname -r)/updates" \( -name 'nvidia*.ko' -o -name 'nvidia*.ko.zst' -o -name 'nvidia*.ko.xz' -o -name 'nvidia*.ko.gz' \) 2>/dev/null || true)
                finding FIX "Signed $signed_count NVIDIA module(s) with MOK key"
            }

            if [[ ! -f "$mok_dir/MOK.priv" ]]; then
                finding WARNING "Secure Boot is enabled but no MOK signing key exists"
                if confirm_action "Generate MOK keypair, sign NVIDIA modules, and enroll key for Secure Boot"; then
                    # Step 1: Generate keypair
                    run_privileged "Create MOK directory" mkdir -p "$mok_dir"
                    run_privileged "Generate MOK keypair" \
                        openssl req -new -x509 -newkey rsa:2048 \
                        -keyout "$mok_dir/MOK.priv" \
                        -outform DER -out "$mok_dir/MOK.der" \
                        -nodes -days 36500 \
                        -subj "/CN=GPU Detective MOK Signing Key/"
                    run_privileged "Restrict MOK private key permissions" chmod 600 "$mok_dir/MOK.priv"

                    # Step 2: Sign NVIDIA modules
                    _sign_nvidia_modules

                    # Step 3: Enroll the key (user sets a one-time password for MOK Manager)
                    finding INFO "Enrolling MOK key — you will be prompted for a one-time password"
                    finding INFO "  IMPORTANT: Remember this password! At next reboot, the blue"
                    finding INFO "  MOK Manager screen will appear: Enroll MOK → Continue → Enter password"
                    run_privileged "Enroll MOK key" mokutil --import "$mok_dir/MOK.der"
                    finding FIX "MOK key enrolled — REBOOT REQUIRED to complete enrollment"

                    # Step 4: Configure DKMS to reuse this key for future kernel/driver updates
                    local dkms_conf="/etc/dkms/framework.conf"
                    if [[ -f "$dkms_conf" ]] && ! grep -q "mok_signing_key" "$dkms_conf" 2>/dev/null; then
                        run_privileged "Configure DKMS to use MOK key" \
                            bash -c "printf '\nmok_signing_key=%s\nmok_certificate=%s\n' '$mok_dir/MOK.priv' '$mok_dir/MOK.der' >> '$dkms_conf'"
                        finding FIX "Configured DKMS to auto-sign future module builds with MOK key"
                    fi
                fi
            else
                # Key exists — check if modules are actually signed
                finding OK "MOK signing key exists at $mok_dir/MOK.priv"
                local unsigned_count=0
                local unsigned_list=()
                while IFS= read -r mod_path; do
                    [[ -f "$mod_path" ]] || continue
                    local mod_info
                    mod_info="$(modinfo "$mod_path" 2>/dev/null || true)"
                    if ! echo "$mod_info" | grep -q 'signer:'; then
                        ((unsigned_count++)) || true
                        unsigned_list+=("$mod_path")
                    fi
                done < <(find "/lib/modules/$(uname -r)/updates" \( -name 'nvidia*.ko' -o -name 'nvidia*.ko.zst' -o -name 'nvidia*.ko.xz' -o -name 'nvidia*.ko.gz' \) 2>/dev/null || true)

                if (( unsigned_count > 0 )); then
                    finding WARNING "$unsigned_count NVIDIA module(s) are unsigned despite MOK key existing"
                    for umod in "${unsigned_list[@]}"; do
                        finding INFO "  Unsigned: $(basename "$umod")"
                    done
                    if confirm_action "Re-sign $unsigned_count unsigned NVIDIA module(s)"; then
                        _sign_nvidia_modules
                    fi
                else
                    finding OK "All NVIDIA modules are signed"
                fi
            fi
        fi
    fi

    # Fix 7: Load GPU module manually
    for mod in nvidia amdgpu i915; do
        if modinfo "$mod" >/dev/null 2>&1 && ! lsmod | grep -qi "^$mod"; then
            # Only try to load if relevant GPU is present
            local should_load=false
            case "$mod" in
                nvidia)  lspci -nn | grep -qi 'nvidia' && should_load=true ;;
                amdgpu)  lspci -nn | grep -qi 'amd.*\(vga\|3d\|display\)' && should_load=true ;;
                i915)    lspci -nn | grep -qi 'intel.*\(vga\|display\)' && should_load=true ;;
            esac
            if [[ "$should_load" == true ]]; then
                if confirm_action "Try loading $mod kernel module now"; then
                    if run_privileged "Load $mod module" modprobe "$mod"; then
                        finding FIX "Loaded $mod kernel module"
                    else
                        finding WARNING "Failed to load $mod — check dmesg for details"
                    fi
                fi
            fi
        fi
    done
}

# ============================================================================
#  REPORT GENERATION
# ============================================================================

generate_report() {
    mkdir -p "$REPORT_DIR"
    local report_file="${REPORT_DIR}/gpu-report-$(date +%Y%m%d-%H%M%S).txt"

    {
        echo "=== GPU Detective Report ==="
        echo "Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -r)"
        echo "Ubuntu: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
        echo ""
        echo "=== PCI GPU Devices ==="
        lspci -nnk 2>/dev/null | grep -A3 -iE 'vga|3d controller|display controller' || true
        echo ""
        echo "=== Loaded GPU Modules ==="
        lsmod | grep -iE 'nvidia|amdgpu|radeon|nouveau|i915|xe|drm' || echo "none"
        echo ""
        echo "=== Kernel Parameters ==="
        cat /proc/cmdline
        echo ""
        echo "=== GPU dmesg Errors ==="
        dmesg 2>/dev/null | grep -iE '(nvidia|amdgpu|radeon|i915|nouveau|drm|gpu)' | grep -iE '(error|fail|warn|firmware)' | tail -30 || echo "none"
        echo ""
        echo "=== DRM Devices ==="
        ls -la /dev/dri/ 2>/dev/null || echo "none"
        echo ""
        echo "=== Secure Boot ==="
        mokutil --sb-state 2>/dev/null || echo "unknown"
        echo ""
        echo "=== NVIDIA Packages ==="
        dpkg -l 2>/dev/null | grep -i nvidia || echo "none"
        echo ""
        echo "=== BIOS Info ==="
        echo "Vendor: $(cat /sys/class/dmi/id/bios_vendor 2>/dev/null || echo unknown)"
        echo "Version: $(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo unknown)"
        echo "Date: $(cat /sys/class/dmi/id/bios_date 2>/dev/null || echo unknown)"
    } > "$report_file"

    finding OK "Report saved to: $report_file"
    echo "$report_file"
}

# ============================================================================
#  SUMMARY
# ============================================================================

print_summary() {
    section "Summary"

    printf '  Issues found:  %s%d%s\n' "$C_RED" "$ISSUES_FOUND" "$C_RESET" >&2
    printf '  Warnings:      %s%d%s\n' "$C_YELLOW" "$WARNINGS" "$C_RESET" >&2
    printf '  Issues fixed:  %s%d%s\n' "$C_GREEN" "$ISSUES_FIXED" "$C_RESET" >&2

    if (( ISSUES_FOUND > 0 && ISSUES_FIXED < ISSUES_FOUND )); then
        printf '\n  %sUnresolved issues remain. Run with "fix" command to attempt automatic repair:%s\n' "$C_YELLOW" "$C_RESET" >&2
        printf '    sudo %s fix\n' "$SCRIPT_NAME" >&2
        printf '    sudo %s fix --dry-run   # preview first\n\n' "$SCRIPT_NAME" >&2
    fi

    if (( ISSUES_FIXED > 0 )); then
        printf '\n  %s*** REBOOT REQUIRED to apply changes ***%s\n\n' "${C_BOLD}${C_YELLOW}" "$C_RESET" >&2
    fi

    if (( ISSUES_FOUND == 0 && WARNINGS == 0 )); then
        printf '\n  %sAll GPU checks passed — hardware and drivers look healthy.%s\n\n' "$C_GREEN" "$C_RESET" >&2
    fi
}

# ============================================================================
#  MAIN
# ============================================================================

main() {
    readonly START_TIME="$(date +%s)"
    parse_args "$@"
    acquire_lock
    check_dependencies

    mkdir -p "$STATE_DIR"
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME}.XXXXXX")"
    readonly TEMP_DIR

    log INFO "GPU Detective v${SCRIPT_VERSION} — command=$COMMAND dry_run=$DRY_RUN"

    case "$COMMAND" in
        scan)
            scan_pci_devices
            check_nvidia_drivers
            check_amd_drivers
            check_intel_drivers
            check_kernel_messages
            check_secure_boot
            check_kernel_params
            check_initramfs
            check_bios_settings
            check_display_stack
            check_gpu_power
            print_summary
            ;;
        drivers)
            scan_pci_devices
            check_nvidia_drivers
            check_amd_drivers
            check_intel_drivers
            check_kernel_messages
            check_secure_boot
            check_kernel_params
            check_initramfs
            print_summary
            ;;
        bios)
            scan_pci_devices
            check_bios_settings
            check_kernel_params
            check_secure_boot
            print_summary
            ;;
        fix)
            scan_pci_devices
            check_nvidia_drivers
            check_amd_drivers
            check_intel_drivers
            check_kernel_messages
            check_secure_boot
            check_kernel_params
            check_initramfs
            attempt_fixes
            print_summary
            ;;
        report)
            scan_pci_devices
            check_nvidia_drivers
            check_amd_drivers
            check_intel_drivers
            check_kernel_messages
            check_secure_boot
            check_kernel_params
            check_initramfs
            check_bios_settings
            check_display_stack
            check_gpu_power
            generate_report
            print_summary
            ;;
    esac

    log INFO "Operation completed successfully"
}

main "$@"
