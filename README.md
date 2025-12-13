# PowOS - Portable Gaming Workstation

A fully portable Linux workstation that runs from a USB SSD. Plug into any machine, boot, work. Unplug and take your entire environment with you.

## Two Commands. That's It.

```bash
# Test in Docker (opens KDE desktop in browser)
docker compose up

# Create bootable ISO when ready
just build-iso
```

Then burn the ISO to your USB SSD and boot from it. Everything else is automatic.

## What Makes This Special

### Unplug Resilience (HomeFS)
Working on your desktop, need to leave? **Just unplug the USB drive.** The system continues running from RAM cache. Plug back in later - changes sync automatically. No data loss.

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
# HomeFS shows "Disabled (direct mode)" - that's correct for Docker
# On real hardware with USB, it enables automatically
```

## Creating the ISO

```bash
# Build bootable ISO
just build-iso

# Output: build/output/powos.iso
```

Then use your preferred tool to write it:
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
4. HomeFS mounts your home directory
   → Metadata cached to RAM for instant access
   → Files lazy-loaded on demand
   → Writes journaled for safety
5. KDE Plasma desktop starts
6. You're ready to work

When you unplug:
- System keeps running from RAM cache
- All writes saved to journal
- Desktop notification shows "Running from cache"

When you replug:
- Journal replays to USB automatically
- "Sync complete" notification
- Zero data loss
```

## USB Drive Setup (Automatic on First Boot)

PowOS expects this partition layout (created automatically by installer):

```
USB SSD (e.g., Lexar NM790 4TB)
├── Partition 1: EFI (512MB, FAT32)
├── Partition 2: PowOS System (100GB, BTRFS)
│   └── Base OS, overlays, state
└── Partition 3: HomeFS User Data (remainder, BTRFS)
    └── /home - your files, lazy-loaded via FUSE
```

Label the home partition `POWOS-HOME` for auto-detection.

## Key Commands

| Command | What it does |
|---------|--------------|
| `docker compose up` | Test PowOS in Docker |
| `just build-iso` | Create bootable ISO |
| `homefs status` | Show cache stats, sync status |
| `homefs sync` | Force sync to USB |
| `pinstall <pkg>` | Install package + commit to git |

## How HomeFS Works

HomeFS is a FUSE filesystem that makes your USB drive "unpluggable":

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

**Cache limits**: 4GB RAM by default (configurable in `/etc/homefs/config.json`)

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
│       └── sync.py            # USB sync daemon
│
├── config/
│   ├── profiles/              # Hardware profiles
│   ├── homefs/config.json     # HomeFS settings
│   └── udev/                  # USB hotplug rules
│
├── build/
│   ├── build-iso.sh           # ISO creation script
│   └── output/                # Built ISOs go here
│
└── docs/
    ├── HOMEFS-DESIGN.md       # HomeFS architecture
    └── HOMEFS-INTEGRATION.md  # Boot integration details
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
# Check for VNC errors
```

**HomeFS not starting on real hardware?**
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

## Documentation

- [CLAUDE.md](CLAUDE.md) - Technical reference for AI/developers
- [USER_STORIES.md](USER_STORIES.md) - Feature requirements and acceptance criteria
- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture details
- [docs/HOMEFS-DESIGN.md](docs/HOMEFS-DESIGN.md) - HomeFS deep dive

## License

MIT
