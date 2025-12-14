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

### Layered Persistence - Install Anything, Rollback Anytime

Unlike traditional "immutable" systems where you can't modify the OS, PowOS uses **layered persistence**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HOW LAYERS WORK                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐                                                         │
│  │   RAM (upper)   │ ← All writes go here first (instant)                    │
│  └────────┬────────┘                                                         │
│           │ syncs every 60s                                                  │
│           ▼                                                                  │
│  ┌─────────────────┐                                                         │
│  │  Custom Layer   │ ← Your packages, configs, customizations                │
│  └────────┬────────┘   (persists across reboots)                             │
│           │                                                                  │
│  ┌─────────────────┐                                                         │
│  │  Updates Layer  │ ← OS updates (separate from your stuff)                 │
│  └────────┬────────┘                                                         │
│           │                                                                  │
│  ┌─────────────────┐                                                         │
│  │   Base (Bazzite)│ ← Original OS image                                     │
│  └─────────────────┘                                                         │
│                                                                              │
│  Install anything: dnf install neovim → goes to RAM → syncs to custom layer  │
│  Update broke something? → powos rollback updates → skip that layer          │
│  Your customization broke? → powos rollback custom → skip that layer         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key insight:** You're NOT locked into an immutable system. Install packages, change configs, do whatever - it all persists. But if something breaks, you can roll back individual layers without losing everything.

### User Data - Lazy Loading for 4TB

Your 4TB of files can't fit in RAM. CacheFS solves this:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         USER DATA (CacheFS)                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  IN RAM (always):                                                            │
│  ├─ File metadata (names, sizes, permissions) ─── instant ls/find           │
│  └─ LRU cache of accessed files ───────────────── 4GB of hot files          │
│                                                                              │
│  ON USB (lazy-loaded):                                                       │
│  └─ Actual file contents ──────────────────────── 4TB                        │
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

In Docker you'll see "Standard" boot mode - that's correct because Docker doesn't have real hardware boot. On real hardware, it enables full RAM boot with layers automatically.

## Key Commands

| Command | What it does |
|---------|--------------|
| `powos status` | Show layers, RAM usage, USB state |
| `powos layers` | Detailed layer stack view |
| `powos sync` | Force sync RAM changes to USB |
| `powos rollback` | Show rollback options |
| `powos rollback custom` | Skip custom layer next boot |
| `powos rollback updates` | Skip updates layer next boot |
| `powos rollback reset` | Clear rollback, use all layers |
| `powos update` | Check for OS updates |
| `powos containers` | List containers and images |
| `powos containers create <name>` | Create a new dev container |
| `powos containers enter <name>` | Enter a container |
| `pinstall <pkg>` | Install package + commit to git |

## Container Development

PowOS uses **Podman + Distrobox** for mutable development containers on top of the immutable base OS.

```bash
# Create a development container
powos containers create dev              # Default Fedora
powos containers create arch archlinux   # Arch Linux with AUR
powos containers create ubuntu ubuntu:22.04

# Enter and work inside the container
powos containers enter dev
# Now you're in a full Fedora environment - install anything!
sudo dnf install neovim nodejs rust

# Exit back to PowOS
exit

# Create all predefined containers from distrobox.ini
powos containers assemble

# Export an app from container to host desktop
powos containers export dev code    # VSCode from container appears in host menu

# Clean up unused containers/images
powos containers prune

# Direct podman access
powos containers podman ps
powos containers podman images
```

### Easy Install with GUI Export

The magic command: install apps in containers, use them on your host desktop!

```bash
# Install Firefox from Arch (gets latest version + AUR access)
powos install -c arch -e firefox

# Install VSCode in a dev container, appears in your app menu
powos install -c dev -e code

# Install CLI tools to a container (no export needed)
powos install -c dev nodejs npm rust cargo

# Install to host (goes to custom layer, persists across reboots)
powos install neovim htop
```

### Build from Dockerfile

Podman reads Dockerfiles natively - no conversion needed!

```bash
# Build from current directory
powos build

# Build with a tag
powos build . myapp:latest

# Build from specific path
powos build ./my-project myimage:v1

# Run your image
podman run -it myapp:latest
```

**Why Podman + Distrobox?**
- **Rootless**: No daemon, no root required
- **Mutable**: Install anything inside containers without touching base OS
- **Integrated**: Containers share your home directory, GPU, audio, etc.
- **Persistent**: Containers survive reboots, stored on USB
- **Dockerfile compatible**: Build any Docker project with `powos build`

## Source Overlays - Customize Any App

Build custom versions of apps that **override the system version**. Your patches persist across updates!

```bash
# List available source templates
powos source list

# Create a new source overlay
powos source new myapp https://github.com/user/myapp

# Or use an existing template (neovim, btop, etc.)
powos source get neovim
powos source build neovim
powos source enable neovim

# Now YOUR custom neovim overrides the system version!
```

### Example: Custom Neovim with Patches

```bash
# Fetch source
powos source get neovim

# Add your patches
cd /var/lib/powos/sources/neovim/upstream
# Make your changes...
git diff > ../patches/01-my-feature.patch

# Rebuild with patches
powos source patch neovim
powos source build neovim
powos source enable neovim

# Your custom neovim is now active!
nvim --version  # Shows your build
```

### How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                    Source Overlay System                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  sources/neovim/                                                 │
│  ├── source.conf        # Upstream URL, deps                    │
│  ├── patches/           # Your patches (applied in order)       │
│  │   └── 01-feature.patch                                       │
│  ├── build.sh           # Build script                          │
│  └── upstream/          # Fetched source code                   │
│                                                                  │
│  ↓ powos source build neovim                                    │
│                                                                  │
│  extensions/neovim/                                              │
│  └── usr/bin/nvim       # Your custom build                     │
│                                                                  │
│  ↓ powos source enable neovim                                   │
│                                                                  │
│  systemd-sysext merges extension into /usr                      │
│  Your nvim OVERRIDES system nvim!                               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Included Source Templates

| App | Description |
|-----|-------------|
| `neovim` | Custom Neovim editor build |
| `btop` | btop++ system monitor |
| `hello-powos` | Example overlay template |

Create your own: `powos source new myapp https://github.com/...`

## powos status Output

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
  USB:        Connected
  Cached:     142 files

USB Drive
  Status:     ● Connected
  Last Sync:  30s ago

Unplug Safety
  ✓ FULLY PROTECTED
    OS in RAM, user data cached
    USB can be unplugged anytime!
```

## powos layers Output

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

## Rollback Examples

```bash
# Something broke after installing a package?
powos rollback custom
# Reboot → runs without your custom layer
# Fix the issue, then:
powos rollback reset

# OS update broke something?
powos rollback updates
# Reboot → runs without updates layer
# Your customizations still work!

# Everything broken? Go back to pure base:
powos rollback all
# Reboot → clean Bazzite, no customizations, no updates
```

## What Happens on Real Hardware Boot

```
1. BIOS/UEFI loads PowOS from USB

2. Dracut module sets up layered overlay
   → Mounts base image (read-only)
   → Stacks updates layer (if present)
   → Stacks custom layer (if present)
   → Creates RAM upper layer (8GB+ tmpfs)
   → ENTIRE OS NOW IN RAM

3. Chameleon Boot detects hardware
   → GPU type (NVIDIA/AMD/Intel)
   → Power source (AC/Battery)
   → Applies matching profile

4. Layer sync daemon starts
   → Syncs RAM changes to custom layer every 60s
   → Changes persist across reboots

5. CacheFS mounts user data
   → Scans USB for file metadata → loads to RAM
   → Sets up 4GB LRU cache for file contents

6. KDE Plasma desktop starts

7. You're ready to work - USB is now OPTIONAL
```

## USB Drive Layout

```
USB SSD (e.g., Lexar NM790 4TB)
├── Partition 1: EFI (512MB, FAT32)
├── Partition 2: PowOS System (100GB, BTRFS)
│   └── Base OS image
└── Partition 3: Data (remainder, BTRFS)
    └── Label: POWOS-DATA
        ├── layers/
        │   ├── custom/     ← Your customizations
        │   └── updates/    ← OS updates
        └── home/           ← User data (CacheFS source)
```

## RAM Requirements

| Mode | RAM Needed | What's Protected |
|------|------------|------------------|
| OS layers (ramboot) | 8-20 GB | Operating system + customizations |
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
│   ├── powos                  # CLI (status, sync, layers, rollback)
│   └── pinstall               # Install + git commit
│
├── lib/
│   ├── hardware-detect.sh     # Chameleon Boot
│   ├── overlay-manager.sh     # systemd-sysext builder
│   ├── dracut/                # RAM boot module
│   │   └── 90powos-ramboot/   # Dracut module for layered RAM boot
│   ├── ramfs/                 # Layer management
│   │   └── layer-sync.py      # Syncs RAM to custom layer
│   └── cachefs/               # User data lazy-loading
│       ├── powos-cachefs.py   # FUSE filesystem
│       └── cachefs-sync.py    # Sync daemon
│
├── config/
│   ├── profiles/              # Hardware profiles
│   └── bootc/                 # Boot configuration
│
├── sources/                   # Overlay source code
│   ├── gpu-nvidia/
│   ├── gpu-amd/
│   └── ...
│
└── build/
    ├── build-iso.sh           # ISO creation script
    └── output/                # Built ISOs go here
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

## Credentials

```
VNC Password: powos
User login:   powos / powos
```

## Troubleshooting

**Check system status:**
```bash
powos status
powos layers
```

**RAM boot not activating?**
```bash
cat /proc/cmdline | grep powos
# Should contain: rd.powos.ramboot=1
```

**Rollback not working?**
```bash
powos rollback
# Shows current rollback state and options
```

**Force sync before unplugging:**
```bash
powos sync
powos safe  # Returns 0 if safe to unplug
```

## Documentation

- [CLAUDE.md](CLAUDE.md) - Technical reference for developers
- [ARCHITECTURE.md](ARCHITECTURE.md) - Full system architecture
- [USER_STORIES.md](USER_STORIES.md) - Feature requirements

## License

MIT
