# PowOS - Technical Reference

## Quick Start

```bash
# Test in Docker (opens KDE desktop in browser)
docker compose up

# Create bootable ISO (requires podman)
just build-iso
```

Access desktop at `http://localhost:6091/vnc.html` (password: `powos`)

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

## CLI Commands

### Status & Info
```bash
powos status          # Full status (layers, RAM, USB, protection)
powos layers          # Detailed layer stack with sizes
powos layers status   # Same as above
powos hardware        # Show detected hardware
powos version         # Show version and active layers
```

### Layer Management
```bash
powos layers sync           # Force sync RAM → custom layer
powos layers clear custom   # Clear custom layer entirely
powos layers clear updates  # Clear updates layer entirely
```

### Rollback
```bash
powos rollback              # Show rollback options
powos rollback custom       # Skip custom layer on next boot
powos rollback updates      # Skip updates layer on next boot
powos rollback all          # Boot with base only
powos rollback reset        # Clear all rollback flags
```

### Updates
```bash
powos update          # Check for OS updates
powos update apply    # Apply updates to updates layer
```

### Sync & Safety
```bash
powos sync            # Force sync all changes to USB
powos safe            # Check if safe to unplug USB
```

### Package Installation
```bash
powos install PKG...              # Install to custom layer
powos install -c NAME PKG...      # Install to container NAME
powos install -c NAME -e PKG...   # Install + export GUI apps to host
```

### Container Management
```bash
powos containers list             # List all containers
powos containers create NAME IMG  # Create new container
powos containers enter NAME       # Enter container shell
powos containers remove NAME      # Remove container
powos containers export NAME APP  # Export GUI app to host menu
powos containers assemble         # Create from distrobox.ini
powos containers prune            # Clean up unused images
```

### Build from Dockerfile
```bash
powos build                       # Build from ./Dockerfile
powos build -f FILE               # Build from specific file
powos build -t TAG                # Build with tag
powos build -t myapp:v1 ./dir     # Full example
```

### Source Overlays
```bash
powos source list                 # List all source overlays
powos source new NAME             # Create new source template
powos source get NAME             # Fetch upstream source
powos source patch NAME           # Apply patches to upstream
powos source build NAME           # Build overlay from source
powos source enable NAME          # Enable (override system version)
powos source disable NAME         # Disable (restore system version)
```

## Example Output

**powos status:**
```
PowOS Status
════════════════════════════════════════

Active Layers
  Stack:      custom,updates,base
              ├─ ● custom (your packages & configs)
              ├─ ● updates (OS updates)
              └─ ● base (Bazzite)

RAM Overlay
  Mode:       ● Running from RAM
  Allocated:  8G
  Used:       1.2G (changes since boot)

User Data (/home)
  Mode:       ● CacheFS (lazy-load)
  Cached:     142 files

USB Drive
  Status:     ● Connected
  Last Sync:  30s ago

Unplug Safety
  ✓ FULLY PROTECTED
    USB can be unplugged anytime!
```

**powos layers:**
```
Layer Stack
════════════════════════════════════════

  Writes → [RAM Upper] → sync → [Custom Layer] → USB

  Lower layers (read-only at runtime):
    ● custom    - Your packages, configs, customizations
                  Size: 2.1G
    ● updates   - OS updates
                  Size: 156M
    ● base      - Bazzite OS image

  RAM Upper (writes since boot):
    Files changed: 47
    Size: 89M
```

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

6. CacheFS for User Data
   └─ FUSE mount at /home/powos
   └─ Metadata always in RAM
   └─ Contents lazy-loaded

7. Desktop Environment
   └─ KDE Plasma ready
```

## Kernel Command Line Args

```bash
rd.powos.ramboot=1        # Enable layered RAM boot
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
│   ├── pinstall               # Install + git commit
│   └── powos-init-usb         # Initialize USB drive
│
├── lib/
│   ├── hardware-detect.sh     # Chameleon Boot
│   ├── overlay-manager.sh     # systemd-sysext builder
│   ├── dracut/
│   │   └── 90powos-ramboot/
│   │       ├── module-setup.sh
│   │       ├── ramboot-setup.sh      # Layered overlayfs setup
│   │       └── powos-overlay-init.sh
│   ├── ramfs/
│   │   └── layer-sync.py      # Syncs RAM → custom layer
│   └── cachefs/
│       ├── powos-cachefs.py   # FUSE filesystem
│       └── cachefs-sync.py    # User data sync
│
├── config/
│   ├── profiles/              # Hardware profiles (16)
│   └── bootc/kargs.d/         # Kernel arguments
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
    └── powos-init-usb.sh
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

Python daemon that syncs RAM changes to custom layer:

```
lib/ramfs/layer-sync.py
├── Runs every 60 seconds
├── Rsyncs RAM upper → custom layer on USB
├── Excludes temp files, caches
└── Handles USB disconnect/reconnect
```

**State files:**
```
/run/powos/
├── ramboot-state         # Boot state (layers, RAM size)
├── layer-paths           # Paths for sync daemon
├── layer-sync-status.json
└── rollback-kargs        # Pending rollback flags
```

### 3. CacheFS (User Data)

FUSE filesystem for lazy-loading terabytes of user data:

```
IN RAM (always):
├─ File metadata ─────── ~100MB for 1M files
└─ LRU cache ─────────── 4GB (configurable)

ON USB (lazy-loaded):
└─ Actual contents ───── up to 4TB

USB unplugged:
  ls ~/Documents/     → works (metadata RAM)
  cat cached.txt      → works (in cache)
  cat uncached.txt    → error "offline"
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

### 7. Source Overlays (Custom App Builds)

Override system apps with custom builds:

```
┌─────────────────────────────────────────────────────────────────┐
│              Source Overlay Workflow                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  sources/neovim/                                                 │
│  ├── source.conf      ← UPSTREAM_URL, BUILD_DEPS                 │
│  ├── build.sh         ← Compile instructions                     │
│  ├── upstream/        ← Git clone (powos source get)             │
│  └── patches/         ← Your customizations                      │
│        ├── 001-my-feature.patch                                  │
│        └── 002-fix-something.patch                               │
│                                                                  │
│  powos source get neovim     →  Clone upstream                   │
│  powos source patch neovim   →  Apply patches/                   │
│  powos source build neovim   →  Run build.sh → extensions/       │
│  powos source enable neovim  →  systemd-sysext merge             │
│                                                                  │
│  Result: Your custom neovim at /usr/bin/nvim                     │
│          System version masked until disable                     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Example source.conf:**
```bash
# sources/neovim/source.conf
DESCRIPTION="Custom Neovim build with your patches"
UPSTREAM_URL="https://github.com/neovim/neovim"
UPSTREAM_BRANCH="stable"
BUILD_DEPS="cmake make gcc g++ unzip gettext curl"
RUNTIME_DEPS=""
```

**Example build.sh:**
```bash
#!/bin/bash
OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
cd "$SRC_DIR/upstream"
make CMAKE_BUILD_TYPE=Release CMAKE_INSTALL_PREFIX=/usr
make install DESTDIR="$OUTPUT_DIR"
```

**Workflow:**
```bash
# 1. Create source template
powos source new my-app

# 2. Edit source.conf with upstream URL

# 3. Fetch source
powos source get my-app

# 4. Make changes, create patches
cd sources/my-app/upstream
# edit files...
git diff > ../patches/001-my-change.patch

# 5. Build
powos source build my-app

# 6. Enable (overrides system version)
powos source enable my-app

# 7. Later: disable to restore system version
powos source disable my-app
```

## Rollback Scenarios

| Command | What Happens | Use When |
|---------|--------------|----------|
| `powos rollback custom` | Skip your customizations | Package you installed broke something |
| `powos rollback updates` | Skip OS updates | OS update broke something |
| `powos rollback all` | Base OS only | Everything is broken |
| `powos rollback reset` | Use all layers | Ready to try again |

## Protection Matrix

| Component | Location | USB Unplugged? |
|-----------|----------|----------------|
| Kernel | RAM | ✅ Always works |
| OS (/usr, /etc, /var) | RAM overlay | ✅ Always works |
| Running processes | RAM | ✅ Always works |
| User file metadata | RAM (CacheFS) | ✅ Always works |
| Recently accessed files | RAM cache | ✅ Always works |
| Unaccessed user files | USB | ⏸️ Offline until reconnect |

## RAM Requirements

| Component | RAM | Purpose |
|-----------|-----|---------|
| OS overlay | 8-20 GB | Running OS + writes |
| CacheFS cache | 4 GB | Recently accessed files |
| **Recommended** | **16-32 GB** | Full unplug resilience |

## Development Workflow

```bash
# 1. Make changes
vim bin/powos

# 2. Rebuild and test
docker compose up --build

# 3. Check status
docker exec powos powos status
docker exec powos powos layers

# 4. Access desktop
open http://localhost:6091/vnc.html

# 5. Build ISO for real hardware
just build-iso
```

## Container Notes

**Base Image:** `ghcr.io/ublue-os/bazzite-nvidia:stable`

**Bazzite quirks:**
- `/usr/local` doesn't exist (we create it)
- `/mnt` is a symlink (we remove and recreate)
- Use `--break-system-packages` for pip

**VNC:** TigerVNC + noVNC (software rendering)

**Ports:**
- 5901: VNC direct
- 6091: noVNC web interface

**Container Runtime:**
- Podman (daemonless, rootless)
- `podman-docker` provides Docker CLI compatibility
- Distrobox for mutable dev containers
- fuse-overlayfs for rootless storage

**Registries (unqualified):**
- docker.io
- ghcr.io
- quay.io

## Troubleshooting

**Check system status:**
```bash
powos status
powos layers
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

**CacheFS not working:**
```bash
blkid | grep POWOS-DATA
mount | grep cachefs
cat /run/powos/cachefs-status.json
```

**Rollback state:**
```bash
powos rollback
# Shows current rollback flags
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
```bash
# List overlays
powos source list

# Check if overlay is enabled
ls -la /var/lib/extensions/

# Rebuild overlay
powos source build NAME

# Check systemd-sysext
systemd-sysext status
systemd-sysext refresh
```

## Credentials

```
VNC Password: powos
User login:   powos / powos
```

## License

MIT
