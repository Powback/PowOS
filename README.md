# PowOS - Portable Gaming Workstation

A fully portable Linux workstation that runs from a USB SSD. Plug into any machine, boot, work. **Unplug the USB and keep working.** Plug back in - changes sync automatically. No data loss, no crash.

## Two Commands. That's It.

```bash
# Test in Docker (opens KDE desktop in browser)
docker compose up

# Create bootable ISO when ready
just build-iso
```

Then burn the ISO to your USB SSD and boot from it. Everything else is automatic.

## What Makes This Special

### Unplug Resilience - The Killer Feature

Working on your desktop, need to leave? **Just yank the USB drive out.** The system continues running. Plug back in later - changes sync automatically.

**How is this possible?**

PowOS uses a two-layer approach:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    LAYER 1: OS IN RAM (dracut + overlayfs)                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  During boot, a dracut module copies the entire OS to RAM:                   │
│                                                                              │
│    USB (read-only)  +  RAM (writes)  =  Running System                       │
│         lower            upper            merged                             │
│                                                                              │
│  Result: All of /usr, /etc, /var, running processes → IN RAM                 │
│  USB can be unplugged → OS keeps running                                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                    LAYER 2: USER DATA (CacheFS - lazy loading)               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Your 4TB of files can't fit in RAM. CacheFS solves this:                    │
│                                                                              │
│    IN RAM (always):                                                          │
│    ├─ File metadata (names, sizes, permissions) ─── instant ls/find         │
│    └─ LRU cache of accessed files ───────────────── 4GB of hot files        │
│                                                                              │
│    ON USB (lazy-loaded):                                                     │
│    └─ Actual file contents ──────────────────────── 4TB                      │
│                                                                              │
│  Access pattern:                                                             │
│    cat file.txt → in cache? serve instantly : load from USB, cache it       │
│                                                                              │
│  USB unplugged:                                                              │
│    ls ~/Documents/     → works (metadata in RAM)                             │
│    cat cached-file.txt → works (in RAM cache)                                │
│    cat other-file.txt  → "offline" until USB reconnected                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Hardware Chameleon

One drive works on ANY machine:
- **Your desktop with RTX 3090s** → Loads NVIDIA drivers, performance mode
- **Random laptop with Intel graphics** → Loads Mesa, battery saver mode
- **Friend's AMD gaming rig** → Loads AMD drivers automatically

Zero configuration. Boot and it figures it out.

### 15-Minute Phoenix Recovery

Drive dies? Lost it? Stolen?
```bash
# On any machine with a fresh USB drive:
git clone https://github.com/YOU/powos ~/powos
just hydrate
just build-iso
# Burn to new USB, boot - everything restored
```
Your entire environment restored: tools, configs, custom binaries, everything.

## Testing (Docker)

```bash
# Start PowOS in Docker
docker compose up --build

# Access the desktop
open http://localhost:6091/vnc.html
# Password: powos

# Check status
docker exec powos powos status
```

In Docker you'll see "Standard" boot mode and "tmpfs" for user data - that's correct because Docker doesn't have real hardware boot or USB. On real hardware, it enables full RAM boot and CacheFS automatically.

## Creating the ISO

```bash
# Build bootable ISO (requires podman)
just build-iso

# Output: build/output/powos.iso
```

Then write to USB:
- **Linux**: `sudo dd if=build/output/powos.iso of=/dev/sdX bs=4M status=progress`
- **Windows**: Rufus, Etcher, or similar
- **macOS**: `sudo dd if=build/output/powos.iso of=/dev/diskN bs=4m`

## What Happens on Real Hardware Boot

```
1. BIOS/UEFI loads PowOS from USB

2. Dracut module activates RAM boot
   → Creates 8GB+ tmpfs for OS overlay
   → USB becomes read-only lower layer
   → All writes go to RAM
   → ENTIRE OS NOW IN RAM

3. Chameleon Boot detects hardware
   → GPU type (NVIDIA/AMD/Intel)
   → Power source (AC/Battery)
   → Applies matching profile

4. CacheFS mounts user data
   → Scans USB for file metadata → loads to RAM
   → Sets up 4GB LRU cache for file contents
   → Files lazy-load on first access

5. KDE Plasma desktop starts

6. You're ready to work - USB is now OPTIONAL
```

**Unplugging USB:**
- OS keeps running (entire OS in RAM)
- Cached files still accessible
- New files you access will be "offline"
- Desktop notification: "USB disconnected - running from cache"

**Replugging USB:**
- Sync daemon detects reconnection
- Dirty files synced back to USB
- Uncached files become accessible again
- Desktop notification: "Sync complete"

## USB Drive Setup

PowOS expects this partition layout:

```
USB SSD (e.g., Lexar NM790 4TB)
├── Partition 1: EFI (512MB, FAT32)
├── Partition 2: PowOS System (100GB, BTRFS)
│   └── Base OS, overlays, state
└── Partition 3: User Data (remainder, BTRFS)
    └── Label: POWOS-DATA (auto-detected)
```

## Key Commands

| Command | What it does |
|---------|--------------|
| `docker compose up` | Test PowOS in Docker |
| `just build-iso` | Create bootable ISO |
| `powos status` | Show OS mode, user data mode, USB state |
| `powos sync` | Force sync cached changes to USB |
| `pinstall <pkg>` | Install package + commit to git |

## powos status Output

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
  USB:        Connected
  Pending:    0 files
  Cache:      847M in RAM

USB Drive
  Status:     ● Connected
  Last Sync:  30s ago

Unplug Safety
  ✓ FULLY PROTECTED
    OS: in RAM, User data: cached
    USB can be unplugged anytime!
```

## RAM Requirements

| Mode | RAM Needed | What's Protected |
|------|------------|------------------|
| OS only (ramboot) | 8-20 GB | Operating system |
| User cache (CacheFS) | 4 GB | Recently accessed files |
| **Total recommended** | **16-32 GB** | **Full unplug resilience** |

## Hardware Profiles

Chameleon Boot auto-selects the right profile:

| Hardware | Profile | What it configures |
|----------|---------|-------------------|
| Desktop + NVIDIA | `desktop-nvidia-performance` | Full GPU power, persistence mode |
| Laptop + NVIDIA + AC | `laptop-nvidia-performance` | Balanced GPU/power |
| Laptop + NVIDIA + Battery | `laptop-nvidia-battery` | GPU sleeps, Intel iGPU active |
| Laptop + Intel | `laptop-intel-battery` | Aggressive power saving |
| Any + Virtual/Container | `virtual` | Minimal config, no hardware polling |

## Project Structure

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
│   ├── hardware-detect.sh     # Chameleon Boot
│   ├── overlay-manager.sh     # systemd-sysext builder
│   ├── dracut/                # RAM boot module
│   │   └── 90powos-ramboot/   # Dracut module for full RAM boot
│   ├── cachefs/               # User data lazy-loading
│   │   ├── powos-cachefs.py   # FUSE filesystem
│   │   └── cachefs-sync.py    # Sync daemon
│   └── ramfs/                 # Legacy overlay system
│
├── config/
│   ├── profiles/              # Hardware profiles
│   └── bootc/                 # Boot configuration
│
├── sources/                   # Overlay source code
│   ├── gpu-nvidia/
│   ├── gpu-amd/
│   ├── device-steamdeck/
│   └── ...
│
└── build/
    ├── build-iso.sh           # ISO creation script
    └── output/                # Built ISOs go here
```

## Credentials

```
VNC Password: powos
User login:   powos / powos
```

## Troubleshooting

**Desktop won't load in Docker?**
```bash
docker compose logs powos | tail -50
```

**Check system status:**
```bash
powos status
```

**RAM boot not activating on real hardware?**
```bash
# Check kernel cmdline
cat /proc/cmdline | grep powos

# Should contain: rd.powos.ramboot=1
```

**CacheFS not working?**
```bash
# Check if USB detected
blkid | grep POWOS-DATA

# Check mounts
mount | grep cachefs
```

## Documentation

- [CLAUDE.md](CLAUDE.md) - Technical reference for developers
- [ARCHITECTURE.md](ARCHITECTURE.md) - Full system architecture (5 layers)
- [USER_STORIES.md](USER_STORIES.md) - Feature requirements

## License

MIT
