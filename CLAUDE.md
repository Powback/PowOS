# PowOS - Technical Reference

## Quick Start

```bash
# Test in Docker (opens KDE desktop in browser)
docker compose up

# Create bootable ISO (requires podman)
just build-iso
```

Access desktop at `http://localhost:6091/vnc.html` (password: `powos`)

## Architecture Overview

PowOS has 5 layers that work together for full unplug resilience:

```
┌────────────────────────────────────────────────────────────────────┐
│                         PowOS                                       │
├────────────────────────────────────────────────────────────────────┤
│  Base: Bazzite (Fedora Atomic + Gaming Optimizations + NVIDIA)     │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Layer 1: Hardware Detection (Chameleon Boot)                       │
│           Auto-configure for any machine's GPU/power/form           │
│                                                                     │
│  Layer 2: System Overlays (systemd-sysext)                          │
│           Custom binaries without modifying immutable base OS       │
│                                                                     │
│  Layer 3: RAM Boot (dracut module)                                  │
│           Entire OS runs from RAM - USB optional after boot         │
│                                                                     │
│  Layer 4: CacheFS (FUSE lazy-loader)                                │
│           User data lazy-loaded on access, cached in RAM            │
│                                                                     │
│  Layer 5: Package Management (pinstall)                             │
│           Tracked installs, reproducible via git                    │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. RAM Boot (Layer 3) - OS Unplug Resilience

A dracut module sets up overlayfs during initramfs, BEFORE userspace starts.

**How it works:**
```
Boot sequence (in initramfs):
1. Kernel loads, initramfs runs
2. Dracut module 90powos-ramboot activates
3. Creates tmpfs (8GB default) at /run/powos-overlay
4. Mounts USB root as read-only lower layer
5. Sets up overlayfs with RAM upper layer
6. pivot_root to the overlay
7. ENTIRE OS NOW RUNS FROM RAM

Result:
- All of /usr, /etc, /var → in RAM
- All writes → go to RAM
- USB can be unplugged → OS keeps running
```

**Kernel cmdline args:**
```
rd.powos.ramboot=1      # Enable RAM boot
rd.powos.ramsize=8G     # RAM allocation (default 8G)
```

**Files:**
```
lib/dracut/90powos-ramboot/
├── module-setup.sh       # Dracut module definition
├── ramboot-setup.sh      # Pre-pivot hook (sets up overlayfs)
└── powos-overlay-init.sh # Userspace init (sync daemon)

config/bootc/kargs.d/
└── 50-powos-ramboot.toml # Kernel cmdline args for bootc
```

### 2. CacheFS (Layer 4) - User Data Lazy Loading

User data can be terabytes - can't fit in RAM. CacheFS solves this with lazy loading.

**How it works:**
```
┌─────────────────────────────────────────────────────────────────┐
│                /home/powos (what you see)                        │
│                         │                                        │
│                    CacheFS FUSE                                  │
│                    /           \                                 │
│                   /             \                                │
│         RAM Cache (4GB)    USB Backing Store (4TB)               │
│         LRU eviction       Lazy-loaded on access                 │
└─────────────────────────────────────────────────────────────────┘

IN RAM (always):
├─ File metadata (names, sizes, perms) ─── ~100MB for 1M files
└─ LRU cache of accessed files ─────────── 4GB (configurable)

ON USB (lazy-loaded):
└─ Actual file contents ────────────────── up to 4TB

Access pattern:
  cat ~/Documents/report.pdf
  1. Metadata lookup → instant (RAM)
  2. Check cache → miss
  3. Load from USB → ~100ms
  4. Store in cache
  5. Serve from RAM → instant
  6. File stays cached (LRU eviction if full)

USB unplugged:
  ls ~/Documents/     → works (metadata in RAM)
  cat cached.txt      → works (in RAM cache)
  cat uncached.txt    → error "offline"
```

**Files:**
```
lib/cachefs/
├── powos-cachefs.py    # FUSE filesystem implementation
└── cachefs-sync.py     # Sync daemon for dirty files
```

**Configuration:**
```bash
POWOS_CACHE_SIZE=4G     # RAM cache size (default 4G)
```

### 3. Chameleon Boot (Layer 1) - Hardware Detection

Automatic hardware detection and profile application.

**Detection:**
```
GPU:    nvidia, amd, intel, virtual
Power:  ac, battery
Form:   desktop, laptop, tablet
Virt:   physical, kvm, vmware, docker
```

**Profiles (`config/profiles/`):**
| Profile | GPU | Power | Configuration |
|---------|-----|-------|---------------|
| desktop-nvidia-performance | NVIDIA | AC | Full GPU, persistence mode |
| laptop-nvidia-battery | NVIDIA | Battery | GPU sleep, iGPU active |
| laptop-intel-battery | Intel | Battery | Aggressive power saving |
| virtual | Any | Any | Minimal, no hardware polling |

**Files:**
```
lib/hardware-detect.sh      # Detection logic
config/profiles/*.conf      # Profile configurations
```

### 4. System Overlays (Layer 2) - Custom Binaries

Custom binaries via systemd-sysext without modifying base OS.

**Creating an overlay:**
```bash
mkdir -p sources/my-tool
cat > sources/my-tool/build.sh << 'EOF'
#!/bin/bash
mkdir -p "$OUTPUT_DIR/usr/bin"
curl -o "$OUTPUT_DIR/usr/bin/my-tool" https://example.com/my-tool
chmod +x "$OUTPUT_DIR/usr/bin/my-tool"
EOF
```

**Building:**
```bash
bash lib/overlay-manager.sh build my-tool
bash lib/overlay-manager.sh build-all
```

**Existing overlays:**
- `gpu-nvidia` - NVIDIA configuration, udev rules
- `gpu-amd` - AMD configuration
- `gpu-intel` - Intel configuration
- `device-steamdeck` - Steam Deck support
- `device-rog-ally` - ROG Ally support
- `hello-powos` - Example overlay

## Directory Structure

```
PowOS/
├── Containerfile              # THE OS definition
├── docker-compose.yml         # Test environment
├── justfile                   # Build commands
│
├── bin/                       # User commands
│   ├── powos-boot             # Main boot script
│   ├── powos                  # CLI (status, sync)
│   └── pinstall               # Install + git commit
│
├── lib/
│   ├── hardware-detect.sh     # Chameleon Boot (Layer 1)
│   ├── overlay-manager.sh     # systemd-sysext builder (Layer 2)
│   ├── dracut/                # RAM boot (Layer 3)
│   │   └── 90powos-ramboot/
│   │       ├── module-setup.sh
│   │       ├── ramboot-setup.sh
│   │       └── powos-overlay-init.sh
│   ├── cachefs/               # User data lazy-loader (Layer 4)
│   │   ├── powos-cachefs.py
│   │   └── cachefs-sync.py
│   └── ramfs/                 # Legacy overlay system
│
├── config/
│   ├── profiles/              # Hardware profiles
│   ├── bootc/                 # Boot configuration
│   └── ramboot.conf           # RAM boot config
│
├── sources/                   # Overlay source code
│   ├── gpu-nvidia/
│   ├── gpu-amd/
│   ├── device-steamdeck/
│   └── ...
│
├── systemd/                   # Boot services
│   └── powos-ramboot-init.service
│
└── build/
    ├── build-iso.sh           # ISO creation
    └── output/                # Built ISOs
```

## Boot Sequence Detail

```
1. UEFI loads kernel + initramfs from USB

2. Dracut module (90powos-ramboot) runs:
   └─ Creates 8GB tmpfs
   └─ Mounts USB as read-only lower
   └─ Sets up overlayfs
   └─ Writes /run/powos/ramboot-state
   └─ pivot_root to overlay
   → OS NOW RUNS FROM RAM

3. Hardware Detection
   └─ /usr/lib/powos/powos-hardware-detect
   └─ Applies profile from config/profiles/

4. System Overlays
   └─ /usr/lib/powos/powos-overlay-load
   └─ Enables sysext from /var/lib/extensions

5. CacheFS for User Data
   └─ Detects USB with label POWOS-DATA
   └─ Starts CacheFS FUSE at /home/powos
   └─ Scans metadata to RAM
   └─ Starts sync daemon

6. Desktop Environment
   └─ Creates user "powos"
   └─ Starts TigerVNC + noVNC
   └─ KDE Plasma ready
```

## What's Protected When USB Unplugged

| Component | Location | Unplug Safe? |
|-----------|----------|--------------|
| Kernel | RAM | ✓ Always |
| OS (/usr, /etc, /var) | RAM (overlayfs) | ✓ Always |
| Running processes | RAM | ✓ Always |
| User file metadata | RAM (CacheFS) | ✓ Always |
| Recently accessed files | RAM (LRU cache) | ✓ Always |
| Unaccessed user files | USB | ✗ Offline until reconnect |

**Full protection requires:**
- 8-20GB RAM for OS overlay
- 4GB RAM for user file cache
- Total: 16-32GB recommended

## USB Drive Layout

```
USB SSD (e.g., Lexar NM790 4TB)
├── Partition 1: EFI (512MB, FAT32)
├── Partition 2: PowOS System (100GB, BTRFS)
│   └── Base OS, overlays, state
└── Partition 3: User Data (remainder, BTRFS)
    └─ Label: POWOS-DATA (auto-detected)
```

## Environment Variables

```bash
# RAM Boot
rd.powos.ramboot=1          # Enable (kernel cmdline)
rd.powos.ramsize=8G         # RAM allocation (kernel cmdline)

# CacheFS
POWOS_CACHE_SIZE=4G         # User data cache size

# Hardware simulation (testing)
POWOS_MOCK_HARDWARE=nvidia  # Simulate GPU
POWOS_MOCK_POWER=ac         # Simulate power source
```

## CLI Commands

```bash
powos status    # Full system status (OS mode, CacheFS, USB)
powos sync      # Force sync to USB
powos hardware  # Show detected hardware
```

**Example output:**
```
PowOS Status
============

Operating System
  Mode:       ● FULL RAM BOOT
              Entire OS running from RAM
  RAM:        8G allocated
  Used:       1.2G (changes since boot)

User Data (/home)
  Mode:       ● CacheFS (lazy-load)
              Files load on-demand, cached in RAM
  Cache:      847M in RAM

USB Drive
  Status:     ● Connected
  Last Sync:  30s ago

Unplug Safety
  ✓ FULLY PROTECTED
    USB can be unplugged anytime!
```

## Container-Specific Notes

**Base Image:** `ghcr.io/ublue-os/bazzite-nvidia:stable`

Bazzite quirks:
- `/usr/local` doesn't exist by default (we create it)
- `/mnt` is a symlink (we remove and recreate it)
- Use `--break-system-packages` for pip

**VNC Setup:**
- TigerVNC + noVNC (not KasmVNC - too many issues)
- Software rendering forced (`LIBGL_ALWAYS_SOFTWARE=1`)

**Ports:**
```
5901: VNC direct (TigerVNC)
6091: noVNC web interface
```

## Troubleshooting

**Check system status:**
```bash
powos status
```

**RAM boot not activating:**
```bash
# Check kernel cmdline
cat /proc/cmdline | grep powos
# Should contain: rd.powos.ramboot=1

# Check ramboot state
cat /run/powos/ramboot-state
```

**CacheFS not working:**
```bash
# Check USB detection
blkid | grep POWOS-DATA

# Check FUSE mount
mount | grep cachefs

# Check CacheFS status
cat /run/powos/cachefs-status.json
```

**Desktop issues:**
```bash
docker compose logs powos | tail -50
```

## Key Design Decisions

1. **Dracut module for RAM boot**: Sets up overlayfs in initramfs before userspace, ensuring entire OS is in RAM from the start
2. **CacheFS (FUSE) for user data**: Lazy-loading allows terabytes of data with only gigabytes of RAM
3. **LRU cache eviction**: Hot files stay in RAM, cold files evicted automatically
4. **Metadata always in RAM**: `ls` and `find` always work, even offline
5. **Two-layer architecture**: OS overlay (kernel) + user data (FUSE) = complete coverage
6. **Bazzite base**: Gaming-optimized, NVIDIA drivers, immutable filesystem

## Development Workflow

```bash
# 1. Make changes
vim lib/cachefs/powos-cachefs.py

# 2. Rebuild and test
docker compose up --build

# 3. Check status
docker exec powos powos status

# 4. Access desktop
open http://localhost:6091/vnc.html

# 5. Build ISO for real hardware
just build-iso
```

## Credentials

```
VNC Password: powos
User login:   powos / powos
```

## License

MIT
