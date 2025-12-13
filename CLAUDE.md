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

```
┌────────────────────────────────────────────────────────────────────┐
│                         PowOS                                       │
├────────────────────────────────────────────────────────────────────┤
│  Base: Bazzite (Fedora Atomic + Gaming Optimizations + NVIDIA)     │
│  + KDE Plasma Desktop (via TigerVNC + noVNC)                       │
│  + HomeFS (FUSE filesystem for USB hot-unplug resilience)          │
│  + Chameleon Boot (hardware auto-detection)                        │
│  + systemd-sysext overlays (custom binaries)                       │
├────────────────────────────────────────────────────────────────────┤
│  Boot Sequence                                                      │
│  ├─ 1. Hardware Detection (GPU/Power/Form Factor)                  │
│  ├─ 2. Load System Overlays (systemd-sysext)                       │
│  ├─ 3. HomeFS Setup (USB detection, FUSE mount)                    │
│  └─ 4. Start Desktop (TigerVNC + noVNC)                            │
└────────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. HomeFS (Unplug Resilience)

FUSE-based filesystem that allows USB hot-unplug without data loss.

**How it works:**
```
Normal operation:
┌─────────────┐      ┌─────────────┐      ┌─────────────┐
│ Application │ ──── │   HomeFS    │ ──── │  USB SSD    │
│   (vim)     │      │ (FUSE+RAM)  │      │ /home/user  │
└─────────────┘      └─────────────┘      └─────────────┘

USB unplugged:
┌─────────────┐      ┌─────────────┐      ┌ ─ ─ ─ ─ ─ ─┐
│ Application │ ──── │   HomeFS    │      │  USB SSD    │
│   (vim)     │      │  (RAM only) │       (unplugged)
└─────────────┘      └─────────────┘      └ ─ ─ ─ ─ ─ ─┘
                            │
                     Writes go to journal
                     Reads from RAM cache

USB replugged:
┌─────────────┐      ┌─────────────┐      ┌─────────────┐
│ Application │ ──── │   HomeFS    │ ──── │  USB SSD    │
│   (vim)     │      │ (syncing)   │      │ /home/user  │
└─────────────┘      └─────────────┘      └─────────────┘
                            │
                     Journal replays to USB
```

**Key Features:**
- Metadata cached in RAM for instant access
- Files lazy-loaded from USB on first access
- Writes go to write-ahead journal (WAL)
- When USB unplugged: system continues from RAM cache
- When USB replugged: journal replays, changes sync
- Desktop notifications for plug/unplug events

**Files:**
```
lib/homefs/
├── homefs.py      # Main FUSE driver
├── journal.py     # Write-ahead log
├── cache.py       # LRU cache manager
├── sync.py        # USB sync daemon
└── cli.py         # User commands

config/homefs/config.json  # Cache size, sync interval, exclusions
bin/homefs-usb-notify      # USB hotplug handler
```

**Configuration (`config/homefs/config.json`):**
```json
{
  "cache": {
    "max_size": "4G",              // RAM cache limit
    "large_file_threshold": "100M" // Chunk large files
  },
  "sync": {
    "strategy": "batched",         // Batch writes for performance
    "batch_interval": 30           // Sync every 30 seconds
  },
  "preload": [                     // Always keep in RAM
    ".bashrc", ".ssh/config"
  ],
  "exclude": [                     // Never cache
    ".cache/**", "Downloads/**"
  ]
}
```

**Commands:**
```bash
homefs status       # Show cache stats, USB status, safe-to-unplug
homefs sync         # Force sync to USB
homefs cache stats  # Detailed cache statistics
```

**Docker vs Real Hardware:**
- In Docker: HomeFS runs in "direct mode" (no USB to detect)
- On real hardware: Auto-detects USB with label `POWOS-HOME`
- Status shows "Disabled (direct mode)" in Docker - this is correct

### 2. Chameleon Boot (Hardware Detection)

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

### 3. System Overlays (Frankenstein Mods)

Custom binaries via systemd-sysext without modifying base OS.

**Creating an overlay:**
```bash
mkdir -p sources/my-tool
cat > sources/my-tool/build.sh << 'EOF'
#!/bin/bash
mkdir -p "$OUTPUT_DIR/usr/bin"
cp /path/to/my-tool "$OUTPUT_DIR/usr/bin/"
EOF
```

**Building:**
```bash
bash lib/overlay-manager.sh build my-tool
bash lib/overlay-manager.sh build-all
```

## Directory Structure

```
PowOS/
├── Containerfile              # THE OS definition
├── docker-compose.yml         # Test environment
├── justfile                   # Build commands
│
├── bin/                       # User commands
│   ├── powos-boot             # Main boot script
│   ├── pinstall               # Install + git commit
│   └── homefs-usb-notify      # USB hotplug handler
│
├── lib/
│   ├── hardware-detect.sh     # Chameleon Boot
│   ├── overlay-manager.sh     # systemd-sysext builder
│   └── homefs/                # HomeFS FUSE filesystem
│       ├── homefs.py          # Main FUSE driver
│       ├── journal.py         # Write-ahead log
│       ├── cache.py           # LRU cache manager
│       ├── sync.py            # USB sync daemon
│       └── cli.py             # CLI interface
│
├── config/
│   ├── profiles/              # Hardware profiles
│   ├── homefs/config.json     # HomeFS settings
│   └── udev/                  # USB hotplug rules
│
├── build/
│   ├── build-iso.sh           # ISO creation (uses podman + bootc)
│   └── output/                # Built ISOs go here
│
├── overlays/                  # Built system extensions
├── sources/                   # Overlay source code
└── systemd/                   # Boot services
```

## Container-Specific Notes

**Base Image:** `ghcr.io/ublue-os/bazzite-nvidia:stable`

Bazzite is an immutable Fedora-based OS. Key quirks:
- `/usr/local` doesn't exist by default (we create it)
- `/mnt` is a symlink (we remove and recreate it)
- Use `--break-system-packages` for pip

**VNC Setup:**
- TigerVNC + noVNC (not KasmVNC - too many issues)
- Software rendering forced (`LIBGL_ALWAYS_SOFTWARE=1`)
- This avoids NVIDIA EGL crashes in container

**Ports:**
```
5901: VNC direct (TigerVNC)
6091: noVNC web interface (browser access)
```

## Boot Sequence Detail

```
1. Hardware Detection
   └─ /usr/lib/powos/powos-hardware-detect
   └─ Writes to /run/powos/hardware

2. System Overlays
   └─ /usr/lib/powos/powos-overlay-load
   └─ Enables extensions in /var/lib/extensions

3. HomeFS Setup
   ├─ Check for USB with label "POWOS-HOME"
   ├─ If found: Mount USB, start HomeFS FUSE, start sync daemon
   └─ If not found: Direct mode (no lazy-load)

4. Desktop Environment
   ├─ Create user "powos" if needed
   ├─ Start D-Bus
   ├─ Start TigerVNC on :1 (port 5901)
   └─ Start noVNC websocket proxy (port 8443 → 6091)
```

## USB Drive Layout

PowOS expects this partition layout (created by installer):

```
USB SSD (e.g., Lexar NM790 4TB)
├── Partition 1: EFI (512MB, FAT32)
├── Partition 2: PowOS System (100GB, BTRFS)
│   └── Base OS, overlays, state
└── Partition 3: HomeFS User Data (remainder, BTRFS)
    └── Label: POWOS-HOME (auto-detected)
```

## Building the ISO

ISO building requires **podman** (not docker) and uses bootc-image-builder.

```bash
# Build ISO
just build-iso

# Output: build/output/powos.iso

# Write to USB (Linux)
sudo dd if=build/output/powos.iso of=/dev/sdX bs=4M status=progress

# Write to USB (Windows)
# Use Rufus, Etcher, or similar
```

**Requirements:**
- podman installed
- ~20GB disk space
- Root/sudo access

## Environment Variables

```bash
POWOS_HOMEFS=auto|true|false   # HomeFS mode (auto-detects USB)
POWOS_USB_UUID=<uuid>          # Force specific USB UUID
POWOS_MOCK_HARDWARE=nvidia     # Simulate GPU for testing
POWOS_MOCK_POWER=ac            # Simulate power source
```

## Troubleshooting

**Desktop won't load:**
```bash
docker compose logs powos | tail -50
# Look for VNC or X11 errors
```

**HomeFS not starting on real hardware:**
```bash
# Check if USB detected
blkid | grep POWOS-HOME

# Check HomeFS status
homefs status

# Check logs
journalctl -u powos-homefs -f
```

**Safe to unplug?**
```bash
homefs status
# Look for "Safe to unplug: Yes"
# If "No", wait for sync to complete
```

**NVIDIA EGL crash:**
Already handled - software rendering forced. If still crashing:
```bash
export LIBGL_ALWAYS_SOFTWARE=1
export __EGL_VENDOR_LIBRARY_FILENAMES=/dev/null
```

## Credentials

```
VNC Password: powos
User login:   powos / powos
```

## Key Design Decisions

1. **TigerVNC over KasmVNC**: KasmVNC had too many issues (user prompts, certificates, segfaults)
2. **Software rendering in container**: NVIDIA EGL crashes with hardware acceleration
3. **FUSE-based HomeFS**: Allows intercepting all file ops for caching/journaling
4. **Batched sync**: Better performance than immediate writes (30s intervals)
5. **Auto-detection**: USB label "POWOS-HOME" triggers HomeFS automatically
6. **Bazzite base**: Gaming-optimized, NVIDIA drivers included, immutable filesystem

## Development Workflow

```bash
# 1. Make changes to source files

# 2. Rebuild and test
docker compose up --build

# 3. Access desktop
open http://localhost:6091/vnc.html

# 4. When ready for production
just build-iso

# 5. Burn and boot on any machine
```

## License

MIT
