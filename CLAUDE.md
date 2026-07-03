# PowOS - Technical Reference

## Quick Start

```bash
# Test in Docker (opens KDE desktop in browser)
docker compose up

# Create live USB image (requires podman)
# Output: build/output/powos.raw (LIVE BOOT, not an installer)
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
powos health          # System health check with issues/warnings
powos health --ai     # Talk to health AI agent for troubleshooting
powos layers          # Detailed layer stack with sizes
powos layers status   # Same as above
powos hardware        # Show detected hardware
powos version         # Show version and active layers
```

### Sync (RAM ↔ USB)

**Real-world scenario:** Your USB runs on Machine A, you unplug and use on Machine B, then return to Machine A. Both machines have changes in RAM - conflict!

```bash
powos sync                    # Sync RAM ↔ USB (detects conflicts)
powos sync status             # Show sync status & conflicts
powos sync resolve            # Interactive conflict resolution
powos sync resolve --ai       # AI analyzes conflicts & recommends action
powos sync --keep-ram         # Force RAM changes to USB (your work wins)
powos sync --keep-usb         # Reload from USB (USB wins, reboot needed)
powos sync --merge            # Attempt basic merge (may need manual intervention)
powos sync diff               # Show differences between RAM and USB
```

**How conflict detection works:**
- USB has a `.powos-sync` marker tracking which machine last wrote to it
- If you're on Machine A but USB was last written by Machine B → CONFLICT
- Choose to keep your RAM changes, USB changes, or merge manually
- Use `--ai` to discuss the conflict with the health agent before deciding

### Flush & Safety
```bash
powos flush           # Force flush RAM changes to USB now (no conflict check)
powos safe            # Check if safe to unplug USB
```

### Mobile Mode (RAM-Only) — ⚠️ WIP

Copy OS to RAM so USB can be unplugged. Everything included by default.

> **Status:** Copying files to RAM layer works. **Live remount is not yet implemented** (`lib/mobile.sh:441`). `powos mobile enable` copies files but requires a reboot to activate the new layer. The `overlayfs remounted` step is a stub.

```bash
powos mobile                    # Enable mobile mode (copy all to RAM, reboot needed)
powos mobile -c                 # Interactive menu to customize
powos mobile status             # Show current mode
powos mobile disable            # Return to USB-backed mode

# Category management (non-interactive, for scripts/LLMs)
powos mobile categories         # List all categories with sizes
powos mobile exclude Games      # Exclude a category
powos mobile include Games      # Include a category
powos mobile include-all        # Reset to include everything
powos mobile exclude-all        # Start fresh, include nothing
```

**How it works (current state):**
- Categories detected from package manager (rpm groups)
- Selected categories copied to a RAM layer on disk
- **Reboot required** to activate the new overlay stack
- After reboot with mobile layer: USB optional for OS operations
- User data: still uses default USB bind-mount (or CacheFS if enabled)

### Backup (USB → Cloud)

Optional cloud backup of your USB state to a git repository:

```bash
powos backup status           # Show backup status (ahead/behind)
powos backup push             # Push USB state to cloud
powos backup push -m "msg"    # Push with custom commit message
powos backup pull             # Pull from cloud (merge strategy)
powos backup pull --theirs    # Pull and discard local changes
powos backup setup <url>      # Configure cloud backup repository
powos backup ignore           # Edit .syncignore in editor
powos backup ignore "pattern" # Add pattern to .syncignore
powos backup refresh          # Regenerate ignore rules
powos backup export [file]    # Export state to tarball
powos backup import <file>    # Import state from tarball
powos backup machine init     # Create machine-specific branch
```

**What gets backed up:**
- `projects/` - Your development projects
- `sources/` - Overlay source code
- `containers/distrobox.ini` - Container definitions
- `config/` - PowOS configuration

**Configuring what NOT to backup:**

Edit `.syncignore` in your state repo (`/var/lib/powos/git/.syncignore`):

```bash
powos backup ignore             # Opens in editor
powos backup ignore "big-data/" # Quick add a pattern
```

**Default exclusions** (in `.syncignore`):
- `node_modules/`, `vendor/`, `.venv/` - Package managers
- `dist/`, `build/`, `target/` - Build artifacts
- `.env`, `secrets/`, `*.key` - Secrets
- `.next/`, `.nuxt/`, `.cache/` - Framework caches
- `*.iso`, `*.img`, `*.vmdk` - Large binaries
- `.mozilla/`, `.config/chromium/` - Browser profiles

### Updates
```bash
powos update              # Check for available updates
powos update os           # Update Bazzite base OS
powos update powos        # Update PowOS scripts
powos update packages     # Update installed packages
powos update overlays     # Rebuild overlays with latest upstream
powos update apply        # Apply all updates (os + packages)
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

**Note:** rollback sets kernel args via `grubby`; grubby failures are reported loudly. `/run/powos/rollback-kargs` is informational only — nothing reads it at boot, so it is NOT a fallback. After reboot, verify with `grep powos /proc/cmdline`.

### Package Installation
```bash
powos install PKG...              # Install to custom layer
powos install -c NAME PKG...      # Install to container NAME
powos install -c NAME -e PKG...   # Install + export GUI apps to host
```

### Install to Disk (dual-boot) — 🚧 New / needs hardware validation

The USB is a **single live image with a boot menu**: "PowOS Live" (default,
runs from RAM) and "Install PowOS to disk". Choosing Install boots live and
launches an interactive installer — nothing is wiped without an explicit
target + confirmation. Always runnable by hand from the live system:

```bash
sudo powos install-system                 # Interactive: pick disk + mode
sudo powos install-system --dry-run       # Show the plan, change nothing
sudo powos install-system --alongside     # Dual-boot: install into free space, keep Windows
sudo powos install-system --whole-disk    # Erase target disk (must type disk model to confirm)
sudo powos install-system --shared-gb 200 # Also create a shared NTFS data partition (now labeled POWOS-GAMES)
```

**Boot-menu mechanism:** the "Install PowOS" entry is a Boot Loader Spec entry
(`loader/entries/powos-install.conf`) added by `install-to-usb.sh` — a copy of
the live entry plus kernel arg `powos.install=1`. `powos-installer.service`
(`ConditionKernelCommandLine=powos.install`) launches the installer on tty1.

**Dual-boot notes automated by the installer:** sets RTC to local time (matches
Windows), reminds to disable Windows Fast Startup/hibernation, recommends the
UEFI boot menu (atomic Bazzite's GRUB won't auto-list Windows), and advises
keeping Steam Proton prefixes on native FS while sharing only assets on NTFS.

> ⚠️ **Status:** whole-disk uses `bootc install to-disk`; the dual-boot
> "alongside" path (partition free space + reuse Windows ESP via
> `bootc install to-filesystem`) is **EXPERIMENTAL** — see `TODO(hw)` markers
> in `lib/install-system.sh`. Validate on a VM / spare disk before trusting it.

### Windows: dual-boot, reciprocal VM, GPU hotswap
```bash
powos boot windows          # one-shot reboot into bare-metal Windows, back after
powos vm windows [--gpu]    # run the installed Windows as a KVM guest (no reboot)
powos gpu status            # where the dGPU is (host vs vfio/VM) + readiness
powos gpu to-vm | to-host   # hotswap the dGPU between Linux (CUDA) and a VM
```
**Anti-cheat reality (see `docs/DUAL-BOOT-VM.md`):** kernel anti-cheats
(EAC/BattlEye/Vanguard — e.g. Arc Raiders) **block VMs** → those games need
**bare-metal Windows** (`powos boot windows`, a reboot). Non-anti-cheat games run
**native on Linux/Proton** (no VM). The VM is for productivity + non-AC
Windows-only titles. `--gpu` hotswaps the dGPU in for the session and reclaims it
on exit (keeps CUDA on the host otherwise).

> ⚠️ **Status / testability:** GPU hotswap + passthrough is **hardware-only** —
> it can't be exercised in Docker/CI (no GPU, vfio, IOMMU, or Windows image). The
> harness covers PowOS boot (`test/e2e`) + command/PCI-detection logic
> (`test/tier1/test-gpu.sh`). Hard prereqs: IOMMU on; **desktop on the iGPU**
> (else releasing the dGPU freezes the session — `powos gpu to-vm` refuses while
> the GPU is in use). Keep a TTY/SSH the first time.

### Games Storage (powos games) — shared NTFS partition, both OSes

POWOS-GAMES is a first-class partition: NTFS, labeled `POWOS-GAMES`,
deliberately visible to Windows. Every other PowOS partition is hidden from
Windows via GPT type GUIDs (Linux-filesystem type = no drive letter = no
"format this disk?" prompts) — see the exposure contract in `docs/WINDOWS.md`.
Created at USB flash time (`install-to-usb.sh --games-gb N`), by the disk
installer (`--shared-gb`, now labeled POWOS-GAMES), or later on any existing
system via the CLI. Machine-local: each machine creates its own on its own
PowOS-owned disk.

```bash
powos games status                    # partition, mount, Steam wiring state
powos games create --size N [--disk D] [--dry-run] [--yes]  # create POWOS-GAMES
powos games mount                     # mount at /var/mnt/games (ntfs3)
powos games steam-setup               # Steam library on the shared partition
powos games resize                    # stub — not implemented
```

**Steam wiring (`steam-setup`):** mounts POWOS-GAMES at `/var/mnt/games` via
ntfs3 (uid/gid, windows_names), creates `SteamLibrary/steamapps`, keeps
`compatdata`/`shadercache` on native btrfs via symlinks (Proton prefixes break
on NTFS), adds the library to `libraryfolders.vdf` when Steam is closed, and
drops `GAMES-README.txt` at the partition root telling the Windows side to add
`<letter>:\SteamLibrary` as a Windows Steam library. One installed game serves
both OSes.

> ⚠️ **Safety/status:** nothing touches a disk except a user-run command
> against a device the user names, behind plan display + confirmations +
> `--dry-run`. Implemented, not yet hardware-validated.

### Bare-Metal Windows on USB (powos windows) — 🚧 EXPERIMENTAL, needs hardware validation

Full design: `docs/WINDOWS.md`. Windows lives in its own partitions (WIN-ESP +
POWOS-WIN) on a PowOS-owned disk; the user supplies their own ISO + license.

```bash
powos windows status              # partition, hibernation state, boot entries, guards
powos windows create [--disk D]   # carve WIN-ESP + POWOS-WIN (plan + confirm) 🚧
powos windows install --iso PATH  # ISO-in-VM install onto the real partitions 🚧
powos windows finalize            # boot entries + post-install wiring
powos windows                     # guarded switch: flush + stop layer-sync → guards →
                                  #   BootNext → hibernate (--reboot fallback until
                                  #   hibernation ships) 🚧
powos windows snapshot|snapshots|rollback   # ntfsclone-based, refuses dirty/hibernated
powos windows vm                  # stub until hardware validation
```

> 🚧 **Status:** the switch and `install` are EXPERIMENTAL — implemented, not
> yet hardware-validated. The hibernation half is blocked on
> `docs/HIBERNATION.md`; until it ships, `powos windows --reboot` is the
> fallback. Same safety posture as `powos games`: named device, plan,
> confirmations, `--dry-run`.

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

### Development (powos dev)
```bash
powos dev list                    # List all projects
powos dev new NAME                # Create new project from scratch

# AI Project Creator - generates full project from description
powos dev new --ai mytool                              # Interactive mode
powos dev new --ai "CLI that converts JSON to YAML" jsonyaml
powos dev new --ai "async web scraper with Redis queue" scraper

# Docker projects (AI-powered)
powos dev new --docker myapi
powos dev new --docker --desc "REST API with Redis" myapi

# Fork existing repos
powos dev fork kde:dolphin
powos dev fork https://github.com/user/repo
powos dev fork --docker URL       # Fork and auto-dockerize

powos dev build NAME              # Build project
powos dev enable NAME             # Install to system as overlay
powos dev disable NAME            # Remove from system
powos dev update NAME             # Pull upstream changes (forks only)
```

### AI Agent System (powos ai)

The AI agent system provides configurable AI assistance with multiple clients, agent personalities, and specialized flavors.

```bash
# Basic prompts
powos ai "help me set up this project"
powos ai --agent coder "review this function"
powos ai --agent health "is my system healthy?"

# Agent flavors (specialized modes)
powos ai --agent health:sync "help with this conflict"
powos ai --agent health:layers "layer corruption issue"
powos ai --agent containerizer:python "containerize this flask app"
powos ai --agent containerizer:node "dockerize my next.js app"
powos ai --agent coder:review "check this code for issues"

# Agent aliases (multiple names for same agent)
powos ai --agent docker "containerize this"     # → containerizer
powos ai --agent pod "help with containers"     # → containerizer

# Client selection
powos ai --client claude "explain this"    # Default
powos ai --client gemini "analyze this"
powos ai --client ollama "local inference"

# Interactive mode
powos ai -i                               # Start chat session
powos ai -i --agent coder                 # Chat with specific agent

# Session management
powos ai session new myproject            # Create named session
powos ai -s myproject "hello"             # Use session
powos ai -s myproject "continue..."       # Session maintains context
powos ai --continue "what next?"          # Continue last conversation
powos ai sessions                         # List all sessions
powos ai session export myproject md      # Export as markdown

# Output formats
powos ai --json "hello"                   # Full JSON with session_id
powos ai --verbose "create a todo"        # Verbose with tool use

# List agents with their flavors
powos ai agents
```

**Available Agents & Flavors:**

| Agent | Description | Flavors |
|-------|-------------|---------|
| `assistant` | General purpose (default) | - |
| `coder` | Coding assistance | `:review` - Code review specialist |
| `devops` | System admin, containers | - |
| `health` | PowOS diagnostics | `:sync` - RAM↔USB conflicts, `:layers` - Layer issues |
| `creator` | Project generator | - |
| `containerizer` | Container config generator | `:python`, `:node` |

**Aliases:** `docker`, `pod`, `container` → `containerizer`

**Keeping agents current (single source of truth):** the system-facing agents
(`assistant`, `health`, `devops`) inject `config/ai/context/capabilities.md`
plus live `powos help` at call time via `AGENT_CONTEXT_CMD`. Edit that ONE doc
when features change — do not re-describe features in individual agent prompts,
which drift. Ships to `/etc/powos/ai/context/capabilities.md`.

**Agent Config Structure:**
```
config/ai/agents/
├── health/
│   ├── agent.conf        # Main agent config
│   ├── sync.conf         # :sync flavor
│   └── layers.conf       # :layers flavor
├── containerizer/
│   ├── agent.conf
│   ├── python.conf
│   └── node.conf
├── coder/
│   ├── agent.conf
│   └── review.conf
└── ...
```

**Library Usage (in scripts):**
```bash
source /usr/lib/powos/ai/agent.sh

# Basic calls
ai_call "what should I do?"
ai_call --agent devops "diagnose this"
ai_call --agent health:sync "help with conflict"

# Interactive with context
ai_interactive --agent health --context "$system_state"
```

**Creating Custom Agents:**

1. Create agent directory and config:
```bash
mkdir -p config/ai/agents/myagent

# config/ai/agents/myagent/agent.conf
AGENT_NAME="myagent"
AGENT_DESCRIPTION="My custom agent"
AGENT_CLIENT="claude"  # or gemini, ollama
AGENT_ALIASES="myalias otheralias"  # Optional aliases
AGENT_SYSTEM_PROMPT="You are a specialist in..."
```

2. Add flavors (optional) - any .conf file except agent.conf:
```bash
# config/ai/agents/myagent/specialized.conf
FLAVOR_NAME="specialized"
FLAVOR_DESCRIPTION="Specialized mode for X"
FLAVOR_PROMPT="## Specialized Mode

Focus on X, Y, Z..."
```

3. Use it:
```bash
powos ai --agent myagent "help me"
powos ai --agent myagent:specialized "detailed help"
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
  Mode:       ● USB bind-mount (direct)
  CacheFS:    disabled (set POWOS_CACHEFS_ENABLED=true in /etc/powos/config)

USB Drive
  Status:     ● Connected
  Last Sync:  30s ago

Unplug Safety
  ⚠ OS PROTECTED, HOME REQUIRES USB
    OS runs from RAM (safe to unplug for OS)
    /home is USB-mounted (enable CacheFS for full unplug resilience)
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

6. User Data Mount
   └─ Default: direct USB bind-mount at /home/powos
   └─ If POWOS_CACHEFS_ENABLED=true: FUSE mount (lazy-load)
   └─ CacheFS is opt-in and experimental (disabled by default)

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

### 3. CacheFS (User Data) — 🚫 Incomplete, must remain disabled

FUSE filesystem for lazy-loading user data. **Disabled by default and must stay disabled:** write-back to USB is NOT implemented — writes land in the RAM cache and are never persisted to the USB source, so any written data is lost on unmount/reboot. Do not enable (`POWOS_CACHEFS_ENABLED=true`) until write-back exists. Default is direct USB bind-mount.

```
When enabled (POWOS_CACHEFS_ENABLED=true):
  IN RAM:
  ├─ File metadata ─────── ~100MB for 1M files
  └─ LRU cache ─────────── 4GB (configurable)

  ON USB (lazy-loaded):
  └─ Actual contents ───── up to 4TB

  USB unplugged:
    ls ~/Documents/     → works (metadata RAM)
    cat cached.txt      → works (in cache)
    cat uncached.txt    → error "offline"

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

# 5. Build ISO for real hardware
just build-iso
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

**CacheFS (disabled by default — write-back to USB not implemented; keep disabled):**
```bash
# CacheFS is mounted directly by bin/powos-boot at boot when
# POWOS_CACHEFS_ENABLED=true is set in /etc/powos/config (reboot to apply).
# WARNING: writes are never persisted back to USB — do not enable.

# Debug when enabled:
blkid | grep POWOS-DATA
mount | grep cachefs
cat /run/powos/cachefs-status.json
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

## CI & GitHub API etiquette (agents: READ THIS)

The GitHub REST API allows **5,000 requests/hour shared across every agent and
tool on this account** — it has been exhausted by run-polling before. Rules:

- **NEVER `gh run watch`** — it polls every ~3s (~1,200 req/h per watcher).
- Don't poll `gh run list`/`gh run view` in loops. Check once, then wait
  minutes (ScheduleWakeup or a long sleep), not seconds.
- **"Did the build publish?" doesn't need the REST API at all.** The registry
  API is separate and effectively unmetered:
  ```bash
  skopeo inspect --creds "Powback:$(gh auth token)" \
      docker://ghcr.io/powback/powos:nvidia-open | jq -r '.Digest, .Created'
  ```
  New digest/timestamp = build landed. Prefer this for completion checks.
- Reserve `gh run view --log-failed` for diagnosing a KNOWN failure, not for
  discovering whether one happened.
- `gh api rate_limit` is free (doesn't count) — check it if unsure.

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

> **Note:** Tier-2 VM testing infrastructure does not exist yet. There is no automated test suite for real-hardware behavior.

## Feature Status

| Feature | Status | Notes |
|---------|--------|-------|
| Layered RAM boot | ✅ Implemented (hardware validation pending) | OS in RAM, layers from USB; previously broken on real hardware (NEWROOT no-op), fix awaiting validation |
| Hardware detection (17 profiles) | ✅ Implemented | Auto-selects on boot |
| Layer sync (RAM→USB, 60s) | ✅ Implemented (hardware validation pending) | Whiteout translation, USB disconnect guard, failure notifications; previously broken (`--delete-after` wipe), fix awaiting validation |
| systemd-sysext overlays | ✅ Implemented | Custom binaries merged into /usr |
| Container dev (Distrobox) | ✅ Implemented | Mutable dev containers |
| Rollback | ✅ Implemented | grubby can silently fail — verify via `/run/powos/rollback-kargs` |
| CacheFS | 🚫 Incomplete — keep disabled | Write-back to USB NOT implemented; written data is lost. Must remain disabled |
| Mobile mode | 🚧 WIP | Files copied to RAM but live remount not implemented; reboot needed |
| Sync conflict detection | ⚠️ Partial | Detection works; `--merge` has basic implementation, may need manual help |
| Cloud backup | ⚠️ Partial | git-based implementation exists (`lib/backup.sh`); not fully validated |
| Tier-2 VM testing | ❌ Missing | Only Docker/tier-1 tests exist |

## Credentials

```
VNC Password: powos
User login:   powos / powos
```

## License

MIT
