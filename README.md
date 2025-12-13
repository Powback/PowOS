# PowOS - Portable Gaming Workstation

A fully portable Linux workstation that runs from a USB SSD. Plug into any machine, boot, work. **Unplug the USB and keep working from RAM.** Plug back in - changes sync automatically.

## Two Commands. That's It.

```bash
# Test in Docker (opens KDE desktop in browser)
docker compose up

# Create bootable ISO when ready
just build-iso
```

Then burn the ISO to your USB SSD and boot from it. Everything else is automatic.

## What Makes This Special

### Unplug Resilience (RAM Overlay)
Working on your desktop, need to leave? **Just unplug the USB drive.** The system continues running from RAM. Plug back in later - changes sync automatically. No data loss, no crash.

```
USB plugged in:
┌─────────────┐      ┌─────────────┐      ┌─────────────┐
│   Your App  │ ──── │ RAM Overlay │ ──── │  USB SSD    │
│   (vim)     │      │  (cache)    │      │  (storage)  │
└─────────────┘      └─────────────┘      └─────────────┘

USB unplugged:
┌─────────────┐      ┌─────────────┐
│   Your App  │ ──── │ RAM Overlay │      (USB gone, don't care)
│   (vim)     │      │ (all in RAM)│
└─────────────┘      └─────────────┘

USB replugged:
┌─────────────┐      ┌─────────────┐      ┌─────────────┐
│   Your App  │ ──── │ RAM Overlay │ ───► │  USB SSD    │
│   (vim)     │      │ (syncing)   │      │  (updated)  │
└─────────────┘      └─────────────┘      └─────────────┘
```

### Hardware Chameleon
One drive works on ANY machine:
- **Your desktop with dual RTX 3090s** → Loads NVIDIA drivers, performance mode
- **Random laptop with Intel graphics** → Loads Mesa, battery saver mode
- **Friend's AMD gaming rig** → Loads AMD drivers automatically

Zero configuration. Boot and it figures it out.

### 15-Minute Phoenix Recovery
Drive dies? Lost it? Stolen?
```bash
# On any machine with a fresh USB drive:
git clone https://github.com/YOU/powos ~/powos
just hydrate
```
Your entire environment restored: tools, configs, custom binaries, everything.

## Testing (Docker)

```bash
# Start PowOS in Docker
docker compose up --build

# Access the desktop
open http://localhost:6091/vnc.html
# Password: powos

# You'll see KDE Plasma desktop
# "RAM Overlay: Disabled" - that's correct for Docker (no USB)
# On real hardware with USB, it enables automatically
```

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
2. Chameleon Boot detects your hardware
   → GPU type (NVIDIA/AMD/Intel)
   → Power source (AC/Battery)
   → Form factor (Desktop/Laptop)
3. Applies matching profile automatically
4. RAM Overlay activates
   → USB mounted read-only as base layer
   → RAM tmpfs as write layer (overlayfs)
   → All writes go to RAM, synced to USB periodically
5. KDE Plasma desktop starts
6. You're ready to work

Unplugging USB:
- System keeps running (everything in RAM overlay)
- Desktop notification: "Running from RAM"
- No interruption to your work

Replugging USB:
- Sync daemon detects reconnection
- RAM changes written to USB
- "Sync complete" notification
```

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
| `powos status` | Show USB, RAM overlay, sync status |
| `powos sync` | Force sync RAM to USB |
| `powos safe` | Check if safe to unplug |
| `pinstall <pkg>` | Install package + commit to git |

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
│   ├── powos                  # CLI (status, sync, safe)
│   └── pinstall               # Install + git commit
│
├── lib/
│   ├── hardware-detect.sh     # Chameleon Boot
│   ├── overlay-manager.sh     # systemd-sysext builder
│   └── ramfs/                 # RAM overlay system
│       ├── overlay-mount.sh   # overlayfs setup
│       └── sync-daemon.py     # USB sync daemon
│
├── config/
│   └── profiles/              # Hardware profiles
│
├── build/
│   ├── build-iso.sh           # ISO creation script
│   └── output/                # Built ISOs go here
│
└── docs/
    └── RAMFS-DESIGN.md        # RAM overlay architecture
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

**RAM overlay not activating on real hardware?**
```bash
# Check if USB detected
blkid | grep POWOS-DATA

# Check overlay status
powos status

# Check powos boot logs
journalctl -u powos-boot -f
```

**Safe to unplug?**
```bash
powos safe
# ✓ Safe to unplug USB
# or
# ✗ Not safe - sync in progress
```

## Documentation

- [CLAUDE.md](CLAUDE.md) - Technical reference for AI/developers
- [USER_STORIES.md](USER_STORIES.md) - Feature requirements and acceptance criteria
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture details
- [docs/RAMFS-DESIGN.md](docs/RAMFS-DESIGN.md) - RAM overlay deep dive

## License

MIT
