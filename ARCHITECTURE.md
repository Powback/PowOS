# PowOS System Architecture

> How all the pieces fit together

## The Big Picture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              USB SSD (4TB)                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│  Partition 1: EFI (512MB)      │ UEFI bootloader                            │
│  Partition 2: System (100GB)   │ Bazzite OS base image                      │
│  Partition 3: Data (remainder) │ Label: POWOS-DATA                          │
│    ├─ layers/custom/           │ Your packages, configs (persistent)        │
│    ├─ layers/updates/          │ OS updates (separate from custom)          │
│    └─ home/                    │ User data (CacheFS source)                 │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Core Concept: Layered Persistence

Unlike traditional "immutable" systems, PowOS uses **layered persistence with independent rollback**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         LAYER STACK (top to bottom)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐                                                         │
│  │   RAM (upper)   │ ← All writes go here first (instant, volatile)          │
│  └────────┬────────┘                                                         │
│           │ layer-sync daemon (every 60s)                                    │
│           ▼                                                                  │
│  ┌─────────────────┐                                                         │
│  │  Custom Layer   │ ← Your packages, configs (persists across reboots)      │
│  │  (read-only)    │   Location: /mnt/powos-usb/layers/custom/               │
│  └────────┬────────┘   Rollback: rd.powos.skip.custom=1                      │
│           │                                                                  │
│  ┌─────────────────┐                                                         │
│  │  Updates Layer  │ ← OS updates (separate from your stuff)                 │
│  │  (read-only)    │   Location: /mnt/powos-usb/layers/updates/              │
│  └────────┬────────┘   Rollback: rd.powos.skip.updates=1                     │
│           │                                                                  │
│  ┌─────────────────┐                                                         │
│  │   Base Layer    │ ← Original Bazzite image (never modified)               │
│  │  (read-only)    │   Location: System partition                            │
│  └─────────────────┘                                                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

How overlayfs merges them:
  - Read: Check RAM → Custom → Updates → Base (first match wins)
  - Write: Always goes to RAM upper layer
  - Result: You see a unified filesystem
```

## Boot Sequence

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           BOOT SEQUENCE                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. INITRAMFS (dracut module: 90powos-ramboot)                               │
│     ├─ Create 8GB+ tmpfs for RAM upper layer                                 │
│     ├─ Mount USB data partition                                              │
│     ├─ Stack layers: custom:updates:base (skip if rollback flags set)        │
│     ├─ Mount overlayfs as new root                                           │
│     └─ ENTIRE OS NOW IN RAM                                                  │
│                                    │                                         │
│  2. HARDWARE DETECTION (Chameleon Boot)                                      │
│     ├─ Detect: GPU (nvidia/amd/intel) + Power (ac/battery) + Form           │
│     └─ Apply: config/profiles/desktop-nvidia-performance.conf               │
│                                    │                                         │
│  3. SYSTEM OVERLAYS (systemd-sysext)                                         │
│     ├─ Load extensions from /var/lib/extensions/                            │
│     └─ Merge custom binaries into /usr                                      │
│                                    │                                         │
│  4. LAYER SYNC DAEMON                                                        │
│     ├─ Start layer-sync.py (syncs RAM → custom layer)                       │
│     └─ Runs every 60 seconds                                                │
│                                    │                                         │
│  5. CACHEFS (User Data)                                                      │
│     ├─ Mount /home/powos via FUSE                                           │
│     ├─ Metadata always in RAM                                                │
│     └─ File contents lazy-loaded on access                                  │
│                                    │                                         │
│  6. DESKTOP                                                                  │
│     └─ KDE Plasma                                                           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Layer 1: Layered RAM Boot (Dracut Module)

**Purpose:** Run entire OS from RAM with persistent layers that can be independently rolled back.

### How It Works

The dracut module (`90powos-ramboot`) runs during initramfs:

```bash
# Kernel command line options:
rd.powos.ramboot=1        # Enable layered RAM boot
rd.powos.ramsize=8G       # RAM allocation (default 8G)
rd.powos.skip.custom=1    # ROLLBACK: Skip custom layer
rd.powos.skip.updates=1   # ROLLBACK: Skip updates layer
```

### The Overlay Stack

```
┌─────────────────────────────────────────────────────────────────┐
│                    OVERLAYFS CONFIGURATION                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  mount -t overlay overlay \                                      │
│    -o lowerdir=custom:updates:base,\                             │
│       upperdir=/run/powos-overlay/upper,\                        │
│       workdir=/run/powos-overlay/work \                          │
│    /merged                                                       │
│                                                                  │
│  Priority (highest to lowest):                                   │
│    1. RAM upper     - writes land here                           │
│    2. Custom layer  - your persistent changes                    │
│    3. Updates layer - OS updates                                 │
│    4. Base layer    - original Bazzite                           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Rollback Scenarios

```
┌─────────────────────────────────────────────────────────────────┐
│  Normal Boot                                                     │
│    Layers: RAM → Custom → Updates → Base                         │
│    You see: All your customizations + updates + base OS          │
├─────────────────────────────────────────────────────────────────┤
│  powos rollback custom (rd.powos.skip.custom=1)                  │
│    Layers: RAM → Updates → Base                                  │
│    You see: Updates + base OS (your customizations hidden)       │
│    Use when: A package you installed broke something             │
├─────────────────────────────────────────────────────────────────┤
│  powos rollback updates (rd.powos.skip.updates=1)                │
│    Layers: RAM → Custom → Base                                   │
│    You see: Your customizations + base OS (updates hidden)       │
│    Use when: An OS update broke something                        │
├─────────────────────────────────────────────────────────────────┤
│  powos rollback all (both flags)                                 │
│    Layers: RAM → Base                                            │
│    You see: Clean base OS only                                   │
│    Use when: Everything is broken, need clean slate              │
└─────────────────────────────────────────────────────────────────┘
```

### Files

```
lib/dracut/90powos-ramboot/
├── module-setup.sh       # Dracut module definition
├── ramboot-setup.sh      # Sets up layered overlayfs
└── powos-overlay-init.sh # Userspace initialization

lib/ramfs/
├── layer-sync.py         # Syncs RAM → custom layer (every 60s)
└── overlay-mount.sh      # Legacy overlay utilities

/run/powos/
├── ramboot-state         # Current boot state (layers, RAM size)
├── layer-paths           # Paths for sync daemon
├── layer-sync-status.json # Sync daemon status
└── rollback-kargs        # Pending rollback flags
```

## Layer 2: Hardware Detection (Chameleon Boot)

**Purpose:** Automatically configure system based on detected hardware.

```
Boot on Desktop with RTX 3090:
  GPU=nvidia, Power=ac, Form=desktop
  → Profile: desktop-nvidia-performance
  → NVIDIA persistence mode ON, full power

Boot on Laptop with Intel on battery:
  GPU=intel, Power=battery, Form=laptop
  → Profile: laptop-intel-battery
  → Aggressive power saving, screen dimming

Boot in Docker/VM:
  GPU=virtual, Power=ac, Form=desktop
  → Profile: virtual
  → No hardware polling, minimal config
```

**Files:**
```
lib/hardware-detect.sh           # Detection logic
config/profiles/*.conf           # Profile configurations (16 profiles)
/run/powos/hardware              # Runtime state
```

## Layer 3: System Overlays (systemd-sysext)

**Purpose:** Add custom binaries to base OS without modifying it.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Base OS (Bazzite)                             │
│                    IMMUTABLE - cannot modify                     │
└─────────────────────────────────────────────────────────────────┘
                              +
┌─────────────────────────────────────────────────────────────────┐
│                 System Extensions (sysext)                       │
│  extensions/gpu-nvidia/usr/bin/nvidia-smi                       │
│  extensions/hello-powos/usr/bin/hello-powos                     │
└─────────────────────────────────────────────────────────────────┘
                              ↓
              systemd-sysext merge
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    Merged /usr                                   │
│  Base OS binaries + Extension binaries                          │
└─────────────────────────────────────────────────────────────────┘
```

**Files:**
```
sources/                         # Overlay source code
├── gpu-nvidia/build.sh
├── gpu-amd/build.sh
├── device-steamdeck/build.sh
└── hello-powos/build.sh

extensions/                      # Built overlays (gitignored)
lib/overlay-manager.sh           # Build/enable/disable overlays
```

## Layer 4: CacheFS (Lazy-Loading User Data)

**Purpose:** User data (terabytes) can't fit in RAM. CacheFS lazy-loads files on access.

```
┌─────────────────────────────────────────────────────────────────┐
│                    CacheFS Architecture                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   IN RAM (always):                                               │
│   ├─ File METADATA (names, sizes, perms) ─── ~100MB for 1M files│
│   └─ LRU CACHE of accessed files ─────────── 4GB default        │
│                                                                  │
│   ON USB (lazy-loaded):                                          │
│   └─ Actual file contents ────────────────── 4TB                 │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   USB unplugged:                                                 │
│   - ls ~/Documents/ ─────────────────────── works (metadata RAM) │
│   - cat cached-file.txt ─────────────────── works (in cache)     │
│   - cat uncached-file.txt ───────────────── error "offline"      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Files:**
```
lib/cachefs/
├── powos-cachefs.py    # FUSE filesystem implementation
└── cachefs-sync.py     # Sync daemon for dirty files
```

## Layer 5: Package Management (pinstall)

**Purpose:** Install packages AND track them in git for reproducibility.

```
┌─────────────────────────────────────────────────────────────────┐
│                         pinstall neovim                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   1. INSTALL                                                     │
│      └─ dnf install neovim                                       │
│      └─ Goes to RAM upper layer → syncs to custom layer          │
│                                                                  │
│   2. RECORD                                                      │
│      └─ Add "neovim" to containers/distrobox.ini                │
│                                                                  │
│   3. COMMIT                                                      │
│      └─ git commit -m "pinstall: neovim"                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Layer 6: Container Development (Podman + Distrobox)

**Purpose:** Mutable development environments on top of the immutable base OS.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Container Architecture                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  PowOS (Immutable Base)                                          │
│  ├─ Bazzite + Layered Persistence                               │
│  └─ Podman (rootless, daemonless)                               │
│         │                                                        │
│         ├─ Distrobox Containers (mutable dev environments)       │
│         │   ├─ powos-dev (Arch Linux)                           │
│         │   │   └─ Install anything: neovim, rust, go, etc.     │
│         │   ├─ powos-node (Node.js 20)                          │
│         │   ├─ powos-python (Python 3.12 + ML libs)             │
│         │   └─ powos-build (Fedora build tools)                 │
│         │                                                        │
│         └─ OCI Containers (standard Podman)                      │
│             └─ Run any Docker/OCI image                         │
│                                                                  │
│  Key Benefits:                                                   │
│  ├─ Rootless: No daemon, no root required                       │
│  ├─ Integrated: Containers share home, GPU, audio               │
│  ├─ Persistent: Containers survive reboots                      │
│  └─ Exportable: Apps from containers appear in host menu        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Files:**
```
containers/
└── distrobox.ini         # Predefined container configurations

Config files installed:
/etc/containers/registries.conf.d/00-powos.conf    # Registry config
/etc/containers/storage.conf.d/00-powos.conf       # Storage config
```

## CLI Commands

### Status & Info
```bash
powos status          # Full system status (layers, RAM, USB, protection)
powos layers          # Detailed layer stack view
powos layers status   # Same as above
powos hardware        # Show detected hardware
powos version         # Show version and active layers
```

### Layer Management
```bash
powos layers sync     # Force sync RAM → custom layer
powos layers clear custom   # Clear custom layer entirely
powos layers clear updates  # Clear updates layer entirely
```

### Rollback
```bash
powos rollback                # Show rollback options
powos rollback custom         # Skip custom layer on next boot
powos rollback updates        # Skip updates layer on next boot
powos rollback all            # Boot with base only
powos rollback reset          # Clear all rollback flags
```

### Updates
```bash
powos update          # Check for OS updates
powos update os       # Apply OS updates (to updates layer)
powos update packages # Apply package updates (to custom layer)
powos update apply    # Apply all updates
```

### Containers
```bash
powos containers              # List all containers and images
powos containers create NAME  # Create new distrobox container
powos containers enter NAME   # Enter a container
powos containers stop NAME    # Stop a container
powos containers remove NAME  # Remove a container
powos containers assemble     # Create all predefined containers
powos containers export NAME APP  # Export app to host menu
powos containers prune        # Clean up unused resources
powos containers podman ARGS  # Pass through to podman
```

### Sync & Safety
```bash
powos sync            # Force sync all changes to USB
powos safe            # Check if safe to unplug USB
```

## USB Storage Layout

```
POWOS-DATA partition (BTRFS):
├── layers/
│   ├── custom/           # Your packages, configs, customizations
│   │   ├── usr/          # Modified system files
│   │   ├── etc/          # Modified configs
│   │   └── var/          # Modified state
│   └── updates/          # OS updates (separate from custom)
│       ├── usr/
│       ├── etc/
│       └── var/
├── home/                 # User data (CacheFS source)
│   └── powos/
│       ├── Documents/
│       ├── Projects/
│       └── ...
└── state/                # PowOS state files
```

## RAM Requirements

| Component | RAM | Purpose |
|-----------|-----|---------|
| OS overlay (tmpfs) | 8-20 GB | Running OS + writes |
| CacheFS cache | 4 GB | Recently accessed files |
| **Recommended** | **16-32 GB** | Full unplug resilience |

## Recovery Flow (15-Minute Phoenix)

```
USB drive dies/lost/stolen
         │
         ▼
┌─────────────────────────────────────────┐
│  1. Boot any Linux (live USB, etc)      │
│  2. git clone github.com/YOU/powos      │
│  3. just hydrate                        │
│  4. just build-iso                      │
│  5. dd to new USB                       │
│  6. Boot - everything's back            │
└─────────────────────────────────────────┘
```

## File Structure Summary

```
PowOS/
├── Containerfile              # THE OS definition
├── docker-compose.yml         # Development testing
├── justfile                   # Command runner
│
├── bin/
│   ├── powos                  # CLI (status, layers, rollback, update)
│   ├── powos-boot             # Boot orchestrator
│   ├── pinstall               # Package + git commit
│   └── powos-init-usb         # Initialize USB drive
│
├── lib/
│   ├── hardware-detect.sh     # Chameleon Boot
│   ├── overlay-manager.sh     # systemd-sysext builder
│   ├── dracut/
│   │   └── 90powos-ramboot/   # Layered RAM boot module
│   ├── ramfs/
│   │   └── layer-sync.py      # RAM → custom layer sync
│   └── cachefs/
│       ├── powos-cachefs.py   # FUSE filesystem
│       └── cachefs-sync.py    # User data sync
│
├── config/
│   ├── profiles/              # Hardware profiles (16)
│   └── bootc/kargs.d/         # Kernel arguments
│
├── sources/                   # Overlay source code
│   ├── gpu-nvidia/
│   ├── gpu-amd/
│   └── ...
│
├── systemd/
│   ├── powos-layer-sync.service  # Layer sync daemon
│   └── powos-ramboot-init.service
│
└── build/
    ├── build-iso.sh           # Create bootable ISO
    └── powos-init-usb.sh      # USB initialization script
```

## Quick Reference

| Feature | Command | Description |
|---------|---------|-------------|
| Check status | `powos status` | Layers, RAM, USB, protection level |
| View layers | `powos layers` | Layer stack with sizes |
| Force sync | `powos sync` | Sync RAM to USB immediately |
| Rollback custom | `powos rollback custom` | Skip your customizations next boot |
| Rollback updates | `powos rollback updates` | Skip OS updates next boot |
| Clear rollback | `powos rollback reset` | Use all layers next boot |
| Check updates | `powos update` | Check for available updates |
| Apply updates | `powos update apply` | Download and apply updates |
| Install package | `pinstall <pkg>` | Install + record + commit |
| Init USB | `powos-init-usb /dev/sdX` | Prepare USB drive |
