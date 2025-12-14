# PowOS System Architecture

> How all the pieces fit together

## The Big Picture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              USB SSD (4TB)                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│  Partition 1: EFI (512MB)      │ UEFI bootloader                            │
│  Partition 2: System (100GB)   │ Bazzite OS + PowOS                         │
│  Partition 3: Data (remainder) │ /home, state, overlays (Label: POWOS-DATA) │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           BOOT SEQUENCE                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. HARDWARE DETECTION (Chameleon Boot)                                      │
│     ├─ Detect: GPU (nvidia/amd/intel) + Power (ac/battery) + Form           │
│     └─ Apply: config/profiles/desktop-nvidia-performance.conf               │
│                                    │                                         │
│  2. SYSTEM OVERLAYS (systemd-sysext)                                         │
│     ├─ Load extensions from /var/lib/extensions/                            │
│     └─ Merge custom binaries into /usr (without modifying base OS)          │
│                                    │                                         │
│  3. RAM OVERLAY (Unplug Resilience)                                          │
│     ├─ Mount USB data partition read-only as lower layer                    │
│     ├─ Create tmpfs (RAM) as upper layer                                    │
│     ├─ overlayfs combines them → all writes go to RAM                       │
│     └─ Sync daemon: rsync RAM changes to USB every 30s                      │
│                                    │                                         │
│  4. DESKTOP                                                                  │
│     └─ KDE Plasma via TigerVNC + noVNC                                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Layer 1: Hardware Detection (Chameleon Boot)

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
config/profiles/*.conf           # Profile configurations
/run/powos/hardware              # Runtime state (written at boot)
```

**How it works:**
```bash
# 1. Detect hardware
GPU_TYPE=$(lspci | grep -qi nvidia && echo "nvidia" || echo "intel")
POWER=$(cat /sys/class/power_supply/AC*/online | grep -q 1 && echo "ac" || echo "battery")

# 2. Select profile
PROFILE="${FORM_FACTOR}-${GPU_TYPE}-${POWER_SOURCE}"

# 3. Apply settings
source /etc/powos/profiles/${PROFILE}.conf
```

## Layer 2: System Overlays (systemd-sysext)

**Purpose:** Add custom binaries to immutable base OS without modifying it.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Base OS (Bazzite)                             │
│                    /usr/bin/*, /usr/lib/*                        │
│                    IMMUTABLE - cannot modify                     │
└─────────────────────────────────────────────────────────────────┘
                              +
┌─────────────────────────────────────────────────────────────────┐
│                 System Extensions (sysext)                       │
│  extensions/gpu-nvidia/usr/bin/nvidia-smi                       │
│  extensions/hello-powos/usr/bin/hello-powos                     │
│  extensions/device-steamdeck/usr/lib/...                        │
└─────────────────────────────────────────────────────────────────┘
                              ↓
              systemd-sysext merge
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    Merged /usr                                   │
│  Base OS binaries + Extension binaries                          │
│  /usr/bin/hello-powos now exists!                               │
└─────────────────────────────────────────────────────────────────┘
```

**Creating an overlay:**
```bash
# 1. Create source
mkdir -p sources/my-tool
cat > sources/my-tool/build.sh << 'EOF'
#!/bin/bash
mkdir -p "$OUTPUT_DIR/usr/bin"
curl -o "$OUTPUT_DIR/usr/bin/my-tool" https://example.com/my-tool
chmod +x "$OUTPUT_DIR/usr/bin/my-tool"
EOF

# 2. Build
bash lib/overlay-manager.sh build my-tool
# Creates: extensions/my-tool/usr/bin/my-tool

# 3. Enable (on real hardware, auto at boot)
systemd-sysext merge
# Now: /usr/bin/my-tool exists
```

**Files:**
```
sources/                         # Overlay source code
├── gpu-nvidia/build.sh
├── hello-powos/build.sh
└── device-steamdeck/build.sh

extensions/                      # Built overlays (gitignored)
├── gpu-nvidia/usr/...
├── hello-powos/usr/bin/hello-powos
└── device-steamdeck/usr/...

lib/overlay-manager.sh           # Build/enable/disable overlays
```

## Layer 3: RAM Overlay (Unplug Resilience)

**Purpose:** Run the ENTIRE OS from RAM so USB can be unplugged completely.

### How It Works

The magic happens during boot via a custom **dracut module**:

```
┌─────────────────────────────────────────────────────────────────┐
│                    BOOT SEQUENCE (initramfs)                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. UEFI loads kernel + initramfs from USB                       │
│                                                                  │
│  2. Dracut module (90powos-ramboot) activates:                   │
│     ├─ Creates 8GB tmpfs at /run/powos-overlay                   │
│     ├─ Mounts USB root as READ-ONLY lower layer                  │
│     ├─ Uses tmpfs as WRITE upper layer                           │
│     └─ Creates overlayfs as new root                             │
│                                                                  │
│  3. System switches to overlay root                              │
│     └─ ENTIRE OS now runs from RAM!                              │
│                                                                  │
│  4. USB becomes optional - can be unplugged                      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### The Overlay Structure

```
┌─────────────────────────────────────────────────────────────────┐
│                    FULL SYSTEM OVERLAY                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   UPPER LAYER (tmpfs - RAM, 8GB default)                         │
│   ├─ ALL writes go here: /usr, /etc, /home, /var, everything    │
│   ├─ Survives USB unplug completely                             │
│   └─ Location: /run/powos-overlay/upper/                         │
│                                                                  │
│   LOWER LAYER (USB - read-only)                                  │
│   ├─ Original OS from USB                                        │
│   ├─ Read-only, cached in RAM as accessed                        │
│   └─ Can be disconnected after boot                              │
│                                                                  │
│   MERGED VIEW (what you see as /)                                │
│   ├─ Reads: RAM first, USB if not in RAM                         │
│   ├─ Writes: always go to RAM                                    │
│   └─ Mount point: / (entire root filesystem)                     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘

Sync Daemon (background):
  Every 30 seconds:
    if USB connected:
      rsync /run/powos-overlay/upper/ → USB persistence partition
```

### Unplug Scenario

```
1. You're running anything - vim, browser, compile job, whatever
2. USB is unplugged (intentionally or accidentally)
3. EVERYTHING keeps working - entire OS is in RAM
4. New writes go to RAM upper layer
5. Desktop notification: "USB disconnected - running from RAM"
6. USB is replugged
7. Sync daemon detects, rsyncs RAM changes → USB
8. Desktop notification: "Changes synced to USB"
9. Zero data loss, zero interruption
```

### Enabling Full RAM Boot

RAM boot is enabled by kernel command line arguments:

```
rd.powos.ramboot=1      # Enable full RAM boot
rd.powos.ramsize=8G     # RAM allocation (default 8G)
```

These are set automatically in the ISO. For custom installs, add to bootloader config.

### Files

```
lib/dracut/90powos-ramboot/
├── module-setup.sh      # Dracut module definition
├── ramboot-setup.sh     # Hook that sets up overlayfs
└── powos-overlay-init.sh # Userspace init (sync daemon, etc)

lib/ramfs/
├── overlay-mount.sh     # Legacy overlay for /home only
└── sync-daemon.py       # Background rsync to USB

bin/powos                # CLI: status, sync, safe

config/bootc/kargs.d/
└── 50-powos-ramboot.toml # Kernel cmdline args

systemd/
└── powos-ramboot-init.service # Userspace init service
```

### Commands

```bash
powos status    # Show boot mode, RAM usage, USB state
powos sync      # Force sync to USB now
powos safe      # Always safe in ramboot mode!
```

### RAM Requirements

| Mode | RAM Needed | What's Protected |
|------|------------|------------------|
| Legacy (Phase 1) | 2-4 GB | Only /home |
| **Full RAM Boot (Phase 2)** | **8-16 GB** | **ENTIRE OS** |

For full protection, you need enough RAM to hold the OS + your working set.
Recommended: 16GB+ for comfortable use, 32GB+ for heavy workloads.

## Layer 4: Package Management (pinstall)

**Purpose:** Install packages AND track them in git for reproducibility.

```
┌─────────────────────────────────────────────────────────────────┐
│                         pinstall neovim                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   1. INSTALL (runtime)                                           │
│      └─ dnf install neovim                                       │
│                                                                  │
│   2. RECORD (config)                                             │
│      └─ Add "neovim" to containers/distrobox.ini                │
│                                                                  │
│   3. COMMIT (persistence)                                        │
│      └─ git commit -m "pinstall: neovim"                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘

On new machine (hydration):
  git clone your-powos-repo
  just hydrate
  → Reads distrobox.ini, reinstalls all packages
  → Rebuilds all overlays from sources/
  → Full environment restored
```

**Files:**
```
bin/pinstall             # Install + record + commit
bin/premove              # Remove + record + commit
containers/distrobox.ini # Package list (tracked in git)
```

## How Everything Connects

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           RUNTIME FLOW                                    │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  YOU                                                                      │
│   │                                                                       │
│   ├─► Run application                                                     │
│   │     └─► Binary from: Base OS OR System Extension (Layer 2)           │
│   │           └─► Reads files from: RAM Overlay (Layer 3)                │
│   │                 └─► Falls through to USB if not in RAM cache         │
│   │                                                                       │
│   ├─► Save a file                                                         │
│   │     └─► Write goes to: RAM upper layer (Layer 3)                     │
│   │           └─► Sync daemon: periodically rsyncs to USB                │
│   │                                                                       │
│   ├─► Install a package                                                   │
│   │     └─► pinstall pkg (Layer 4)                                       │
│   │           ├─► Installs immediately                                   │
│   │           ├─► Records to distrobox.ini                               │
│   │           └─► Git commits for persistence                            │
│   │                                                                       │
│   ├─► Create custom binary                                                │
│   │     └─► sources/my-tool/build.sh (Layer 2)                           │
│   │           └─► Build → extensions/ → systemd-sysext merge             │
│   │                                                                       │
│   ├─► Plug into different machine                                         │
│   │     └─► Hardware detection runs (Layer 1)                            │
│   │           └─► Applies correct profile for this hardware              │
│   │                                                                       │
│   └─► Unplug USB                                                          │
│         └─► System keeps running (Layer 3 - RAM overlay)                 │
│               └─► Replug → sync daemon writes changes to USB             │
│                                                                           │
└──────────────────────────────────────────────────────────────────────────┘
```

## Recovery Flow (15-Minute Phoenix)

```
USB drive dies/lost/stolen
         │
         ▼
┌─────────────────────────────────────────┐
│  1. Boot any Linux (live USB, etc)      │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  2. Clone your PowOS repo               │
│     git clone github.com/YOU/powos      │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  3. Hydrate                             │
│     just hydrate                        │
│     ├─ Rebuild overlays from sources/   │
│     ├─ Reinstall packages from config   │
│     └─ Restore everything               │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  4. Build ISO & burn to new USB         │
│     just build-iso                      │
│     dd if=powos.iso of=/dev/sdX         │
└─────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│  5. Boot - everything's back            │
└─────────────────────────────────────────┘
```

## Testing Strategy

```
┌─────────────────────────────────────────────────────────────────┐
│                    TIER 3: REAL HARDWARE                        │
│                    Final validation only                        │
│                    USB → Physical Machine                       │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │
┌─────────────────────────────────────────────────────────────────┐
│                    TIER 2: QEMU/KVM VM                          │
│                    Boot testing, systemd                        │
│                    just vm-boot                                 │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │
┌─────────────────────────────────────────────────────────────────┐
│                    TIER 1: DOCKER COMPOSE                       │
│                    Fast iteration, 90% of dev time              │
│                    docker compose up                            │
└─────────────────────────────────────────────────────────────────┘
```

## File Structure Summary

```
PowOS/
├── Containerfile              # THE OS definition
├── docker-compose.yml         # Tier 1 testing
├── justfile                   # Command runner
│
├── bin/
│   ├── powos                  # CLI (status, sync, safe)
│   ├── powos-boot             # Boot orchestrator
│   └── pinstall               # Package + git commit
│
├── lib/
│   ├── hardware-detect.sh     # Layer 1: Chameleon Boot
│   ├── overlay-manager.sh     # Layer 2: Build/enable sysext
│   └── ramfs/                 # Layer 3: RAM overlay
│       ├── overlay-mount.sh
│       └── sync-daemon.py
│
├── config/
│   └── profiles/              # Hardware profiles
│       ├── desktop-nvidia-performance.conf
│       ├── laptop-intel-battery.conf
│       └── virtual.conf
│
├── sources/                   # Overlay source code (Layer 2)
│   ├── gpu-nvidia/build.sh
│   └── hello-powos/build.sh
│
├── extensions/                # Built overlays (gitignored)
│
├── containers/
│   └── distrobox.ini          # Package list (Layer 4)
│
└── build/
    ├── build-iso.sh           # Create bootable ISO
    └── output/                # Built ISOs
```

## Quick Reference

| Layer | Purpose | Key Files | Commands |
|-------|---------|-----------|----------|
| 1. Hardware | Auto-configure for machine | `lib/hardware-detect.sh`, `config/profiles/` | `powos hardware` |
| 2. Overlays | Custom binaries | `sources/*/build.sh`, `lib/overlay-manager.sh` | `just build <name>` |
| 3. RAM | Unplug resilience | `lib/ramfs/`, `bin/powos` | `powos status`, `powos sync` |
| 4. Packages | Tracked installs | `bin/pinstall`, `containers/distrobox.ini` | `pinstall <pkg>` |
