#!/usr/bin/env bash
#
# vm-detect.sh — Red-team VM/hypervisor detection and escape vector auditing
#
# Usage: vm-detect.sh [OPTIONS] [COMMAND]
#
# Commands:
#   scan            Run all detection checks (default)
#   quick           Fast checks only (no timing attacks, no ACPI)
#   escape-audit    Detect hypervisor and report known escape CVEs
#   benchmark       RDTSC timing attack with detailed statistics
#
# Options:
#   -v, --verbose     Enable verbose/debug output
#   -q, --quiet       Exit code only (0=physical, 1=VM detected)
#       --json        Machine-readable JSON output
#   -h, --help        Show this help message
#       --version     Show version information
#
# Exit codes:
#   0  No virtualization detected (physical hardware)
#   1  Virtualization detected
#   2  Error / usage
#
# Author:  Lukas / Script & Automation Engineer
# Version: 1.0.0
# Date:    2026-04-03

set -euo pipefail
IFS=$'\n\t'

# --- Constants ---
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="1.0.0"

# --- Color Support ---
if [[ -t 2 ]] && [[ "${TERM:-}" != "dumb" ]]; then
    readonly C_RED=$'\033[0;31m'
    readonly C_GREEN=$'\033[0;32m'
    readonly C_YELLOW=$'\033[0;33m'
    readonly C_BLUE=$'\033[0;34m'
    readonly C_CYAN=$'\033[0;36m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_BOLD="" C_DIM="" C_RESET=""
fi

# --- Defaults ---
VERBOSE=false
QUIET=false
JSON_OUTPUT=false
COMMAND="scan"

# --- Known Virtual Signatures ---

# MAC OUI prefixes (uppercase, colon-separated first 3 octets)
declare -A VIRTUAL_OUIS=(
    ["52:54:00"]="QEMU/KVM"
    ["08:00:27"]="VirtualBox"
    ["00:0C:29"]="VMware"
    ["00:50:56"]="VMware"
    ["00:15:5D"]="Hyper-V"
    ["00:16:3E"]="Xen"
    ["02:42:AC"]="Docker"
    ["0A:00:27"]="VirtualBox (host-only)"
)

# PCI vendor IDs
declare -A VIRTUAL_PCI_VENDORS=(
    ["0x1af4"]="virtio (Red Hat/QEMU)"
    ["0x15ad"]="VMware"
    ["0x80ee"]="VirtualBox (InnoTek)"
    ["0x1234"]="QEMU VGA"
    ["0x1b36"]="QEMU/Red Hat"
    ["0x5853"]="Xen"
)

# DMI strings that indicate virtualization
VIRTUAL_DMI_STRINGS=(
    "QEMU" "KVM" "Bochs" "innotek" "VirtualBox" "VMware"
    "Microsoft Corporation" "Xen" "Amazon EC2" "Google Compute"
    "DigitalOcean" "Hetzner" "BHYVE" "Parallels"
)

# Disk model/vendor strings
VIRTUAL_DISK_MODELS=(
    "QEMU HARDDISK" "QEMU DVD-ROM" "QEMU CD-ROM"
    "VBOX HARDDISK" "VBOX CD-ROM"
    "VMware Virtual" "Virtual disk" "Virtual CD"
)

# Kernel modules
VIRTUAL_MODULES=(
    "kvm_intel" "kvm_amd" "kvm"
    "vboxguest" "vboxsf" "vboxvideo"
    "vmw_balloon" "vmw_vmci" "vmw_vsock_vmci_transport" "vmxnet3" "vmw_pvscsi"
    "hv_vmbus" "hv_storvsc" "hv_netvsc" "hv_balloon" "hyperv_keyboard"
    "xen_blkfront" "xen_netfront" "xenfs"
    "virtio_blk" "virtio_net" "virtio_scsi" "virtio_pci" "virtio_balloon" "virtio_console"
)

# Processes
VIRTUAL_PROCS=(
    "qemu-ga" "spice-vdagent"
    "VBoxService" "VBoxClient"
    "vmtoolsd" "vmware-rpctool" "vmware-vmblock-fuse"
    "hv_kvp_daemon" "hv_vss_daemon" "hv_fcopy_daemon"
    "xe-daemon" "xenconsoled"
)

# --- Evidence Tracking ---
declare -A EVIDENCE       # category -> pipe-delimited findings
declare -A SCORES         # category -> 0 (clean), 1 (suspicious), 2 (detected)
declare -A HYPERVISOR_HITS # hypervisor_name -> hit count
DETECTED_HYPERVISOR=""
FINAL_CONFIDENCE=0

# --- Escape CVE Database ---
declare -A ESCAPE_CVES
ESCAPE_CVES["QEMU/KVM"]="CVE-2015-3456|VENOM: Floppy disk controller buffer overflow — arbitrary code on host|CRITICAL
CVE-2019-14378|SLiRP heap overflow via fragmented IP packets — host code execution|CRITICAL
CVE-2020-14364|USB EHCI out-of-bounds read/write — host code execution|CRITICAL
CVE-2021-3748|virtio-net use-after-free — host code execution|CRITICAL
CVE-2021-3947|NVME out-of-bounds write — host DoS/code execution|HIGH
CVE-2022-0358|virtiofsd TOCTOU sandbox escape — host filesystem access|HIGH
CVE-2023-3019|DMA reentrancy bug — host memory corruption|HIGH
CVE-2023-3255|VNC infinite loop — host DoS|MEDIUM
CVE-2024-3446|virtio-net OOB in e1000e backend — host code execution|CRITICAL
CVE-2024-4467|QCOW2 image crafted to escape — host filesystem read/write|CRITICAL"

ESCAPE_CVES["VirtualBox"]="CVE-2018-2698|Core escalation via 3D acceleration — host code execution|CRITICAL
CVE-2020-2575|Core escape via shared folders — host filesystem access|HIGH
CVE-2021-2145|Core privilege escalation — host DoS/code execution|HIGH
CVE-2023-21987|VBoxSVGA 3D heap overflow — host code execution|CRITICAL
CVE-2023-22098|Core out-of-bounds write — host DoS|HIGH"

ESCAPE_CVES["VMware"]="CVE-2017-4901|DnD/CnP heap overflow (Workstation/Fusion) — host code execution|CRITICAL
CVE-2020-3947|SVGA use-after-free — host code execution|CRITICAL
CVE-2021-22045|CD-ROM emulation heap overflow — host code execution|CRITICAL
CVE-2022-31705|USB 2.0 EHCI controller heap overflow — host code execution|CRITICAL
CVE-2023-20869|Bluetooth device sharing stack overflow — host code execution|CRITICAL"

ESCAPE_CVES["Hyper-V"]="CVE-2021-28476|vmswitch remote code execution — host takeover|CRITICAL
CVE-2022-23270|Point-to-Point VPN escape — host network access|HIGH
CVE-2024-20699|Hyper-V denial of service via crafted packets|MEDIUM"

ESCAPE_CVES["Xen"]="CVE-2017-7228|x86 shadow pagetable escape — host code execution|CRITICAL
CVE-2019-17349|Grant table race condition — host memory corruption|HIGH
CVE-2022-42331|x86 speculative branch bypass — cross-VM data leak|MEDIUM"

# --- Logging ---
log() {
    local level="$1"; shift
    [[ "$QUIET" == true ]] && return
    local color
    case "$level" in
        DEBUG) [[ "$VERBOSE" != true ]] && return; color="$C_CYAN" ;;
        INFO)  color="$C_GREEN"  ;;
        WARN)  color="$C_YELLOW" ;;
        ERROR) color="$C_RED"    ;;
        *)     color="$C_RESET"  ;;
    esac
    if [[ "$JSON_OUTPUT" == true ]]; then
        printf '{"level":"%s","msg":"%s"}\n' "$level" "$*" >&2
    else
        printf '%s[%-5s]%s %s\n' "$color" "$level" "$C_RESET" "$*" >&2
    fi
}

die() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 2; }

# --- Result Display ---
result() {
    local status="$1" category="$2"; shift 2
    local detail="$*"
    [[ "$QUIET" == true ]] && return
    [[ "$JSON_OUTPUT" == true ]] && return
    local icon color
    case "$status" in
        DETECTED)   icon="[!!]"; color="$C_RED" ;;
        SUSPICIOUS) icon="[??]"; color="$C_YELLOW" ;;
        CLEAN)      icon="[OK]"; color="$C_GREEN" ;;
        SKIPPED)    icon="[--]"; color="$C_DIM" ;;
    esac
    printf '  %s%-10s%s  %-18s %s\n' "$color" "$icon" "$C_RESET" "$category" "$detail" >&2
}

section() {
    [[ "$QUIET" == true ]] && return
    [[ "$JSON_OUTPUT" == true ]] && return
    printf '\n%s══════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RESET" >&2
    printf '%s  %s%s\n' "$C_BOLD" "$1" "$C_RESET" >&2
    printf '%s══════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RESET" >&2
}

record() {
    local category="$1" score="$2" hypervisor="${3:-}" detail="${4:-}"
    SCORES["$category"]=$score
    EVIDENCE["$category"]="${detail}"
    if [[ -n "$hypervisor" && "$score" -ge 1 ]]; then
        HYPERVISOR_HITS["$hypervisor"]=$(( ${HYPERVISOR_HITS["$hypervisor"]:-0} + score ))
    fi
}

# ═══════════════════════════════════════════════════════════
# Detection Functions
# ═══════════════════════════════════════════════════════════

detect_cpuid() {
    log DEBUG "Checking CPUID hypervisor bit and vendor string"
    local findings="" score=0 hv=""

    # Method 1: /proc/cpuinfo flags
    if grep -qw 'hypervisor' /proc/cpuinfo 2>/dev/null; then
        findings="hypervisor flag present in /proc/cpuinfo"
        score=2
        log DEBUG "Found hypervisor flag in cpuinfo"
    fi

    # Method 2: cpuid tool (if available)
    if command -v cpuid &>/dev/null; then
        local vendor_string
        vendor_string=$(cpuid -1 -l 0x40000000 -r 2>/dev/null | head -1 || true)
        if [[ -n "$vendor_string" ]]; then
            # Parse the vendor string from EBX+ECX+EDX
            local ebx ecx edx
            ebx=$(echo "$vendor_string" | grep -oP 'ebx=0x\K[0-9a-f]+' || true)
            ecx=$(echo "$vendor_string" | grep -oP 'ecx=0x\K[0-9a-f]+' || true)
            edx=$(echo "$vendor_string" | grep -oP 'edx=0x\K[0-9a-f]+' || true)
            if [[ -n "$ebx" ]]; then
                local decoded
                decoded=$(printf '%s%s%s' \
                    "$(echo "$ebx" | xxd -r -p 2>/dev/null | rev 2>/dev/null || true)" \
                    "$(echo "$ecx" | xxd -r -p 2>/dev/null | rev 2>/dev/null || true)" \
                    "$(echo "$edx" | xxd -r -p 2>/dev/null | rev 2>/dev/null || true)")
                case "$decoded" in
                    *KVMKVMKVM*)    hv="QEMU/KVM"; findings="${findings:+$findings | }CPUID vendor: KVMKVMKVM" ;;
                    *VMwareVMware*) hv="VMware"; findings="${findings:+$findings | }CPUID vendor: VMwareVMware" ;;
                    *VBoxVBoxVBox*) hv="VirtualBox"; findings="${findings:+$findings | }CPUID vendor: VBoxVBoxVBox" ;;
                    *XenVMMXenVMM*) hv="Xen"; findings="${findings:+$findings | }CPUID vendor: XenVMMXenVMM" ;;
                    *"Microsoft Hv"*) hv="Hyper-V"; findings="${findings:+$findings | }CPUID vendor: Microsoft Hv" ;;
                esac
                [[ -n "$hv" ]] && score=2
            fi
        fi
    else
        # Fallback: try reading hypervisor info from sysfs
        if [[ -r /sys/hypervisor/type ]]; then
            local hyp_type
            hyp_type=$(cat /sys/hypervisor/type 2>/dev/null || true)
            case "$hyp_type" in
                xen) hv="Xen"; score=2; findings="${findings:+$findings | }/sys/hypervisor/type=$hyp_type" ;;
                kvm) hv="QEMU/KVM"; score=2; findings="${findings:+$findings | }/sys/hypervisor/type=$hyp_type" ;;
            esac
        fi

        # Fallback: systemd-detect-virt
        if command -v systemd-detect-virt &>/dev/null; then
            local sdv
            sdv=$(systemd-detect-virt 2>/dev/null || true)
            if [[ "$sdv" != "none" && -n "$sdv" ]]; then
                case "$sdv" in
                    kvm|qemu) hv="QEMU/KVM" ;;
                    oracle)   hv="VirtualBox" ;;
                    vmware)   hv="VMware" ;;
                    microsoft) hv="Hyper-V" ;;
                    xen)      hv="Xen" ;;
                    *)        hv="$sdv" ;;
                esac
                score=2
                findings="${findings:+$findings | }systemd-detect-virt=$sdv"
            fi
        fi
    fi

    record "CPUID" "$score" "$hv" "$findings"
    case "$score" in
        0) result CLEAN "CPUID" "No hypervisor bit or vendor string detected" ;;
        1) result SUSPICIOUS "CPUID" "$findings" ;;
        2) result DETECTED "CPUID" "$findings" ;;
    esac
}

detect_dmi() {
    log DEBUG "Checking DMI/SMBIOS tables"
    local findings="" score=0 hv=""

    local dmi_fields=(
        sys_vendor product_name product_serial product_version
        bios_vendor bios_version bios_date
        board_vendor board_name board_serial
        chassis_vendor chassis_type
    )

    for field in "${dmi_fields[@]}"; do
        local path="/sys/class/dmi/id/$field"
        [[ -r "$path" ]] || continue
        local value
        value=$(cat "$path" 2>/dev/null || true)
        [[ -z "$value" ]] && continue

        for pattern in "${VIRTUAL_DMI_STRINGS[@]}"; do
            if echo "$value" | grep -qi "$pattern" 2>/dev/null; then
                findings="${findings:+$findings | }$field='$value' (matches $pattern)"
                score=2
                case "$pattern" in
                    QEMU|KVM|Bochs)           hv="QEMU/KVM" ;;
                    innotek|VirtualBox)        hv="VirtualBox" ;;
                    VMware)                    hv="VMware" ;;
                    "Microsoft Corporation")   hv="Hyper-V" ;;
                    Xen)                       hv="Xen" ;;
                    "Amazon EC2")              hv="Xen" ;;
                    "Google Compute")          hv="QEMU/KVM" ;;
                esac
                break
            fi
        done
    done

    # Also check if serial looks auto-generated (all zeros, or very short)
    local serial
    serial=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || true)
    if [[ -n "$serial" ]]; then
        if [[ "$serial" =~ ^0+$ ]] || [[ ${#serial} -le 4 ]]; then
            if [[ "$score" -lt 1 ]]; then
                findings="${findings:+$findings | }product_serial='$serial' (suspiciously short/zeroed)"
                score=1
            fi
        fi
    fi

    record "DMI/SMBIOS" "$score" "$hv" "$findings"
    case "$score" in
        0) result CLEAN "DMI/SMBIOS" "All DMI fields appear legitimate" ;;
        1) result SUSPICIOUS "DMI/SMBIOS" "$findings" ;;
        2) result DETECTED "DMI/SMBIOS" "$findings" ;;
    esac
}

detect_pci() {
    log DEBUG "Checking PCI device tree"
    local findings="" score=0 hv=""

    # Method 1: scan /sys/bus/pci/devices
    if [[ -d /sys/bus/pci/devices ]]; then
        for dev in /sys/bus/pci/devices/*/; do
            [[ -r "${dev}vendor" ]] || continue
            local vendor
            vendor=$(cat "${dev}vendor" 2>/dev/null || true)
            if [[ -n "${VIRTUAL_PCI_VENDORS[$vendor]:-}" ]]; then
                local dev_id
                dev_id=$(basename "$dev")
                findings="${findings:+$findings | }PCI $dev_id vendor=$vendor (${VIRTUAL_PCI_VENDORS[$vendor]})"
                score=2
                case "$vendor" in
                    0x1af4|0x1b36) hv="QEMU/KVM" ;;
                    0x15ad)        hv="VMware" ;;
                    0x80ee)        hv="VirtualBox" ;;
                    0x1234)        hv="QEMU/KVM" ;;
                    0x5853)        hv="Xen" ;;
                esac
            fi
        done
    fi

    # Method 2: lspci descriptions
    if command -v lspci &>/dev/null; then
        local lspci_out
        lspci_out=$(lspci 2>/dev/null || true)
        local pci_patterns=("QEMU" "Virtio" "VMware" "VirtualBox" "Hyper-V" "Xen" "Red Hat" "bochs")
        for pat in "${pci_patterns[@]}"; do
            local matches
            matches=$(echo "$lspci_out" | grep -i "$pat" 2>/dev/null || true)
            if [[ -n "$matches" ]]; then
                # Take first match for brevity
                local first
                first=$(echo "$matches" | head -1)
                findings="${findings:+$findings | }lspci: $first"
                score=2
                case "$pat" in
                    QEMU|Virtio|"Red Hat"|bochs) hv="QEMU/KVM" ;;
                    VMware)                       hv="VMware" ;;
                    VirtualBox)                   hv="VirtualBox" ;;
                    Hyper-V)                      hv="Hyper-V" ;;
                    Xen)                          hv="Xen" ;;
                esac
            fi
        done
    fi

    record "PCI Devices" "$score" "$hv" "$findings"
    case "$score" in
        0) result CLEAN "PCI Devices" "No virtual PCI devices found" ;;
        1) result SUSPICIOUS "PCI Devices" "$findings" ;;
        2) result DETECTED "PCI Devices" "$findings" ;;
    esac
}

detect_disks() {
    log DEBUG "Checking disk model/vendor strings"
    local findings="" score=0 hv=""

    # Check for virtio disk device names
    local vd_disks
    vd_disks=$(ls /dev/vd* 2>/dev/null || true)
    if [[ -n "$vd_disks" ]]; then
        findings="virtio disk devices: $(echo "$vd_disks" | tr '\n' ' ')"
        score=2
        hv="QEMU/KVM"
    fi

    # Check disk model/vendor in sysfs
    for blk in /sys/block/*/; do
        local blk_name
        blk_name=$(basename "$blk")
        # Skip loop, ram, dm devices
        [[ "$blk_name" =~ ^(loop|ram|dm-|sr) ]] && continue

        for attr in model vendor; do
            local path="${blk}device/$attr"
            [[ -r "$path" ]] || continue
            local value
            value=$(cat "$path" 2>/dev/null | xargs || true)  # xargs to trim whitespace
            [[ -z "$value" ]] && continue

            for pattern in "${VIRTUAL_DISK_MODELS[@]}"; do
                if echo "$value" | grep -qi "$pattern" 2>/dev/null; then
                    findings="${findings:+$findings | }$blk_name $attr='$value'"
                    score=2
                    case "$pattern" in
                        QEMU*) hv="QEMU/KVM" ;;
                        VBOX*) hv="VirtualBox" ;;
                        VMware*|Virtual*) hv="VMware" ;;
                    esac
                    break
                fi
            done
        done

        # Check disk serial for QEMU patterns
        local serial_path="${blk}device/serial"
        if [[ -r "$serial_path" ]]; then
            local serial
            serial=$(cat "$serial_path" 2>/dev/null | xargs || true)
            if [[ "$serial" =~ ^QM[0-9]+ ]] || [[ "$serial" == "QEMU"* ]]; then
                findings="${findings:+$findings | }$blk_name serial='$serial' (QEMU pattern)"
                score=2
                hv="QEMU/KVM"
            fi
        fi
    done

    record "Disk" "$score" "$hv" "$findings"
    case "$score" in
        0) result CLEAN "Disk" "Disk identifiers appear legitimate" ;;
        1) result SUSPICIOUS "Disk" "$findings" ;;
        2) result DETECTED "Disk" "$findings" ;;
    esac
}

detect_processes() {
    log DEBUG "Checking for virtual guest processes and kernel modules"
    local findings="" score=0 hv=""

    # Check kernel modules
    if [[ -r /proc/modules ]]; then
        local loaded_mods
        loaded_mods=$(cut -d' ' -f1 /proc/modules 2>/dev/null || true)
        for mod in "${VIRTUAL_MODULES[@]}"; do
            if echo "$loaded_mods" | grep -qx "$mod" 2>/dev/null; then
                findings="${findings:+$findings | }module: $mod"
                score=2
                case "$mod" in
                    kvm*|virtio*)           hv="QEMU/KVM" ;;
                    vbox*)                  hv="VirtualBox" ;;
                    vmw*|vmxnet*|vmw_pvscsi) hv="VMware" ;;
                    hv_*|hyperv_*)          hv="Hyper-V" ;;
                    xen_*|xenfs)            hv="Xen" ;;
                esac
            fi
        done
    fi

    # Check running processes
    local running_procs
    running_procs=$(ps -A -o comm= 2>/dev/null || true)
    for proc in "${VIRTUAL_PROCS[@]}"; do
        if echo "$running_procs" | grep -qx "$proc" 2>/dev/null; then
            findings="${findings:+$findings | }process: $proc"
            score=2
            case "$proc" in
                qemu-ga|spice-vdagent)  hv="QEMU/KVM" ;;
                VBox*)                  hv="VirtualBox" ;;
                vmtoolsd|vmware-*)      hv="VMware" ;;
                hv_*)                   hv="Hyper-V" ;;
                xe-daemon|xenconsoled)  hv="Xen" ;;
            esac
        fi
    done

    record "Processes" "$score" "$hv" "$findings"
    case "$score" in
        0) result CLEAN "Processes" "No virtual guest agents or modules found" ;;
        1) result SUSPICIOUS "Processes" "$findings" ;;
        2) result DETECTED "Processes" "$findings" ;;
    esac
}

detect_filesystem() {
    log DEBUG "Checking filesystem artifacts"
    local findings="" score=0 hv=""

    # Docker / container
    if [[ -f /.dockerenv ]]; then
        findings="/.dockerenv exists (Docker container)"
        score=2; hv="Docker"
    fi
    if [[ -r /run/systemd/container ]]; then
        local ctype
        ctype=$(cat /run/systemd/container 2>/dev/null || true)
        findings="${findings:+$findings | }/run/systemd/container=$ctype"
        score=2; hv="${ctype:-container}"
    fi

    # Hypervisor type
    if [[ -r /sys/hypervisor/type ]]; then
        local hyp_type
        hyp_type=$(cat /sys/hypervisor/type 2>/dev/null || true)
        findings="${findings:+$findings | }/sys/hypervisor/type=$hyp_type"
        score=2
        case "$hyp_type" in
            xen) hv="Xen" ;;
            kvm) hv="QEMU/KVM" ;;
            *) hv="$hyp_type" ;;
        esac
    fi

    # Virtio ports
    if [[ -d /dev/virtio-ports ]]; then
        local ports
        ports=$(ls /dev/virtio-ports/ 2>/dev/null || true)
        if [[ -n "$ports" ]]; then
            findings="${findings:+$findings | }/dev/virtio-ports/ exists: $ports"
            score=2; hv="QEMU/KVM"
        fi
    fi

    # Guest agent binaries
    local agent_paths=(
        "/usr/bin/qemu-ga" "/usr/sbin/qemu-ga"
        "/usr/sbin/VBoxService" "/usr/bin/VBoxClient"
        "/usr/bin/vmtoolsd" "/usr/bin/vmware-toolbox-cmd"
    )
    for agent in "${agent_paths[@]}"; do
        if [[ -x "$agent" ]]; then
            findings="${findings:+$findings | }$agent present"
            score=2
            case "$agent" in
                *qemu*)    hv="QEMU/KVM" ;;
                *VBox*)    hv="VirtualBox" ;;
                *vmware*|*vmtoolsd*) hv="VMware" ;;
            esac
        fi
    done

    # QEMU fw_cfg
    if [[ -d /sys/firmware/qemu_fw_cfg ]]; then
        findings="${findings:+$findings | }/sys/firmware/qemu_fw_cfg exists"
        score=2; hv="QEMU/KVM"
    fi

    # Device tree (some cloud VMs)
    if [[ -r /sys/firmware/devicetree/base/hypervisor/compatible ]]; then
        local compat
        compat=$(cat /sys/firmware/devicetree/base/hypervisor/compatible 2>/dev/null | tr '\0' ' ' || true)
        if [[ -n "$compat" ]]; then
            findings="${findings:+$findings | }devicetree hypervisor: $compat"
            score=2
        fi
    fi

    record "Filesystem" "$score" "$hv" "$findings"
    case "$score" in
        0) result CLEAN "Filesystem" "No virtual filesystem artifacts" ;;
        1) result SUSPICIOUS "Filesystem" "$findings" ;;
        2) result DETECTED "Filesystem" "$findings" ;;
    esac
}

detect_timing() {
    log DEBUG "Running RDTSC timing attack (CPUID trap measurement)"
    local findings="" score=0

    # We need a C compiler
    local cc=""
    for try in cc gcc; do
        if command -v "$try" &>/dev/null; then
            cc="$try"; break
        fi
    done

    if [[ -z "$cc" ]]; then
        record "Timing" 0 "" "Skipped: no C compiler available (install gcc)"
        result SKIPPED "Timing" "No C compiler available (install gcc for timing attack)"
        return
    fi

    local src dst
    src=$(mktemp /tmp/vm_timing_XXXXXX.c)
    dst=$(mktemp /tmp/vm_timing_XXXXXX)

    cat > "$src" << 'TIMING_C'
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(__x86_64__) || defined(__i386__)

static inline uint64_t rdtsc(void) {
    uint32_t lo, hi;
    __asm__ volatile ("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
}

static inline void cpuid_call(void) {
    uint32_t eax, ebx, ecx, edx;
    __asm__ volatile ("cpuid" : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx)
                     : "a"(0));
}

int cmp_u64(const void *a, const void *b) {
    uint64_t va = *(const uint64_t *)a;
    uint64_t vb = *(const uint64_t *)b;
    return (va > vb) - (va < vb);
}

int main(void) {
    const int ITERS = 10000;
    uint64_t *cpuid_deltas = malloc(ITERS * sizeof(uint64_t));
    uint64_t *nop_deltas = malloc(ITERS * sizeof(uint64_t));

    if (!cpuid_deltas || !nop_deltas) return 1;

    // Warmup
    for (int i = 0; i < 100; i++) { cpuid_call(); }

    // Measure CPUID (causes VM exit under hypervisor)
    for (int i = 0; i < ITERS; i++) {
        uint64_t t0 = rdtsc();
        cpuid_call();
        uint64_t t1 = rdtsc();
        cpuid_deltas[i] = t1 - t0;
    }

    // Measure NOP sled (no VM exit)
    for (int i = 0; i < ITERS; i++) {
        uint64_t t0 = rdtsc();
        __asm__ volatile (
            "nop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\n"
            "nop\nnop\nnop\nnop\nnop\nnop\nnop\nnop\n"
        );
        uint64_t t1 = rdtsc();
        nop_deltas[i] = t1 - t0;
    }

    // Sort for median
    qsort(cpuid_deltas, ITERS, sizeof(uint64_t), cmp_u64);
    qsort(nop_deltas, ITERS, sizeof(uint64_t), cmp_u64);

    uint64_t cpuid_median = cpuid_deltas[ITERS / 2];
    uint64_t nop_median = nop_deltas[ITERS / 2];

    // Compute mean
    uint64_t cpuid_sum = 0, nop_sum = 0;
    for (int i = ITERS / 10; i < ITERS * 9 / 10; i++) {
        cpuid_sum += cpuid_deltas[i];
        nop_sum += nop_deltas[i];
    }
    uint64_t cpuid_mean = cpuid_sum / (ITERS * 8 / 10);
    uint64_t nop_mean = nop_sum / (ITERS * 8 / 10);

    double ratio = (nop_median > 0) ? (double)cpuid_median / nop_median : 0.0;

    printf("cpuid_median=%lu cpuid_mean=%lu nop_median=%lu nop_mean=%lu ratio=%.2f\n",
           cpuid_median, cpuid_mean, nop_median, nop_mean, ratio);

    free(cpuid_deltas);
    free(nop_deltas);
    return 0;
}

#else
int main(void) {
    printf("unsupported_arch=1\n");
    return 0;
}
#endif
TIMING_C

    if ! "$cc" -O2 -o "$dst" "$src" 2>/dev/null; then
        rm -f "$src" "$dst"
        record "Timing" 0 "" "Skipped: C compilation failed"
        result SKIPPED "Timing" "C compilation failed"
        return
    fi
    rm -f "$src"

    local output
    output=$("$dst" 2>/dev/null || true)
    rm -f "$dst"

    if echo "$output" | grep -q "unsupported_arch"; then
        record "Timing" 0 "" "Skipped: non-x86 architecture"
        result SKIPPED "Timing" "Non-x86 architecture"
        return
    fi

    local cpuid_median cpuid_mean nop_median nop_mean ratio
    cpuid_median=$(echo "$output" | grep -oP 'cpuid_median=\K[0-9]+' || echo "0")
    cpuid_mean=$(echo "$output" | grep -oP 'cpuid_mean=\K[0-9]+' || echo "0")
    nop_median=$(echo "$output" | grep -oP 'nop_median=\K[0-9]+' || echo "0")
    nop_mean=$(echo "$output" | grep -oP 'nop_mean=\K[0-9]+' || echo "0")
    ratio=$(echo "$output" | grep -oP 'ratio=\K[0-9.]+' || echo "0")

    findings="CPUID/NOP ratio=${ratio} (cpuid_median=${cpuid_median}, nop_median=${nop_median})"
    log DEBUG "$findings"

    # Thresholds: bare metal CPUID is typically 50-200 cycles, VM exits add 500-5000+
    # Ratio > 5 is highly suspicious, > 20 is almost certain VM
    local ratio_int
    ratio_int=$(printf '%.0f' "$ratio" 2>/dev/null || echo "0")
    if [[ "$ratio_int" -ge 20 ]]; then
        score=2
        findings="$findings — VM exit overhead detected (ratio >= 20)"
    elif [[ "$ratio_int" -ge 5 ]]; then
        score=1
        findings="$findings — possible VM exit overhead (ratio >= 5)"
    else
        score=0
        findings="$findings — timing consistent with bare metal"
    fi

    record "Timing" "$score" "" "$findings"
    case "$score" in
        0) result CLEAN "Timing" "CPUID/NOP ratio=${ratio} (normal)" ;;
        1) result SUSPICIOUS "Timing" "CPUID/NOP ratio=${ratio} (elevated)" ;;
        2) result DETECTED "Timing" "CPUID/NOP ratio=${ratio} (VM exit overhead)" ;;
    esac
}

detect_mac() {
    log DEBUG "Checking network interface MAC addresses"
    local findings="" score=0 hv=""

    for iface in /sys/class/net/*/; do
        local ifname
        ifname=$(basename "$iface")
        [[ "$ifname" == "lo" ]] && continue
        local mac_path="${iface}address"
        [[ -r "$mac_path" ]] || continue
        local mac
        mac=$(cat "$mac_path" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)
        [[ -z "$mac" || "$mac" == "00:00:00:00:00:00" ]] && continue

        local oui="${mac:0:8}"
        if [[ -n "${VIRTUAL_OUIS[$oui]:-}" ]]; then
            findings="${findings:+$findings | }$ifname MAC=$mac (${VIRTUAL_OUIS[$oui]})"
            score=2
            case "${VIRTUAL_OUIS[$oui]}" in
                QEMU*|*KVM*) hv="QEMU/KVM" ;;
                VirtualBox*) hv="VirtualBox" ;;
                VMware*)     hv="VMware" ;;
                Hyper-V*)    hv="Hyper-V" ;;
                Xen*)        hv="Xen" ;;
                Docker*)     hv="Docker" ;;
            esac
        else
            log DEBUG "$ifname MAC=$mac OUI=$oui — not in virtual OUI database"
        fi
    done

    record "MAC Address" "$score" "$hv" "$findings"
    case "$score" in
        0) result CLEAN "MAC Address" "No virtual OUI prefixes detected" ;;
        1) result SUSPICIOUS "MAC Address" "$findings" ;;
        2) result DETECTED "MAC Address" "$findings" ;;
    esac
}

detect_cpu_anomalies() {
    log DEBUG "Checking CPU model and feature anomalies"
    local findings="" score=0

    local cpu_model cpu_flags cpu_vendor
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || true)
    cpu_flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2 || true)
    cpu_vendor=$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || true)
    local cpu_count
    cpu_count=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "0")

    # Check for hypervisor flag (overlap with CPUID check, but this is CPU-specific)
    if echo "$cpu_flags" | grep -qw 'hypervisor' 2>/dev/null; then
        findings="hypervisor CPU flag set"
        score=2
    fi

    # Check for QEMU-specific model names
    if [[ "$cpu_model" == *"QEMU"* ]] || [[ "$cpu_model" == *"Common KVM"* ]]; then
        findings="${findings:+$findings | }CPU model contains VM identifier: $cpu_model"
        score=2
    fi

    # Check CPU count vs model (a high-end model with 1-2 cores is suspicious)
    if [[ "$cpu_count" -le 2 ]] && [[ "$cpu_model" =~ (Xeon|EPYC|Threadripper) ]]; then
        if [[ "$score" -lt 1 ]]; then score=1; fi
        findings="${findings:+$findings | }Server CPU ($cpu_model) with only $cpu_count cores — unusual"
    fi

    record "CPU" "$score" "" "$findings"
    case "$score" in
        0) result CLEAN "CPU" "$cpu_model ($cpu_vendor, $cpu_count cores)" ;;
        1) result SUSPICIOUS "CPU" "$findings" ;;
        2) result DETECTED "CPU" "$findings" ;;
    esac
}

detect_acpi() {
    log DEBUG "Checking ACPI tables for hypervisor signatures"
    local findings="" score=0 hv=""

    # DSDT and other ACPI tables (requires root or readable sysfs)
    local acpi_tables=(
        "/sys/firmware/acpi/tables/DSDT"
        "/sys/firmware/acpi/tables/FACP"
        "/sys/firmware/acpi/tables/APIC"
        "/sys/firmware/acpi/tables/SSDT1"
    )
    local acpi_patterns=("BOCHS" "BXPC" "QEMU" "VBOX" "VRTUAL" "VMWARE" "PTLTD" "KVMKVMKVM" "MSFT")

    for table in "${acpi_tables[@]}"; do
        [[ -r "$table" ]] || continue
        local strings_out
        strings_out=$(strings "$table" 2>/dev/null || true)
        for pattern in "${acpi_patterns[@]}"; do
            if echo "$strings_out" | grep -qi "$pattern" 2>/dev/null; then
                findings="${findings:+$findings | }$(basename "$table") contains '$pattern'"
                score=2
                case "$pattern" in
                    BOCHS|BXPC|QEMU|KVMKVMKVM) hv="QEMU/KVM" ;;
                    VBOX)      hv="VirtualBox" ;;
                    VMWARE)    hv="VMware" ;;
                    VRTUAL)    hv="Hyper-V" ;;
                    PTLTD)     hv="QEMU/KVM" ;;  # Bochs/SeaBIOS
                esac
            fi
        done
    done

    # DMI binary tables
    if [[ -r /sys/firmware/dmi/tables/DMI ]]; then
        local dmi_strings
        dmi_strings=$(strings /sys/firmware/dmi/tables/DMI 2>/dev/null || true)
        for pattern in "QEMU" "Bochs" "VirtualBox" "VMware" "innotek" "SeaBIOS"; do
            if echo "$dmi_strings" | grep -qi "$pattern" 2>/dev/null; then
                findings="${findings:+$findings | }DMI binary table contains '$pattern'"
                score=2
                case "$pattern" in
                    QEMU|Bochs|SeaBIOS) hv="QEMU/KVM" ;;
                    VirtualBox|innotek) hv="VirtualBox" ;;
                    VMware)             hv="VMware" ;;
                esac
            fi
        done
    fi

    if [[ -z "$findings" ]] && [[ ! -r /sys/firmware/acpi/tables/DSDT ]]; then
        record "ACPI" 0 "" "Cannot read ACPI tables (run as root for full check)"
        result SKIPPED "ACPI" "Cannot read ACPI tables (run as root)"
        return
    fi

    record "ACPI" "$score" "$hv" "$findings"
    case "$score" in
        0) result CLEAN "ACPI" "No hypervisor signatures in ACPI/DMI tables" ;;
        1) result SUSPICIOUS "ACPI" "$findings" ;;
        2) result DETECTED "ACPI" "$findings" ;;
    esac
}

detect_network() {
    log DEBUG "Checking network topology for virtual indicators"
    local findings="" score=0 hv=""

    # Check for virbr* interfaces (shouldn't be visible inside a VM, but misconfigs happen)
    local virbr
    virbr=$(ls /sys/class/net/ 2>/dev/null | grep '^virbr' || true)
    if [[ -n "$virbr" ]]; then
        findings="virbr interface(s) found: $virbr (libvirt bridge — likely host, not guest)"
        # virbr inside a VM is unusual, but could mean nested virt
        score=1
    fi

    # Check default gateway MAC in ARP table
    local gw_ip
    gw_ip=$(ip route show default 2>/dev/null | awk '/default via/ {print $3; exit}' || true)
    if [[ -n "$gw_ip" ]]; then
        # Ping gateway to populate ARP
        ping -c1 -W1 "$gw_ip" &>/dev/null || true
        local gw_mac
        gw_mac=$(ip neigh show "$gw_ip" 2>/dev/null | awk '{print $5}' | tr '[:lower:]' '[:upper:]' | head -1 || true)
        if [[ -n "$gw_mac" && "$gw_mac" != "FAILED" ]]; then
            local gw_oui="${gw_mac:0:8}"
            if [[ -n "${VIRTUAL_OUIS[$gw_oui]:-}" ]]; then
                findings="${findings:+$findings | }Gateway MAC=$gw_mac (${VIRTUAL_OUIS[$gw_oui]})"
                score=2
                case "${VIRTUAL_OUIS[$gw_oui]}" in
                    QEMU*|*KVM*) hv="QEMU/KVM" ;;
                    *) ;;
                esac
            else
                log DEBUG "Gateway $gw_ip MAC=$gw_mac OUI=$gw_oui — not virtual"
            fi
        fi
    fi

    # Check for bridge interfaces
    local bridges
    bridges=$(ls -d /sys/class/net/*/bridge 2>/dev/null | sed 's|/sys/class/net/||;s|/bridge||' || true)
    if [[ -n "$bridges" ]]; then
        findings="${findings:+$findings | }Bridge interfaces: $bridges"
        if [[ "$score" -lt 1 ]]; then score=1; fi
    fi

    record "Network" "$score" "$hv" "$findings"
    case "$score" in
        0) result CLEAN "Network" "Network topology appears physical" ;;
        1) result SUSPICIOUS "Network" "$findings" ;;
        2) result DETECTED "Network" "$findings" ;;
    esac
}

# ═══════════════════════════════════════════════════════════
# Verdict Computation
# ═══════════════════════════════════════════════════════════

VERDICT=""

compute_verdict() {
    local total_score=0 max_score=0 num_detected=0

    for cat in "${!SCORES[@]}"; do
        local s=${SCORES[$cat]}
        total_score=$((total_score + s))
        max_score=$((max_score + 2))
        [[ "$s" -ge 2 ]] && ((num_detected++)) || true
    done

    # Determine hypervisor by highest hit count
    local best_hv="" best_count=0
    for hv in "${!HYPERVISOR_HITS[@]}"; do
        if [[ ${HYPERVISOR_HITS[$hv]} -gt $best_count ]]; then
            best_count=${HYPERVISOR_HITS[$hv]}
            best_hv="$hv"
        fi
    done
    DETECTED_HYPERVISOR="$best_hv"

    if [[ $max_score -gt 0 ]]; then
        FINAL_CONFIDENCE=$((total_score * 100 / max_score))
    fi

    if [[ $num_detected -ge 1 ]]; then
        VERDICT="VIRTUAL MACHINE DETECTED"
    elif [[ $FINAL_CONFIDENCE -ge 50 ]]; then
        VERDICT="LIKELY VIRTUAL"
    elif [[ $FINAL_CONFIDENCE -ge 20 ]]; then
        VERDICT="SUSPICIOUS"
    else
        VERDICT="PHYSICAL (or very well hidden)"
    fi
}

# ═══════════════════════════════════════════════════════════
# Output
# ═══════════════════════════════════════════════════════════

print_verdict() {
    local verdict="$1"
    [[ "$QUIET" == true ]] && return
    [[ "$JSON_OUTPUT" == true ]] && return

    section "VERDICT"
    local color
    case "$verdict" in
        "VIRTUAL MACHINE DETECTED") color="$C_RED" ;;
        "LIKELY VIRTUAL")           color="$C_YELLOW" ;;
        "SUSPICIOUS")               color="$C_YELLOW" ;;
        *)                          color="$C_GREEN" ;;
    esac

    printf '\n  %s%s  %s%s\n' "$C_BOLD" "$color" "$verdict" "$C_RESET" >&2
    printf '  Confidence: %d%%\n' "$FINAL_CONFIDENCE" >&2
    if [[ -n "$DETECTED_HYPERVISOR" ]]; then
        printf '  Hypervisor: %s%s%s\n' "$C_BOLD" "$DETECTED_HYPERVISOR" "$C_RESET" >&2
    fi
    printf '\n' >&2
}

print_json() {
    local verdict="$1"

    local categories="{"
    local first=true
    for cat in "${!SCORES[@]}"; do
        [[ "$first" == true ]] && first=false || categories+=","
        local score=${SCORES[$cat]}
        local evidence=${EVIDENCE[$cat]:-}
        local status
        case "$score" in
            0) status="clean" ;; 1) status="suspicious" ;; 2) status="detected" ;;
        esac
        # Escape JSON strings
        evidence=$(echo "$evidence" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')
        categories+="\"$(echo "$cat" | tr '[:upper:]' '[:lower:]' | tr ' /' '_')\":{\"status\":\"$status\",\"score\":$score,\"detail\":\"$evidence\"}"
    done
    categories+="}"

    printf '{"verdict":"%s","confidence":%d,"hypervisor":"%s","categories":%s}\n' \
        "$verdict" "$FINAL_CONFIDENCE" "${DETECTED_HYPERVISOR:-none}" "$categories"
}

# ═══════════════════════════════════════════════════════════
# Subcommands
# ═══════════════════════════════════════════════════════════

cmd_scan() {
    section "VM Detection Scan — Full Analysis"
    log INFO "Running all 11 detection checks..."

    detect_cpuid
    detect_dmi
    detect_pci
    detect_disks
    detect_processes
    detect_filesystem
    detect_timing
    detect_mac
    detect_cpu_anomalies
    detect_acpi
    detect_network

    compute_verdict

    if [[ "$JSON_OUTPUT" == true ]]; then
        print_json "$VERDICT"
    else
        print_verdict "$VERDICT"
    fi

    [[ "$VERDICT" == "PHYSICAL"* ]] && return 0 || return 1
}

cmd_quick() {
    section "VM Detection Scan — Quick Mode"
    log INFO "Running 7 fast checks (skipping timing, ACPI, network, CPU anomalies)..."

    detect_cpuid
    detect_dmi
    detect_pci
    detect_disks
    detect_processes
    detect_filesystem
    detect_mac

    compute_verdict

    if [[ "$JSON_OUTPUT" == true ]]; then
        print_json "$VERDICT"
    else
        print_verdict "$VERDICT"
    fi

    [[ "$VERDICT" == "PHYSICAL"* ]] && return 0 || return 1
}

cmd_escape_audit() {
    # First detect what we're running on
    section "Hypervisor Detection"
    log INFO "Identifying hypervisor for escape vector analysis..."

    detect_cpuid
    detect_dmi
    detect_pci
    detect_processes
    detect_filesystem

    compute_verdict

    if [[ "$JSON_OUTPUT" != true ]]; then
        print_verdict "$VERDICT"
    fi

    if [[ -z "$DETECTED_HYPERVISOR" ]]; then
        if [[ "$JSON_OUTPUT" == true ]]; then
            printf '{"verdict":"%s","confidence":%d,"hypervisor":"none","escape_vectors":[]}\n' \
                "$VERDICT" "$FINAL_CONFIDENCE"
        else
            log INFO "No hypervisor detected — no escape vectors to report"
        fi
        [[ "$VERDICT" == "PHYSICAL"* ]] && return 0 || return 1
    fi

    section "Escape Vector Audit — $DETECTED_HYPERVISOR"

    local cve_data="${ESCAPE_CVES[$DETECTED_HYPERVISOR]:-}"
    if [[ -z "$cve_data" ]]; then
        log WARN "No CVE data for hypervisor: $DETECTED_HYPERVISOR"
        return 1
    fi

    if [[ "$JSON_OUTPUT" == true ]]; then
        local json_cves="["
        local first=true
        while IFS=$'\n' read -r line; do
            [[ -z "$line" ]] && continue
            local cve desc sev
            IFS='|' read -r cve desc sev <<< "$line"
            [[ "$first" == true ]] && first=false || json_cves+=","
            json_cves+="{\"cve\":\"$cve\",\"description\":\"$desc\",\"severity\":\"$sev\"}"
        done <<< "$cve_data"
        json_cves+="]"
        printf '{"verdict":"%s","confidence":%d,"hypervisor":"%s","escape_vectors":%s}\n' \
            "$VERDICT" "$FINAL_CONFIDENCE" "$DETECTED_HYPERVISOR" "$json_cves"
    else
        local count=0
        while IFS=$'\n' read -r line; do
            [[ -z "$line" ]] && continue
            local cve desc sev
            IFS='|' read -r cve desc sev <<< "$line"
            ((count++)) || true
            local color
            case "$sev" in
                CRITICAL) color="$C_RED" ;;
                HIGH)     color="$C_YELLOW" ;;
                *)        color="$C_BLUE" ;;
            esac
            printf '  %s%-17s%s %s[%s]%s %s\n' "$C_BOLD" "$cve" "$C_RESET" "$color" "$sev" "$C_RESET" "$desc" >&2
        done <<< "$cve_data"
        printf '\n  %s%d known escape vectors%s for %s\n\n' "$C_BOLD" "$count" "$C_RESET" "$DETECTED_HYPERVISOR" >&2
        log WARN "These are KNOWN CVEs. Patched hypervisors may not be vulnerable."
        log WARN "Check hypervisor version: qemu --version, VBoxManage --version, etc."
    fi

    return 1
}

cmd_benchmark() {
    section "RDTSC Timing Benchmark"
    log INFO "Running detailed timing analysis..."

    VERBOSE=true  # Force verbose for benchmark
    detect_timing
    VERBOSE=${orig_verbose:-false}

    compute_verdict

    if [[ "$JSON_OUTPUT" == true ]]; then
        print_json "$VERDICT"
    fi

    [[ "${SCORES[Timing]:-0}" -ge 2 ]] && return 1 || return 0
}

# ═══════════════════════════════════════════════════════════
# Usage / Help
# ═══════════════════════════════════════════════════════════

usage() {
    cat <<EOF
${C_BOLD}$SCRIPT_NAME $SCRIPT_VERSION${C_RESET} — Red-team VM detection and escape vector auditing

${C_BOLD}USAGE${C_RESET}
    $SCRIPT_NAME [OPTIONS] [COMMAND]

${C_BOLD}COMMANDS${C_RESET}
    scan            Run all 11 detection checks (default)
    quick           Fast checks only (skip timing, ACPI, network)
    escape-audit    Detect hypervisor + report known escape CVEs
    benchmark       RDTSC timing attack with detailed statistics

${C_BOLD}OPTIONS${C_RESET}
    -v, --verbose   Verbose/debug output
    -q, --quiet     Exit code only (0=physical, 1=VM)
        --json      Machine-readable JSON output
    -h, --help      Show this help
        --version   Show version

${C_BOLD}DETECTION CATEGORIES${C_RESET}
    CPUID           Hypervisor bit + vendor string (leaf 0x40000000)
    DMI/SMBIOS      /sys/class/dmi/id/* manufacturer/product strings
    PCI Devices     Virtual PCI vendor IDs (virtio, VMware, VBox)
    Disk            Disk model/vendor/serial + virtio block devices
    Processes       Guest agent processes + kernel modules
    Filesystem      /sys/hypervisor, /dev/virtio-ports, fw_cfg, etc.
    Timing          RDTSC: CPUID trap overhead vs NOP baseline
    MAC Address     OUI prefix matching (QEMU, VBox, VMware, Hyper-V)
    CPU             Model string anomalies, hypervisor flag
    ACPI            DSDT/FACP/DMI binary table signatures (BOCHS, BXPC)
    Network         Gateway MAC, bridge interfaces

${C_BOLD}EXIT CODES${C_RESET}
    0  No virtualization detected
    1  Virtualization detected
    2  Error or bad usage

${C_BOLD}EXAMPLES${C_RESET}
    # Full scan (needs root for ACPI tables)
    sudo ./$SCRIPT_NAME scan

    # Quick check — just exit code
    ./$SCRIPT_NAME quick --quiet && echo "Physical" || echo "Virtual"

    # JSON output for automation
    sudo ./$SCRIPT_NAME scan --json | jq .

    # Identify hypervisor and list escape CVEs
    sudo ./$SCRIPT_NAME escape-audit

    # Timing attack benchmark
    ./$SCRIPT_NAME benchmark
EOF
}

# ═══════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════

main() {
    local orig_verbose="$VERBOSE"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose) VERBOSE=true; shift ;;
            -q|--quiet)   QUIET=true; shift ;;
            --json)       JSON_OUTPUT=true; shift ;;
            -h|--help)    usage; exit 0 ;;
            --version)    echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            scan|quick|escape-audit|benchmark) COMMAND="$1"; shift ;;
            *) die "Unknown option or command: $1 (see --help)" ;;
        esac
    done

    case "$COMMAND" in
        scan)         cmd_scan ;;
        quick)        cmd_quick ;;
        escape-audit) cmd_escape_audit ;;
        benchmark)    cmd_benchmark ;;
        *)            die "Unknown command: $COMMAND" ;;
    esac
}

main "$@"
