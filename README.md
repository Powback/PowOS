# PowOS - Portable Gaming Workstation

A fully portable Linux workstation that runs from a USB SSD. Plug into any machine, boot, work. The OS runs entirely from RAM — pulling the USB won't crash your session. Changes sync to USB every 60 seconds.

> **Honest disclaimer:** PowOS is in active development. The OS RAM-boot and layer-sync are solid. CacheFS (lazy-loaded home data enabling true unplug while reading files) is **opt-in and experimental**. Mobile mode (copy OS to RAM for USB-free sessions) requires a reboot after enabling and is **not yet live-remountable**. See [Feature Status](#feature-status) for details.

## Two Commands. That's It.

```bash
# Test in Docker (opens KDE desktop in browser)
docker compose up

# Create bootable ISO when ready
just build-iso
```

Then burn the ISO to your USB SSD and boot from it. Everything else is automatic.

## What Makes This Special

### Unplug Resilience

Working on your desktop, need to leave? **Yank the USB drive out.** The OS keeps running (it's in RAM). Changes you made since the last sync (up to 60s) stay in RAM.

When you plug back in, unsaved RAM changes sync automatically.

**What's protected without CacheFS (default):**
- The entire OS and all running processes (in RAM) — always safe
- Files you've already opened/written (in RAM page cache)
- Any files in home dir that fit in kernel page cache

**What requires CacheFS enabled (opt-in):**
- Reliable `ls ~/Documents/` after unplug (metadata in RAM)
- Opening files not in kernel cache after unplug

Default setup uses a direct USB bind-mount for `/home`. CacheFS is opt-in via `POWOS_CACHEFS_ENABLED=true` in `/etc/powos/config`.

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

### User Data

By default, `/home` is a direct bind-mount from the USB drive. This is simple and reliable, but means some operations depend on the USB being connected.

**CacheFS (opt-in, experimental):** For lazy-loading terabytes of user data with unplug resilience:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    USER DATA (CacheFS - opt-in)                              │
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

Enable CacheFS: set `POWOS_CACHEFS_ENABLED=true` in `/etc/powos/config`. Note: CacheFS has known limitations (missing fsync, potential data loss on power failure). Use at your own risk.

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

## Complete Command Reference

### System Status
| Command | What it does |
|---------|--------------|
| `powos status` | Full system status (layers, RAM, USB, protection) |
| `powos version` | Show PowOS version and active layers |
| `powos hardware` | Show detected hardware (GPU, power, form factor) |
| `powos safe` | Check if safe to unplug USB (exit 0 = safe) |

### Layer Management
| Command | What it does |
|---------|--------------|
| `powos layers` | Show layer stack with sizes |
| `powos layers status` | Detailed layer status |
| `powos layers sync` | Force sync RAM → custom layer |
| `powos layers clear custom` | Clear custom layer entirely |
| `powos layers clear updates` | Clear updates layer entirely |

### Rollback
| Command | What it does |
|---------|--------------|
| `powos rollback` | Show rollback options and current state |
| `powos rollback custom` | Skip custom layer on next boot |
| `powos rollback updates` | Skip updates layer on next boot |
| `powos rollback all` | Boot with base only (skip both layers) |
| `powos rollback reset` | Clear all rollback flags |

### Updates
| Command | What it does |
|---------|--------------|
| `powos update` | Check for available updates |
| `powos update os` | Apply OS updates (to updates layer) |
| `powos update packages` | Apply package updates (to custom layer) |
| `powos update apply` | Apply all updates |
| `powos sync` | Force sync all changes to USB |

### Package Installation
| Command | What it does |
|---------|--------------|
| `powos install <pkg>` | Install package to host (custom layer) |
| `powos install -c NAME <pkg>` | Install package to a container |
| `powos install -c NAME -e <pkg>` | Install GUI app to container + export to host menu |
| `pinstall <pkg>` | Install package + auto-commit to git |

### Container Management
| Command | What it does |
|---------|--------------|
| `powos containers` | List all containers and images |
| `powos containers create <name> [image]` | Create a new distrobox container |
| `powos containers enter <name>` | Enter a container shell |
| `powos containers stop <name>` | Stop a running container |
| `powos containers remove <name>` | Remove a container |
| `powos containers assemble` | Create all predefined containers (from distrobox.ini) |
| `powos containers export <name> <app>` | Export app from container to host menu |
| `powos containers prune` | Clean up unused containers/images |
| `powos containers podman <args>` | Pass through to podman directly |

### Container Building
| Command | What it does |
|---------|--------------|
| `powos build` | Build from ./Containerfile or ./Dockerfile |
| `powos build . <tag>` | Build with a specific tag |
| `powos build <path> [tag]` | Build from specific path |

### Development System (Build Custom Apps)
| Command | What it does |
|---------|--------------|
| `powos dev` | List all projects |
| `powos dev list` | List all projects with status |
| `powos dev new <name>` | Create a new project from scratch |
| `powos dev fork <upstream>` | Fork existing app (e.g., `kde:dolphin`, `https://github.com/...`) |
| `powos dev build <name>` | Build project to overlay |
| `powos dev enable <name>` | Enable overlay (overrides system version) |
| `powos dev disable <name>` | Disable overlay (restore system version) |
| `powos dev update <name>` | Pull upstream changes (forks only) |

### Shortcuts
| Short | Full Command |
|-------|--------------|
| `powos c` | `powos containers` |
| `powos i` | `powos install` |
| `powos b` | `powos build` |
| `powos d` | `powos dev` |

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

## Development System - Build & Customize Apps

The unified `powos dev` system lets you build new apps OR fork existing ones using the same workflow.

### Create a New Project

```bash
# Create a new project
powos dev new myapp
cd /var/lib/powos/projects/myapp/src
# Write your code
powos dev build myapp
powos dev enable myapp
# Your app is now in the system!
```

### Fork & Customize Existing Apps (e.g., KDE Dolphin)

```bash
# Fork Dolphin file manager
powos dev fork kde:dolphin

# Edit the source
cd /var/lib/powos/projects/dolphin/src
# Make your changes (add red sidebar, custom features, etc.)

# Build and enable
powos dev build dolphin
powos dev enable dolphin
# YOUR custom Dolphin now overrides the system version!

# Later: pull upstream updates
powos dev update dolphin
```

### How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                    Development System                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  projects/dolphin/                                               │
│  ├── src/              # YOUR editable copy (edit this!)        │
│  ├── upstream/         # Original source (forks only, for ref)  │
│  ├── project.conf      # Project metadata                       │
│  └── build.sh          # Build script (auto-generated)          │
│                                                                  │
│  ↓ powos dev build dolphin                                      │
│                                                                  │
│  extensions/dolphin/                                             │
│  └── usr/bin/dolphin   # Your custom build                      │
│                                                                  │
│  ↓ powos dev enable dolphin                                     │
│                                                                  │
│  systemd-sysext merges extension into /usr                      │
│  Your Dolphin OVERRIDES system Dolphin!                         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Supported Fork Sources

| Source | Example |
|--------|---------|
| KDE Apps | `kde:dolphin`, `kde:konsole`, `kde:kate`, `kde:gwenview` |
| Git URLs | `https://github.com/user/repo` |

### Project Status

```bash
powos dev list
# Output:
# Projects
# ════════════════════════════════════════
#   ★ dolphin (fork)
#       ↳ https://invent.kde.org/system/dolphin.git
#   ● myapp (custom)
#   ○ experiment (custom)
#
# Legend: ★ enabled  ● built  ○ not built
```

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
  Mode:       ● USB bind-mount (direct)
  USB:        Connected
  CacheFS:    disabled (opt-in, see /etc/powos/config)

USB Drive
  Status:     ● Connected
  Last Sync:  30s ago

Unplug Safety
  ⚠ OS PROTECTED, HOME REQUIRES USB
    OS runs from RAM (safe to unplug)
    /home is USB-mounted (some ops need USB)
    Enable CacheFS for full unplug resilience
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

**Rollback limitation:** `powos rollback` writes kernel args via `grubby`. If `grubby` is not installed or fails, the rollback flag is written to `/run/powos/rollback-kargs` instead — which the initramfs checks. The `grubby` call always exits 0 (`|| true`), so a failure is silent. Check `powos rollback` output and verify flags in `/run/powos/rollback-kargs`.

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

5. User data mount
   → Default: direct bind-mount of USB /home (USB must stay connected for full access)
   → With CacheFS enabled: lazy-load FUSE mount (metadata in RAM, contents on-demand)

6. KDE Plasma desktop starts

7. You're ready to work
   → OS is fully in RAM (USB can be yanked without crashing)
   → Home dir access depends on mount mode (see step 5)
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
│   ├── powos                  # Main CLI (all commands)
│   ├── powos-boot             # Boot orchestrator
│   ├── pinstall               # Install + git commit
│   └── premove                # Remove + git commit
│
├── lib/
│   ├── hardware-detect.sh     # Chameleon Boot (auto hardware config)
│   ├── overlay-manager.sh     # systemd-sysext overlay builder
│   ├── dev-commands.sh        # Unified dev system (powos dev)
│   ├── dracut/                # Initramfs modules
│   │   └── 90powos-ramboot/   # Layered RAM boot module
│   ├── ramfs/                 # RAM layer management
│   │   └── layer-sync.py      # Syncs RAM → custom layer (60s)
│   └── cachefs/               # User data lazy-loading
│       ├── powos-cachefs.py   # FUSE filesystem
│       └── cachefs-sync.py    # Sync daemon
│
├── config/
│   ├── profiles/              # Hardware profiles (16 profiles)
│   │   ├── desktop-nvidia-performance.conf
│   │   ├── laptop-nvidia-battery.conf
│   │   └── ...
│   └── bootc/kargs.d/         # Kernel boot arguments
│
├── projects/                  # Development projects (gitignored)
│   └── <name>/                # Each project (new or forked)
│       ├── src/               # Your editable source code
│       ├── upstream/          # Original source (forks only)
│       ├── project.conf       # Project metadata
│       └── build.sh           # Build script
│
├── sources/                   # Built-in overlays and KDE config
│   ├── kde/                   # KDE app configuration
│   │   └── dev.conf           # App categories, build deps
│   ├── hello-powos/           # Example overlay
│   ├── gpu-nvidia/            # NVIDIA driver overlay
│   ├── gpu-amd/               # AMD driver overlay
│   └── gpu-intel/             # Intel driver overlay
│
├── extensions/                # Built overlays (gitignored)
│
├── containers/
│   └── distrobox.ini          # Predefined container definitions
│
├── systemd/                   # System services
│   ├── powos-layer-sync.service   # Layer sync daemon
│   ├── powos-cachefs-sync.service # CacheFS sync daemon
│   └── powos-ramboot-init.service # RAM boot init
│
└── build/
    ├── build-iso.sh           # Create bootable ISO
    ├── install-to-usb.sh      # Install to USB drive
    └── output/                # Built ISOs go here
```

## Creating the Live USB Image

PowOS builds a **live boot image** (`powos.raw`), not an installer ISO. The image runs directly from USB without touching any other disk.

```bash
# Build live USB image (requires podman)
just build-iso

# Output: build/output/powos.raw
```

Write to USB with the provided script (has safety checks):
```bash
sudo ./build/install-to-usb.sh /dev/sdX
```

Or write manually (be careful to use correct device):
- **Linux**: `sudo dd if=build/output/powos.raw of=/dev/sdX bs=4M status=progress`
- **Windows**: Rufus in DD mode, or balenaEtcher
- **macOS**: `sudo dd if=build/output/powos.raw of=/dev/diskN bs=4m`

**Safety:** `install-to-usb.sh` refuses to write to non-removable drives (internal SSDs). NVMe devices get a warning (some USB NVMe enclosures are detected as non-removable — use `POWOS_OVERRIDE_REMOVABLE=1` to bypass).

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

## Feature Status

Honest assessment of what works:

| Feature | Status | Notes |
|---------|--------|-------|
| Layered RAM boot | ✅ Implemented (hardware validation pending) | OS in RAM, layers from USB |
| Hardware detection | ✅ Implemented | 17 hardware profiles |
| Layer sync (RAM→USB) | ✅ Implemented (hardware validation pending) | Every 60s, whiteout translation, USB disconnect detection |
| systemd-sysext overlays | ✅ Implemented | Custom binaries merged into /usr |
| Container dev (Distrobox) | ✅ Implemented | Mutable dev containers |
| Rollback (custom/updates) | ✅ Implemented | grubby failures reported loudly; verify after reboot via `grep powos /proc/cmdline` |
| CacheFS lazy-loading | 🚫 Incomplete — keep disabled | Write-back to USB not implemented; written data is lost |
| Mobile mode (USB-free) | 🚧 WIP | Copies OS to RAM but live remount not implemented — requires reboot to take effect |
| Sync conflict detection | ⚠️ Partial | Detection works; merge is manual |
| Shared games partition (`powos games`) | ⚠️ Implemented, not hardware-validated | NTFS POWOS-GAMES shared with Windows; Steam library wiring |
| Bare-metal Windows on USB (`powos windows`) | 🚧 Experimental | Spec + CLI (docs/WINDOWS.md); hardware validation pending |
| Cloud backup | ⚠️ Partial | git-based implementation exists; not fully validated |
| AI-assisted healing | 🧪 Experimental | Requires manual Ollama setup |
| Tier-2 VM testing | ❌ Not yet | Only Docker/tier-1 tests exist |

## Testing

```bash
# Docker tests (fast, no real hardware needed)
docker compose up --build
docker exec powos powos status
docker exec powos bash /var/lib/powos/src/test/tier1/test-hardware-detect.sh
docker exec powos bash /var/lib/powos/src/test/tier1/test-overlay.sh
docker exec powos bash /var/lib/powos/src/test/tier1/test-pinstall.sh
docker exec powos python3 /var/lib/powos/src/test/tier1/test-layer-sync.py
docker exec powos python3 /var/lib/powos/src/test/tier1/test-cachefs.py
```

**What Docker tests cover:**
- Hardware detection logic
- Overlay build/enable/disable
- Package install workflow
- Layer sync logic (unit tests, not real overlayfs)
- CacheFS unit tests

**What requires real hardware or VM:**
- Actual overlayfs RAM boot (Docker uses privileged mode, not real initramfs)
- USB detection and real sync
- CacheFS FUSE mount behavior
- Rollback across reboots
- Hardware profile application

> **Note:** Tier-2 VM testing infrastructure does not exist yet. Pre-hardware testing checklist: (1) run all Docker tests, (2) verify `powos status` output, (3) check `powos layers` shows correct stack, (4) test `powos sync` manually before relying on auto-sync.

## Documentation

- [CLAUDE.md](CLAUDE.md) - Technical reference for developers
- [ARCHITECTURE.md](ARCHITECTURE.md) - Full system architecture
- [USER_STORIES.md](USER_STORIES.md) - Feature requirements

## License

MIT
