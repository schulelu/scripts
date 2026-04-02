#!/usr/bin/env bash

# VM Post-Setup — First-boot provisioning for Ubuntu cloud-image VMs
# Installs modern CLI tools, dev environments, nginx+SSL, firewall, and shell config
# Usage: sudo bash vm-post-setup.sh [--user USERNAME]
#
# Can be run standalone or via kvm-manager.sh --post-setup

set -euo pipefail

# --- Configuration ---
TARGET_USER="ubuntu"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) TARGET_USER="${2:-ubuntu}"; shift 2 ;;
        *)      shift ;;
    esac
done
TARGET_HOME=$(eval echo "~${TARGET_USER}")

DONE_MARKER="/opt/.post-setup-done"

# --- Color Output ---
RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; RESET=""
if [ -t 1 ]; then
    RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
    CYAN=$(tput setaf 6); BOLD=$(tput bold); RESET=$(tput sgr0)
fi

log() { echo "${GREEN}[POST-SETUP]${RESET} $*"; }
warn() { echo "${YELLOW}[POST-SETUP]${RESET} $*"; }
err() { echo "${RED}[POST-SETUP]${RESET} $*"; }
phase() { echo "${BOLD}${CYAN}[POST-SETUP]${RESET} ${BOLD}$*${RESET}"; }

# --- Pre-flight ---
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)"
    exit 1
fi

if [[ -f "$DONE_MARKER" ]]; then
    warn "Post-setup already ran on $(cat "$DONE_MARKER")"
    warn "Re-running will overwrite existing configuration"
    echo -n "${YELLOW}Continue? [y/N]${RESET} "
    # In non-interactive mode (cloud-init), skip the prompt
    if [ -t 0 ]; then
        read -r answer
        [[ "$answer" =~ ^[Yy]$ ]] || exit 0
    fi
fi

if ! id "$TARGET_USER" &>/dev/null; then
    err "User '$TARGET_USER' does not exist"
    exit 1
fi

# Helper to run commands as the target user
run_as_user() {
    sudo -H -u "$TARGET_USER" bash -c "$*"
}

# Phase timer
PHASE_START=$SECONDS
phase_done() {
    local elapsed=$(( SECONDS - PHASE_START ))
    log "Done (${elapsed}s)"
    PHASE_START=$SECONDS
}

# ============================================================================
# Phase 1: System packages
# ============================================================================
phase "Phase 1/11: Installing system packages..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get full-upgrade -y -qq

# Core tools + modern CLI replacements + web stack
apt-get install -y -qq \
    screen curl wget gcc git build-essential cmake pkg-config meson ninja-build \
    redis-server poppler-utils \
    bat ripgrep fd-find fzf zoxide btop duf git-delta httpie \
    nginx-full apache2-utils \
    ufw \
    jq unzip tar gzip

apt-get autoremove -y -qq

log "System packages installed"
phase_done

# ============================================================================
# Phase 2: Binary installs (tools not in apt)
# ============================================================================
phase "Phase 2/11: Installing binary tools (eza, dust, sd, procs, starship)..."

ARCH=$(dpkg --print-architecture)

# eza — modern ls replacement (not in Ubuntu 24.04 apt)
EZA_VERSION="0.23.4"
if ! command -v eza &>/dev/null; then
    if [[ "$ARCH" == "amd64" ]]; then
        EZA_URL="https://github.com/eza-community/eza/releases/download/v${EZA_VERSION}/eza_x86_64-unknown-linux-gnu.tar.gz"
    else
        EZA_URL="https://github.com/eza-community/eza/releases/download/v${EZA_VERSION}/eza_aarch64-unknown-linux-gnu.tar.gz"
    fi
    log "Installing eza v${EZA_VERSION}..."
    TMP_EZA=$(mktemp -d)
    wget --timeout=30 --tries=3 -qO "${TMP_EZA}/eza.tar.gz" "$EZA_URL"
    tar -xzf "${TMP_EZA}/eza.tar.gz" -C "${TMP_EZA}"
    install -m 755 "${TMP_EZA}/eza" /usr/local/bin/eza
    rm -rf "$TMP_EZA"
    log "eza installed"
else
    log "eza already installed, skipping"
fi

# dust — modern du replacement (not in Ubuntu 24.04 apt)
DUST_VERSION="1.1.2"
if ! command -v dust &>/dev/null; then
    if [[ "$ARCH" == "amd64" ]]; then
        DUST_URL="https://github.com/bootandy/dust/releases/download/v${DUST_VERSION}/dust-v${DUST_VERSION}-x86_64-unknown-linux-musl.tar.gz"
    else
        DUST_URL="https://github.com/bootandy/dust/releases/download/v${DUST_VERSION}/dust-v${DUST_VERSION}-aarch64-unknown-linux-musl.tar.gz"
    fi
    log "Installing dust v${DUST_VERSION}..."
    TMP_DUST=$(mktemp -d)
    wget --timeout=30 --tries=3 -qO "${TMP_DUST}/dust.tar.gz" "$DUST_URL"
    tar -xzf "${TMP_DUST}/dust.tar.gz" -C "${TMP_DUST}" --strip-components=1
    install -m 755 "${TMP_DUST}/dust" /usr/local/bin/dust
    rm -rf "$TMP_DUST"
    log "dust installed"
else
    log "dust already installed, skipping"
fi

# sd — modern sed replacement
SD_VERSION="1.0.0"
if ! command -v sd &>/dev/null; then
    if [[ "$ARCH" == "amd64" ]]; then
        SD_URL="https://github.com/chmln/sd/releases/download/v${SD_VERSION}/sd-v${SD_VERSION}-x86_64-unknown-linux-musl.tar.gz"
    else
        SD_URL="https://github.com/chmln/sd/releases/download/v${SD_VERSION}/sd-v${SD_VERSION}-aarch64-unknown-linux-musl.tar.gz"
    fi
    log "Installing sd v${SD_VERSION}..."
    TMP_SD=$(mktemp -d)
    wget --timeout=30 --tries=3 -qO "${TMP_SD}/sd.tar.gz" "$SD_URL"
    tar -xzf "${TMP_SD}/sd.tar.gz" -C "${TMP_SD}" --strip-components=1
    install -m 755 "${TMP_SD}/sd" /usr/local/bin/sd
    rm -rf "$TMP_SD"
    log "sd installed"
else
    log "sd already installed, skipping"
fi

# procs — modern ps replacement
PROCS_VERSION="0.14.11"
if ! command -v procs &>/dev/null; then
    if [[ "$ARCH" == "amd64" ]]; then
        PROCS_URL="https://github.com/dalance/procs/releases/download/v${PROCS_VERSION}/procs-v${PROCS_VERSION}-x86_64-linux.zip"
    else
        PROCS_URL="https://github.com/dalance/procs/releases/download/v${PROCS_VERSION}/procs-v${PROCS_VERSION}-aarch64-linux.zip"
    fi
    log "Installing procs v${PROCS_VERSION}..."
    TMP_PROCS=$(mktemp -d)
    wget --timeout=30 --tries=3 -qO "${TMP_PROCS}/procs.zip" "$PROCS_URL"
    unzip -q "${TMP_PROCS}/procs.zip" -d "${TMP_PROCS}"
    install -m 755 "${TMP_PROCS}/procs" /usr/local/bin/procs
    rm -rf "$TMP_PROCS"
    log "procs installed"
else
    log "procs already installed, skipping"
fi

# starship — cross-shell prompt
if ! command -v starship &>/dev/null; then
    log "Installing starship..."
    curl -sS --connect-timeout 30 --retry 3 https://starship.rs/install.sh | sh -s -- -y >/dev/null
    log "starship installed"
else
    log "starship already installed, skipping"
fi
phase_done

# ============================================================================
# Phase 3: Shell configuration
# ============================================================================
phase "Phase 3/11: Configuring shell (aliases, zoxide, fzf, starship)..."

# Create ~/.local/bin and symlink batcat → bat
run_as_user "mkdir -p ${TARGET_HOME}/.local/bin"
if [[ ! -L "${TARGET_HOME}/.local/bin/bat" ]]; then
    ln -sf /usr/bin/batcat "${TARGET_HOME}/.local/bin/bat"
    chown -h "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.local/bin/bat"
fi

# Bash aliases — modern tool replacements
cat > "${TARGET_HOME}/.bash_aliases" <<'ALIASES'
# Modern CLI tool aliases (Rust-based replacements)
alias cat='batcat --paging=never'
alias ls='eza'
alias ll='eza -alh --git'
alias la='eza -a'
alias lt='eza --tree --level=2'
alias grep='rg'
alias find='fd'
alias top='btop'
alias du='dust'
alias df='duf'
alias diff='delta'
alias ps='procs'
ALIASES
chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.bash_aliases"

# Bashrc additions — zoxide, fzf, starship, PATH
# Remove old block if present, then re-add (allows updates on re-run)
BASHRC_START="# --- vm-post-setup ---"
BASHRC_END="# --- end vm-post-setup ---"
if grep -qF "$BASHRC_START" "${TARGET_HOME}/.bashrc" 2>/dev/null; then
    sed -i "/${BASHRC_START}/,/${BASHRC_END}/d" "${TARGET_HOME}/.bashrc"
fi
cat >> "${TARGET_HOME}/.bashrc" <<'BASHRC'

# --- vm-post-setup ---
# Modern shell integrations
export PATH="${HOME}/.local/bin:${PATH}"
eval "$(zoxide init bash)"
source /usr/share/doc/fzf/examples/key-bindings.bash 2>/dev/null
source /usr/share/bash-completion/completions/fzf 2>/dev/null
eval "$(starship init bash)"
# --- end vm-post-setup ---
BASHRC
chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.bashrc"

log "Shell configured"
phase_done

# ============================================================================
# Phase 4: Miniconda
# ============================================================================
phase "Phase 4/11: Installing Miniconda..."

if [[ ! -d "${TARGET_HOME}/miniconda3/bin" ]]; then
    run_as_user "mkdir -p ${TARGET_HOME}/miniconda3"
    if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
        MINICONDA_ARCH="aarch64"
    else
        MINICONDA_ARCH="x86_64"
    fi
    run_as_user "wget --timeout=30 --tries=3 -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${MINICONDA_ARCH}.sh -O ${TARGET_HOME}/miniconda3/miniconda.sh"
    run_as_user "bash ${TARGET_HOME}/miniconda3/miniconda.sh -b -u -p ${TARGET_HOME}/miniconda3"
    rm -f "${TARGET_HOME}/miniconda3/miniconda.sh"

    # Init conda for bash
    run_as_user "${TARGET_HOME}/miniconda3/bin/conda init bash"
    # Don't auto-activate base environment
    run_as_user "${TARGET_HOME}/miniconda3/bin/conda config --set auto_activate_base false"

    log "Miniconda installed (auto_activate_base disabled)"
else
    log "Miniconda already installed, skipping"
fi
phase_done

# ============================================================================
# Phase 5: NVM + Node
# ============================================================================
phase "Phase 5/11: Installing NVM + Node..."

NVM_VERSION="0.40.4"
NODE_VERSION="22"

if [[ ! -d "${TARGET_HOME}/.nvm" ]]; then
    run_as_user "wget --timeout=30 --tries=3 -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh | bash"
    log "NVM v${NVM_VERSION} installed"
else
    log "NVM already installed, skipping"
fi

# Install Node (needs nvm sourced)
if ! run_as_user "source ${TARGET_HOME}/.nvm/nvm.sh && command -v node" &>/dev/null; then
    run_as_user "source ${TARGET_HOME}/.nvm/nvm.sh && nvm install ${NODE_VERSION}"
    log "Node ${NODE_VERSION} installed"
else
    log "Node already installed, skipping"
fi

# Install global npm packages
run_as_user "source ${TARGET_HOME}/.nvm/nvm.sh && npm install -g pm2@latest tldr 2>/dev/null" || true
log "PM2 + tldr installed globally"
phase_done

# ============================================================================
# Phase 6: Nginx + self-signed SSL
# ============================================================================
phase "Phase 6/11: Configuring Nginx with self-signed SSL..."

# Create SSL directories
mkdir -p /etc/nginx/snippets/ssl
mkdir -p /etc/nginx/snippets/htpasswd

# Generate self-signed certificate with SAN
SSL_DIR=$(mktemp -d)
cat > "${SSL_DIR}/san.conf" <<'SSLCONF'
[req]
default_bits  = 4096
distinguished_name = req_distinguished_name
req_extensions = req_ext
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
countryName = DE
stateOrProvinceName = N/A
localityName = PRIVATE
organizationName = Self-signed certificate
commonName = 127.0.0.1: Self-signed certificate

[req_ext]
subjectAltName = @alt_names

[v3_req]
subjectAltName = @alt_names

[alt_names]
IP.1 = 127.0.0.1
SSLCONF

# Add VM's own IP to SAN if detectable
VM_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
if [[ -n "$VM_IP" && "$VM_IP" != "127.0.0.1" ]]; then
    echo "IP.2 = ${VM_IP}" >> "${SSL_DIR}/san.conf"
    log "Added VM IP ${VM_IP} to certificate SAN"
fi

openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
    -keyout /etc/nginx/snippets/ssl/_server1.key \
    -out /etc/nginx/snippets/ssl/_server1.crt \
    -config "${SSL_DIR}/san.conf" 2>/dev/null
rm -rf "$SSL_DIR"

log "Self-signed SSL certificate generated (10 year validity)"

# ssl-selfsigned.conf
cat > /etc/nginx/snippets/ssl-selfsigned.conf <<'SSLSELF'
ssl_certificate /etc/nginx/snippets/ssl/_server1.crt;
ssl_certificate_key /etc/nginx/snippets/ssl/_server1.key;
SSLSELF

# ssl-params.conf
cat > /etc/nginx/snippets/ssl-params.conf <<'SSLPARAMS'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305";
ssl_ecdh_curve secp384r1;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
SSLPARAMS

# nginx.conf
cat > /etc/nginx/nginx.conf <<'NGINXCONF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 2048;
    multi_accept on;
}

http {
    open_file_cache max=1000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    sendfile on;
    client_max_body_size 4096m;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    keepalive_requests 100000;
    client_body_buffer_size 512k;
    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr "$host" - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" "$http_user_agent" '
                    '$request_time $upstream_response_time $upstream_response_length';

    access_log /dev/null main;
    error_log /dev/null crit;

    gzip on;
    gzip_disable "msie6";
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types text/plain text/css application/json application/javascript
               text/xml application/xml application/xml+rss text/javascript;

    proxy_connect_timeout 600;
    proxy_send_timeout 600;
    proxy_read_timeout 600;
    send_timeout 600;
    fastcgi_send_timeout 300s;
    fastcgi_read_timeout 300s;
    uwsgi_connect_timeout 75s;
    uwsgi_read_timeout 600s;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXCONF

# Remove default site, create reverse-proxy template
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-enabled/default <<'SITE'
server {
    listen 80;
    listen [::]:80;
    server_name _;
    return 302 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name _;
    root /var/www/;

    include snippets/ssl-selfsigned.conf;
    include snippets/ssl-params.conf;

    client_max_body_size 512m;

    try_files $uri $uri/ =404;
}
SITE

nginx -t 2>/dev/null && systemctl reload nginx
log "Nginx configured with self-signed SSL"
phase_done

# ============================================================================
# Phase 7: System Dashboard
# ============================================================================
phase "Phase 7/11: Installing system dashboard..."

mkdir -p /var/www

# Dashboard generator — collects live system stats, renders cybersecurity-themed HTML
cat > /usr/local/bin/vm-dashboard-gen << 'DASHGEN'
#!/usr/bin/env bash
# VM Dashboard Generator — regenerates /var/www/index.html with live system stats
umask 022

HOST=$(hostname)
OS_INFO=$(lsb_release -d -s 2>/dev/null || grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release 2>/dev/null || echo "Linux")
KERN=$(uname -r | cut -d- -f1-2)
ARCH=$(uname -m)
UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || echo "?")
LOAD_1=$(awk '{print $1}' /proc/loadavg)
LOAD_5=$(awk '{print $2}' /proc/loadavg)
LOAD_15=$(awk '{print $3}' /proc/loadavg)
PROCS=$(ps -e --no-headers 2>/dev/null | wc -l)
CPU_CORES=$(nproc)
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
MEM_H_USED=$(free -h | awk '/Mem:/ {print $3}')
MEM_H_TOTAL=$(free -h | awk '/Mem:/ {print $2}')
SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
if [[ $SWAP_TOTAL -gt 0 ]]; then SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL)); else SWAP_PCT=0; fi
SWAP_H_USED=$(free -h | awk '/Swap:/ {print $3}')
SWAP_H_TOTAL=$(free -h | awk '/Swap:/ {print $2}')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
IP_ADDR=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
IP_ADDR=${IP_ADDR:-"offline"}
IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
IFACE=${IFACE:-"?"}
MAC=$(ip link show "$IFACE" 2>/dev/null | awk '/ether/ {print $2}' || echo "?")
USERS_ON=$(who 2>/dev/null | wc -l)
SSH_CNT=$(ss -tnp 2>/dev/null | grep -c ':22 ') || SSH_CNT=0
OPEN_PORTS=$(ss -tlnp 2>/dev/null | tail -n +2 | wc -l)
if [[ -r /etc/ufw/ufw.conf ]]; then
    UFW_ENABLED=$(grep -oP '(?<=^ENABLED=).*' /etc/ufw/ufw.conf 2>/dev/null)
    [[ "$UFW_ENABLED" == "yes" ]] && UFW_ST="ACTIVE" || UFW_ST="INACTIVE"
else
    UFW_ST="N/A"
fi
FAIL_24H=$(journalctl -u ssh --since "24 hours ago" --no-pager 2>/dev/null | grep -ci "failed\|invalid") || FAIL_24H=0
PKGS=$(dpkg -l 2>/dev/null | grep -c '^ii') || PKGS=0
NOW=$(date '+%Y-%m-%d %H:%M:%S %Z')

mem_color="#00ff41"; [[ $MEM_PCT -ge 70 ]] && mem_color="#ffaa00"; [[ $MEM_PCT -ge 90 ]] && mem_color="#ff0040"
disk_color="#00ff41"; [[ $DISK_PCT -ge 70 ]] && disk_color="#ffaa00"; [[ $DISK_PCT -ge 90 ]] && disk_color="#ff0040"
swap_color="#00ff41"; [[ $SWAP_PCT -ge 70 ]] && swap_color="#ffaa00"; [[ $SWAP_PCT -ge 90 ]] && swap_color="#ff0040"
threat_level="NOMINAL"; threat_color="#00ff41"
[[ $FAIL_24H -ge 10 ]] && threat_level="ELEVATED" && threat_color="#ffaa00"
[[ $FAIL_24H -ge 50 ]] && threat_level="CRITICAL" && threat_color="#ff0040"
ufw_color="#00ff41"; [[ "$UFW_ST" != "ACTIVE" ]] && ufw_color="#ff0040"

SERVICES_ROWS=""
while IFS='|' read -r port pname laddr; do
    SERVICES_ROWS="${SERVICES_ROWS}<tr><td class=\"val\">${port}</td><td>${pname}</td><td class=\"dim\">${laddr}</td></tr>"
done < <(ss -tlnp 2>/dev/null | tail -n +2 | awk '{
    n=split($4, a, ":")
    port=a[n]
    pname=$6
    sub(/.*"/, "", pname)
    sub(/".*/, "", pname)
    if(pname == "") pname = "?"
    printf "%s|%s|%s\n", port, pname, $4
}' | sort -t'|' -k1 -n | head -12)

TMP=$(mktemp /var/www/.dashboard.XXXXXX)
cat > "$TMP" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="refresh" content="60">
<title>${HOST} // FAULT Dashboard</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{background:#0a0a0a;color:#c0c0c0;font-family:'Courier New','Lucida Console',monospace;min-height:100vh;overflow-x:hidden}
#matrix{position:fixed;top:0;left:0;width:100%;height:100%;z-index:0;opacity:0.35}
.scan{position:fixed;top:0;left:0;width:100%;height:100%;z-index:1000;pointer-events:none;
  background:repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(0,0,0,0.03) 2px,rgba(0,0,0,0.03) 4px)}
.wrap{position:relative;z-index:1;max-width:1100px;margin:0 auto;padding:2rem 1.5rem}
.banner{text-align:center;margin-bottom:0.5rem}
.banner pre{display:inline-block;color:#00ff41;font-size:clamp(0.32rem,1.4vw,0.85rem);line-height:1.2;
  text-shadow:0 0 20px rgba(0,255,65,0.6),0 0 40px rgba(0,255,65,0.3);
  animation:glow 3s ease-in-out infinite alternate,glitch 12s linear infinite}
@keyframes glow{
  from{text-shadow:0 0 10px rgba(0,255,65,0.4),0 0 20px rgba(0,255,65,0.2);filter:brightness(0.95)}
  to{text-shadow:0 0 20px rgba(0,255,65,0.8),0 0 40px rgba(0,255,65,0.4),0 0 80px rgba(0,255,65,0.15);filter:brightness(1.05)}}
@keyframes glitch{
  0%,96%,100%{transform:translate(0);opacity:1}
  96.5%{transform:translate(-2px,1px);opacity:0.85}
  97%{transform:translate(3px,-1px);opacity:0.9}
  97.5%{transform:translate(-1px,0);opacity:1}}
.sub{color:#3a5a3a;font-size:0.8rem;margin-top:0.4rem;letter-spacing:0.3em}
.sub .cur{animation:blink 1s step-end infinite;color:#00ff41}
@keyframes blink{50%{opacity:0}}
.host-badge{display:inline-block;margin-top:0.8rem;padding:0.3rem 1rem;border:1px solid #1a3a1a;border-radius:3px;
  color:#00d4ff;font-size:0.75rem;letter-spacing:0.15em;background:rgba(0,212,255,0.05)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:1.2rem;margin-top:1.5rem}
.card{background:rgba(13,17,23,0.85);border:1px solid #1a3a1a;border-radius:6px;overflow:hidden;
  backdrop-filter:blur(8px);animation:fadeIn 0.6s ease-out both}
.card:nth-child(1){animation-delay:0.1s}.card:nth-child(2){animation-delay:0.2s}
.card:nth-child(3){animation-delay:0.3s}.card:nth-child(4){animation-delay:0.4s}
.card:nth-child(5){animation-delay:0.5s}
@keyframes fadeIn{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
.ch{display:flex;align-items:center;gap:0.5rem;padding:0.7rem 1rem;border-bottom:1px solid #1a3a1a;background:rgba(0,255,65,0.03)}
.ch .dot{width:8px;height:8px;border-radius:50%;background:#00ff41;box-shadow:0 0 6px #00ff41;animation:pulse 2s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:0.4}}
.ch h2{font-size:0.8rem;font-weight:bold;color:#e0e0e0;letter-spacing:0.15em;text-transform:uppercase}
.cb{padding:1rem}
.row{display:flex;justify-content:space-between;align-items:center;padding:0.35rem 0;border-bottom:1px solid rgba(26,58,26,0.3)}
.row:last-child{border-bottom:none}
.lbl{color:#4a6a4a;font-size:0.75rem;text-transform:uppercase;letter-spacing:0.1em}
.val{color:#00d4ff;font-size:0.85rem}
.val-g{color:#00ff41}.val-d{color:#6a8a6a;font-size:0.75rem}
.pw{margin:0.6rem 0}
.pl{display:flex;justify-content:space-between;margin-bottom:0.3rem}
.pb{height:12px;background:#1a1a1a;border-radius:2px;overflow:hidden}
.pf{height:100%;border-radius:2px}
.sec{grid-column:1 / -1}
.sec .ch{background:rgba(255,0,64,0.05)}
.sec .dot{background:#ff0040;box-shadow:0 0 6px #ff0040}
.sg{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:1rem}
.si{text-align:center;padding:0.5rem}
.sv{font-size:1.3rem;font-weight:bold;margin-bottom:0.2rem}
.sl{color:#4a6a4a;font-size:0.7rem;text-transform:uppercase;letter-spacing:0.1em}
.svc{grid-column:1 / -1}
.st{width:100%;border-collapse:collapse;font-size:0.8rem}
.st th{text-align:left;color:#4a6a4a;font-size:0.7rem;text-transform:uppercase;letter-spacing:0.1em;padding:0.4rem 0.5rem;border-bottom:1px solid #1a3a1a}
.st td{padding:0.35rem 0.5rem;border-bottom:1px solid rgba(26,58,26,0.2);color:#8a8a8a}
.st .val{color:#00d4ff}.st .dim{color:#4a6a4a}
.foot{text-align:center;margin-top:2rem;padding:1rem;color:#3a5a3a;font-size:0.7rem;letter-spacing:0.15em;border-top:1px solid #1a3a1a}
@media(max-width:700px){.grid{grid-template-columns:1fr}.wrap{padding:1rem}.sg{grid-template-columns:repeat(2,1fr)}}
</style>
</head>
<body>
<canvas id="matrix"></canvas>
<div class="scan"></div>
<div class="wrap">
  <div class="banner">
    <pre>
 :::::::::: :::     :::    ::: :::    :::::::::::
 :+:      :+: :+:   :+:    :+: :+:        :+:
 +:+     +:+   +:+  +:+    +:+ +:+        +:+
 :#::+::# +#++:++#++ +#+    +:+ +#+        +#+
 +#+     +#+     +#+ +#+    +#+ +#+        +#+
 #+#     #+#     #+# #+#    #+# #+#        #+#
 ###     ###     ###  ########  ########## ###</pre>
    <div class="sub">FORENSICS &amp; ANALYSIS UTILITY TOOLKIT<span class="cur">_</span></div>
    <div class="host-badge">${HOST} &bull; ${OS_INFO} &bull; ${ARCH}</div>
  </div>
  <div class="grid">
    <div class="card">
      <div class="ch"><span class="dot"></span><h2>System</h2></div>
      <div class="cb">
        <div class="row"><span class="lbl">Hostname</span><span class="val">${HOST}</span></div>
        <div class="row"><span class="lbl">OS</span><span class="val-d">${OS_INFO}</span></div>
        <div class="row"><span class="lbl">Kernel</span><span class="val">${KERN}</span></div>
        <div class="row"><span class="lbl">Arch</span><span class="val">${ARCH}</span></div>
        <div class="row"><span class="lbl">CPU</span><span class="val-d">${CPU_MODEL}</span></div>
        <div class="row"><span class="lbl">Cores</span><span class="val">${CPU_CORES}</span></div>
        <div class="row"><span class="lbl">Packages</span><span class="val-d">${PKGS} installed</span></div>
        <div class="row"><span class="lbl">Uptime</span><span class="val">${UPTIME}</span></div>
        <div class="row"><span class="lbl">Load</span><span class="val">${LOAD_1} ${LOAD_5} ${LOAD_15}</span></div>
        <div class="row"><span class="lbl">Processes</span><span class="val">${PROCS}</span></div>
      </div>
    </div>
    <div class="card">
      <div class="ch"><span class="dot"></span><h2>Resources</h2></div>
      <div class="cb">
        <div class="pw"><div class="pl"><span class="lbl">Memory</span><span class="val-d">${MEM_H_USED} / ${MEM_H_TOTAL} (${MEM_PCT}%)</span></div>
          <div class="pb"><div class="pf" style="width:${MEM_PCT}%;background:${mem_color};box-shadow:0 0 8px ${mem_color}"></div></div></div>
        <div class="pw"><div class="pl"><span class="lbl">Disk /</span><span class="val-d">${DISK_USED} / ${DISK_TOTAL} (${DISK_PCT}%)</span></div>
          <div class="pb"><div class="pf" style="width:${DISK_PCT}%;background:${disk_color};box-shadow:0 0 8px ${disk_color}"></div></div></div>
        <div class="pw"><div class="pl"><span class="lbl">Swap</span><span class="val-d">${SWAP_H_USED} / ${SWAP_H_TOTAL} (${SWAP_PCT}%)</span></div>
          <div class="pb"><div class="pf" style="width:${SWAP_PCT}%;background:${swap_color};box-shadow:0 0 8px ${swap_color}"></div></div></div>
      </div>
    </div>
    <div class="card">
      <div class="ch"><span class="dot"></span><h2>Network</h2></div>
      <div class="cb">
        <div class="row"><span class="lbl">IPv4</span><span class="val">${IP_ADDR}</span></div>
        <div class="row"><span class="lbl">Interface</span><span class="val">${IFACE}</span></div>
        <div class="row"><span class="lbl">MAC</span><span class="val-d">${MAC}</span></div>
        <div class="row"><span class="lbl">SSH Sessions</span><span class="val">${SSH_CNT}</span></div>
        <div class="row"><span class="lbl">Users Online</span><span class="val">${USERS_ON}</span></div>
        <div class="row"><span class="lbl">Listening Ports</span><span class="val">${OPEN_PORTS}</span></div>
      </div>
    </div>
    <div class="card sec">
      <div class="ch"><span class="dot"></span><h2>Security</h2></div>
      <div class="cb"><div class="sg">
        <div class="si"><div class="sv" style="color:${ufw_color}">${UFW_ST}</div><div class="sl">Firewall</div></div>
        <div class="si"><div class="sv" style="color:${threat_color}">${threat_level}</div><div class="sl">Threat Level</div></div>
        <div class="si"><div class="sv" style="color:#00d4ff">${FAIL_24H}</div><div class="sl">Failed Auth (24h)</div></div>
        <div class="si"><div class="sv" style="color:#00d4ff">${SSH_CNT}</div><div class="sl">Active SSH</div></div>
      </div></div>
    </div>
    <div class="card svc">
      <div class="ch"><span class="dot"></span><h2>Listening Services</h2></div>
      <div class="cb">
        <table class="st"><thead><tr><th>Port</th><th>Process</th><th>Bind Address</th></tr></thead>
        <tbody>${SERVICES_ROWS}</tbody></table>
      </div>
    </div>
  </div>
  <div class="foot">AUTO-REFRESH 60s &bull; ${NOW}</div>
</div>
<script>
(function(){
var c=document.getElementById("matrix"),x=c.getContext("2d");
c.width=window.innerWidth;c.height=window.innerHeight;
var ch="01FAULT:.;|/=~^!@#%&?<>{}[]+*-",fs=14,cols=Math.floor(c.width/fs),d=[];
for(var i=0;i<cols;i++)d[i]=Math.floor(Math.random()*-50);
function draw(){x.fillStyle="rgba(10,10,10,0.05)";x.fillRect(0,0,c.width,c.height);x.font=fs+"px monospace";
for(var i=0;i<d.length;i++){var t=ch[Math.floor(Math.random()*ch.length)];
x.fillStyle="rgba(0,255,65,"+(0.15+Math.random()*0.35)+")";x.fillText(t,i*fs,d[i]*fs);
if(d[i]*fs>c.height&&Math.random()>0.975)d[i]=0;d[i]++;}}
setInterval(draw,50);
window.addEventListener("resize",function(){c.width=window.innerWidth;c.height=window.innerHeight;
var nc=Math.floor(c.width/fs);while(d.length<nc)d.push(0);d.length=nc;});
})();
</script>
</body>
</html>
HTMLEOF
chmod 644 "$TMP"
mv -f "$TMP" /var/www/index.html
DASHGEN
chmod +x /usr/local/bin/vm-dashboard-gen

# Systemd timer for 60s dashboard regeneration
cat > /etc/systemd/system/vm-dashboard-gen.service << 'SVCUNIT'
[Unit]
Description=Regenerate VM system dashboard
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vm-dashboard-gen
SVCUNIT

cat > /etc/systemd/system/vm-dashboard-gen.timer << 'TMRUNIT'
[Unit]
Description=Regenerate VM dashboard every 60s

[Timer]
OnBootSec=5s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
TMRUNIT

systemctl daemon-reload
systemctl enable --now vm-dashboard-gen.timer
/usr/local/bin/vm-dashboard-gen

log "System dashboard installed (auto-refreshes every 60s)"
phase_done

# ============================================================================
# Phase 8: UFW Firewall
# ============================================================================
phase "Phase 8/11: Configuring UFW firewall..."

ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp   # HTTP
ufw allow 443/tcp  # HTTPS
ufw allow 8080/tcp # Dev port
ufw limit 22/tcp comment 'Rate limit SSH'
ufw --force enable

log "UFW enabled (SSH, HTTP, HTTPS, 8080 allowed)"
phase_done

# ============================================================================
# Phase 9: earlyoom — userspace OOM killer (replaces systemd-oomd)
# ============================================================================
phase "Phase 9/11: Configuring earlyoom..."

apt-get install -y -qq earlyoom

# Disable systemd-oomd (unreliable, kills wrong processes, reacts too late)
systemctl disable --now systemd-oomd 2>/dev/null || true
systemctl mask systemd-oomd 2>/dev/null || true

# Configure earlyoom:
#   -m 5   = trigger at 5% free memory (aggressive — don't let the system thrash)
#   -s 10  = trigger at 10% free swap
#   -r 60  = report memory stats every 60s to syslog
#   -n     = send SIGTERM notification via d-bus (logged to journal)
#   -p     = prefer killing processes with oom_score_adj >= 300
#   --avoid = never kill critical services
#   --prefer = kill dev/build processes first
mkdir -p /etc/default
cat > /etc/default/earlyoom <<'EARLYOOM_CONF'
EARLYOOM_ARGS="-m 5 -s 10 -r 60 -n -p --avoid '^(sshd|systemd|nginx|redis-server|earlyoom)$' --prefer '^(npm|node|python3?|java|cc1plus|cc1|g\+\+|webpack|conda|pip)$'"
EARLYOOM_CONF

systemctl enable --now earlyoom
log "earlyoom enabled (kills at 5% free RAM, prefers dev processes, protects sshd/nginx/redis)"
phase_done

# ============================================================================
# Phase 10: sysctl tuning
# ============================================================================
phase "Phase 10/11: Applying sysctl optimizations..."

SYSCTL_MARKER="# --- vm-post-setup ---"
if ! grep -qF "$SYSCTL_MARKER" /etc/sysctl.conf 2>/dev/null; then
    cat >> /etc/sysctl.conf <<SYSCTL

${SYSCTL_MARKER}
# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Log martian packets
net.ipv4.conf.all.log_martians = 1

# Source validation (RFC1812)
net.ipv4.conf.all.rp_filter = 1

# Ignore broadcast ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Minimal swapping
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# Connection handling
net.core.somaxconn = 5000
net.ipv4.tcp_max_syn_backlog = 3000
net.core.netdev_max_backlog = 5000
fs.file-max = 184028
net.ipv4.ip_local_port_range = 10000 65000

# Disable source routing
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.secure_redirects = 0

# Network forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# TCP performance
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 40960
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Connection churn
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_max_tw_buckets = 40960
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# TCP Fast Open
net.ipv4.tcp_fastopen = 3

# inotify
fs.inotify.max_user_watches = 524288
# --- end vm-post-setup ---
SYSCTL

    sysctl -p >/dev/null 2>&1 || true
    log "sysctl optimizations applied"
else
    log "sysctl already configured, skipping"
fi
phase_done

# ============================================================================
# Phase 11: MOTD — Cybersecurity-themed login banner
# ============================================================================
phase "Phase 11/11: Installing MOTD..."

# Disable default Ubuntu MOTD components
chmod -x /etc/update-motd.d/* 2>/dev/null || true

cat > /etc/update-motd.d/00-cyber-motd <<'MOTDSCRIPT'
#!/usr/bin/env bash

# ── Colors ──
RED='\033[0;31m'    GRN='\033[0;32m'    YEL='\033[1;33m'
CYN='\033[0;36m'    WHT='\033[1;37m'    GRY='\033[0;90m'
DGRN='\033[2;32m'   DCYN='\033[2;36m'   DIM='\033[2;37m'
RST='\033[0m'       BLD='\033[1m'

# ── System Data ──
HOST=$(hostname)
KERN=$(uname -r | cut -d- -f1-2)
ARCH=$(uname -m)
UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || echo "?")
LOAD=$(awk '{printf "%.2f %.2f %.2f", $1, $2, $3}' /proc/loadavg)
PROCS=$(ps -e --no-headers 2>/dev/null | wc -l)
CPU_CORES=$(nproc)
MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))
MEM_H_USED=$(free -h | awk '/Mem:/ {print $3}')
MEM_H_TOTAL=$(free -h | awk '/Mem:/ {print $2}')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_NUM=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
IP_ADDR=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
IP_ADDR=${IP_ADDR:-"offline"}
USERS_ON=$(who 2>/dev/null | wc -l)
SSH_CNT=$(ss -tnp 2>/dev/null | grep -c ':22 ') || SSH_CNT=0
OPEN_PORTS=$(ss -tlnp 2>/dev/null | tail -n +2 | wc -l)
if [[ -r /etc/ufw/ufw.conf ]]; then
    UFW_ENABLED=$(grep -oP '(?<=^ENABLED=).*' /etc/ufw/ufw.conf 2>/dev/null)
    [[ "$UFW_ENABLED" == "yes" ]] && UFW_ST="active" || UFW_ST="inactive"
else
    UFW_ST="n/a"
fi
FAIL_24H=$(journalctl -u ssh --since "24 hours ago" --no-pager 2>/dev/null | grep -ci "failed\|invalid") || FAIL_24H=0
NOW=$(date '+%Y-%m-%d %H:%M:%S %Z')

# ── Bar Builder ──
make_bar() {
    local pct=$1 len=20 filled empty col
    filled=$((pct * len / 100))
    [[ $filled -lt 0 ]] && filled=0
    [[ $filled -gt $len ]] && filled=$len
    empty=$((len - filled))
    if   [[ $pct -ge 90 ]]; then col="$RED"
    elif [[ $pct -ge 70 ]]; then col="$YEL"
    else col="$GRN"; fi
    printf "${col}"
    for ((i=0; i<filled; i++)); do printf '█'; done
    printf "${GRY}"
    for ((i=0; i<empty; i++)); do printf '░'; done
    printf "${RST}"
}

MEM_BAR=$(make_bar "$MEM_PCT")
DISK_BAR=$(make_bar "$DISK_NUM")

# ── Matrix Rain (single-width chars only) ──
rain() {
    local chars='0123456789!@#$%^&*=+~<>|/:;,.{}[]-_\?'
    local out="" len=${#chars}
    for ((i=0; i<$1; i++)); do out+="${chars:RANDOM%len:1}"; done
    echo "$out"
}

R1=$(rain 56)
R2=$(rain 56)

# ── Threat Level ──
if   [[ $FAIL_24H -ge 50 ]]; then THREAT="${RED}${BLD}CRITICAL${RST}"
elif [[ $FAIL_24H -ge 10 ]]; then THREAT="${YEL}${BLD}ELEVATED${RST}"
else                               THREAT="${GRN}${BLD}NOMINAL${RST}"; fi

# ── Render ──
echo
echo -e "  ${DGRN}${R1}${RST}"
echo
echo -e "  ${GRN} :::::::::: :::     :::    ::: :::    ::::::::::: ${RST}"
echo -e "  ${GRN} :+:      :+: :+:   :+:    :+: :+:        :+:     ${RST}"
echo -e "  ${GRN} +:+     +:+   +:+  +:+    +:+ +:+        +:+     ${RST}"
echo -e "  ${GRN} :#::+::# +#++:++#++ +#+    +:+ +#+        +#+     ${RST}"
echo -e "  ${GRN} +#+     +#+     +#+ +#+    +#+ +#+        +#+     ${RST}"
echo -e "  ${GRN} #+#     #+#     #+# #+#    #+# #+#        #+#     ${RST}"
echo -e "  ${GRN} ###     ###     ###  ########  ########## ###     ${RST}"
echo -e "  ${DIM} Forensics & Analysis Utility Toolkit${RST}"
echo
echo -e "  ${DGRN}${R2}${RST}"
echo
echo -e "  ${GRY}──────────────────────────────────────────────────────${RST}"
echo -e "  ${WHT} SYSTEM ${RST}  ${CYN}${HOST}${RST}"
echo -e "  ${WHT} KERNEL ${RST}  ${DCYN}${KERN} ${DIM}(${ARCH})${RST}"
echo -e "  ${WHT} UPTIME ${RST}  ${DCYN}${UPTIME}${RST}"
echo -e "  ${WHT} LOAD   ${RST}  ${DCYN}${LOAD}${RST}   ${DIM}[${CPU_CORES} cores / ${PROCS} procs]${RST}"
echo -e "  ${GRY}──────────────────────────────────────────────────────${RST}"
echo -en "  ${WHT} MEMORY ${RST}  ${MEM_BAR}  ${DIM}${MEM_H_USED} / ${MEM_H_TOTAL} (${MEM_PCT}%)${RST}\n"
echo -en "  ${WHT} DISK / ${RST}  ${DISK_BAR}  ${DIM}${DISK_USED} / ${DISK_TOTAL} (${DISK_NUM}%)${RST}\n"
echo -e "  ${GRY}──────────────────────────────────────────────────────${RST}"
echo -e "  ${WHT} IPV4   ${RST}  ${CYN}${IP_ADDR}${RST}"
echo -e "  ${WHT} SSH    ${RST}  ${DCYN}${SSH_CNT} sessions${RST}   ${DIM}[${USERS_ON} users / ${OPEN_PORTS} ports]${RST}"
echo -e "  ${GRY}──────────────────────────────────────────────────────${RST}"
echo -e "  ${RED} UFW    ${RST}  ${CYN}${UFW_ST}${RST}"
echo -e "  ${RED} THREAT ${RST}  ${THREAT}"
echo -e "  ${RED} AUTH   ${RST}  ${DCYN}${FAIL_24H} failed attempts${RST} ${DIM}(24h)${RST}"
echo -e "  ${GRY}──────────────────────────────────────────────────────${RST}"
echo -e "  ${GRY} ${NOW}${RST}"
echo
MOTDSCRIPT

chmod +x /etc/update-motd.d/00-cyber-motd

# Also show MOTD on SSH login
# Handle both monolithic sshd_config and sshd_config.d/ fragments
if ! grep -qE "^[[:space:]]*PrintMotd[[:space:]]+yes" /etc/ssh/sshd_config 2>/dev/null; then
    sed -i '/^[[:space:]]*#\?[[:space:]]*PrintMotd/d' /etc/ssh/sshd_config 2>/dev/null || true
    echo "PrintMotd yes" >> /etc/ssh/sshd_config
fi
# Override any sshd_config.d/ fragments that might set PrintMotd no
if [[ -d /etc/ssh/sshd_config.d ]]; then
    echo "PrintMotd yes" > /etc/ssh/sshd_config.d/99-motd.conf
fi
# Disable static motd to only show dynamic one
echo "" > /etc/motd 2>/dev/null || true

log "Cybersecurity MOTD installed"
phase_done

# ============================================================================
# Done
# ============================================================================
date -Iseconds > "$DONE_MARKER"

phase "Post-setup complete!"
log "Installed:"
log "  Modern CLI: bat, eza, rg, fd, fzf, zoxide, btop, dust, duf, delta, sd, procs, starship, httpie"
log "  Dev envs:   Miniconda (conda), NVM + Node ${NODE_VERSION} + PM2 + tldr"
log "  Web:        Nginx + self-signed SSL (10yr) + system dashboard"
log "  Security:   UFW (zero-trust), earlyoom, sysctl hardened"
log ""
log "Log out and back in (or 'source ~/.bashrc') for shell changes to take effect"
