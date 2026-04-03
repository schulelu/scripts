# Linux Toolkit

A collection of bash scripts for KVM virtual machine management, malware sandbox forensics, and Linux system diagnostics.

| Script | Description |
|--------|-------------|
| `kvm-manager.sh` | Full KVM VM lifecycle management with snapshots, templates, GPU passthrough, and anti-detection hardening |
| `vm-forensics.sh` | Live traffic monitoring and post-analysis for KVM malware sandboxes |
| `vm-post-setup.sh` | First-boot provisioning for Ubuntu cloud-image VMs (CLI tools, dev envs, web stack, security) |
| `desktop-lag-doctor.sh` | Diagnose and fix micro-lags on Linux desktops |
| `vm-detect.sh` | Red-team VM/hypervisor detection and escape vector auditing |
| `gpu-detective.sh` | Detect, diagnose, and resolve undetected GPU issues on Ubuntu |

## Prerequisites

- Ubuntu / Debian-based system
- Root or sudo access
- Hardware virtualization support (Intel VT-x / AMD-V) for KVM

Install all KVM dependencies automatically:

```bash
sudo ./kvm-manager.sh setup
```

This installs `qemu-kvm`, `libvirt`, `virtinst`, `qemu-utils`, `cloud-image-utils`, enables the libvirt daemon, configures the default network, and optionally sets up NVIDIA GPU passthrough (IOMMU + VFIO).

For forensics features, you also need `tcpdump` and `tshark`:

```bash
sudo apt-get install tcpdump tshark wireshark-common
```

---

## kvm-manager.sh

KVM VM manager with fast snapshot rollback, cloud-image provisioning, anti-detection hardening for malware sandboxes, and GPU passthrough for LLM/CUDA workloads.

All commands require `sudo`.

### Quick Start

```bash
# Install KVM stack
sudo ./kvm-manager.sh setup

# Create a cloud-image VM (boots in seconds, no installer)
sudo ./kvm-manager.sh create my-vm --cloud-image

# SSH into it
sudo ./kvm-manager.sh ssh my-vm
```

### Command Reference

#### VM Lifecycle

```
create <name> [options]       Create a new VM
  --cloud-image                 Ubuntu cloud image (boots in seconds, no installer)
  --iso <path>                  Install from ISO (server ISO, serial console)
  --template <vm>               Clone from existing VM/template
  --cpu <N>                     vCPU count (default: 2)
  --ram <size>                  RAM size, e.g. 2G, 512M (default: 2048M)
  --disk <size>                 Disk size, e.g. 20G, 1T (default: 20G)
  --stealth                     Apply anti-detection hardening (malware analysis)
  --gpu                         Pass through host NVIDIA GPU (requires setup first)
  --post-setup [path]           Run post-setup script after first boot
delete <name> [--force]       Delete VM and all its storage
list                          List all VMs with status
```

#### Templates

```
template-create <vm>          Mark a VM as a reusable template
template-list                 List available templates
clone <source> <new-name>     Clone a VM
```

#### Snapshots

```
snap <vm> <snapshot-name>         Create a snapshot
rollback <vm> <snapshot-name>     Revert to a snapshot (sub-second)
snap-list <vm>                    List snapshots for a VM
snap-delete <vm> <snapshot-name>  Delete a snapshot
```

#### Anti-Detection (Malware Sandbox Hardening)

```
harden <vm> [options]         Apply anti-detection hardening to a shut-off VM
  --profile <N>                 Hardware profile: 0=Dell, 1=Lenovo, 2=HP (default: random)
  --verify                      Verify all hardening changes were applied
```

Stealth mode spoofs SMBIOS (manufacturer, product, BIOS), generates realistic serial numbers, randomizes MAC addresses using real OUI prefixes, and removes KVM/QEMU identifiers. Use `--stealth` on create or `harden` on an existing VM.

#### GPU Passthrough

```
gpu-status                    Check GPU passthrough readiness (IOMMU, VFIO, driver)
```

Configured automatically during `setup` if an NVIDIA GPU is detected. Requires a reboot after initial setup.

#### Provisioning

```
post-setup <vm> [script-path]   Run post-setup script on existing VM via SSH
analyze <vm> [forensics-args]   Run vm-forensics analysis on a VM
```

#### Monitoring & Access

```
status <vm>                   Detailed VM information
monitor                       Live overview of all VMs (watch mode)
console <vm>                  Attach to VM serial console
ssh <vm> [ssh-args...]        SSH into VM (auto-detects IP)
```

#### Power

```
start <vm>                    Start a VM
stop <vm> [--force]           Graceful shutdown (--force to kill)
restart <vm>                  Reboot a VM
autostart <vm> [on|off]       Toggle VM autostart on host boot
```

### Usage Examples

**Fully provisioned stealth sandbox:**

```bash
# Create a hardened VM with all dev tools pre-installed
sudo ./kvm-manager.sh create sandbox --cloud-image --cpu 4 --ram 8G --stealth --post-setup

# Snapshot the clean state before running anything suspicious
sudo ./kvm-manager.sh snap sandbox clean

# Run suspicious code inside the VM
sudo ./kvm-manager.sh ssh sandbox -- 'curl -sL http://sketchy-site.example | bash'

# Roll back to clean state instantly
sudo ./kvm-manager.sh rollback sandbox clean
```

**GPU passthrough for LLM workloads:**

```bash
sudo ./kvm-manager.sh setup                  # configures IOMMU + VFIO (reboot after)
sudo ./kvm-manager.sh gpu-status             # verify GPU is bound to vfio-pci
sudo ./kvm-manager.sh create llm-vm --cloud-image --cpu 8 --ram 32G --disk 100G --gpu --post-setup
```

**Template-based workflow:**

```bash
# Create and configure a base VM
sudo ./kvm-manager.sh create base --cloud-image --post-setup
# ... customize as needed ...
sudo ./kvm-manager.sh stop base
sudo ./kvm-manager.sh template-create base

# Spin up clones instantly
sudo ./kvm-manager.sh clone base worker-1
sudo ./kvm-manager.sh clone base worker-2
```

### Best Practices

- **Always snapshot before testing** — `snap` + `rollback` gives you sub-second reverts, so create a `clean` snapshot right after provisioning.
- **Use `--stealth` for malware analysis** — malware often fingerprints VM environments. Stealth mode mimics real Dell/Lenovo/HP hardware.
- **Use `--cloud-image` over `--iso`** — cloud images boot in seconds with no installer needed. Combine with `--post-setup` for a fully provisioned VM in one command.
- **Templates for repetitive work** — create a template once, then `clone` for each new task.
- **GPU passthrough needs a reboot** — after `setup`, reboot the host so IOMMU and VFIO take effect. Check with `gpu-status`.

---

## vm-forensics.sh

Live traffic monitoring and post-capture analysis for KVM malware sandboxes. Flags suspicious ports, DGA-like domains, known mining pools, and shady TLDs with color-coded output.

All commands require `sudo` (for packet capture).

### Quick Start

```bash
# Start capturing traffic from a running VM
sudo ./vm-forensics.sh capture sandbox

# ... do suspicious things inside the VM ...

# Stop capture
sudo ./vm-forensics.sh stop sandbox

# Analyze the captured traffic
sudo ./vm-forensics.sh analyze ./forensics/sandbox/<session>/capture.pcap
```

### Command Reference

#### Live Monitoring

```
capture <vm>          Start background packet capture (pcap file)
live <vm>             Live color-coded traffic display (Ctrl+C to stop)
watch-all <vm>        Combined: background capture + live display
stop [vm]             Stop capture processes (all if no vm specified)
```

#### Analysis

```
analyze <pcap-file>           Post-analysis of captured traffic
disk-diff <vm> <snapshot>     Compare current disk state vs snapshot (VM must be off)
dump-mem <vm>                 Capture VM memory for Volatility analysis
report <session-dir>          Generate summary report from session data
```

#### Testing

```
simulate <vm>         Deploy and run safe test patterns inside the VM
```

The `simulate` command generates known-bad traffic patterns using non-routable domains and localhost so you can validate your monitoring setup without any real risk.

### What It Detects

| Indicator | Details |
|-----------|---------|
| **Suspicious ports** | 4444, 5555, 8888, 1337, 6666, 9999, 31337, 3389 |
| **Suspicious TLDs** | .xyz, .top, .club, .work, .click, .loan, .gq, .ml, .cf, .tk |
| **Mining pools** | pool.minexmr, xmrpool, monerohash, cryptonight, coinhive, stratum |
| **DGA domains** | Labels >20 chars, all-consonant labels, high digit ratio |

In live mode, suspicious activity is highlighted in **red** (high confidence: C2 ports, DGA, mining) or **yellow** (medium: suspicious TLDs).

### Usage Examples

**Full malware analysis workflow:**

```bash
# 1. Create a hardened sandbox and snapshot clean state
sudo ./kvm-manager.sh create sandbox --cloud-image --stealth
sudo ./kvm-manager.sh snap sandbox clean

# 2. Start monitoring (capture + live display)
sudo ./vm-forensics.sh watch-all sandbox

# 3. In another terminal, run the suspicious payload
sudo ./kvm-manager.sh ssh sandbox -- 'npm install suspicious-package'

# 4. Stop capture (Ctrl+C on watch-all, or from another terminal)
sudo ./vm-forensics.sh stop sandbox

# 5. Analyze captured traffic
sudo ./vm-forensics.sh analyze ./forensics/sandbox/<session>/capture.pcap

# 6. Compare filesystem changes against clean snapshot
sudo ./kvm-manager.sh stop sandbox
sudo ./vm-forensics.sh disk-diff sandbox clean

# 7. Generate a report
sudo ./vm-forensics.sh report ./forensics/sandbox/<session>/

# 8. Roll back and repeat
sudo ./kvm-manager.sh rollback sandbox clean
```

**Validate your setup with simulated traffic:**

```bash
sudo ./vm-forensics.sh capture sandbox
sudo ./vm-forensics.sh simulate sandbox    # generates safe test patterns
sudo ./vm-forensics.sh stop sandbox
sudo ./vm-forensics.sh analyze ./forensics/sandbox/<session>/capture.pcap
```

**Memory forensics:**

```bash
# Dump VM memory while it's running (for Volatility analysis)
sudo ./vm-forensics.sh dump-mem sandbox
# Analyze with: vol.py -f <dump-file> linux.pslist
```

### Best Practices

- **Always snapshot before analysis** — so you can `rollback` to a clean state after.
- **Use `simulate` first** — validates that your capture and analysis pipeline works before running real malware.
- **Use `watch-all` for interactive sessions** — combines background pcap capture with live display. The pcap is saved even if you miss something in the live view.
- **Run `disk-diff` after stopping the VM** — the VM must be shut off for disk comparison. Compare against your clean snapshot to see all filesystem changes.
- **Session directories** are created under `./forensics/<vm-name>/<timestamp>/` — each capture gets its own timestamped directory.

---

## vm-detect.sh

Red-team VM/hypervisor detection tool. Runs **inside a guest** to detect virtualization, identify the hypervisor type, report confidence scores, and audit known escape vectors. Use it to validate your stealth hardening setup.

### Commands

```
scan            Run all 11 detection checks (default)
quick           Fast checks only (skip timing, ACPI, network)
escape-audit    Detect hypervisor + report known escape CVEs
benchmark       RDTSC timing attack with detailed statistics
```

### Options

```
-v, --verbose     Enable verbose/debug output
-q, --quiet       Exit code only (0=physical, 1=VM detected)
    --json        Machine-readable JSON output
```

### Detection Categories

| Check | Method | Signal |
|-------|--------|--------|
| **CPUID** | Hypervisor bit + vendor string (leaf 0x40000000) | High |
| **DMI/SMBIOS** | `/sys/class/dmi/id/*` for QEMU/KVM/VBox/VMware strings | High |
| **PCI Devices** | Virtual PCI vendor IDs (virtio 0x1af4, VMware 0x15ad, VBox 0x80ee) | High |
| **Disk** | Disk model/vendor/serial + virtio block device names | Medium |
| **Processes** | Guest agent processes (qemu-ga, VBoxService) + kernel modules | Medium |
| **Filesystem** | `/sys/hypervisor`, `/dev/virtio-ports`, `qemu_fw_cfg`, etc. | Medium |
| **Timing** | RDTSC: CPUID trap overhead vs NOP baseline (compiled C) | High |
| **MAC Address** | OUI prefix matching against known virtual prefixes | Medium |
| **CPU** | Model string anomalies, hypervisor flag, core count vs model | Medium |
| **ACPI** | DSDT/FACP/DMI binary table signatures (BOCHS, BXPC, QEMU) | High |
| **Network** | Gateway MAC, bridge interfaces, virbr detection | Low |

### Escape Audit

The `escape-audit` command identifies the hypervisor and reports known VM escape CVEs:

- **QEMU/KVM**: VENOM (CVE-2015-3456), USB EHCI (CVE-2020-14364), virtio-net UAF (CVE-2021-3748), QCOW2 escape (CVE-2024-4467), and more
- **VirtualBox**: 3D acceleration escape (CVE-2018-2698), VBoxSVGA heap overflow (CVE-2023-21987)
- **VMware**: DnD heap overflow (CVE-2017-4901), USB EHCI (CVE-2022-31705)
- **Hyper-V**: vmswitch RCE (CVE-2021-28476)

### Usage

```bash
# Full scan inside a VM (needs root for ACPI tables)
sudo ./vm-detect.sh scan

# Quick check — just exit code
./vm-detect.sh quick --quiet && echo "Physical" || echo "Virtual"

# JSON output for automation
sudo ./vm-detect.sh scan --json | jq .

# Identify hypervisor and list escape CVEs
sudo ./vm-detect.sh escape-audit

# Test your stealth hardening
sudo ./kvm-manager.sh create sandbox --cloud-image --stealth
# Copy vm-detect.sh into the VM and run it
sudo ./kvm-manager.sh ssh sandbox -- 'sudo bash /tmp/vm-detect.sh scan'
```

### Best Practices

- **Run on unhardened VMs first** — establishes a baseline of what gets detected before hardening.
- **Run after `kvm-manager.sh harden`** — validates that hardening actually reduced detection surface.
- **Use `--json` for CI/automation** — parse results programmatically to gate deployments.
- **ACPI checks need root** — the timing attack needs `gcc`. Install both for a complete scan.
- **Escape CVEs are informational** — patched hypervisors may not be vulnerable. Always check your QEMU/libvirt version.

---

## vm-post-setup.sh

Automatic first-boot provisioning for Ubuntu cloud-image VMs. Transforms a bare cloud image into a fully equipped development and analysis environment in a single run.

### How to Use

```bash
# Option 1: Automatically during VM creation
sudo ./kvm-manager.sh create my-vm --cloud-image --post-setup

# Option 2: On an existing VM
sudo ./kvm-manager.sh post-setup my-vm

# Option 3: Standalone (run inside the VM)
sudo bash vm-post-setup.sh [--user USERNAME]
```

The script is idempotent — it can be re-run safely. A marker file (`/opt/.post-setup-done`) tracks whether it has already been executed.

### What It Installs (12 Phases)

| Phase | What | Details |
|-------|------|---------|
| **1. System packages** | Core + modern CLI tools | `bat`, `ripgrep`, `fd-find`, `fzf`, `zoxide`, `btop`, `duf`, `git-delta`, `httpie`, `redis-server`, `jq`, build tools |
| **2. Binary installs** | Tools not in apt repos | `eza` (modern ls), `dust` (modern du), `sd` (modern sed), `procs` (modern ps), `starship` (prompt) |
| **3. Shell config** | Aliases + integrations | Aliases all classic commands to modern replacements (`cat`->`bat`, `ls`->`eza`, `grep`->`rg`, `find`->`fd`, `top`->`btop`, etc.), configures zoxide, fzf keybindings, starship prompt |
| **4. Miniconda** | Python env manager | Installed with `auto_activate_base` disabled so it doesn't interfere |
| **5. NVM + Node** | Node.js environment | NVM + Node 22 + PM2 (process manager) + tldr |
| **6. Nginx + SSL** | Reverse proxy + HTTPS | Self-signed certificate (10-year validity, includes VM IP in SAN), HTTP->HTTPS redirect, optimized config with gzip + keepalive |
| **7. System dashboard** | Web-based status page | Cybersecurity-themed HTML dashboard at `https://<vm-ip>/` showing system stats, resource usage, security status. Auto-refreshes every 60s via systemd timer |
| **8. UFW firewall** | Zero-trust firewall | Denies all incoming by default, allows SSH (rate-limited), HTTP, HTTPS, 8080 |
| **9. earlyoom** | Userspace OOM killer | Replaces `systemd-oomd`. Triggers at 5% free RAM, kills dev/build processes first, protects sshd/nginx/redis |
| **10. sysctl tuning** | Kernel optimizations | SYN flood protection, TCP BBR congestion control, connection tuning, inotify limits, swap minimization, martian packet logging |
| **11. MOTD** | Login banner | Cybersecurity-themed terminal banner with live system stats (memory, disk, network, security threat level) |
| **12. NVIDIA GPU + CUDA** | GPU driver (conditional) | Only runs if an NVIDIA GPU is detected (including passthrough). Installs driver + CUDA toolkit + adds to PATH |

### Shell Aliases After Setup

| You type | Runs |
|----------|------|
| `cat` | `bat` (syntax highlighting) |
| `ls` | `eza` |
| `ll` | `eza -alh --git` |
| `lt` | `eza --tree --level=2` |
| `grep` | `ripgrep` |
| `find` | `fd` |
| `top` | `btop` |
| `du` | `dust` |
| `df` | `duf` |
| `diff` | `delta` |
| `ps` | `procs` |

---

## desktop-lag-doctor.sh

Diagnoses and fixes micro-lags on Linux desktops. Checks for common performance issues like compositor problems, I/O bottlenecks, swappiness, and scheduler misconfigurations, then offers interactive fixes with rollback support.

### Commands

```
diagnose        Run all diagnostic checks (prompts to fix interactively)
fix             Apply all safe performance tuning at once
monitor         Live monitoring loop for lag sources
rollback        Restore previous settings from a saved snapshot
```

### Options

```
-d, --dry-run     Show what fix would do without applying
-v, --verbose     Enable verbose/debug output
-q, --quiet       Suppress non-error output
-y, --yes         Auto-confirm all fix prompts
    --json        Machine-readable JSON output
```

### Usage

```bash
# Interactive diagnosis (recommended first run)
sudo ./desktop-lag-doctor.sh diagnose

# Apply all fixes non-interactively
sudo ./desktop-lag-doctor.sh fix --yes

# Preview fixes without applying
sudo ./desktop-lag-doctor.sh fix --dry-run

# Undo previous fixes
sudo ./desktop-lag-doctor.sh rollback
```

---

## gpu-detective.sh

Detects, diagnoses, and resolves undetected GPU issues on Ubuntu. Useful when your GPU isn't showing up, drivers are broken, or you need a full diagnostic report.

### Commands

```
scan            Full hardware scan for all GPUs (default)
drivers         Check and fix driver issues
bios            Inspect UEFI/BIOS-related GPU settings
fix             Attempt automatic resolution of common GPU issues
report          Generate a full diagnostic report file
```

### Options

```
-d, --dry-run     Show what fix would do without applying
-v, --verbose     Enable verbose/debug output
-q, --quiet       Suppress non-error output
-y, --yes         Auto-confirm all fix prompts
    --json        Machine-readable JSON output
```

### Usage

```bash
# Full GPU scan
sudo ./gpu-detective.sh scan

# Check and fix driver issues
sudo ./gpu-detective.sh drivers

# Generate a diagnostic report
sudo ./gpu-detective.sh report

# Auto-fix with dry-run preview
sudo ./gpu-detective.sh fix --dry-run
sudo ./gpu-detective.sh fix --yes
```
