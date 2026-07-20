#!/usr/bin/env bash

# KVM Manager — Quick VM setup, snapshot & rollback for Ubuntu
# Usage: kvm-manager.sh <command> [options]
# Run 'kvm-manager.sh help' for full command list

set -euo pipefail

# --- Constants ---
SCRIPT_NAME="kvm-manager"
SCRIPT_VERSION="1.0.0"
DEFAULT_CPU=2
DEFAULT_RAM_MIB=2048
DEFAULT_DISK_GB=20
LIBVIRT_IMAGES="/var/lib/libvirt/images"
TEMPLATE_MARKER=".kvm-template"
KVM_SSH_KEY="" # Set dynamically in main() via get_kvm_ssh_key_path
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
DEFAULT_POST_SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vm-post-setup.sh"

# --- GPU Passthrough (VFIO) ---
VFIO_CONF="/etc/modprobe.d/vfio.conf"
VFIO_MODULES_CONF="/etc/modules-load.d/vfio.conf"
GPU_PCI_ADDRS=()   # Set by detect_nvidia_gpu()
GPU_VFIO_IDS=""    # Set by detect_nvidia_gpu()

# --- Anti-Detection Hardware Profiles ---
# Format: manufacturer|product|bios_vendor|bios_version|mac_oui|board_manufacturer|board_product|chassis_manufacturer|chassis_type|nic_model
STEALTH_PROFILES=(
    "Dell Inc.|OptiPlex 7090|Dell Inc.|2.20.0|D0:94:66|Dell Inc.|0KWVT8|Dell Inc.|3|e1000e"
    "Lenovo|ThinkCentre M920q|Lenovo|M22KT55A|70:5A:0F|Lenovo|312D|Lenovo|3|e1000e"
    "HP|ProDesk 400 G7|HP|S17 Ver. 02.05.00|3C:52:82|HP|87D6|HP|3|e1000e"
)

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
    log_msg ERROR "$@"
    exit 1
}

# --- Validation Helpers ---

function check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)"
    fi
}

function validate_vm_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        die "Invalid VM name '$name' — use alphanumeric, dots, hyphens, underscores"
    fi
}

function validate_snap_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        die "Invalid snapshot name '$name' — use alphanumeric, dots, hyphens, underscores"
    fi
}

function vm_exists() {
    virsh dominfo "$1" &>/dev/null
}

function require_vm() {
    local name="$1"
    if ! vm_exists "$name"; then
        die "VM '$name' does not exist"
    fi
}

function confirm() {
    local prompt="$1"
    echo -n "${YELLOW}${prompt} [y/N]${RESET} "
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

function generate_serial() {
    head -c 100 /dev/urandom | tr -dc 'A-Z0-9' | head -c 7
}

function generate_mac() {
    local oui_prefix="$1"
    printf '%s:%02X:%02X:%02X' "$oui_prefix" \
        $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
}

function require_deps() {
    local dep missing=()
    for dep in "$@"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    log_msg ERROR "Missing required commands: ${missing[*]}"
    log_msg INFO "Run '$SCRIPT_NAME setup' to install all KVM dependencies, or install manually."

    if [[ $EUID -eq 0 ]]; then
        if confirm "Install KVM packages now?"; then
            apt-get update -qq
            apt-get install -y \
                qemu-kvm libvirt-daemon-system libvirt-clients \
                virtinst qemu-utils
            systemctl enable --now libvirtd
            log_msg INFO "Dependencies installed"
            local still_missing=()
            for dep in "${missing[@]}"; do
                if ! command -v "$dep" &>/dev/null; then
                    still_missing+=("$dep")
                fi
            done
            if [[ ${#still_missing[@]} -gt 0 ]]; then
                die "Still missing after install: ${still_missing[*]}"
            fi
            return 0
        fi
    fi

    die "Cannot continue without: ${missing[*]}"
}

# --- GPU Passthrough Helpers ---
# GPU handling is vendor-agnostic at the VFIO level (NVIDIA / AMD / Intel).
# PCI addresses use the short "NN:NN.N" form (domain 0000 assumed, as elsewhere).

function gpu_enumerate() {
    # Echo one PCI head address (NN:NN.N) per GPU / display controller.
    # Strip a leading 0000: domain (some lspci builds print domain-qualified BDFs);
    # domain 0000 is assumed throughout, as elsewhere in this script.
    lspci -nn 2>/dev/null \
        | grep -iE 'VGA compatible controller|3D controller|Display controller' \
        | awk '{print $1}' \
        | sed 's/^0000://'
}

function gpu_is_primary() {
    # True if this PCI address is the host's boot/primary GPU (boot_vga=1).
    local f="/sys/bus/pci/devices/0000:${1}/boot_vga"
    [[ -r "$f" && "$(cat "$f" 2>/dev/null)" == "1" ]]
}

function gpu_host_driver() {
    # Echo the kernel driver bound to a PCI address, or "unbound".
    local link="/sys/bus/pci/devices/0000:${1}/driver"
    if [[ -L "$link" ]]; then
        basename "$(readlink "$link")"
    else
        echo "unbound"
    fi
}

function gpu_iommu_group() {
    # Echo the IOMMU group number for a PCI address, or empty if unknown.
    # Must return 0 even when absent — it is used in $() assignments under set -e.
    local link="/sys/bus/pci/devices/0000:${1}/iommu_group"
    [[ -e "$link" ]] && basename "$(readlink "$link")"
    return 0
}

function gpu_vendor_name() {
    # Map a GPU PCI address to a vendor keyword.
    local vid
    vid=$(lspci -n -s "$1" 2>/dev/null | awk '{print $3}' | cut -d: -f1)
    case "$vid" in
        10de) echo nvidia ;;
        1002) echo amd ;;
        8086) echo intel ;;
        *)    echo unknown ;;
    esac
}

function resolve_gpu_group() {
    # For the GPU at PCI addr $1, populate GPU_PCI_ADDRS=() and GPU_VFIO_IDS
    # with every non-bridge device in its IOMMU group (or same bus:slot
    # functions pre-IOMMU). PCI bridges/root-ports are skipped — they must not
    # be bound to vfio-pci or attached as host-devices.
    local gpu_addr="$1"
    GPU_PCI_ADDRS=()
    GPU_VFIO_IDS=""
    local gpu_slot="${gpu_addr%.*}"

    local iommu_group_dir=""
    if [[ -d /sys/kernel/iommu_groups ]]; then
        local group_path
        for group_path in /sys/kernel/iommu_groups/*/devices/0000:${gpu_addr}; do
            if [[ -e "$group_path" ]]; then
                iommu_group_dir=$(dirname "$group_path")
                break
            fi
        done
    fi

    local -a addrs=() ids=()
    local addr class id
    if [[ -n "$iommu_group_dir" ]]; then
        local dev
        for dev in "${iommu_group_dir}"/0000:*; do
            [[ -e "$dev" ]] || continue
            addr=$(basename "$dev" | sed 's/^0000://')
            read -r class id < <(lspci -n -s "$addr" 2>/dev/null | awk '{print $2, $3}')
            [[ "$class" == 06* ]] && continue   # skip PCI bridges / root ports
            addrs+=("$addr")
            ids+=("$id")
        done
    else
        # Fallback: same bus:slot functions (pre-IOMMU)
        local line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            addr=$(echo "$line" | awk '{print $1}')
            read -r class id < <(lspci -n -s "$addr" 2>/dev/null | awk '{print $2, $3}')
            [[ "$class" == 06* ]] && continue
            addrs+=("$addr")
            ids+=("$id")
        done < <(lspci -nn 2>/dev/null | grep -E "^(0000:)?${gpu_slot}\." | sed 's/^0000://')
    fi

    [[ ${#addrs[@]} -eq 0 ]] && return 1
    GPU_PCI_ADDRS=("${addrs[@]}")
    GPU_VFIO_IDS=$(IFS=,; echo "${ids[*]}")
    return 0
}

function gpu_hostdev_addrs() {
    # Print host PCI addresses (NN:NN.N) of every PCI <hostdev> assigned to a VM.
    # State-tracks the XML so only <source> addresses (host side) are printed.
    virsh dumpxml "$1" 2>/dev/null | awk '
        /<hostdev[^>]*type=.pci./ { inhd=1 }
        /<\/hostdev>/            { inhd=0; insrc=0 }
        inhd && /<source>/       { insrc=1 }
        inhd && /<\/source>/     { insrc=0 }
        inhd && insrc && /<address/ {
            bus=slot=fn=""
            if (match($0, /bus=.0x[0-9a-fA-F]+/))      { s=substr($0,RSTART,RLENGTH); sub(/.*0x/,"",s); bus=s }
            if (match($0, /slot=.0x[0-9a-fA-F]+/))     { s=substr($0,RSTART,RLENGTH); sub(/.*0x/,"",s); slot=s }
            if (match($0, /function=.0x[0-9a-fA-F]+/)) { s=substr($0,RSTART,RLENGTH); sub(/.*0x/,"",s); fn=s }
            if (bus!="" && slot!="" && fn!="") printf "%s:%s.%s\n", bus, slot, fn
        }'
}

function gpu_assigned_vm() {
    # Echo the first defined VM whose PCI host-devices include addr $1, else nothing.
    local addr="$1" vm
    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        if gpu_hostdev_addrs "$vm" | grep -qx "$addr"; then
            echo "$vm"
            return 0
        fi
    done < <(virsh list --all --name 2>/dev/null | grep -v '^$')
    return 1
}

function resolve_gpu_selector() {
    # Map a selector (index, BDF, or comma-list) to GPU head PCI addresses.
    # Echoes one addr per line on stdout. Returns 1 if any token is invalid.
    local sel="$1"
    local -a gpus=()
    mapfile -t gpus < <(gpu_enumerate)
    [[ ${#gpus[@]} -eq 0 ]] && { log_msg ERROR "No GPUs detected" >&2; return 1; }

    local -a tokens=()
    IFS=',' read -ra tokens <<< "$sel"
    local token
    for token in "${tokens[@]}"; do
        token="${token// /}"
        [[ -z "$token" ]] && continue
        token="${token#0000:}"   # strip domain prefix if present
        if [[ "$token" =~ ^[0-9]+$ ]]; then
            if [[ "$token" -ge ${#gpus[@]} ]]; then
                log_msg ERROR "GPU index $token out of range (0-$(( ${#gpus[@]} - 1 ))) — see 'gpu-list'" >&2
                return 1
            fi
            echo "${gpus[$token]}"
        elif [[ "$token" =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$ ]]; then
            local found=false g
            for g in "${gpus[@]}"; do
                [[ "$g" == "$token" ]] && { found=true; break; }
            done
            [[ "$found" != true ]] && { log_msg ERROR "PCI address $token is not a GPU — see 'gpu-list'" >&2; return 1; }
            echo "$token"
        else
            log_msg ERROR "Invalid GPU selector '$token' — use an index, PCI address, or comma-list" >&2
            return 1
        fi
    done
}

function print_gpu_table() {
    # The "nice selection": every GPU with index, driver, state and VM assignment.
    local -a gpus=()
    mapfile -t gpus < <(gpu_enumerate)
    if [[ ${#gpus[@]} -eq 0 ]]; then
        log_msg INFO "No GPUs / display controllers detected"
        return
    fi

    printf "${BOLD}%-4s %-12s %-34s %-6s %-10s %-11s %s${RESET}\n" \
        "IDX" "PCI" "MODEL" "GROUP" "DRIVER" "STATE" "ASSIGNED"
    printf "%-4s %-12s %-34s %-6s %-10s %-11s %s\n" \
        "----" "------------" "----------------------------------" "------" "----------" "-----------" "----------"

    local i addr
    for i in "${!gpus[@]}"; do
        addr="${gpus[$i]}"
        local model group driver state assigned c
        model=$(lspci -s "$addr" 2>/dev/null | sed -E 's/^[^ ]+ [^:]+: //' | cut -c1-34)
        group=$(gpu_iommu_group "$addr"); group="${group:--}"
        driver=$(gpu_host_driver "$addr")
        if gpu_is_primary "$addr"; then
            state="primary"
        elif [[ "$driver" == "vfio-pci" ]]; then
            state="vfio-ready"
        else
            state="host"
        fi
        assigned=$(gpu_assigned_vm "$addr" || true); assigned="${assigned:-free}"
        c="$RESET"
        [[ "$state" == "vfio-ready" && "$assigned" == "free" ]] && c="$GREEN"
        [[ "$state" == "primary" ]] && c="$YELLOW"
        [[ "$assigned" != "free" ]] && c="$CYAN"
        printf "%-4s %-12s %-34s %-6s %-10s ${c}%-11s${RESET} %s\n" \
            "$i" "$addr" "$model" "$group" "$driver" "$state" "$assigned"
    done
}

function check_vfio_ready() {
    # True if IOMMU is enabled and at least one non-primary GPU is bound to vfio-pci.
    grep -qE '(intel|amd)_iommu=on' /proc/cmdline 2>/dev/null || return 1

    local addr
    while IFS= read -r addr; do
        [[ -z "$addr" ]] && continue
        gpu_is_primary "$addr" && continue
        [[ "$(gpu_host_driver "$addr")" == "vfio-pci" ]] && return 0
    done < <(gpu_enumerate)
    return 1
}

function pci_to_virsh_hostdev() {
    # Convert PCI address "01:00.0" to virsh format "pci_0000_01_00_0"
    local addr="$1"
    echo "pci_0000_${addr//:/_}" | sed 's/\./_/g'
}

function attach_gpu_hostdevs() {
    # Attach every PCI addr in GPU_PCI_ADDRS to VM $1 as a persistent host-device.
    local vm="$1" addr
    for addr in "${GPU_PCI_ADDRS[@]}"; do
        virt-xml "$vm" --add-device --host-device "$(pci_to_virsh_hostdev "$addr")" --define >/dev/null \
            || die "Failed to attach GPU device $addr to '$vm'"
    done
}

function get_kvm_ssh_key_path() {
    local user_home
    if [[ -n "${SUDO_USER:-}" ]]; then
        user_home=$(eval echo "~${SUDO_USER}")
    else
        user_home="$HOME"
    fi
    echo "${user_home}/.ssh/kvm-manager"
}

function ensure_ssh_key() {
    # Migrate legacy key from /var/lib/libvirt/images/ if it exists
    local legacy_key="${LIBVIRT_IMAGES}/kvm-manager-key"
    if [[ -f "$legacy_key" && ! -f "$KVM_SSH_KEY" ]]; then
        log_msg INFO "Migrating SSH key to ${KVM_SSH_KEY}..."
        local key_dir
        key_dir="$(dirname "$KVM_SSH_KEY")"
        mkdir -p "$key_dir"
        chmod 700 "$key_dir"
        cp "$legacy_key" "$KVM_SSH_KEY"
        cp "${legacy_key}.pub" "${KVM_SSH_KEY}.pub"
        chmod 600 "$KVM_SSH_KEY"
        chmod 644 "${KVM_SSH_KEY}.pub"
        if [[ -n "${SUDO_USER:-}" ]]; then
            chown "${SUDO_USER}:${SUDO_USER}" "$key_dir" "$KVM_SSH_KEY" "${KVM_SSH_KEY}.pub"
        fi
        rm -f "$legacy_key" "${legacy_key}.pub"
        log_msg INFO "Key migrated successfully"
        return 0
    fi

    if [[ ! -f "$KVM_SSH_KEY" ]]; then
        local key_dir
        key_dir="$(dirname "$KVM_SSH_KEY")"
        if [[ ! -d "$key_dir" ]]; then
            mkdir -p "$key_dir"
            chmod 700 "$key_dir"
            if [[ -n "${SUDO_USER:-}" ]]; then
                chown "${SUDO_USER}:${SUDO_USER}" "$key_dir"
            fi
        fi

        log_msg INFO "Generating SSH keypair at ${KVM_SSH_KEY}..."
        ssh-keygen -t ed25519 -f "$KVM_SSH_KEY" -N "" -C "kvm-manager" >/dev/null
        chmod 600 "$KVM_SSH_KEY"
        chmod 644 "${KVM_SSH_KEY}.pub"

        if [[ -n "${SUDO_USER:-}" ]]; then
            chown "${SUDO_USER}:${SUDO_USER}" "$KVM_SSH_KEY" "${KVM_SSH_KEY}.pub"
        fi
    fi
}

function parse_ram_to_mib() {
    local input="$1"
    local num unit
    if [[ "$input" =~ ^([0-9]+)([gGmM])?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2],,}"
        case "$unit" in
            g) echo $(( num * 1024 )) ;;
            m|"") echo "$num" ;;
        esac
    else
        die "Invalid RAM size '$input' — use e.g. 2G, 512M, or 4096"
    fi
}

function parse_disk_to_gb() {
    local input="$1"
    local num unit
    if [[ "$input" =~ ^([0-9]+)([gGtT])?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2],,}"
        case "$unit" in
            t) echo $(( num * 1024 )) ;;
            g|"") echo "$num" ;;
        esac
    else
        die "Invalid disk size '$input' — use e.g. 20G, 1T, or 50"
    fi
}

# --- VM Information Helpers ---

function get_vm_ip() {
    local name="$1"
    local ip=""

    # Try qemu-guest-agent first
    ip=$(virsh domifaddr "$name" --source agent 2>/dev/null \
        | awk '/ipv4/ {split($4,a,"/"); print a[1]}' \
        | grep -v '^127\.' | head -1) || true
    if [[ -n "$ip" ]]; then echo "$ip"; return; fi

    # Try DHCP lease
    ip=$(virsh domifaddr "$name" --source lease 2>/dev/null \
        | awk '/ipv4/ {split($4,a,"/"); print a[1]}' \
        | grep -v '^127\.' | head -1) || true
    if [[ -n "$ip" ]]; then echo "$ip"; return; fi

    # Try ARP
    ip=$(virsh domifaddr "$name" --source arp 2>/dev/null \
        | awk '/ipv4/ {split($4,a,"/"); print a[1]}' \
        | grep -v '^127\.' | head -1) || true
    if [[ -n "$ip" ]]; then echo "$ip"; return; fi

    echo ""
}

function is_template() {
    [[ -f "${LIBVIRT_IMAGES}/${1}${TEMPLATE_MARKER}" ]]
}

function get_vm_state() {
    virsh domstate "$1" 2>/dev/null | head -1
}

# --- Setup ---

function cmd_setup() {
    check_root
    log_msg PHASE "Installing KVM/libvirt stack on Ubuntu"

    apt-get update -qq
    apt-get install -y \
        qemu-kvm libvirt-daemon-system libvirt-clients \
        virtinst virt-viewer bridge-utils cpu-checker \
        qemu-utils cloud-image-utils

    log_msg INFO "Checking hardware virtualization support..."
    if kvm-ok; then
        log_msg INFO "KVM acceleration available"
    else
        log_msg WARN "KVM acceleration NOT available — VMs will be very slow"
    fi

    systemctl enable --now libvirtd
    log_msg INFO "libvirtd service enabled and started"

    # Set up default network
    virsh net-start default 2>/dev/null || true
    virsh net-autostart default 2>/dev/null || true
    log_msg INFO "Default network active"

    # Add calling user to libvirt group
    local calling_user="${SUDO_USER:-}"
    if [[ -n "$calling_user" ]]; then
        usermod -aG libvirt,kvm "$calling_user"
        log_msg INFO "User '$calling_user' added to libvirt and kvm groups"
        log_msg WARN "Log out and back in for group membership to take effect"
    fi

    log_msg PHASE "KVM setup complete"

    # --- GPU Passthrough (VFIO) Setup ---
    log_msg PHASE "Configuring GPU passthrough..."

    local -a all_gpus=()
    mapfile -t all_gpus < <(gpu_enumerate)
    if [[ ${#all_gpus[@]} -eq 0 ]]; then
        log_msg INFO "No GPU / display controller detected — skipping GPU passthrough setup"
        return 0
    fi

    # Bind every GPU EXCEPT the host's primary (boot_vga) one to vfio-pci.
    local -a bind_gpus=() bind_drivers=()
    local g primary="" reserved_driver=""
    for g in "${all_gpus[@]}"; do
        if gpu_is_primary "$g"; then
            primary="$g"
            reserved_driver=$(gpu_host_driver "$g")
            log_msg INFO "Reserving primary GPU $g ($(lspci -s "$g" 2>/dev/null | sed 's/^[^ ]* //')) for the host"
        else
            bind_gpus+=("$g")
        fi
    done

    if [[ ${#bind_gpus[@]} -eq 0 ]]; then
        if [[ -n "$primary" ]]; then
            log_msg WARN "Only the primary GPU is present — nothing to pass through (the host needs it)"
            log_msg PHASE "Setup complete"
            return 0
        fi
        log_msg WARN "No primary (boot_vga) GPU detected — binding ALL GPUs to vfio-pci"
        bind_gpus=("${all_gpus[@]}")
    fi

    # Collect vendor:device IDs + IOMMU siblings of every GPU to bind.
    local -a bind_ids=()
    for g in "${bind_gpus[@]}"; do
        local d
        d=$(gpu_host_driver "$g")
        [[ "$d" != "unbound" && "$d" != "vfio-pci" ]] && bind_drivers+=("$d")
        resolve_gpu_group "$g" || continue
        local id
        IFS=',' read -ra _ids <<< "$GPU_VFIO_IDS"
        for id in "${_ids[@]}"; do bind_ids+=("$id"); done
        log_msg INFO "Will bind GPU $g group [${GPU_VFIO_IDS}] to vfio-pci"
    done
    GPU_VFIO_IDS=$(printf '%s\n' "${bind_ids[@]}" | awk 'NF && !seen[$0]++' | paste -sd,)
    GPU_PCI_ADDRS=("${bind_gpus[@]}")   # used only for the reboot summary below

    local NEEDS_REBOOT=false

    # 1. Enable IOMMU in GRUB
    local iommu_param
    if grep -q GenuineIntel /proc/cpuinfo 2>/dev/null; then
        iommu_param="intel_iommu=on"
    else
        iommu_param="amd_iommu=on"
    fi

    if grep -qE '(intel|amd)_iommu=on' /proc/cmdline 2>/dev/null; then
        log_msg INFO "IOMMU already enabled in kernel cmdline"
    else
        log_msg INFO "Enabling IOMMU in GRUB configuration..."
        if [[ -f /etc/default/grub ]]; then
            local current_cmdline
            current_cmdline=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | sed 's/^GRUB_CMDLINE_LINUX_DEFAULT="//' | sed 's/"$//')
            sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${current_cmdline} ${iommu_param} iommu=pt\"|" /etc/default/grub
            update-grub 2>/dev/null
            log_msg INFO "GRUB updated with '${iommu_param} iommu=pt'"
            NEEDS_REBOOT=true
        else
            log_msg WARN "Cannot find /etc/default/grub — add '${iommu_param} iommu=pt' to kernel cmdline manually"
        fi
    fi

    # 2. Configure VFIO to claim the selected GPUs at boot.
    #    Bind by vendor:device ID. softdep pre-empts each GPU driver EXCEPT the one
    #    serving the reserved primary GPU (so an iGPU on the same driver still loads).
    #    ponytail: two identical-model GPUs share one vendor:device ID, so ids= binds
    #    BOTH. To keep one for the host, pin it with a per-address driver_override in a
    #    boot script instead — not handled here.
    log_msg INFO "Writing VFIO modprobe configuration..."
    {
        echo "# GPU passthrough — generated by $SCRIPT_NAME"
        echo "# Bound to vfio-pci: ${GPU_PCI_ADDRS[*]}"
        [[ -n "$primary" ]] && echo "# Primary GPU reserved for host: $primary (driver: ${reserved_driver:-none})"
        echo "options vfio-pci ids=${GPU_VFIO_IDS}"
        local drv
        for drv in $(printf '%s\n' "${bind_drivers[@]}" nvidia nvidia_drm nvidia_uvm nvidia_modeset nouveau amdgpu radeon \
                     | awk 'NF && !seen[$0]++'); do
            [[ "$drv" == "$reserved_driver" ]] && continue
            echo "softdep $drv pre: vfio-pci"
        done
    } > "$VFIO_CONF"
    log_msg INFO "Written $VFIO_CONF (IDs: ${GPU_VFIO_IDS})"

    # 3. Load VFIO modules early via initramfs
    cat > "$VFIO_MODULES_CONF" <<'MODEOF'
vfio
vfio_iommu_type1
vfio_pci
MODEOF
    log_msg INFO "Written $VFIO_MODULES_CONF"

    log_msg INFO "Rebuilding initramfs..."
    update-initramfs -u 2>/dev/null
    log_msg INFO "initramfs rebuilt"

    # 4. Reboot warning
    if [[ "$NEEDS_REBOOT" == true ]]; then
        echo ""
        log_msg WARN "════════════════════════════════════════════"
        log_msg WARN "  REBOOT REQUIRED for GPU passthrough"
        log_msg WARN "  IOMMU + VFIO configuration written."
        log_msg WARN "  After reboot, the selected GPU(s) will be"
        log_msg WARN "  bound to vfio-pci and available for VMs."
        log_msg WARN "════════════════════════════════════════════"
        log_msg INFO "After reboot, verify with: $SCRIPT_NAME gpu-status"
        echo ""
    else
        log_msg INFO "VFIO configuration updated. Verify with: $SCRIPT_NAME gpu-status"
    fi

    log_msg PHASE "Setup complete"
}

# --- VM Lifecycle ---

function cmd_create() {
    check_root
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME create <name> [--template VM | --iso PATH] [--cpu N] [--ram SIZE] [--disk SIZE]"
    fi

    local name="$1"; shift
    validate_vm_name "$name"

    if vm_exists "$name"; then
        die "VM '$name' already exists"
    fi

    local template="" iso="" cloud_image=false stealth=false gpu=false cpu=$DEFAULT_CPU ram_mib=$DEFAULT_RAM_MIB disk_gb=$DEFAULT_DISK_GB
    local post_setup="" post_setup_script="" gpu_selector="" gpu_vendor=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --template)    template="$2"; shift 2 ;;
            --iso)         iso="$2"; shift 2 ;;
            --cloud-image) cloud_image=true; shift ;;
            --stealth)     stealth=true; shift ;;
            --gpu)
                gpu=true
                # Optional selector (index / PCI addr / comma-list) unless next arg is a flag
                if [[ $# -ge 2 && "${2:0:2}" != "--" ]]; then
                    gpu_selector="$2"; shift 2
                else
                    shift
                fi
                ;;
            --post-setup)
                post_setup=true
                # Next arg is optional path (if it doesn't start with --)
                if [[ $# -ge 2 && "${2:0:2}" != "--" ]]; then
                    post_setup_script="$2"; shift 2
                else
                    shift
                fi
                ;;
            --cpu)         cpu="$2"; shift 2 ;;
            --ram)         ram_mib=$(parse_ram_to_mib "$2"); shift 2 ;;
            --disk)        disk_gb=$(parse_disk_to_gb "$2"); shift 2 ;;
            *)             die "Unknown option: $1" ;;
        esac
    done

    # Resolve post-setup script path
    if [[ "$post_setup" == true ]]; then
        if [[ -z "$post_setup_script" ]]; then
            if [[ -f "$DEFAULT_POST_SETUP" ]]; then
                post_setup_script="$DEFAULT_POST_SETUP"
                log_msg INFO "Using default post-setup script: $post_setup_script"
            else
                echo -n "${YELLOW}Post-setup script path: ${RESET}"
                read -r post_setup_script
            fi
        fi
        if [[ ! -f "$post_setup_script" ]]; then
            die "Post-setup script not found: $post_setup_script"
        fi
    fi

    local source_count=0
    [[ -n "$template" ]] && source_count=$((source_count + 1))
    [[ -n "$iso" ]] && source_count=$((source_count + 1))
    [[ "$cloud_image" == true ]] && source_count=$((source_count + 1))
    if [[ $source_count -gt 1 ]]; then
        die "Cannot combine --template, --iso, and --cloud-image"
    fi

    # GPU passthrough validation + selection
    if [[ "$gpu" == true ]]; then
        if [[ "$stealth" == true ]]; then
            die "Cannot combine --gpu with --stealth (GPU passthrough exposes real hardware)"
        fi
        if ! check_vfio_ready; then
            die "GPU passthrough not ready — run '$SCRIPT_NAME setup' and reboot first (check with '$SCRIPT_NAME gpu-status')"
        fi

        # Resolve which GPU head(s) to pass through.
        local -a gpu_heads=()
        if [[ -z "$gpu_selector" ]]; then
            # Default: first free, vfio-bound, non-primary GPU.
            local g
            while IFS= read -r g; do
                [[ -z "$g" ]] && continue
                gpu_is_primary "$g" && continue
                [[ "$(gpu_host_driver "$g")" != "vfio-pci" ]] && continue
                [[ -n "$(gpu_assigned_vm "$g")" ]] && continue
                gpu_heads=("$g"); break
            done < <(gpu_enumerate)
            [[ ${#gpu_heads[@]} -eq 0 ]] && die "No free vfio-bound GPU available — see '$SCRIPT_NAME gpu-list'"
        else
            mapfile -t gpu_heads < <(resolve_gpu_selector "$gpu_selector") \
                || die "Invalid --gpu selector: $gpu_selector"
            [[ ${#gpu_heads[@]} -eq 0 ]] && die "Invalid --gpu selector: $gpu_selector"
        fi

        # Validate each and build the deduplicated union of their IOMMU groups.
        local -a all_addrs=() head
        for head in "${gpu_heads[@]}"; do
            if [[ "$(gpu_host_driver "$head")" != "vfio-pci" ]]; then
                die "GPU $head is not bound to vfio-pci — run '$SCRIPT_NAME setup' (check '$SCRIPT_NAME gpu-list')"
            fi
            local other
            other=$(gpu_assigned_vm "$head" || true)
            [[ -n "$other" ]] && log_msg WARN "GPU $head is already assigned to VM '$other' — they cannot run simultaneously"
            resolve_gpu_group "$head" || die "Could not resolve IOMMU group for GPU $head"
            all_addrs+=("${GPU_PCI_ADDRS[@]}")
        done
        mapfile -t GPU_PCI_ADDRS < <(printf '%s\n' "${all_addrs[@]}" | awk 'NF && !seen[$0]++')
        gpu_vendor=$(gpu_vendor_name "${gpu_heads[0]}")

        if [[ $ram_mib -lt 8192 ]]; then
            log_msg WARN "GPU workloads typically need ≥8G RAM (current: ${ram_mib}M)"
        fi
        log_msg INFO "GPU passthrough: ${GPU_PCI_ADDRS[*]} → VM '$name'"
    fi

    if [[ -n "$template" ]]; then
        log_msg PHASE "Creating VM '$name' from template '$template'"
        require_vm "$template"

        local state
        state=$(get_vm_state "$template")
        if [[ "$state" != "shut off" ]]; then
            log_msg WARN "Template '$template' is $state — shutting down for clone..."
            virsh shutdown "$template" 2>/dev/null || true
            local waited=0
            while [[ "$(get_vm_state "$template")" != "shut off" && $waited -lt 60 ]]; do
                sleep 2
                waited=$((waited + 2))
            done
            if [[ "$(get_vm_state "$template")" != "shut off" ]]; then
                die "Template '$template' did not shut down in time — use 'virsh destroy $template' to force"
            fi
        fi

        virt-clone --original "$template" --name "$name" --auto-clone
        log_msg INFO "Cloned from '$template'"

        # Adjust resources if non-default
        if [[ $cpu -ne $DEFAULT_CPU ]]; then
            virsh setvcpus "$name" "$cpu" --config --maximum
            virsh setvcpus "$name" "$cpu" --config
        fi
        if [[ $ram_mib -ne $DEFAULT_RAM_MIB ]]; then
            virsh setmaxmem "$name" "${ram_mib}M" --config
            virsh setmem "$name" "${ram_mib}M" --config
        fi

        # Attach GPU passthrough device(s) to the clone (templates carry none)
        if [[ "$gpu" == true ]]; then
            local clone_mtype
            clone_mtype=$(virsh dumpxml "$name" 2>/dev/null | grep -oP "machine='\K[^']+" | head -1)
            [[ "$clone_mtype" != *q35* ]] && log_msg WARN "Cloned VM machine type is '${clone_mtype:-unknown}' — GPU passthrough works best with q35"
            log_msg INFO "Attaching GPU passthrough device(s) to '$name'..."
            attach_gpu_hostdevs "$name"
        fi

    elif [[ -n "$iso" ]]; then
        if [[ ! -f "$iso" ]]; then
            die "ISO file not found: $iso"
        fi

        # Copy ISO to libvirt images dir if not already there (avoids permission issues)
        local iso_path
        iso_path=$(realpath "$iso")
        if [[ "$iso_path" != "${LIBVIRT_IMAGES}/"* ]]; then
            local iso_dest="${LIBVIRT_IMAGES}/$(basename "$iso_path")"
            if [[ ! -f "$iso_dest" ]]; then
                log_msg INFO "Copying ISO to ${LIBVIRT_IMAGES}/ (libvirt needs access)..."
                cp "$iso_path" "$iso_dest"
            fi
            iso_path="$iso_dest"
        fi

        log_msg PHASE "Creating VM '$name' from ISO"

        local -a vi_args=(
            --name "$name"
            --vcpus "$cpu"
            --memory "$ram_mib"
            --disk "path=${LIBVIRT_IMAGES}/${name}.qcow2,size=${disk_gb},format=qcow2,bus=virtio"
            --location "$iso_path,kernel=casper/vmlinuz,initrd=casper/initrd"
            --extra-args "console=ttyS0"
            --os-variant detect=on
            --network network=default,model=virtio
            --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0
            --graphics none
            --noautoconsole
        )

        if [[ "$gpu" == true ]]; then
            vi_args+=(--machine q35)
            local pci_addr
            for pci_addr in "${GPU_PCI_ADDRS[@]}"; do
                vi_args+=(--host-device "$(pci_to_virsh_hostdev "$pci_addr")")
            done
        fi

        virt-install "${vi_args[@]}"

        log_msg INFO "VM '$name' created — attach with 'virsh console $name'"

    elif [[ "$cloud_image" == true ]]; then
        log_msg PHASE "Creating VM '$name' from Ubuntu cloud image"

        local img_name
        img_name=$(basename "$CLOUD_IMAGE_URL")
        local base_img="${LIBVIRT_IMAGES}/${img_name}"
        local disk_path="${LIBVIRT_IMAGES}/${name}.qcow2"
        local seed_path="${LIBVIRT_IMAGES}/${name}-seed.img"

        # Download base image if not cached or stale
        if [[ -f "$base_img" ]]; then
            local cache_age_days=$(( ($(date +%s) - $(stat -c%Y "$base_img")) / 86400 ))
            if [[ $cache_age_days -gt 7 ]]; then
                log_msg WARN "Cloud image is ${cache_age_days} days old"
                if confirm "Download fresh cloud image?"; then
                    rm -f "$base_img"
                else
                    log_msg INFO "Using cached image (${cache_age_days}d old)"
                fi
            else
                log_msg INFO "Using cached cloud image (${cache_age_days}d old)"
            fi
        fi
        if [[ ! -f "$base_img" ]]; then
            log_msg INFO "Downloading cloud image..."
            wget -q --show-progress -O "$base_img" "$CLOUD_IMAGE_URL"
        fi

        # Create disk from base image and resize
        log_msg INFO "Creating ${disk_gb}G disk..."
        cp "$base_img" "$disk_path"
        qemu-img resize "$disk_path" "${disk_gb}G"

        # Generate cloud-init seed ISO
        ensure_ssh_key
        local pub_key
        pub_key=$(cat "${KVM_SSH_KEY}.pub")

        local ci_dir
        ci_dir=$(mktemp -d)

        # Build cloud-init user-data
        local ci_runcmd="" ci_packages="" ci_write_files=""

        if [[ "$stealth" != true ]]; then
            ci_packages="packages:
  - qemu-guest-agent"
            ci_runcmd="  - systemctl enable --now qemu-guest-agent"
        else
            # In stealth mode: purge packages that leak VM identity
            ci_runcmd="  - apt-get purge -y open-vm-tools open-vm-tools-desktop 2>/dev/null || true
  - apt-get purge -y qemu-guest-agent 2>/dev/null || true
  - rm -f /etc/vmware-tools 2>/dev/null || true"
        fi

        if [[ "$post_setup" == true && -n "$post_setup_script" ]]; then
            local script_size
            script_size=$(stat -c%s "$post_setup_script")
            if [[ $script_size -gt 5242880 ]]; then
                die "Post-setup script is $((script_size/1024))KB — too large for cloud-init (max 5MB). Use 'post-setup' command instead."
            fi
            log_msg INFO "Embedding post-setup script into cloud-init ($(( script_size / 1024 ))KB)..."
            local script_b64
            script_b64=$(base64 -w0 "$post_setup_script")
            ci_write_files="write_files:
  - path: /opt/vm-post-setup.sh
    permissions: '0755'
    encoding: b64
    content: ${script_b64}"
            if [[ -n "$ci_runcmd" ]]; then
                ci_runcmd="${ci_runcmd}
  - bash /opt/vm-post-setup.sh --user ubuntu 2>&1 | tee /var/log/vm-post-setup.log"
            else
                ci_runcmd="  - bash /opt/vm-post-setup.sh --user ubuntu 2>&1 | tee /var/log/vm-post-setup.log"
            fi
        fi

        # GPU passthrough marker for vm-post-setup.sh
        if [[ "$gpu" == true ]]; then
            local gpu_marker="  - path: /opt/.gpu-passthrough
    permissions: '0644'
    content: |
      GPU_PCI_ADDRESSES=\"${GPU_PCI_ADDRS[*]}\"
      GPU_VENDOR=${gpu_vendor:-unknown}"
            if [[ -n "$ci_write_files" ]]; then
                ci_write_files="${ci_write_files}
${gpu_marker}"
            else
                ci_write_files="write_files:
${gpu_marker}"
            fi
        fi

        {
            cat <<CIEOF
#cloud-config
users:
  - name: ubuntu
    lock_passwd: true
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${pub_key}
ssh_pwauth: false
package_update: true
CIEOF
            [[ "$stealth" != true ]] && echo "package_upgrade: true"
            [[ -n "$ci_packages" ]] && echo "$ci_packages"
            [[ -n "$ci_write_files" ]] && echo "$ci_write_files"
            if [[ -n "$ci_runcmd" ]]; then
                echo "runcmd:"
                echo "$ci_runcmd"
            fi
        } > "${ci_dir}/user-data"

        cat > "${ci_dir}/meta-data" <<CIEOF
instance-id: ${name}
local-hostname: ${name}
CIEOF

        cloud-localds "$seed_path" "${ci_dir}/user-data" "${ci_dir}/meta-data"
        rm -rf "$ci_dir"

        if [[ "$stealth" == true ]]; then
            # i440FX machine type: all PCI devices use Intel vendor IDs (0x8086)
            # Q35 creates ~14 PCIe root ports with Red Hat vendor 0x1b36 — instant VM detection
            # USB disabled: qemu-xhci also uses 0x1b36, headless VMs don't need USB
            virt-install \
                --name "$name" \
                --vcpus "$cpu" \
                --memory "$ram_mib" \
                --disk "path=${disk_path},format=qcow2,bus=sata" \
                --disk "path=${seed_path},device=cdrom" \
                --os-variant ubuntu24.04 \
                --network network=default \
                --graphics none \
                --machine pc \
                --controller usb,model=none \
                --import \
                --noreboot \
                --noautoconsole
        else
            local -a vi_cloud_args=(
                --name "$name"
                --vcpus "$cpu"
                --memory "$ram_mib"
                --disk "path=${disk_path},format=qcow2,bus=virtio"
                --disk "path=${seed_path},device=cdrom"
                --os-variant ubuntu24.04
                --network network=default,model=virtio
                --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0
                --graphics none
                --import
                --noautoconsole
            )

            if [[ "$gpu" == true ]]; then
                vi_cloud_args+=(--machine q35)
                local pci_addr
                for pci_addr in "${GPU_PCI_ADDRS[@]}"; do
                    vi_cloud_args+=(--host-device "$(pci_to_virsh_hostdev "$pci_addr")")
                done
                log_msg INFO "GPU passthrough: attaching ${#GPU_PCI_ADDRS[@]} PCI device(s) to VM"
            fi

            virt-install "${vi_cloud_args[@]}"
        fi

        log_msg INFO "VM '$name' created — SSH key: ${KVM_SSH_KEY}"
        log_msg INFO "Connect with '$SCRIPT_NAME ssh $name'"
    else
        die "Specify --template, --iso, or --cloud-image to create a VM"
    fi

    if [[ "$stealth" == true ]]; then
        log_msg INFO "Applying stealth hardening..."
        cmd_harden "$name" --verify
        virsh start "$name" >/dev/null
    fi

    # For cloud-init post-setup: wait for completion and auto-snapshot
    if [[ "$post_setup" == true && "$cloud_image" == true ]]; then
        log_msg INFO "Waiting for post-setup to complete (cloud-init)..."
        log_msg INFO "This may take several minutes. Ctrl+C to skip (you can snapshot manually later)."

        local ip="" waited=0 max_boot_wait=120
        # Wait for VM to get an IP
        while [[ -z "$ip" && $waited -lt $max_boot_wait ]]; do
            sleep 5
            waited=$((waited + 5))
            ip=$(get_vm_ip "$name")
        done
        if [[ -z "$ip" ]]; then
            log_msg WARN "Could not detect VM IP after ${max_boot_wait}s — skip auto-snapshot"
            log_msg INFO "Run '$SCRIPT_NAME post-setup $name' manually or snapshot after cloud-init finishes"
        else
            # Poll for the done marker via SSH
            local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
            local ssh_key_args=()
            [[ -r "$KVM_SSH_KEY" ]] && ssh_key_args+=(-i "$KVM_SSH_KEY")
            local max_setup_wait=900 setup_waited=0
            while [[ $setup_waited -lt $max_setup_wait ]]; do
                if ssh -q "${ssh_opts[@]}" "${ssh_key_args[@]}" "ubuntu@${ip}" \
                    "test -f /opt/.post-setup-done" 2>/dev/null; then
                    log_msg INFO "Post-setup finished on '$name'"
                    local snap_name="post-setup"
                    virsh snapshot-create-as "$name" \
                        --name "$snap_name" \
                        --description "Auto-snapshot after post-setup at $(date '+%Y-%m-%d %H:%M:%S')" \
                        --atomic
                    log_msg PHASE "Snapshot '$snap_name' created — rollback anytime with: $SCRIPT_NAME rollback $name $snap_name"
                    break
                fi
                sleep 15
                setup_waited=$((setup_waited + 15))
                [[ $((setup_waited % 60)) -eq 0 ]] && log_msg INFO "Still waiting... (${setup_waited}s)"
            done
            if [[ $setup_waited -ge $max_setup_wait ]]; then
                log_msg WARN "Post-setup did not complete within ${max_setup_wait}s — skipping auto-snapshot"
                log_msg INFO "Check progress: $SCRIPT_NAME ssh $name 'tail -f /var/log/vm-post-setup.log'"
            fi
        fi
    fi

    log_msg PHASE "VM '$name' ready"
}

function cmd_delete() {
    check_root
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME delete <name> [--force]"
    fi

    local name="$1"; shift
    local force=false
    [[ "${1:-}" == "--force" ]] && force=true

    require_vm "$name"

    if [[ "$force" != true ]]; then
        if ! confirm "Delete VM '$name' and all its storage?"; then
            log_msg INFO "Cancelled"
            return
        fi
    fi

    log_msg PHASE "Deleting VM '$name'"

    # Stop if running
    local state
    state=$(get_vm_state "$name")
    if [[ "$state" == "running" || "$state" == "paused" ]]; then
        virsh destroy "$name" 2>/dev/null || true
        log_msg INFO "Stopped VM"
    fi

    # Remove all snapshots
    local snaps
    snaps=$(virsh snapshot-list "$name" --name 2>/dev/null || true)
    if [[ -n "$snaps" ]]; then
        while IFS= read -r snap; do
            [[ -z "$snap" ]] && continue
            virsh snapshot-delete "$name" "$snap" 2>/dev/null || true
        done <<< "$snaps"
        log_msg INFO "Removed snapshots"
    fi

    # Undefine with storage removal (handle UEFI and BIOS)
    virsh undefine "$name" --remove-all-storage --nvram 2>/dev/null \
        || virsh undefine "$name" --remove-all-storage 2>/dev/null \
        || virsh undefine "$name" 2>/dev/null \
        || die "Failed to undefine VM '$name'"

    # Remove template marker if present
    rm -f "${LIBVIRT_IMAGES}/${name}${TEMPLATE_MARKER}"

    log_msg PHASE "VM '$name' deleted"
}

function cmd_list() {
    local vms
    vms=$(virsh list --all --name 2>/dev/null | grep -v '^$' || true)

    if [[ -z "$vms" ]]; then
        log_msg INFO "No VMs found"
        return
    fi

    printf "${BOLD}%-25s %-12s %-6s %-8s %-16s %-5s${RESET}\n" \
        "NAME" "STATE" "vCPUs" "RAM" "IP" "TMPL"
    printf "%-25s %-12s %-6s %-8s %-16s %-5s\n" \
        "-------------------------" "------------" "------" "--------" "----------------" "-----"

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue

        local state vcpus ram_kib ram_display ip tmpl_flag
        state=$(get_vm_state "$name")
        vcpus=$(virsh dominfo "$name" 2>/dev/null | awk '/CPU\(s\)/{print $2}')
        ram_kib=$(virsh dominfo "$name" 2>/dev/null | awk '/Max memory/{print $3}')
        ram_display=$(( ram_kib / 1024 ))M
        if (( ram_kib >= 1048576 )); then
            ram_display="$(( ram_kib / 1048576 ))G"
        fi

        ip="-"
        if [[ "$state" == "running" ]]; then
            local detected_ip
            detected_ip=$(get_vm_ip "$name")
            [[ -n "$detected_ip" ]] && ip="$detected_ip"
        fi

        tmpl_flag=""
        is_template "$name" && tmpl_flag="yes"

        local state_color="$RESET"
        case "$state" in
            running)  state_color="$GREEN" ;;
            "shut off") state_color="$RED" ;;
            paused)   state_color="$YELLOW" ;;
        esac

        printf "%-25s ${state_color}%-12s${RESET} %-6s %-8s %-16s %-5s\n" \
            "$name" "$state" "$vcpus" "$ram_display" "$ip" "$tmpl_flag"
    done <<< "$vms"
}

# --- Template Management ---

function cmd_template_create() {
    check_root
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME template-create <vm-name>"
    fi

    local name="$1"
    require_vm "$name"

    local state
    state=$(get_vm_state "$name")
    if [[ "$state" != "shut off" ]]; then
        if confirm "VM '$name' is $state — shut it down to create template?"; then
            virsh shutdown "$name"
            log_msg INFO "Waiting for shutdown..."
            local waited=0
            while [[ "$(get_vm_state "$name")" != "shut off" && $waited -lt 60 ]]; do
                sleep 2
                waited=$((waited + 2))
            done
            if [[ "$(get_vm_state "$name")" != "shut off" ]]; then
                die "VM did not shut down in time"
            fi
        else
            die "VM must be shut off to create a template"
        fi
    fi

    touch "${LIBVIRT_IMAGES}/${name}${TEMPLATE_MARKER}"

    # Create a base snapshot for the template
    if ! virsh snapshot-list "$name" --name 2>/dev/null | grep -q '^base$'; then
        virsh snapshot-create-as "$name" --name "base" --description "Template base state" --atomic
        log_msg INFO "Created 'base' snapshot"
    fi

    log_msg PHASE "VM '$name' marked as template"
}

function cmd_template_list() {
    local vms
    vms=$(virsh list --all --name 2>/dev/null | grep -v '^$' || true)

    local found=false
    printf "${BOLD}%-25s %-12s${RESET}\n" "TEMPLATE" "STATE"
    printf "%-25s %-12s\n" "-------------------------" "------------"

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if is_template "$name"; then
            found=true
            local state
            state=$(get_vm_state "$name")
            printf "%-25s %-12s\n" "$name" "$state"
        fi
    done <<< "$vms"

    if [[ "$found" == false ]]; then
        log_msg INFO "No templates found — use '$SCRIPT_NAME template-create <vm>' to mark one"
    fi
}

function cmd_clone() {
    check_root
    if [[ $# -lt 2 ]]; then
        die "Usage: $SCRIPT_NAME clone <source-vm> <new-name>"
    fi

    local source="$1" new_name="$2"
    require_vm "$source"
    validate_vm_name "$new_name"

    if vm_exists "$new_name"; then
        die "VM '$new_name' already exists"
    fi

    local state
    state=$(get_vm_state "$source")
    if [[ "$state" != "shut off" ]]; then
        if confirm "Source VM '$source' is $state — shut it down for cloning?"; then
            virsh shutdown "$source"
            log_msg INFO "Waiting for shutdown..."
            local waited=0
            while [[ "$(get_vm_state "$source")" != "shut off" && $waited -lt 60 ]]; do
                sleep 2
                waited=$((waited + 2))
            done
            if [[ "$(get_vm_state "$source")" != "shut off" ]]; then
                die "VM did not shut down in time"
            fi
        else
            die "Source VM must be shut off for cloning"
        fi
    fi

    log_msg PHASE "Cloning '$source' → '$new_name'"
    virt-clone --original "$source" --name "$new_name" --auto-clone
    log_msg PHASE "Clone '$new_name' ready"
}

# --- Snapshot Management ---

function cmd_snap() {
    check_root
    if [[ $# -lt 2 ]]; then
        die "Usage: $SCRIPT_NAME snap <vm-name> <snapshot-name>"
    fi

    local name="$1" snap_name="$2"
    require_vm "$name"
    validate_snap_name "$snap_name"

    log_msg INFO "Creating snapshot '$snap_name' for VM '$name'..."

    local start_time
    start_time=$(date +%s%N)

    virsh snapshot-create-as "$name" \
        --name "$snap_name" \
        --description "Created by $SCRIPT_NAME at $(date '+%Y-%m-%d %H:%M:%S')" \
        --atomic

    local end_time elapsed_ms
    end_time=$(date +%s%N)
    elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    log_msg PHASE "Snapshot '$snap_name' created (${elapsed_ms}ms)"
}

function cmd_rollback() {
    check_root
    if [[ $# -lt 2 ]]; then
        die "Usage: $SCRIPT_NAME rollback <vm-name> <snapshot-name>"
    fi

    local name="$1" snap_name="$2"
    require_vm "$name"
    validate_snap_name "$snap_name"

    # Verify snapshot exists
    if ! virsh snapshot-info "$name" "$snap_name" &>/dev/null; then
        die "Snapshot '$snap_name' not found for VM '$name'"
    fi

    log_msg INFO "Reverting VM '$name' to snapshot '$snap_name'..."

    local start_time
    start_time=$(date +%s%N)

    virsh snapshot-revert "$name" "$snap_name"

    local end_time elapsed_ms
    end_time=$(date +%s%N)
    elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    local state
    state=$(get_vm_state "$name")
    log_msg PHASE "Rolled back to '$snap_name' (${elapsed_ms}ms) — VM is $state"
}

function cmd_snap_list() {
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME snap-list <vm-name>"
    fi

    local name="$1"
    require_vm "$name"

    local snaps
    snaps=$(virsh snapshot-list "$name" --name 2>/dev/null || true)

    if [[ -z "$snaps" ]]; then
        log_msg INFO "No snapshots for VM '$name'"
        return
    fi

    log_msg PHASE "Snapshots for VM '$name':"
    echo ""
    virsh snapshot-list "$name"
    echo ""

    local current
    current=$(virsh snapshot-current "$name" --name 2>/dev/null || true)
    if [[ -n "$current" ]]; then
        log_msg INFO "Current snapshot: $current"
    fi
}

function cmd_snap_delete() {
    check_root
    if [[ $# -lt 2 ]]; then
        die "Usage: $SCRIPT_NAME snap-delete <vm-name> <snapshot-name>"
    fi

    local name="$1" snap_name="$2"
    require_vm "$name"
    validate_snap_name "$snap_name"

    if ! virsh snapshot-info "$name" "$snap_name" &>/dev/null; then
        die "Snapshot '$snap_name' not found for VM '$name'"
    fi

    virsh snapshot-delete "$name" "$snap_name"
    log_msg PHASE "Snapshot '$snap_name' deleted from VM '$name'"
}

# --- Monitoring & Access ---

function cmd_status() {
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME status <vm-name>"
    fi

    local name="$1"
    require_vm "$name"

    local state vcpus ram_kib ram_display ip snap_count autostart

    state=$(get_vm_state "$name")
    vcpus=$(virsh dominfo "$name" | awk '/CPU\(s\)/{print $2}')
    ram_kib=$(virsh dominfo "$name" | awk '/Max memory/{print $3}')
    ram_display="$(( ram_kib / 1024 )) MiB"
    if (( ram_kib >= 1048576 )); then
        ram_display="$(( ram_kib / 1048576 )) GiB"
    fi
    autostart=$(virsh dominfo "$name" | awk '/Autostart/{print $2}')
    snap_count=$(virsh snapshot-list "$name" --name 2>/dev/null | grep -c . || echo 0)

    ip="-"
    if [[ "$state" == "running" ]]; then
        local detected_ip
        detected_ip=$(get_vm_ip "$name")
        [[ -n "$detected_ip" ]] && ip="$detected_ip"
    fi

    local tmpl="no"
    is_template "$name" && tmpl="yes"

    echo ""
    echo "${BOLD}VM: ${name}${RESET}"
    echo "───────────────────────────────"
    printf "  %-14s %s\n" "State:" "$state"
    printf "  %-14s %s\n" "vCPUs:" "$vcpus"
    printf "  %-14s %s\n" "RAM:" "$ram_display"
    printf "  %-14s %s\n" "IP:" "$ip"
    printf "  %-14s %s\n" "Autostart:" "$autostart"
    printf "  %-14s %s\n" "Snapshots:" "$snap_count"
    printf "  %-14s %s\n" "Template:" "$tmpl"

    echo ""
    echo "${BOLD}Disks:${RESET}"
    virsh domblklist "$name" 2>/dev/null | tail -n +3 | while read -r target source_path; do
        [[ -z "$target" || "$source_path" == "-" ]] && continue
        if [[ -f "$source_path" ]]; then
            local vsize asize
            vsize=$(qemu-img info "$source_path" 2>/dev/null | awk '/virtual size/{print $3, $4}')
            asize=$(du -h "$source_path" 2>/dev/null | cut -f1)
            printf "  %-8s %s  (virtual: %s, actual: %s)\n" "$target" "$source_path" "$vsize" "$asize"
        else
            printf "  %-8s %s\n" "$target" "$source_path"
        fi
    done

    echo ""
    echo "${BOLD}Network Interfaces:${RESET}"
    virsh domiflist "$name" 2>/dev/null | tail -n +3 | while read -r iface type source model mac; do
        [[ -z "$iface" ]] && continue
        printf "  %-10s %-10s %-15s %-10s %s\n" "$iface" "$type" "$source" "$model" "$mac"
    done
    echo ""
}

function cmd_monitor() {
    if ! command -v watch &>/dev/null; then
        die "'watch' command not found — install with: apt-get install procps"
    fi

    log_msg INFO "Starting live VM monitor (Ctrl+C to exit)..."
    exec watch -n 2 "$0" list
}

function cmd_console() {
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME console <vm-name>"
    fi

    local name="$1"
    require_vm "$name"

    local state
    state=$(get_vm_state "$name")
    if [[ "$state" != "running" ]]; then
        die "VM '$name' is $state — start it first"
    fi

    log_msg INFO "Connecting to console (Ctrl+] to exit)..."
    exec virsh console "$name"
}

function cmd_ssh() {
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME ssh <vm-name> [ssh-args...]"
    fi

    local name="$1"; shift
    require_vm "$name"

    local state
    state=$(get_vm_state "$name")
    if [[ "$state" != "running" ]]; then
        die "VM '$name' is $state — start it first"
    fi

    local ip
    ip=$(get_vm_ip "$name")
    if [[ -z "$ip" ]]; then
        die "Cannot detect IP for '$name' — install qemu-guest-agent in the VM"
    fi

    local ssh_args=()

    # Use KVM manager key if it exists and is readable by the current user
    if [[ -r "$KVM_SSH_KEY" ]]; then
        ssh_args+=(-i "$KVM_SSH_KEY")
    fi

    # Default to 'ubuntu' user only for cloud-image VMs (indicated by managed key)
    local ssh_target="$ip"
    if [[ -r "$KVM_SSH_KEY" ]]; then
        local has_user=false
        for arg in "$@"; do
            [[ "$arg" == "--" ]] && break
            if [[ "$arg" == *@* || "$arg" == "-l" ]]; then
                has_user=true
                break
            fi
        done
        if [[ "$has_user" == false ]]; then
            ssh_target="ubuntu@${ip}"
        fi
    fi

    log_msg INFO "SSH to $name ($ssh_target)..."
    exec ssh "${ssh_args[@]}" "$ssh_target" "$@"
}

# --- Post-Setup ---

function cmd_post_setup() {
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME post-setup <vm-name> [script-path]"
    fi

    local name="$1"; shift
    require_vm "$name"

    local state
    state=$(get_vm_state "$name")
    if [[ "$state" != "running" ]]; then
        die "VM '$name' is $state — start it first"
    fi

    local ip
    ip=$(get_vm_ip "$name")
    if [[ -z "$ip" ]]; then
        die "Cannot detect IP for '$name' — install qemu-guest-agent in the VM"
    fi

    # Resolve script path
    local script_path="${1:-}"
    if [[ -z "$script_path" ]]; then
        if [[ -f "$DEFAULT_POST_SETUP" ]]; then
            script_path="$DEFAULT_POST_SETUP"
            log_msg INFO "Using default post-setup script: $script_path"
        else
            echo -n "${YELLOW}Post-setup script path: ${RESET}"
            read -r script_path
        fi
    fi
    if [[ ! -f "$script_path" ]]; then
        die "Post-setup script not found: $script_path"
    fi

    local ssh_args=()
    if [[ -r "$KVM_SSH_KEY" ]]; then
        ssh_args+=(-i "$KVM_SSH_KEY")
    fi

    local ssh_user="ubuntu"
    local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

    # Check if already ran
    local already_ran
    already_ran=$(ssh "${ssh_opts[@]}" "${ssh_args[@]}" "${ssh_user}@${ip}" \
        "cat /opt/.post-setup-done 2>/dev/null" 2>/dev/null || true)
    if [[ -n "$already_ran" ]]; then
        log_msg WARN "Post-setup already ran on $already_ran"
        if ! confirm "Run again?"; then
            log_msg INFO "Cancelled"
            return
        fi
    fi

    log_msg PHASE "Running post-setup on '$name' ($ip)..."

    # Copy script to VM
    scp "${ssh_opts[@]}" "${ssh_args[@]}" "$script_path" "${ssh_user}@${ip}:/tmp/vm-post-setup.sh"

    # Execute remotely
    ssh "${ssh_opts[@]}" "${ssh_args[@]}" "${ssh_user}@${ip}" \
        "sudo bash /tmp/vm-post-setup.sh --user ${ssh_user} 2>&1 | tee /tmp/vm-post-setup.log"

    log_msg PHASE "Post-setup complete on '$name'"

    # Auto-snapshot after successful provisioning
    local snap_name="post-setup"
    if virsh snapshot-info "$name" "$snap_name" &>/dev/null; then
        snap_name="post-setup-$(date +%Y%m%d-%H%M%S)"
    fi
    log_msg INFO "Creating snapshot '$snap_name'..."
    virsh snapshot-create-as "$name" \
        --name "$snap_name" \
        --description "Auto-snapshot after post-setup at $(date '+%Y-%m-%d %H:%M:%S')" \
        --atomic
    log_msg PHASE "Snapshot '$snap_name' created — rollback anytime with: $SCRIPT_NAME rollback $name $snap_name"
}

# --- Analyze (forensics wrapper) ---

function cmd_analyze() {
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME analyze <vm-name> [forensics-args...]"
    fi

    local name="$1"; shift
    require_vm "$name"

    local forensics_script
    forensics_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vm-forensics.sh"
    if [[ ! -f "$forensics_script" ]]; then
        die "vm-forensics.sh not found in $(dirname "$forensics_script") — place it alongside kvm-manager.sh"
    fi

    exec bash "$forensics_script" "$name" "$@"
}

# --- Autostart ---

function cmd_autostart() {
    check_root
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME autostart <vm-name> [on|off]"
    fi

    local name="$1"
    local toggle="${2:-on}"
    require_vm "$name"

    case "$toggle" in
        on)
            virsh autostart "$name"
            log_msg INFO "VM '$name' will start automatically on host boot"
            ;;
        off)
            virsh autostart --disable "$name"
            log_msg INFO "VM '$name' autostart disabled"
            ;;
        *)
            die "Unknown toggle '$toggle' — use 'on' or 'off'"
            ;;
    esac
}

# --- GPU Passthrough Status ---

function cmd_gpu_status() {
    log_msg PHASE "GPU Passthrough Status"
    echo ""

    # IOMMU
    if grep -qE '(intel|amd)_iommu=on' /proc/cmdline 2>/dev/null; then
        log_msg INFO "IOMMU:          ${GREEN}enabled${RESET}"
    else
        log_msg WARN "IOMMU:          ${RED}disabled${RESET} — run '$SCRIPT_NAME setup' and reboot"
    fi

    # IOMMU groups
    local group_count=0
    if [[ -d /sys/kernel/iommu_groups ]]; then
        group_count=$(ls /sys/kernel/iommu_groups/ 2>/dev/null | wc -l)
    fi
    if [[ $group_count -gt 0 ]]; then
        log_msg INFO "IOMMU groups:   ${GREEN}${group_count} groups${RESET}"
    else
        log_msg WARN "IOMMU groups:   ${RED}none${RESET} (IOMMU not active — reboot needed after setup)"
    fi

    # Per-GPU table (index, driver, state, VM assignment)
    echo ""
    print_gpu_table

    # Overall readiness
    echo ""
    if check_vfio_ready; then
        log_msg PHASE "${GREEN}GPU passthrough is READY${RESET} — use '--gpu [selector]' when creating VMs"
    else
        log_msg WARN "GPU passthrough is NOT ready"
        if ! grep -qE '(intel|amd)_iommu=on' /proc/cmdline 2>/dev/null; then
            log_msg INFO "  → Run: sudo $SCRIPT_NAME setup"
            log_msg INFO "  → Then reboot the host"
        elif [[ $group_count -eq 0 ]]; then
            log_msg INFO "  → Reboot the host to activate IOMMU"
        else
            log_msg INFO "  → No non-primary GPU is bound to vfio-pci — check $VFIO_CONF and reboot"
        fi
    fi
    echo ""
}

function cmd_gpu_list() {
    log_msg PHASE "GPUs on this host"
    echo ""
    print_gpu_table
    echo ""
    log_msg INFO "Assign with: $SCRIPT_NAME create <vm> --cloud-image --gpu <IDX|PCI>"
    log_msg INFO "         or: $SCRIPT_NAME gpu-attach <vm> <IDX|PCI>"
}

function cmd_gpu_attach() {
    check_root
    if [[ $# -lt 2 ]]; then
        die "Usage: $SCRIPT_NAME gpu-attach <vm-name> <selector>"
    fi

    local name="$1" selector="$2"
    require_vm "$name"

    local state
    state=$(get_vm_state "$name")
    if [[ "$state" != "shut off" ]]; then
        die "VM '$name' must be shut off to attach a GPU (current state: $state)"
    fi

    local -a heads=()
    mapfile -t heads < <(resolve_gpu_selector "$selector") || die "Invalid selector: $selector"
    [[ ${#heads[@]} -eq 0 ]] && die "Invalid selector: $selector"

    local mtype
    mtype=$(virsh dumpxml "$name" 2>/dev/null | grep -oP "machine='\K[^']+" | head -1)
    [[ "$mtype" != *q35* ]] && log_msg WARN "VM machine type is '${mtype:-unknown}' — GPU passthrough works best with q35"

    log_msg PHASE "Attaching GPU(s) to '$name'"
    local head
    for head in "${heads[@]}"; do
        [[ "$(gpu_host_driver "$head")" != "vfio-pci" ]] && \
            log_msg WARN "GPU $head is not bound to vfio-pci — VM may fail to start (run '$SCRIPT_NAME setup')"
        local other
        other=$(gpu_assigned_vm "$head" || true)
        if [[ -n "$other" && "$other" != "$name" ]]; then
            die "GPU $head is already assigned to VM '$other' — detach it there first"
        fi
        if [[ "$other" == "$name" ]]; then
            log_msg WARN "GPU $head already attached to '$name' — skipping"
            continue
        fi
        resolve_gpu_group "$head" || die "Could not resolve IOMMU group for GPU $head"
        attach_gpu_hostdevs "$name"
        log_msg INFO "Attached GPU $head (group: ${GPU_PCI_ADDRS[*]}) to '$name'"
    done
    log_msg PHASE "Done — start it with '$SCRIPT_NAME start $name'"
}

function cmd_gpu_detach() {
    check_root
    if [[ $# -lt 2 ]]; then
        die "Usage: $SCRIPT_NAME gpu-detach <vm-name> <selector>"
    fi

    local name="$1" selector="$2"
    require_vm "$name"

    local state
    state=$(get_vm_state "$name")
    if [[ "$state" != "shut off" ]]; then
        die "VM '$name' must be shut off to detach a GPU (current state: $state)"
    fi

    local -a heads=()
    mapfile -t heads < <(resolve_gpu_selector "$selector") || die "Invalid selector: $selector"
    [[ ${#heads[@]} -eq 0 ]] && die "Invalid selector: $selector"

    log_msg PHASE "Detaching GPU(s) from '$name'"
    local head removed=0
    for head in "${heads[@]}"; do
        resolve_gpu_group "$head" || die "Could not resolve IOMMU group for GPU $head"
        local addr
        for addr in "${GPU_PCI_ADDRS[@]}"; do
            if virt-xml "$name" --remove-device --host-device "$(pci_to_virsh_hostdev "$addr")" --define >/dev/null 2>&1; then
                removed=$((removed + 1))
            fi
        done
        log_msg INFO "Detached GPU $head from '$name'"
    done
    if [[ $removed -eq 0 ]]; then
        log_msg WARN "No matching GPU host-devices were attached to '$name'"
    fi
    log_msg PHASE "GPU detach complete for '$name'"
}

# --- Power Management ---

function cmd_power() {
    local action="$1"; shift
    check_root

    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME $action <vm-name> [--force]"
    fi

    local name="$1"
    local force=false
    [[ "${2:-}" == "--force" ]] && force=true

    require_vm "$name"

    case "$action" in
        start)
            local state
            state=$(get_vm_state "$name")
            if [[ "$state" == "running" ]]; then
                log_msg WARN "VM '$name' is already running"
                return
            fi
            virsh start "$name"
            log_msg PHASE "VM '$name' started"
            ;;
        stop)
            local state
            state=$(get_vm_state "$name")
            if [[ "$state" == "shut off" ]]; then
                log_msg WARN "VM '$name' is already stopped"
                return
            fi
            if [[ "$force" == true ]]; then
                virsh destroy "$name"
                log_msg PHASE "VM '$name' force-stopped"
            else
                virsh shutdown "$name"
                log_msg PHASE "VM '$name' shutdown signal sent (use --force to kill immediately)"
            fi
            ;;
        restart)
            local state
            state=$(get_vm_state "$name")
            if [[ "$state" != "running" ]]; then
                log_msg WARN "VM '$name' is not running — starting it"
                virsh start "$name"
            else
                virsh reboot "$name"
            fi
            log_msg PHASE "VM '$name' restarting"
            ;;
    esac
}

# --- Anti-Detection Hardening ---

function cmd_harden() {
    check_root
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME harden <vm-name> [--profile N] [--verify]"
    fi

    local name="$1"; shift
    local profile_idx="" verify=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile) profile_idx="$2"; shift 2 ;;
            --verify)  verify=true; shift ;;
            *)         die "Unknown option: $1" ;;
        esac
    done

    require_vm "$name"

    local state
    state=$(get_vm_state "$name")
    if [[ "$state" != "shut off" ]]; then
        die "VM '$name' must be shut off for hardening (current state: $state)"
    fi

    # Select hardware profile
    if [[ -z "$profile_idx" ]]; then
        profile_idx=$((RANDOM % ${#STEALTH_PROFILES[@]}))
    fi
    if [[ $profile_idx -ge ${#STEALTH_PROFILES[@]} ]]; then
        die "Invalid profile index: $profile_idx (available: 0-$((${#STEALTH_PROFILES[@]} - 1)))"
    fi

    local profile="${STEALTH_PROFILES[$profile_idx]}"
    local manufacturer product bios_vendor bios_version mac_oui board_manufacturer board_product chassis_manufacturer chassis_type nic_model
    IFS='|' read -r manufacturer product bios_vendor bios_version mac_oui board_manufacturer board_product chassis_manufacturer chassis_type nic_model <<< "$profile"

    local serial
    serial=$(generate_serial)

    log_msg PHASE "Hardening VM '$name' with $manufacturer $product profile"

    # 1. SMBIOS/DMI spoofing
    log_msg INFO "Setting SMBIOS: $manufacturer $product (serial: $serial)"
    local xml_file
    xml_file=$(mktemp)
    virsh dumpxml "$name" --inactive > "$xml_file"

    # Build sysinfo block (types 0-3: BIOS, System, Baseboard, Chassis)
    local sysinfo_block="  <sysinfo type=\"smbios\">
    <bios>
      <entry name=\"vendor\">${bios_vendor}</entry>
      <entry name=\"version\">${bios_version}</entry>
    </bios>
    <system>
      <entry name=\"manufacturer\">${manufacturer}</entry>
      <entry name=\"product\">${product}</entry>
      <entry name=\"serial\">${serial}</entry>
    </system>
    <baseBoard>
      <entry name=\"manufacturer\">${board_manufacturer}</entry>
      <entry name=\"product\">${board_product}</entry>
    </baseBoard>
    <chassis>
      <entry name=\"manufacturer\">${chassis_manufacturer}</entry>
      <entry name=\"type\">${chassis_type}</entry>
    </chassis>
  </sysinfo>"

    python3 -c "
import re, sys
xml = open(sys.argv[1]).read()
xml = re.sub(r'<sysinfo[\s>].*?</sysinfo>\s*', '', xml, flags=re.DOTALL)
xml = xml.replace('</domain>', sys.argv[2] + '\n</domain>')
open(sys.argv[1], 'w').write(xml)
" "$xml_file" "$sysinfo_block"

    # Ensure <smbios mode="sysinfo"/> is in <os> block
    if ! grep -q 'smbios mode' "$xml_file"; then
        sed -i 's|</os>|  <smbios mode="sysinfo"/>\n  </os>|' "$xml_file"
    fi

    virsh define "$xml_file" >/dev/null
    rm -f "$xml_file"

    # 2. Hide KVM hypervisor
    log_msg INFO "Hiding KVM hypervisor signature"
    virt-xml "$name" --edit --features kvm.hidden.state=on --define >/dev/null 2>&1 || {
        # Fallback: inject via XML if virt-xml fails
        xml_file=$(mktemp)
        virsh dumpxml "$name" --inactive > "$xml_file"
        if ! grep -q 'kvm' "$xml_file" || ! grep -q '<hidden' "$xml_file"; then
            if grep -q '<features>' "$xml_file"; then
                sed -i 's|</features>|  <kvm>\n      <hidden state="on"/>\n    </kvm>\n  </features>|' "$xml_file"
            fi
        fi
        virsh define "$xml_file" >/dev/null
        rm -f "$xml_file"
    }

    # 3. CPU: host-passthrough with hypervisor + vmx features disabled
    #    - hypervisor: hides CPUID bit 31 (the "I am a VM" flag in /proc/cpuinfo)
    #    - vmx: prevents guest from seeing VMX and auto-loading kvm_intel module
    log_msg INFO "Setting CPU mode to host-passthrough (hiding hypervisor+vmx)"
    xml_file=$(mktemp)
    virsh dumpxml "$name" --inactive > "$xml_file"
    # Remove any existing CPU definition (multi-line block or self-closing)
    # Use a python one-liner for reliable multi-line XML element removal
    python3 -c "
import re, sys
xml = open(sys.argv[1]).read()
xml = re.sub(r'<cpu[\s>].*?</cpu>\s*', '', xml, flags=re.DOTALL)
xml = re.sub(r'<cpu\s[^>]*/>\s*', '', xml)
open(sys.argv[1], 'w').write(xml)
" "$xml_file"
    # Insert our CPU block before </domain>
    sed -i 's|</domain>|  <cpu mode="host-passthrough" check="none">\n    <feature policy="disable" name="hypervisor"/>\n    <feature policy="disable" name="vmx"/>\n  </cpu>\n</domain>|' "$xml_file"
    virsh define "$xml_file" >/dev/null
    rm -f "$xml_file"

    # 4. MAC address randomization
    local new_mac
    new_mac=$(generate_mac "$mac_oui")
    log_msg INFO "Setting MAC address: $new_mac ($manufacturer OUI)"
    virt-xml "$name" --edit --network mac.address="$new_mac" --define >/dev/null 2>&1 || {
        log_msg WARN "Could not update MAC via virt-xml — update manually with 'virsh edit $name'"
    }

    # 5. NIC model (e1000e looks like real Intel hardware, not virtio)
    log_msg INFO "Setting NIC model to ${nic_model}"
    virt-xml "$name" --edit --network model="${nic_model}" --define >/dev/null 2>&1 || {
        xml_file=$(mktemp)
        virsh dumpxml "$name" --inactive > "$xml_file"
        sed -i "s|<model type='[^']*'/>|<model type='${nic_model}'/>|" "$xml_file"
        virsh define "$xml_file" >/dev/null
        rm -f "$xml_file"
    }

    # 6. Machine type: Q35 -> i440FX (eliminates all 0x1b36 Red Hat PCI vendor IDs)
    #    Q35 creates ~14 PCIe root ports with hardcoded vendor 0x1b36 — instant VM detection.
    #    i440FX uses flat PCI bus; all chipset devices have Intel vendor 0x8086.
    xml_file=$(mktemp)
    virsh dumpxml "$name" --inactive > "$xml_file"
    if grep -q "q35" "$xml_file"; then
        log_msg INFO "Converting machine type from Q35 to i440FX (eliminates Red Hat PCI 0x1b36)"
        python3 -c "
import re, sys
xml = open(sys.argv[1]).read()

# Change machine type to 'pc' (i440FX)
xml = re.sub(r\"machine='[^']*'\", \"machine='pc'\", xml)

# Remove all PCIe root port controllers (i440FX doesn't use PCIe)
xml = re.sub(r\"<controller type='pci'[^>]*model='pcie-root-port'.*?</controller>\s*\", '', xml, flags=re.DOTALL)
xml = re.sub(r\"<controller type='pci'[^>]*model='pcie-root-port'[^/]*/>\s*\", '', xml)

# Replace pcie-root with pci-root (i440FX topology)
xml = re.sub(r\"<controller type='pci'[^>]*model='pcie-root'.*?</controller>\s*\",
             \"<controller type='pci' index='0' model='pci-root'/>\n    \", xml, flags=re.DOTALL)
xml = re.sub(r\"<controller type='pci'[^>]*model='pcie-root'[^/]*/>\s*\",
             \"<controller type='pci' index='0' model='pci-root'/>\n    \", xml)

# Remove all PCI address assignments — libvirt will auto-assign for new topology
xml = re.sub(r\"<address type='pci'[^/]*/>\s*\", '', xml)

# Disable USB controller (qemu-xhci also uses vendor 0x1b36)
xml = re.sub(r\"<controller type='usb'[^>]*>.*?</controller>\s*\",
             \"<controller type='usb' model='none'/>\n    \", xml, flags=re.DOTALL)
xml = re.sub(r\"<controller type='usb'[^/]*/>\",
             \"<controller type='usb' model='none'/>\", xml)

open(sys.argv[1], 'w').write(xml)
" "$xml_file"
        virsh define "$xml_file" >/dev/null
    else
        log_msg INFO "Machine type already non-Q35, skipping conversion"
    fi
    rm -f "$xml_file"

    # 7. Disk bus: virtio -> sata
    log_msg INFO "Changing disk bus to SATA"
    xml_file=$(mktemp)
    virsh dumpxml "$name" --inactive > "$xml_file"
    if grep -q "bus='virtio'" "$xml_file" && grep -q "device='disk'" "$xml_file"; then
        # Change virtio disk bus to sata, update target dev from vd* to sd*
        sed -i "/<disk type=.*device='disk'/,/<\/disk>/ {
            s/bus='virtio'/bus='sata'/
            s/dev='vd/dev='sd/
        }" "$xml_file"
        # Add SATA controller if not present
        if ! grep -q "type='sata'" "$xml_file"; then
            sed -i "s|</devices>|  <controller type=\"sata\" index=\"0\"/>\n  </devices>|" "$xml_file"
        fi
        virsh define "$xml_file" >/dev/null
    else
        log_msg INFO "Disk bus already non-virtio, skipping"
    fi
    rm -f "$xml_file"

    # 8. Remove QEMU guest agent + ALL virtio devices that leak hypervisor
    log_msg INFO "Removing QEMU guest agent channel"
    virt-xml "$name" --remove-device --channel target.name=org.qemu.guest_agent.0 --define >/dev/null 2>&1 || true
    log_msg INFO "Removing all virtio devices (balloon, console, serial, RNG — PCI 0x1af4 leaks)"
    virt-xml "$name" --remove-device --channel target.type=virtio --define >/dev/null 2>&1 || true
    virt-xml "$name" --remove-device --rng all --define >/dev/null 2>&1 || true
    # Remove balloon + virtio-serial controllers via XML (virt-xml can't remove balloon reliably)
    xml_file=$(mktemp)
    virsh dumpxml "$name" --inactive > "$xml_file"
    python3 -c "
import re, sys
xml = open(sys.argv[1]).read()

# Replace memballoon with model='none' (libvirt requires the element, but 'none' disables the PCI device)
xml = re.sub(r'<memballoon[^>]*>.*?</memballoon>', '<memballoon model=\"none\"/>', xml, flags=re.DOTALL)
xml = re.sub(r'<memballoon[^/]*/>', '<memballoon model=\"none\"/>', xml)

# Remove virtio-serial controllers
xml = re.sub(r'<controller type=.virtio-serial.*?</controller>\s*', '', xml, flags=re.DOTALL)
xml = re.sub(r'<controller type=.virtio-serial[^/]*/>\s*', '', xml)

# Remove virtio-RNG devices
xml = re.sub(r'<rng\s+model=.virtio.*?</rng>\s*', '', xml, flags=re.DOTALL)

# Note: The i440FX machine type conversion (step 6) eliminates PCIe root ports (vendor 0x1b36).
# Any remaining virtio devices are caught here as cleanup.

open(sys.argv[1], 'w').write(xml)
" "$xml_file"
    virsh define "$xml_file" >/dev/null
    rm -f "$xml_file"

    # 9. Disk serial/model spoofing
    log_msg INFO "Spoofing disk serial and model strings"
    xml_file=$(mktemp)
    virsh dumpxml "$name" --inactive > "$xml_file"
    local disk_serial
    disk_serial="WD-WCC$(head -c 100 /dev/urandom | tr -dc 'A-Z0-9' | head -c 10)"
    # Add <serial> inside <disk> if not present
    if grep -q "device='disk'" "$xml_file" && ! grep -A15 "device='disk'" "$xml_file" | grep -q '<serial>'; then
        sed -i "/<disk type=.*device='disk'/,/<\/disk>/ {
            /<target /a\\      <serial>${disk_serial}</serial>
        }" "$xml_file"
    fi
    virsh define "$xml_file" >/dev/null
    rm -f "$xml_file"

    # 10. Timer/clock tuning (disable kvmclock and hypervclock)
    log_msg INFO "Configuring stealthy clock sources"
    xml_file=$(mktemp)
    virsh dumpxml "$name" --inactive > "$xml_file"
    local clock_block='  <clock offset="utc">
    <timer name="rtc" tickpolicy="catchup"/>
    <timer name="pit" tickpolicy="delay"/>
    <timer name="hpet" present="no"/>
    <timer name="hypervclock" present="no"/>
    <timer name="kvmclock" present="no"/>
  </clock>'
    python3 -c "
import re, sys
xml = open(sys.argv[1]).read()
replacement = sys.argv[2]
xml = re.sub(r'<clock[\s>].*?</clock>', replacement, xml, flags=re.DOTALL)
if '<clock' not in xml:
    xml = xml.replace('</domain>', replacement + '\n</domain>')
open(sys.argv[1], 'w').write(xml)
" "$xml_file" "$clock_block"
    virsh define "$xml_file" >/dev/null
    rm -f "$xml_file"

    # 11. Graphics/spice channel cleanup (remove hypervisor-specific devices)
    log_msg INFO "Removing spice/VNC channels and virtual display devices"
    virt-xml "$name" --remove-device --channel target.type=spicevmc --define >/dev/null 2>&1 || true
    virt-xml "$name" --remove-device --sound all --define >/dev/null 2>&1 || true
    virt-xml "$name" --remove-device --redirdev all --define >/dev/null 2>&1 || true
    # Replace QXL (leaks hypervisor) with basic VGA
    xml_file=$(mktemp)
    virsh dumpxml "$name" --inactive > "$xml_file"
    if grep -q "model type='qxl'" "$xml_file"; then
        sed -i "s|model type='qxl'|model type='vga'|g" "$xml_file"
        virsh define "$xml_file" >/dev/null
    fi
    rm -f "$xml_file"

    # 12. ACPI table OEM patching + disk model via QEMU namespace
    #     Note: The i440FX conversion (step 6) already eliminated PCIe root port 0x1b36 devices.
    #     This step patches ACPI OEM strings (removes BOCHS/BXPC) and disk model strings.
    log_msg INFO "Patching ACPI OEM strings and disk model via QEMU namespace"
    xml_file=$(mktemp)
    virsh dumpxml "$name" --inactive > "$xml_file"

    # Determine ACPI OEM strings based on manufacturer profile
    local acpi_oem_id acpi_table_id
    case "$manufacturer" in
        *Dell*)   acpi_oem_id="DELL  "; acpi_table_id="DELLBIOS" ;;
        *Lenovo*) acpi_oem_id="LENOVO"; acpi_table_id="TP-N2O  " ;;
        *HP*)     acpi_oem_id="HP    "; acpi_table_id="HPBIOS  " ;;
        *)        acpi_oem_id="DELL  "; acpi_table_id="DELLBIOS" ;;
    esac

    local qemu_block="  <qemu:commandline>
    <qemu:arg value=\"-global\"/>
    <qemu:arg value=\"ide-hd.model=WDC WD10EZEX-08WN4A0\"/>
    <qemu:arg value=\"-global\"/>
    <qemu:arg value=\"acpi-build.oem-id=${acpi_oem_id}\"/>
    <qemu:arg value=\"-global\"/>
    <qemu:arg value=\"acpi-build.oem-table-id=${acpi_table_id}\"/>
  </qemu:commandline>"

    python3 -c "
import re, sys
xml = open(sys.argv[1]).read()
ns = 'xmlns:qemu=\"http://libvirt.org/schemas/domain/qemu/1.0\"'
if 'xmlns:qemu' not in xml:
    xml = xml.replace('<domain type', '<domain ' + ns + ' type')
xml = re.sub(r'<qemu:commandline>.*?</qemu:commandline>\s*', '', xml, flags=re.DOTALL)
xml = xml.replace('</domain>', sys.argv[2] + '\n</domain>')
open(sys.argv[1], 'w').write(xml)
" "$xml_file" "$qemu_block"
    virsh define "$xml_file" >/dev/null
    rm -f "$xml_file"

    # 13. Randomize libvirt bridge MAC (default virbr0 uses QEMU OUI 52:54:00, an
    #     in-guest detection vector via the gateway's ARP entry). Rewriting the
    #     'default' network bounces it, so only do it when no OTHER VM is running on
    #     it — otherwise we would drop those VMs' connectivity.
    log_msg INFO "Checking default network bridge MAC"
    local other_on_default=false vm_iter
    while IFS= read -r vm_iter; do
        [[ -z "$vm_iter" || "$vm_iter" == "$name" ]] && continue
        if virsh domiflist "$vm_iter" 2>/dev/null | awk '{print $3}' | grep -qx default; then
            other_on_default=true; break
        fi
    done < <(virsh list --state-running --name 2>/dev/null | grep -v '^$')

    if [[ "$other_on_default" == true ]]; then
        log_msg WARN "Other VMs are running on the 'default' network — skipping bridge-MAC rewrite to avoid disrupting them"
    else
        local net_xml bridge_mac
        net_xml=$(virsh net-dumpxml default 2>/dev/null || true)
        bridge_mac=$(echo "$net_xml" | grep -oP "mac address='\K[^']+" || true)
        if [[ "$bridge_mac" == 52:54:00* ]]; then
            local new_bridge_mac
            new_bridge_mac=$(generate_mac "$mac_oui")
            log_msg INFO "Replacing default network bridge MAC ($bridge_mac -> $new_bridge_mac)"
            local net_file
            net_file=$(mktemp)
            echo "$net_xml" > "$net_file"
            sed -i "s|mac address='${bridge_mac}'|mac address='${new_bridge_mac}'|" "$net_file"
            virsh net-destroy default >/dev/null 2>&1 || true
            virsh net-define "$net_file" >/dev/null
            virsh net-start default >/dev/null 2>&1 || true
            rm -f "$net_file"
        else
            log_msg INFO "Bridge MAC already non-QEMU: ${bridge_mac:-none}"
        fi
    fi

    # 14. Note: open-vm-tools removal is handled via cloud-init runcmd during --stealth create
    #     For existing VMs being hardened, remove via SSH if possible
    local vm_ip
    vm_ip=$(get_vm_ip "$name" 2>/dev/null || true)
    if [[ -n "$vm_ip" ]]; then
        log_msg INFO "Removing open-vm-tools from guest via SSH"
        ssh -q -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KVM_SSH_KEY" \
            "ubuntu@${vm_ip}" \
            "sudo apt-get purge -y open-vm-tools open-vm-tools-desktop 2>/dev/null; sudo rm -rf /etc/vmware-tools 2>/dev/null" \
            >/dev/null 2>&1 || log_msg WARN "Could not SSH to guest to remove open-vm-tools (run manually)"
    fi

    # Verification
    if [[ "$verify" == true ]]; then
        log_msg PHASE "Verification:"
        local xml
        xml=$(virsh dumpxml "$name" --inactive)

        local checks=0 passed=0

        # Note: virsh dumpxml uses single quotes and lowercase MAC
        local new_mac_lower
        new_mac_lower=$(echo "$new_mac" | tr '[:upper:]' '[:lower:]')

        checks=$((checks + 1))
        if echo "$xml" | grep -qi "name=.manufacturer.>${manufacturer}<"; then
            log_msg INFO "  [PASS] SMBIOS manufacturer: $manufacturer"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] SMBIOS manufacturer not set"
        fi

        checks=$((checks + 1))
        if echo "$xml" | grep -qi "hidden state=.on."; then
            log_msg INFO "  [PASS] KVM hidden state: on"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] KVM hidden state not set"
        fi

        checks=$((checks + 1))
        if echo "$xml" | grep -qi "address=.${new_mac_lower}."; then
            log_msg INFO "  [PASS] MAC address: $new_mac_lower"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] MAC address not updated"
        fi

        checks=$((checks + 1))
        if ! echo "$xml" | grep -q "device='disk'" || ! echo "$xml" | grep -A5 "device='disk'" | grep -q "bus='virtio'"; then
            log_msg INFO "  [PASS] Disk bus: non-virtio"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] Disk still using virtio bus"
        fi

        checks=$((checks + 1))
        if ! echo "$xml" | grep -q 'org.qemu.guest_agent'; then
            log_msg INFO "  [PASS] Guest agent: removed"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] Guest agent channel still present"
        fi

        checks=$((checks + 1))
        if echo "$xml" | grep -qi "mode=.host-passthrough." && echo "$xml" | grep -qi "feature.*policy=.disable.*name=.hypervisor."; then
            log_msg INFO "  [PASS] CPU mode: host-passthrough (hypervisor+vmx hidden)"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] CPU mode not set or hypervisor feature not disabled"
        fi

        checks=$((checks + 1))
        if echo "$xml" | grep -q "memballoon model='none'"; then
            log_msg INFO "  [PASS] Virtio balloon: disabled"
            passed=$((passed + 1))
        elif ! echo "$xml" | grep -q "memballoon"; then
            log_msg INFO "  [PASS] Virtio balloon: removed"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] Virtio balloon still present"
        fi

        checks=$((checks + 1))
        if echo "$xml" | grep -qi "baseBoard"; then
            log_msg INFO "  [PASS] Baseboard SMBIOS: spoofed"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] Baseboard SMBIOS not set"
        fi

        checks=$((checks + 1))
        if echo "$xml" | grep -qi "model type=.${nic_model}."; then
            log_msg INFO "  [PASS] NIC model: ${nic_model}"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] NIC model not set to ${nic_model}"
        fi

        checks=$((checks + 1))
        if echo "$xml" | grep -qi "kvmclock.*present=.no."; then
            log_msg INFO "  [PASS] KVM clock: disabled"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] KVM clock not disabled"
        fi

        checks=$((checks + 1))
        if echo "$xml" | grep -qi '<serial>'; then
            log_msg INFO "  [PASS] Disk serial: spoofed"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] Disk serial not set"
        fi

        checks=$((checks + 1))
        if echo "$xml" | grep -qi "machine='pc'" || echo "$xml" | grep -qi "machine='pc-i440fx"; then
            log_msg INFO "  [PASS] Machine type: i440FX (no Red Hat PCI devices)"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] Machine type is not i440FX (Q35 exposes Red Hat PCI 0x1b36)"
        fi

        checks=$((checks + 1))
        if echo "$xml" | grep -q "controller type='usb' model='none'"; then
            log_msg INFO "  [PASS] USB controller: disabled"
            passed=$((passed + 1))
        elif ! echo "$xml" | grep -q "controller type='usb'"; then
            log_msg INFO "  [PASS] USB controller: removed"
            passed=$((passed + 1))
        else
            log_msg WARN "  [FAIL] USB controller still present (qemu-xhci uses vendor 0x1b36)"
        fi

        log_msg INFO "  Result: $passed/$checks checks passed"
    fi

    log_msg PHASE "VM '$name' hardened"
    log_msg INFO "  Profile:    $manufacturer $product"
    log_msg INFO "  Serial:     $serial"
    log_msg INFO "  MAC:        $new_mac"
    log_msg INFO "  NIC model:  ${nic_model}"
    log_msg INFO "  CPU mode:   host-passthrough (hypervisor+vmx hidden)"
    log_msg INFO "  Machine:    i440FX (all PCI devices Intel 0x8086)"
    log_msg INFO "  Disk bus:   SATA (serial spoofed)"
    log_msg INFO "  Clocks:     kvmclock+hypervclock disabled"
    log_msg INFO "  ACPI:       OEM strings patched"
    log_msg INFO "  Graphics:   spice removed, VGA only"
    log_msg INFO "  USB:        disabled (qemu-xhci uses vendor 0x1b36)"
    log_msg INFO "  Hypervisor: hidden"
    log_msg WARN "Note: IP detection may be slower without guest agent; NIC is ${nic_model} (slower than virtio)"
}

# --- Usage ---

function usage() {
    cat <<EOF
${BOLD}$SCRIPT_NAME $SCRIPT_VERSION${RESET} — KVM VM manager with fast snapshot rollback

${BOLD}USAGE${RESET}
    $SCRIPT_NAME <command> [options]

${BOLD}SETUP${RESET}
    setup                               Install KVM/libvirt packages and configure system

${BOLD}VM LIFECYCLE${RESET}
    create <name> [options]             Create a new VM
        --template <vm>                   Clone from existing VM/template
        --iso <path>                      Install from ISO (server ISO, serial console)
        --cloud-image                     Ubuntu cloud image (no installer, boots in seconds)
        --cpu <N>                         vCPU count (default: $DEFAULT_CPU)
        --ram <size>                      RAM size, e.g. 2G, 512M (default: ${DEFAULT_RAM_MIB}M)
        --disk <size>                     Disk size, e.g. 20G, 1T (default: ${DEFAULT_DISK_GB}G)
        --gpu [selector]                  Pass through a host GPU via VFIO (requires setup first).
                                          selector = GPU index, PCI addr, or comma-list (see gpu-list);
                                          omit to pick the first free GPU. Repeatable devices per VM.
        --post-setup [path]               Run post-setup script on first boot (cloud-image only)
    delete <name> [--force]             Delete VM and all its storage
    list                                List all VMs with status

${BOLD}TEMPLATES${RESET}
    template-create <vm>                Mark a VM as a reusable template
    template-list                       List available templates
    clone <source> <new-name>           Clone a VM

${BOLD}SNAPSHOTS${RESET} (fast rollback for testing)
    snap <vm> <snapshot-name>           Create a snapshot
    rollback <vm> <snapshot-name>       Revert to a snapshot (sub-second)
    snap-list <vm>                      List snapshots for a VM
    snap-delete <vm> <snapshot-name>    Delete a snapshot

${BOLD}ANTI-DETECTION${RESET} (malware analysis sandbox hardening)
    harden <vm> [options]               Apply anti-detection hardening to shut-off VM
        --profile <N>                     Hardware profile: 0=Dell, 1=Lenovo, 2=HP (default: random)
        --verify                          Verify all hardening changes were applied
    create <name> --cloud-image --stealth  Create a pre-hardened VM in one step

${BOLD}PROVISIONING${RESET}
    post-setup <vm> [script-path]       Run post-setup script on existing VM via SSH
                                        Default: vm-post-setup.sh (same directory as kvm-manager)
    analyze <vm> [forensics-args...]    Run vm-forensics analysis on a VM

${BOLD}GPU PASSTHROUGH${RESET} (dedicate host GPUs to VMs — NVIDIA / AMD / Intel)
    gpu-status                          Check GPU passthrough readiness (IOMMU, VFIO, driver)
    gpu-list                            List all GPUs with index, driver, and free/assigned state
    gpu-attach <vm> <selector>          Dedicate GPU(s) to a shut-off VM (index / PCI / comma-list)
    gpu-detach <vm> <selector>          Remove GPU(s) from a shut-off VM

${BOLD}MONITORING & ACCESS${RESET}
    status <vm>                         Detailed VM information
    monitor                             Live overview of all VMs (watch mode)
    console <vm>                        Attach to VM serial console
    ssh <vm> [ssh-args...]              SSH into VM (auto-detects IP)

${BOLD}POWER${RESET}
    start <vm>                          Start a VM
    stop <vm> [--force]                 Graceful shutdown (--force to kill)
    restart <vm>                        Reboot a VM
    autostart <vm> [on|off]             Toggle VM autostart on host boot (default: on)

${BOLD}WORKFLOW EXAMPLES${RESET}
    # Create a fully provisioned stealth VM
    $SCRIPT_NAME create test-vm --cloud-image --cpu 4 --ram 8G --stealth --post-setup
    $SCRIPT_NAME snap test-vm clean

    # Run malware, analyze, then roll back
    $SCRIPT_NAME analyze test-vm
    $SCRIPT_NAME rollback test-vm clean    # sub-second revert!

    # GPU passthrough for LLM workloads (first-time: setup + reboot)
    $SCRIPT_NAME setup                     # binds non-primary GPUs to VFIO
    $SCRIPT_NAME gpu-list                  # after reboot: see which GPUs are free
    $SCRIPT_NAME create llm-vm --cloud-image --cpu 8 --ram 32G --disk 100G --gpu 0 --post-setup

    # Multi-GPU host: give GPU 1 to one VM, and GPUs 2+3 to another
    $SCRIPT_NAME create vm-a --cloud-image --ram 16G --gpu 1
    $SCRIPT_NAME create vm-b --cloud-image --ram 32G --gpu 2,3
    $SCRIPT_NAME gpu-attach vm-a 1         # or attach/detach on an existing shut-off VM
EOF
}

# --- Main ---

function main() {
    color_init
    KVM_SSH_KEY="$(get_kvm_ssh_key_path)"

    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local cmd="$1"; shift

    # Dependency pre-check (skip for setup/help)
    case "$cmd" in
        setup|help|--help|-h|gpu-status|gpu-list) ;;
        create)          require_deps virsh virt-install virt-clone qemu-img wget cloud-localds base64 ;;
        clone)           require_deps virsh virt-clone ;;
        harden)          require_deps virsh virt-xml sed python3 ;;
        gpu-attach|gpu-detach) require_deps virsh virt-xml ;;
        status)          require_deps virsh qemu-img ;;
        ssh)             require_deps virsh ssh ;;
        post-setup)      require_deps virsh ssh scp ;;
        analyze)         ;; # forensics script handles its own deps
        list|delete|template-create|template-list|\
        snap|rollback|snap-list|snap-delete|\
        start|stop|restart|monitor|console|autostart)
                         require_deps virsh ;;
    esac

    case "$cmd" in
        setup)           cmd_setup "$@" ;;
        create)          cmd_create "$@" ;;
        delete)          cmd_delete "$@" ;;
        list)            cmd_list "$@" ;;
        clone)           cmd_clone "$@" ;;
        template-create) cmd_template_create "$@" ;;
        template-list)   cmd_template_list "$@" ;;
        snap)            cmd_snap "$@" ;;
        rollback)        cmd_rollback "$@" ;;
        snap-list)       cmd_snap_list "$@" ;;
        snap-delete)     cmd_snap_delete "$@" ;;
        status)          cmd_status "$@" ;;
        monitor)         cmd_monitor "$@" ;;
        console)         cmd_console "$@" ;;
        ssh)             cmd_ssh "$@" ;;
        post-setup)      cmd_post_setup "$@" ;;
        analyze)         cmd_analyze "$@" ;;
        harden)          cmd_harden "$@" ;;
        gpu-status)      cmd_gpu_status "$@" ;;
        gpu-list)        cmd_gpu_list "$@" ;;
        gpu-attach)      cmd_gpu_attach "$@" ;;
        gpu-detach)      cmd_gpu_detach "$@" ;;
        start)           cmd_power start "$@" ;;
        stop)            cmd_power stop "$@" ;;
        restart)         cmd_power restart "$@" ;;
        autostart)       cmd_autostart "$@" ;;
        help|--help|-h)  usage ;;
        *)               die "Unknown command: $cmd — run '$SCRIPT_NAME help' for usage" ;;
    esac
}

# Only run main when executed directly, not when sourced (e.g. by test_kvm_manager.sh)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
