# PowOS x86/Bazzite Technical Reference

Moved out of CLAUDE.md (friction f100) to keep the root file a short index. Verbatim, nothing changed.
CLI commands are in docs/CLI.md; agent-critical rules (testing, HACK registry, units, commit etiquette, CI
etiquette) stayed in CLAUDE.md.

> **Primary story (scope B): install PowOS to disk as a daily-driver that
> dual-boots Windows.** RAM boot is **OFF by default** — the `rd.powos.ramboot=1`
> karg is no longer baked into the image (it hung the boot on real hardware), so
> the image boots a normal disk root whether flashed to USB or installed. RAM boot
> is now an explicit opt-in (`powos ramboot enable`). The live-USB / RAM /
> CacheFS / mobile / Windows-VHDX / reciprocal-VM / GPU-hotswap features are kept
> in the tree but are opt-in or EXPERIMENTAL, not the primary path.

## Quick Start

```bash
# Test in Docker (opens KDE desktop in browser)
docker compose up

# Build the CANONICAL PowOS installer: an Anaconda GUI ISO (requires podman).
# Output: build/output/bootiso/install.iso (also copied to powos-installer.iso)
podman build -t localhost/powos .              # build the PowOS image
./build/build-iso.sh                           # → build/output/bootiso/install.iso
# flash install.iso → boot → Anaconda GUI installs PowOS to disk → reboot
powos backup pull                              # restore your config

# Or via just:
just installer                                 # PowOS image → Anaconda installer ISO
```

Access desktop at `http://localhost:6091/vnc.html` (password: `powos`)

**Install path (canonical, hardware-validated):** build the Anaconda ISO →
flash `install.iso` → boot → the Anaconda GUI installer picks the disk and
installs PowOS (its own confirmations). `bootc-image-builder --type anaconda-iso`
is the whole mechanism.

**Legacy / experimental (superseded, do NOT present as the way to install):** the
raw-efi live image (`build-iso.sh live-usb` → `powos.raw`), the lean
custom-wizard installer (`build-iso.sh installer-raw` → `powos-installer.raw`),
the in-system `powos install` / `install-system` wizards, and the live-USB
first-boot self-completion (`powos-firstboot-disk`). These custom paths have a
blind TUI / GPU stalls / slow boot. Their services stay in the image (the
Anaconda ISO never triggers `powos.install`, so they don't run) — but the
Anaconda ISO is the supported installer.

## Core Concept: Layered Persistence

PowOS uses **layered persistence with independent rollback** - NOT a traditional immutable system.

```
┌────────────────────────────────────────────────────────────────────┐
│                         LAYER STACK                                │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────┐                                                │
│  │   RAM (upper)   │ ← All writes go here (instant)                 │
│  └────────┬────────┘                                                │
│           │ layer-sync (every 60s)                                  │
│           ▼                                                         │
│  ┌─────────────────┐                                                │
│  │  Custom Layer   │ ← Your packages, configs (persistent)          │
│  └────────┬────────┘   Rollback: rd.powos.skip.custom=1             │
│           │                                                         │
│  ┌─────────────────┐                                                │
│  │  Updates Layer  │ ← OS updates (separate from custom)            │
│  └────────┬────────┘   Rollback: rd.powos.skip.updates=1            │
│           │                                                         │
│  ┌─────────────────┐                                                │
│  │   Base Layer    │ ← Original Bazzite image                       │
│  └─────────────────┘                                                │
│                                                                     │
│  Install anything → RAM → syncs to custom layer → persists          │
│  Update broke something? → powos rollback updates                   │
│  Package broke something? → powos rollback custom                   │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

**Key insight:** You CAN modify the system. Changes persist. But you can roll back individual layers without losing everything.


## Boot Sequence

```
1. UEFI loads kernel + initramfs from USB

2. Dracut module (90powos-ramboot) runs:
   └─ Creates 8GB tmpfs for RAM upper
   └─ Mounts USB data partition
   └─ Stacks layers: custom:updates:base
   └─ Mounts overlayfs as new root
   └─ OS NOW RUNS FROM RAM

3. Hardware Detection (Chameleon Boot)
   └─ Detect GPU/power/form
   └─ Apply matching profile

4. System Overlays (systemd-sysext)
   └─ Load extensions into /usr

5. Layer Sync Daemon starts
   └─ Syncs RAM → custom layer every 60s

6. User Data Mount
   └─ Default: direct USB bind-mount at /home/powos
   └─ If POWOS_CACHEFS_ENABLED=true: FUSE mount (lazy-load)
   └─ CacheFS is opt-in (write-back to USB every 30s + fsync + unmount)

7. Desktop Environment
   └─ KDE Plasma ready
```

## Kernel Command Line Args

NOTE: `rd.powos.ramboot=1` is **no longer baked into the default image** (it hung
the boot on real hardware). The default image boots a normal disk root. RAM boot
is an opt-in: on an installed system `powos ramboot enable` sets
`rd.powos.ramboot.installed=1`; the live-USB auto-karg (`rd.powos.ramboot=1`) is
only ever set by hand.

```bash
rd.powos.ramboot=1        # (opt-in) live-USB layered RAM boot — NOT a default
rd.powos.ramboot.installed=1  # (opt-in) installed OS-in-RAM (powos ramboot enable)
rd.powos.ramsize=8G       # RAM allocation (default 8G)
rd.powos.skip.custom=1    # ROLLBACK: Skip custom layer
rd.powos.skip.updates=1   # ROLLBACK: Skip updates layer
```

## USB Storage Layout

```
USB SSD (e.g., Lexar NM790 4TB)
├── Partition 1: EFI (512MB, FAT32)
├── Partition 2: System (100GB, BTRFS)
│   └── Base OS image
└── Partition 3: Data (remainder, BTRFS)
    └── Label: POWOS-DATA
        ├── layers/
        │   ├── custom/     ← Your customizations (synced from RAM)
        │   └── updates/    ← OS updates
        └── home/           ← User data (CacheFS source)
```

## Directory Structure

```
PowOS/
├── Containerfile              # THE OS definition
├── docker-compose.yml         # Test environment
├── justfile                   # Build commands
│
├── bin/
│   ├── powos                  # Main CLI (all commands below)
│   ├── powos-boot             # Main boot script
│   └── pinstall               # Install + git commit
│
├── lib/
│   ├── hardware-detect.sh     # Chameleon Boot
│   ├── overlay-manager.sh     # systemd-sysext builder
│   ├── sync.sh                # RAM ↔ USB sync with conflict detection
│   ├── backup.sh              # USB ↔ cloud backup (git)
│   ├── mobile.sh              # Mobile mode (copy OS to RAM)
│   ├── dracut/
│   │   └── 90powos-ramboot/
│   │       ├── module-setup.sh
│   │       ├── ramboot-setup.sh      # Layered overlayfs setup
│   │       └── powos-overlay-init.sh
│   ├── ramfs/
│   │   └── layer-sync.py      # Syncs RAM → custom layer
│   ├── cachefs/
│   │   ├── powos-cachefs.py   # FUSE filesystem
│   │   └── cachefs-sync.py    # User data sync
│   └── ai/
│       ├── agent.sh           # Main agent dispatcher + library API
│       ├── session.sh         # Session management
│       └── clients/           # Client implementations
│           ├── claude.sh
│           ├── gemini.sh
│           └── ollama.sh
│
├── config/
│   ├── profiles/              # Hardware profiles (17)
│   ├── bootc/kargs.d/         # Kernel arguments
│   └── ai/
│       ├── agent.conf         # Global AI settings
│       ├── clients/           # Client configs (claude, gemini, ollama)
│       └── agents/            # Agent directories
│           ├── health/        # agent.conf + sync.conf, layers.conf
│           ├── containerizer/ # agent.conf + python.conf, node.conf
│           ├── coder/         # agent.conf + review.conf
│           └── .../           # Each agent in own folder
│
├── containers/
│   └── distrobox.ini          # Container definitions
│
├── sources/                   # Source overlay templates
│   ├── neovim/
│   │   ├── source.conf        # Upstream URL, build deps
│   │   ├── build.sh           # Build script
│   │   ├── upstream/          # Cloned source (gitignored)
│   │   └── patches/           # Your patches
│   ├── btop/
│   │   ├── source.conf
│   │   └── build.sh
│   └── ...
│
├── extensions/                # Built overlays (gitignored)
│
├── systemd/
│   ├── powos-layer-sync.service
│   └── powos-ramboot-init.service
│
└── build/
    ├── build-iso.sh
    └── install-to-usb.sh      # Write image to USB drive
```

## Core Components

### 1. Layered RAM Boot (dracut module)

Sets up multi-layer overlayfs during initramfs:

```bash
# In ramboot-setup.sh:
mount -t overlay overlay \
    -o lowerdir=custom:updates:base,\
       upperdir=/run/powos-overlay/upper,\
       workdir=/run/powos-overlay/work \
    /merged
```

**Files:**
```
lib/dracut/90powos-ramboot/
├── module-setup.sh       # Dracut module definition
├── ramboot-setup.sh      # Layered overlayfs setup
└── powos-overlay-init.sh # Userspace init
```

### 2. Layer Sync Daemon

Python daemon that syncs RAM changes to custom layer (`lib/ramfs/layer-sync.py`):

```
lib/ramfs/layer-sync.py
├── Runs every 60 seconds
├── Translates overlayfs whiteouts (file deletions) before rsync
├── Rsyncs RAM upper → custom layer on USB
├── Excludes temp files, caches
├── Checks USB writable after sync (USB disconnect guard)
├── Flush to disk (sync) after each successful sync
├── Tracks consecutive failures, sends desktop notification at 3+
└── Honest exit codes: rsync exit 23 (partial) = FAILURE, not success
```

**State files:**
```
/run/powos/
├── ramboot-state         # Boot state (layers, RAM size)
├── layer-paths           # Paths for sync daemon
├── layer-sync-status.json  # {last_sync, consecutive_failures, errors}
└── rollback-kargs        # Rollback flags (informational only — not read at boot)
```

### 3. CacheFS (User Data) — opt-in, hardware validation pending

FUSE filesystem for lazy-loading user data with write-back to USB. **Opt-in** via `POWOS_CACHEFS_ENABLED=true` in `/etc/powos/config`. Default is direct USB bind-mount.

**Write-back engine** (in-process, no separate daemon):
- Dirty files flushed to USB every 30s via background thread
- `fsync()` from apps flushes that file to USB synchronously (durability guarantee)
- Unmount (`destroy()`) flushes all dirty files before exit
- Crash-safe: writes go to temp file + atomic rename on USB
- USB disconnect: dirty files queued in RAM, flushed on reconnect
- Desktop notifications on USB disconnect and consecutive flush failures
- Status at `/run/powos/cachefs-status.json` (dirty bytes, file count, last flush)

```
When enabled (POWOS_CACHEFS_ENABLED=true):
  IN RAM:
  ├─ File metadata ─────── ~100MB for 1M files
  └─ LRU cache ─────────── 4GB (configurable)

  ON USB (write-back):
  └─ Actual contents ───── up to 4TB
  └─ Dirty files flushed every 30s + on fsync + on unmount

  USB unplugged:
    ls ~/Documents/     → works (metadata in RAM)
    cat cached.txt      → works (in cache)
    cat uncached.txt    → error "offline"
    echo > file.txt     → works (cached, queued for USB write-back on reconnect)

Default (CacheFS disabled):
  /home is direct bind-mount from USB
  USB must be connected for home dir access
```

### 4. Chameleon Boot (Hardware Detection)

Auto-detects hardware and applies matching profile:

```
Desktop + NVIDIA → desktop-nvidia-performance
Laptop + Battery → laptop-intel-battery
Docker/VM        → virtual
```

### 5. System Overlays (systemd-sysext)

Custom binaries merged into /usr:

```bash
# Create overlay
mkdir -p sources/my-tool
cat > sources/my-tool/build.sh << 'EOF'
#!/bin/bash
mkdir -p "$OUTPUT_DIR/usr/bin"
# Build or download binary
EOF

# Build
bash lib/overlay-manager.sh build my-tool
```

**Overlay Types:**

| Type | Example | Description |
|------|---------|-------------|
| Standard | `hello-powos`, `gpu-nvidia` | Self-contained, builds independently |
| Meta-overlay | `kde` | Requires sub-argument: `kde:dolphin`, `kde:konsole` |

Meta-overlays wrap multiple related apps. During `build-all`, they're skipped gracefully with helpful output showing available sub-options.

### 6. Container Development (Podman + Distrobox)

Mutable dev containers on immutable base:

```
┌──────────────────────────────────────────────────────────────┐
│                 PowOS (immutable base)                       │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│  │  arch-dev   │  │ ubuntu-dev  │  │   fedora    │          │
│  │ (Distrobox) │  │ (Distrobox) │  │  (Podman)   │          │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘          │
│         │                │                │                  │
│         └────────────────┼────────────────┘                  │
│                          │                                   │
│              Host integration (GUI export, /home share)      │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**Distrobox containers** share your home directory and can export GUI apps:

```bash
# Create dev container
powos containers create arch-dev archlinux:latest

# Install dev tools inside
powos install -c arch-dev neovim rust gcc

# Install GUI app and export to host menu
powos install -c arch-dev -e firefox gimp

# Enter container for development
powos containers enter arch-dev
```

**Container definitions** persist in `containers/distrobox.ini`:

```ini
[arch-dev]
image=archlinux:latest
additional_packages="base-devel git neovim"

[ubuntu-dev]
image=ubuntu:22.04
additional_packages="build-essential git"
```

### 7. Development System (powos dev)

Unified system for creating new apps or customizing existing ones:

```
┌─────────────────────────────────────────────────────────────────┐
│              Project Structure                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  projects/myapp/              (new project)                      │
│  ├── src/              ← Your code (edit this)                   │
│  ├── project.conf      ← Project metadata                        │
│  └── build.sh          ← Build script                            │
│                                                                  │
│  projects/dolphin/            (forked project)                   │
│  ├── src/              ← Your modified version (edit this)       │
│  ├── upstream/         ← Original KDE source (read-only)         │
│  ├── project.conf      ← Fork metadata                           │
│  └── build.sh          ← KDE build script                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Create a new app:**
```bash
powos dev new myapp
cd /var/lib/powos/projects/myapp/src
# write your code
powos dev build myapp
powos dev enable myapp
```

**Fork and customize KDE app:**
```bash
powos dev fork kde:dolphin
cd /var/lib/powos/projects/dolphin/src
# make your changes
powos dev build dolphin
powos dev enable dolphin

# Later: pull upstream updates
powos dev update dolphin
```

**Key concepts:**
- `src/` is YOUR code - edit freely
- `upstream/` is reference only (forks)
- `powos dev update` pulls new upstream, you reapply changes
- Same workflow for new apps and forks

## Rollback Scenarios

| Command | What Happens | Use When |
|---------|--------------|----------|
| `powos rollback custom` | Skip your customizations | Package you installed broke something |
| `powos rollback updates` | Skip OS updates | OS update broke something |
| `powos rollback all` | Base OS only | Everything is broken |
| `powos rollback reset` | Use all layers | Ready to try again |

**Rollback note:** grubby failures are reported loudly. `/run/powos/rollback-kargs` is informational only — nothing reads it at boot. Verify flags took effect with `grep powos /proc/cmdline` after reboot.

## Protection Matrix

| Component | Location | USB Unplugged? |
|-----------|----------|----------------|
| Kernel | RAM | ✅ Always works |
| OS (/usr, /etc, /var) | RAM overlay | ✅ Always works |
| Running processes | RAM | ✅ Always works |
| User file metadata | RAM (CacheFS, opt-in) | ✅ Works if CacheFS enabled |
| Recently accessed files | kernel page cache | ✅ May work (kernel-dependent) |
| Home dir access | USB bind-mount (default) | ❌ Needs USB reconnect |
| Home dir access | CacheFS (opt-in) | ⚠️ Works for cached files only |
| Unaccessed user files | USB | ⏸️ Offline until reconnect |

## RAM Requirements

| Component | RAM | Purpose |
|-----------|-----|---------|
| OS overlay | 8-20 GB | Running OS + writes |
| CacheFS cache | 4 GB | Recently accessed files (only when CacheFS enabled) |
| **Minimum recommended** | **16 GB** | OS in RAM + comfortable headroom |
| **With CacheFS** | **24-32 GB** | Full unplug resilience for home dir |

## Development Workflow

### On Windows (Docker dev)
```bash
# 1. Make changes
vim bin/powos

# 2. Rebuild and test
docker compose up --build

# 3. Check status
docker exec powos powos status

# 4. Access desktop
open http://localhost:6091/vnc.html

# 5. Build the Anaconda installer ISO for real hardware
just installer      # → build/output/bootiso/install.iso
```

### On Real Hardware (Live Updates)
After booting from the ISO, the PowOS source is bundled at `/var/lib/powos/src`.
Edit source directly and apply changes without rebuilding:

```bash
# Find the source (bundled or on mounted drive)
cd /var/lib/powos/src        # Bundled source
# OR mount your original dev disk
cd /mnt/original-disk/Projects/PowOS

# Make changes
vim bin/powos

# Apply to running system immediately
powos update self
# Or from custom path:
powos update self --from /mnt/disk/Projects/PowOS

# Track your changes
git add -A && git commit -m "Fixed thing"
git push  # Push back to your repo

# Pull latest from remote
powos update self --pull
```

This enables rapid iteration on real hardware without rebuilding the ISO.

## Container Notes

**Base Image:** `ghcr.io/ublue-os/bazzite-nvidia-open:stable` (default — open NVIDIA
modules, required for RTX 50-series; overridable via `BASE_IMAGE` build ARG:
`bazzite-nvidia` = closed/older cards, `bazzite` = AMD/Intel)

**Bazzite quirks:**
- `/usr/local` doesn't exist (we create it)
- `/mnt` is a symlink (we remove and recreate)
- Use `--break-system-packages` for pip

**VNC:** TigerVNC + noVNC (software rendering)

**Ports:**
- 6091 (host) → 8443 (container): noVNC web interface (websockify)
- 5901: VNC inside the container only (not published to the host)

**Container Runtime (Podman, NOT Docker):**
- **Podman** - Daemonless, rootless by default
- `podman-docker` provides Docker CLI compatibility
- Distrobox for mutable dev containers
- fuse-overlayfs for rootless storage
- Dockerfile/Containerfile both work (Podman reads both)
- `powos ai --agent containerizer` for container help (aliases: docker, pod)

**Registries (unqualified):**
- docker.io
- ghcr.io
- quay.io

## Troubleshooting

**AI-Assisted Troubleshooting:**
```bash
powos health --ai                    # General system diagnosis
powos ai --agent health:sync "..."   # Sync conflict help
powos ai --agent health:layers "..." # Layer/rollback issues
```

**Check system status:**
```bash
powos status
powos layers
powos health                         # Health check with issues/warnings
```

**RAM boot not activating:**
```bash
cat /proc/cmdline | grep powos
# Should contain: rd.powos.ramboot=1

cat /run/powos/ramboot-state
```

**Layer sync issues:**
```bash
cat /run/powos/layer-sync-status.json
```

**CacheFS (opt-in via POWOS_CACHEFS_ENABLED=true):**
```bash
# CacheFS is mounted by bin/powos-boot at boot when
# POWOS_CACHEFS_ENABLED=true is set in /etc/powos/config (reboot to apply).
# Write-back engine flushes dirty files to USB every 30s + on fsync + on unmount.

# Debug:
blkid | grep POWOS-DATA
mount | grep cachefs
cat /run/powos/cachefs-status.json    # dirty files, last flush, errors
powos flush                           # force immediate flush of all dirty files
```

**Rollback state:**
```bash
powos rollback
# Shows current rollback flags

# If rollback not working:
grep powos /proc/cmdline          # After reboot: check flags active
which grubby && grubby --info=DEFAULT  # Check if grubby is installed
# Note: /run/powos/rollback-kargs is informational only — nothing reads it at boot
```

**RAM ↔ USB sync issues:**
```bash
# Check sync status
powos sync status

# Conflict detected?
powos sync resolve            # Interactive resolution
powos sync resolve --ai       # AI-assisted conflict resolution
powos sync --keep-ram         # Force your RAM changes to USB

# Show what's different
powos sync diff
```

**Cloud backup issues:**
```bash
# Check backup status
powos backup status

# If lock file error (interrupted backup):
rm /run/powos/sync.lock

# Check git state
cd /var/lib/powos/git && git status

# Force reset to remote:
powos backup pull --theirs
```

**Container issues:**
```bash
# List containers
powos containers list

# Check Podman storage
podman system info

# Reset Podman if corrupted
podman system reset

# Check Distrobox
distrobox list
```

**Source overlay issues:**

`powos overlay` is the front door — it delegates to `lib/overlay-manager.sh`,
which is the only thing that resolves the source tree correctly on an
installed system (the overlays ship inside the snapshot at
`/var/lib/powos/src/sources`, NOT `/var/lib/powos/sources`).

(`powos source` used to exist as an alias for `powos dev`; it was removed —
`dev` manages PROJECTS, which are a different thing from sysext overlays.)

```bash
# List overlays (+ which are built/enabled)
powos overlay list

# Build / enable / disable one
powos overlay build NAME
powos overlay enable NAME
powos overlay disable NAME

# Check if overlay is enabled
ls -la /var/lib/extensions/

# Check systemd-sysext
systemd-sysext status
systemd-sysext refresh
```


## Testing

### Tier 1 (Docker, fast)
```bash
# Run Docker test suite
docker compose up --build -d
# Tests live in the bundled source at /var/lib/powos/src/test
docker exec powos bash /var/lib/powos/src/test/tier1/test-hardware-detect.sh
docker exec powos bash /var/lib/powos/src/test/tier1/test-overlay.sh
docker exec powos bash /var/lib/powos/src/test/tier1/test-pinstall.sh
docker exec powos python3 /var/lib/powos/src/test/tier1/test-layer-sync.py   # Layer sync + whiteout tests
docker exec powos python3 /var/lib/powos/src/test/tier1/test-cachefs.py      # CacheFS unit tests
```

**What Docker covers:** Hardware detection logic, overlay build/enable/disable, package install, layer sync logic (unit tests, not real overlayfs), CacheFS unit behavior.

**What needs real hardware or VM:** Actual overlayfs RAM boot, real USB detection and sync, CacheFS FUSE mount, rollback across reboots, hardware profile application.

### Tier 2 (QEMU-KVM, boot-to-desktop)

Proves the image boots to a working KDE Plasma desktop. Runs in CI on every
PR/push (stages A-C block publish). See `test/tier2/README.md` for full docs.

```bash
# With a pre-built disk image
just test-e2e path/to/disk.qcow2

# From a container image (runs bib to produce qcow2)
just test-e2e-container localhost/powos:latest

# With ramboot regression test
just test-e2e-ramboot path/to/disk.qcow2

# Stage E: live-USB boot (plain, ramboot+POWOS-DATA, firstboot)
just test-e2e-live path/to/powos.raw

# Direct invocation with all options
./test/tier2/run.sh --image disk.qcow2 --ramboot --artifacts /tmp/results
```

**Stages:**
| Stage | What | Per-PR | Nightly |
|-------|------|--------|---------|
| A | Boot: graphical.target reached, SSH reachable | yes | yes |
| B | SDDM active, not crash-looping, screenshot non-blank | yes | yes |
| C | Autologin -> plasmashell + kwin running, stable 5s | yes | yes |
| D | Anaconda ISO unattended install, then A-C on result | no | yes |
| E | Live-USB: plain boot, ramboot+POWOS-DATA, firstboot self-complete | no | yes |
| R | Boot with `rd.powos.ramboot=1`, verify no hang | opt-in | yes |

**Named regressions caught:** hang before graphical.target, SDDM crash-loop,
session dies after login (plasmashell crash), historical ramboot hang,
live-USB boot failure, ramboot with POWOS-DATA hang, self-heal infinite loop,
firstboot self-completion failure.

**Requires:** qemu-system-x86_64, OVMF, sshpass, python3. KVM recommended
(falls back to TCG with warning). Each stage emits a verdict JSON + screenshots
+ serial log as artifacts.

## Feature Status

| Feature | Status | Notes |
|---------|--------|-------|
| Layered RAM boot | 🧪 Opt-in (off by default), HW validation pending | OS in RAM, layers from USB; **no longer baked on by default** (`powos ramboot enable`); previously broken on real hardware (NEWROOT no-op), fix awaiting validation |
| Hardware detection (17 profiles) | ✅ Implemented | Auto-selects on boot |
| Layer sync (RAM→USB, 60s) | ✅ Implemented (hardware validation pending) | Whiteout translation, USB disconnect guard, failure notifications; previously broken (`--delete-after` wipe), fix awaiting validation |
| systemd-sysext overlays | ✅ Implemented | Custom binaries merged into /usr |
| Container dev (Distrobox) | ✅ Implemented | Mutable dev containers |
| Rollback | ✅ Implemented | grubby can silently fail — verify via `/run/powos/rollback-kargs` |
| CacheFS | ⚠️ Implemented — opt-in, HW validation pending | Write-back engine flushes dirty files to USB (temp+rename crash-safe, 30s interval + fsync + unmount). Opt-in: `POWOS_CACHEFS_ENABLED=true` in `/etc/powos/config` |
| Mobile mode | ✅ Implemented (hardware validation pending) | Live bind mounts: tmpfs + per-directory bind over `/usr` `/opt` `/libexec`. No reboot. `/etc`/`var` still USB-backed. Binds lost on reboot (re-run enable). |
| Sync conflict detection | ✅ Implemented (HW validation pending) | Detection works; `--merge` does 3-way resolve: base manifest tracks last sync, changed-on-one-side taken, both-changed → newer mtime wins + `.powos-conflict-<machine>` copy; `sync resolve` lists conflicts |
| Games resize | ✅ Implemented (HW validation pending) | Grow/shrink POWOS-GAMES via ntfsresize + parted; plan display + `--dry-run`; safety: refuses if mounted, shrink requires `--yes` + ntfsfix pre-check |
| Cloud backup | ⚠️ Partial | git-based implementation exists (`lib/backup.sh`); not fully validated |
| Game-centric CLI (`powos game <name>`) | ✅ Implemented | Facade in `lib/game.sh` over the mods subsystems; `powos games` now lists games, disk work moved to `powos games storage` (bare verbs still dispatch). 83 tests. |
| Venice Unleashed (`powos mods vu`) | 🚧 Implemented, HW validation pending | BF3 community client + VEXT, under GE-Proton in its own prefix (`lib/mods/vu.sh`). Client install/activate/play, dedicated server, native `d3dcompiler_47` (needed on EVERY branch — Wine's stub renders a blank WebUI). **Server mods (`vu mod`)**: install from GitHub (`gh:owner/repo`), local zip/dir, or vumm (account-gated; no search/list — verified against the real v0.2.1 binary); mod = a `mod.json` Name, multi-mod repos let you pick (never auto-all); enable/disable/remove via ModList.txt; `update` re-fetches GitHub mods. 104 unit tests; end-to-end needs BF3 files + an EA account. |
| Agent prompts from `--help` (`!cmd`) | ✅ Implemented | `_ai_expand_prompt_cmds` in `lib/ai/agent.sh` — a `!cmd` line in a system prompt is replaced by that command's output, so agent instructions can't drift from the CLI. Timeout-capped, ANSI-stripped, failures inline. |
| Tier-2 VM testing | ✅ Implemented | QEMU-KVM boot-to-desktop: stages A (boot), B (SDDM), C (desktop), D (Anaconda install), R (ramboot regression). CI blocks publish on A-C. |
| Persistent manager (`powos ai manager`) | ✅ Implemented | Standing orchestrator: long-lived streaming `claude` session (`lib/ai/manager/`), per-directory memory (resumes by cwd), **live comms-inbox injection** (mail becomes a turn, no polling), default escalation hub. Terminal REPL + widget backend: `--once`/`--once-stdin` run one turn, `--json-events` emit a normalized event stream (assistant/tool_use/tool_result/turn_done/inbox), `--list-json` feeds the sidebar. `--safe` keeps permission prompts. 11 hermetic tests + validated against real `claude`. Also: `powos ai --continue` now resumes raw `claude` CLI sessions in the dir. |
| Manager desktop widget (`com.powos.manager`) | ✅ Implemented | Two-pane KDE plasmoid: sidebar (projects `~/Projects/*` with live-thread markers + agent roster with unread badges) and a live chat that renders the manager's `--json-events` stream as bubbles + tool panels. Picking a project switches to its per-dir thread. Thin front-end over the manager backend (transport validated end-to-end vs real `claude`); QML not statically lintable on this box (no qmllint) — verify visually on desktop. |
| Manager's TypeScript sandbox (`powos sandbox`) | ✅ Implemented (Mac; phone via `rooted.sh deploy`, unit ai-sandbox) | `lib/ai/sandbox`, ported from SpaceTimeAI's code mode: the manager's MCP tools `sandbox eval`/`declarations` run a TypeScript job type-checked against only its granted capabilities' functions, in QuickJS with a deadline, heap cap and host-call cap; no process/file/network/env. Deps inside the app (`powos sandbox setup`; the phone deploy builds them from the lock and ships them), fail closed without them. `test-sandbox.py`. |
| Inter-agent comms (`powos comms`) | ✅ Implemented | Daemonless mailbox MCP auto-wired into every `powos ai` agent (`lib/ai/comms/`). Role inboxes (spool under XDG state, no backend); tools `send_message`/`escalate`/`notify_user`/`read_inbox`/`wait_for_message` (blocking yield — no polling). Human/script CLI `powos comms send|watch|inbox|agents|notify`. 19 tier-1 tests; validated end-to-end against a real headless `claude -p`. Opt out: `POWOS_COMMS_ENABLED=0`. |

## Credentials

```
VNC Password: powos
User login:   powos / powos
```

## License

MIT
