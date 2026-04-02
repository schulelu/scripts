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

# --- Anti-Detection Hardware Profiles ---
# Format: manufacturer|product|bios_vendor|bios_version|mac_oui
STEALTH_PROFILES=(
    "Dell Inc.|OptiPlex 7090|Dell Inc.|2.20.0|D0:94:66"
    "Lenovo|ThinkCentre M920q|Lenovo|M22KT55A|70:5A:0F"
    "HP|ProDesk 400 G7|HP|S17 Ver. 02.05.00|3C:52:82"
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

    local template="" iso="" cloud_image=false stealth=false cpu=$DEFAULT_CPU ram_mib=$DEFAULT_RAM_MIB disk_gb=$DEFAULT_DISK_GB
    local post_setup="" post_setup_script=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --template)    template="$2"; shift 2 ;;
            --iso)         iso="$2"; shift 2 ;;
            --cloud-image) cloud_image=true; shift ;;
            --stealth)     stealth=true; shift ;;
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

        virt-install \
            --name "$name" \
            --vcpus "$cpu" \
            --memory "$ram_mib" \
            --disk "path=${LIBVIRT_IMAGES}/${name}.qcow2,size=${disk_gb},format=qcow2,bus=virtio" \
            --location "$iso_path,kernel=casper/vmlinuz,initrd=casper/initrd" \
            --extra-args "console=ttyS0" \
            --os-variant detect=on \
            --network network=default,model=virtio \
            --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
            --graphics none \
            --noautoconsole

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
            virt-install \
                --name "$name" \
                --vcpus "$cpu" \
                --memory "$ram_mib" \
                --disk "path=${disk_path},format=qcow2,bus=sata" \
                --disk "path=${seed_path},device=cdrom" \
                --os-variant ubuntu24.04 \
                --network network=default \
                --graphics none \
                --import \
                --noreboot \
                --noautoconsole
        else
            virt-install \
                --name "$name" \
                --vcpus "$cpu" \
                --memory "$ram_mib" \
                --disk "path=${disk_path},format=qcow2,bus=virtio" \
                --disk "path=${seed_path},device=cdrom" \
                --os-variant ubuntu24.04 \
                --network network=default,model=virtio \
                --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
                --graphics none \
                --import \
                --noautoconsole
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
    local manufacturer product bios_vendor bios_version mac_oui
    IFS='|' read -r manufacturer product bios_vendor bios_version mac_oui <<< "$profile"

    local serial
    serial=$(generate_serial)

    log_msg PHASE "Hardening VM '$name' with $manufacturer $product profile"

    # 1. SMBIOS/DMI spoofing
    log_msg INFO "Setting SMBIOS: $manufacturer $product (serial: $serial)"
    local xml_file
    xml_file=$(mktemp)
    virsh dumpxml "$name" --inactive > "$xml_file"

    # Add or update sysinfo block
    if grep -q '<sysinfo' "$xml_file"; then
        # Remove existing sysinfo block, we'll add a fresh one
        sed -i '/<sysinfo/,/<\/sysinfo>/d' "$xml_file"
    fi

    # Insert sysinfo before </domain>
    sed -i "s|</domain>|  <sysinfo type=\"smbios\">\n    <bios>\n      <entry name=\"vendor\">${bios_vendor}</entry>\n      <entry name=\"version\">${bios_version}</entry>\n    </bios>\n    <system>\n      <entry name=\"manufacturer\">${manufacturer}</entry>\n      <entry name=\"product\">${product}</entry>\n      <entry name=\"serial\">${serial}</entry>\n    </system>\n  </sysinfo>\n</domain>|" "$xml_file"

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

    # 3. MAC address randomization
    local new_mac
    new_mac=$(generate_mac "$mac_oui")
    log_msg INFO "Setting MAC address: $new_mac ($manufacturer OUI)"
    virt-xml "$name" --edit --network mac.address="$new_mac" --define >/dev/null 2>&1 || {
        log_msg WARN "Could not update MAC via virt-xml — update manually with 'virsh edit $name'"
    }

    # 4. Disk bus: virtio -> sata
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

    # 5. Remove QEMU guest agent channel
    log_msg INFO "Removing QEMU guest agent channel"
    virt-xml "$name" --remove-device --channel target.name=org.qemu.guest_agent.0 --define >/dev/null 2>&1 || {
        log_msg INFO "No guest agent channel found (already removed or never added)"
    }

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

        log_msg INFO "  Result: $passed/$checks checks passed"
    fi

    log_msg PHASE "VM '$name' hardened"
    log_msg INFO "  Profile:    $manufacturer $product"
    log_msg INFO "  Serial:     $serial"
    log_msg INFO "  MAC:        $new_mac"
    log_msg INFO "  Disk bus:   SATA"
    log_msg INFO "  Hypervisor: hidden"
    log_msg WARN "Note: IP detection may be slower without guest agent"
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
        setup|help|--help|-h) ;;
        create)          require_deps virsh virt-install virt-clone qemu-img wget cloud-localds ;;
        clone)           require_deps virsh virt-clone ;;
        harden)          require_deps virsh virt-xml sed ;;
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
        start)           cmd_power start "$@" ;;
        stop)            cmd_power stop "$@" ;;
        restart)         cmd_power restart "$@" ;;
        autostart)       cmd_autostart "$@" ;;
        help|--help|-h)  usage ;;
        *)               die "Unknown command: $cmd — run '$SCRIPT_NAME help' for usage" ;;
    esac
}

main "$@"
