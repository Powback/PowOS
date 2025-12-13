# PowOS Overlay Architecture

## Overview

PowOS uses a modular architecture with **two base images** and **systemd-sysext overlays** for device-specific functionality. This document explains what was removed from the base images and will be provided via overlays.

## Base Images

### powos-base-mesa (Default/Recommended)
**Target GPUs:** AMD, Intel
**Graphics Stack:** Valve-patched Mesa
**Compute Support:** ROCm (AMD)
**Size:** ~3.5GB (estimated)

**Includes:**
- CachyOS kernel with scx-scheds
- Full AMD/Intel Mesa stack (Valve patches)
- ROCm for AMD GPU compute workloads
- All firmware (AMD, Intel, NVIDIA, WiFi, Bluetooth)
- KDE Plasma desktop environment
- Core gaming packages (Steam, Lutris, Gamescope)
- Pipewire/WirePlumber (Valve patches)
- Generic hardware utilities

**Excludes:**
- NVIDIA proprietary drivers
- Device-specific hardware support
- Handheld-specific packages
- Gaming mode (Deck UI)

### powos-base-nvidia
**Target GPUs:** NVIDIA
**Graphics Stack:** NVIDIA proprietary drivers
**Compute Support:** CUDA
**Size:** ~3.8GB (estimated)

**Includes:**
- CachyOS kernel with NVIDIA modules
- NVIDIA proprietary driver stack (565+)
- NVIDIA Container Toolkit for GPU containers
- Minimal Mesa (for Zink compatibility)
- All firmware (AMD, Intel, NVIDIA, WiFi, Bluetooth)
- KDE Plasma desktop environment
- Core gaming packages (Steam, Lutris, Gamescope)
- Pipewire/WirePlumber (Valve patches)
- Generic hardware utilities

**Excludes:**
- AMD ROCm
- Device-specific hardware support
- Handheld-specific packages
- Gaming mode (Deck UI)

---

## What Was Removed for Overlays

The following packages and configurations have been **intentionally removed** from the base images and will be provided via **systemd-sysext overlays** based on hardware detection.

### 1. Handheld Hardware Support (Device-Specific Overlays)

These packages are only needed for specific handheld gaming devices:

#### Steam Deck Hardware (`steamdeck-hw.raw`)
```
jupiter-fan-control           # Steam Deck-specific fan control
jupiter-hw-support-btrfs      # Steam Deck hardware support
vpower                        # Virtual power device for Steam Deck
galileo-mura                  # OLED display calibration (Deck OLED only)
steamdeck-dsp                 # Steam Deck audio DSP
powerbuttond                  # Power button daemon
steam_notif_daemon            # Steam notification integration
sdgyrodsu                     # Gyroscope support
```

**Detection:** DMI product name = "Jupiter" (LCD) or "Galileo" (OLED)
**Activation:** Automatic on first boot

#### ROG Ally Hardware (`rog-ally-hw.raw`)
```
/usr/share/pipewire/hardware-profiles/rog-ally/
/usr/share/wireplumber/hardware-profiles/rog-ally/
Device-specific TDP controls
Panel orientation fixes
Controller button mappings
```

**Detection:** DMI product name = "ROG Ally" or "ROG Ally X"
**Activation:** Automatic on first boot

#### Legion Go Hardware (`legion-go-hw.raw`)
```
/usr/share/pipewire/hardware-profiles/legion-go/
/usr/share/wireplumber/hardware-profiles/legion-go/
Device-specific audio profiles
TDP controls
Controller mappings
```

**Detection:** DMI product name contains "Legion Go"
**Activation:** Automatic on first boot

#### Framework Laptop Hardware (`framework-hw.raw`)
```
framework_tool                # Already in base, but config in overlay
Framework-specific kargs
3.5mm audio jack fixes
Suspend/resume fixes
GPIO pinctrl modules
```

**Detection:** DMI vendor = "Framework"
**Activation:** Automatic on first boot

#### Generic Handheld Fallback (`handheld-generic.raw`)
```
hhd                           # Handheld Daemon (universal)
hhd-ui                        # Handheld Daemon UI
Basic controller support
Generic TDP controls
```

**Detection:** Chassis type = handheld (DMI) or unknown handheld detected
**Activation:** Manual or automatic fallback

### 2. Gaming Mode / Deck UI (`gaming-mode.raw`)

The console-like gaming interface (Steam Deck experience):

```
gamescope-session-plus        # Gamescope-based gaming session
gamescope-session-steam       # Steam Big Picture integration
steamos-manager               # SteamOS-like system manager
/usr/share/gamescope-session-plus/bootstrap_steam.tar.gz
/etc/sddm.conf.d/steamos.conf # Auto-login configuration
/etc/systemd/logind.conf.d/deck.conf  # Power button = suspend
Auto-login systemd service
Return-to-gamemode service
```

**Detection:** User choice OR handheld device detected
**Activation:** Manual (`ujust enable-gaming-mode`) or automatic for handhelds
**Services Enabled:**
- `bazzite-autologin.service`
- `steamos-manager.service`
- `return-to-gamemode.service`

**Services Disabled:**
- `input-remapper.service` (conflicts with hhd)

### 3. Device-Specific Tools (Per-Device Overlays)

#### AMD-Specific Tools (`amd-tools.raw`)
```
ryzenadj                      # AMD Ryzen TDP adjustment
Device-specific ryzenadj configs
```

**Detection:** CPU vendor = AMD AND device needs TDP control
**Activation:** Conditional based on device

#### Framework-Specific Tools (`framework-tools.raw`)
```
fw-ectool                     # Framework EC tool
fw-fanctrl                    # Framework fan control
Framework-specific configs
```

**Detection:** DMI vendor = "Framework"
**Activation:** Automatic for Framework devices

#### Input Remapper (`input-remapper.raw`)
```
input-remapper                # Desktop input remapping
input-remapper.service
```

**Detection:** Desktop mode (not handheld gaming mode)
**Activation:** Automatic for desktop, disabled for gaming mode

### 4. Hybrid GPU Support (`hybrid-gpu.raw`)

For laptops with both integrated and discrete GPUs:

```
supergfxctl                   # Hybrid GPU switching daemon
supergfxctl-plasmoid          # KDE widget for GPU switching
supergfxd.service
```

**Detection:** Multiple GPUs detected (iGPU + dGPU)
**Activation:** Manual (`ujust enable-hybrid-gpu`)

### 5. Audio Profiles (Per-Device Overlays)

Device-specific audio configurations moved to overlays:

```
/usr/share/pipewire/hardware-profiles/{device}/
/usr/share/wireplumber/hardware-profiles/{device}/
/etc/pipewire/pipewire.conf.d/{device}.conf
/etc/wireplumber/wireplumber.conf.d/{device}.conf
```

**Devices with profiles:**
- Steam Deck (Jupiter/Galileo)
- ROG Ally / ROG Ally X
- Legion Go
- GPD Win devices
- AOKZOE handhelds
- MSI Claw

**Activation:** Automatic based on DMI detection

---

## Overlay Structure

### Overlay Directory Layout
```
/var/lib/extensions/
├── active/
│   ├── gpu-drivers.raw -> /usr/share/powos/overlays/mesa-drivers.raw
│   ├── device-hw.raw -> /usr/share/powos/overlays/steamdeck-jupiter.raw
│   ├── gaming-mode.raw -> /usr/share/powos/overlays/gaming-mode.raw
│   └── audio-profile.raw -> /usr/share/powos/overlays/audio-steamdeck.raw
└── available/
    ├── steamdeck-jupiter.raw
    ├── steamdeck-galileo.raw
    ├── rog-ally.raw
    ├── rog-ally-x.raw
    ├── legion-go.raw
    ├── framework-hw.raw
    ├── gaming-mode.raw
    ├── input-remapper.raw
    └── hybrid-gpu.raw
```

### Extension Metadata Example

Each overlay contains an `extension-release` file:

```
# /usr/lib/extension-release.d/extension-release.steamdeck-jupiter
ID=fedora
VERSION_ID=43
SYSEXT_LEVEL=1.0
ARCHITECTURE=x86_64
POWOS_OVERLAY_TYPE=device-hardware
POWOS_DEVICE_NAME=Steam Deck (LCD)
POWOS_DMI_MATCH=Jupiter
```

---

## Hardware Detection Service

### powos-hardware-detect.service

Runs on every boot to:
1. Detect GPU vendor
2. Detect device model (DMI)
3. Detect form factor (laptop/desktop/handheld)
4. Activate appropriate overlays
5. Enable/disable relevant services

**Location:** `/usr/lib/systemd/system/powos-hardware-detect.service`
**Script:** `/usr/libexec/powos-hardware-detect`

### Detection Flow

```
Boot
  ↓
Kernel loads
  ↓
Base filesystem mounted
  ↓
systemd-sysext.service (early boot)
  ↓
powos-hardware-detect.service (After=systemd-sysext.service)
  ↓
[Detects hardware]
  ├─ GPU: NVIDIA → Already using nvidia base image
  ├─ GPU: AMD/Intel → Already using mesa base image
  ├─ Device: Steam Deck → Activate steamdeck-jupiter.raw + gaming-mode.raw
  ├─ Device: ROG Ally → Activate rog-ally.raw + gaming-mode.raw
  └─ Device: Desktop → Activate input-remapper.raw
  ↓
systemd-sysext refresh
  ↓
[Continue boot with overlays active]
```

---

## Comparison: Bazzite vs PowOS

### Bazzite Approach (Multi-Stage Build)
```
Base Image (bazzite)
  ├─ Variant: bazzite-deck (FROM bazzite)
  │   └─ Variant: bazzite-deck-nvidia (FROM bazzite-deck)
  └─ Variant: bazzite-nvidia (FROM bazzite)
```

**Problems:**
- 6+ different image variants
- Duplicate packages across images
- Large image downloads
- Can't switch between variants without reinstall

### PowOS Approach (Base + Overlays)
```
Base Images (2)
  ├─ powos-base-mesa (AMD/Intel)
  └─ powos-base-nvidia (NVIDIA)

Overlays (modular, mix-and-match)
  ├─ Device-specific hardware
  ├─ Gaming mode
  ├─ Audio profiles
  └─ Special features
```

**Advantages:**
- Only 2 base images
- Overlays are small (10-100MB each)
- Can enable/disable features without reinstall
- Easy to add community device support
- Faster updates (update base OR overlay independently)

---

## User Experience

### First Boot (Steam Deck Example)

1. User boots PowOS (mesa base image)
2. `powos-hardware-detect.service` runs
3. Detects: DMI = "Jupiter", GPU = AMD
4. Activates overlays:
   - `steamdeck-jupiter.raw`
   - `gaming-mode.raw`
   - `audio-steamdeck.raw`
5. Enables services:
   - `jupiter-fan-control.service`
   - `vpower.service`
   - `bazzite-autologin.service`
6. User sees Steam Deck UI on first login

### Switching Modes (Desktop ↔ Gaming Mode)

**Enable Gaming Mode:**
```bash
ujust enable-gaming-mode
# Activates gaming-mode.raw overlay
# Enables auto-login and gamescope session
# Reboot required
```

**Disable Gaming Mode:**
```bash
ujust disable-gaming-mode
# Deactivates gaming-mode.raw overlay
# Disables auto-login
# Returns to KDE Plasma desktop
# Reboot required
```

### Adding Device Support

**User has unsupported handheld device:**
1. Community creates overlay: `gpd-win4.raw`
2. User downloads overlay: `powos-overlay install community/gpd-win4`
3. Overlay placed in `/var/lib/extensions/available/`
4. Detection script auto-activates on next boot
5. Device works out of the box

---

## Build System Changes

### Bazzite Build (Original)
```bash
# Builds 6+ image variants
podman build -f Containerfile --target bazzite -t bazzite:latest
podman build -f Containerfile --target bazzite-deck -t bazzite-deck:latest
podman build -f Containerfile --target bazzite-nvidia -t bazzite-nvidia:latest
# ... (more variants)
```

### PowOS Build (New)
```bash
# Build base images (2)
podman build -f containers/Containerfile.mesa -t powos-base-mesa:latest
podman build -f containers/Containerfile.nvidia -t powos-base-nvidia:latest

# Build overlays (separate process)
cd overlays/
./build-overlay.sh steamdeck-jupiter
./build-overlay.sh rog-ally
./build-overlay.sh gaming-mode
# ... (more overlays)
```

---

## Future Overlay Ideas

### Potential Overlays
- `laptop-power.raw` - TLP/power management for laptops
- `desktop-perf.raw` - Performance tuning for desktops
- `server-mode.raw` - Headless server configuration
- `dev-tools.raw` - Development environment
- `ai-tools.raw` - AI/ML frameworks (CUDA, ROCm, PyTorch)
- `streaming.raw` - OBS, streaming tools
- `vr-support.raw` - VR runtime, SteamVR
- `retro-gaming.raw` - RetroArch, emulators

### Community Overlays
Users can create and share overlays for:
- Niche hardware devices
- Specific game optimizations
- Regional configurations
- Custom DE themes

---

## Technical Details

### systemd-sysext Capabilities
- Overlays `/usr` directory (read-only)
- Stacks multiple extensions
- Version matching via `extension-release`
- Atomic activation/deactivation
- No base image modification

### systemd-confext Capabilities
- Overlays `/etc` directory
- Merges configuration files
- Supports drop-ins
- Device-specific configs

### Limitations
- Cannot modify existing base files (only add)
- Kernel modules need version matching
- Services in overlays not auto-enabled (detection script does this)
- Firmware must be in base image (loaded before sysext activation)

---

## Migration Guide: Bazzite → PowOS

### For Bazzite Desktop Users
**Old:** `bazzite:latest` (kinoite)
**New:** `powos-base-mesa:latest`
**Overlays:** None (desktop use)
**Migration:** Direct switch, no data loss

### For Bazzite-Deck Users (Steam Deck)
**Old:** `bazzite-deck:latest`
**New:** `powos-base-mesa:latest` + `steamdeck-jupiter.raw` + `gaming-mode.raw`
**Migration:**
1. Switch to `powos-base-mesa`
2. Overlays auto-activate on first boot
3. Gaming mode auto-enabled

### For Bazzite-NVIDIA Users
**Old:** `bazzite-nvidia:latest`
**New:** `powos-base-nvidia:latest`
**Overlays:** None (desktop use)
**Migration:** Direct switch, NVIDIA drivers included

---

## Development Roadmap

### Phase 1: Core Base Images (Current)
- [x] `powos-base-mesa` Containerfile
- [x] `powos-base-nvidia` Containerfile
- [ ] Build and test base images
- [ ] Hardware detection service

### Phase 2: Essential Overlays
- [ ] `steamdeck-jupiter.raw`
- [ ] `steamdeck-galileo.raw`
- [ ] `gaming-mode.raw`
- [ ] `rog-ally.raw`

### Phase 3: Extended Hardware Support
- [ ] Legion Go
- [ ] Framework laptops
- [ ] GPD Win devices
- [ ] Generic handheld fallback

### Phase 4: Community Ecosystem
- [ ] Overlay repository
- [ ] Submission guidelines
- [ ] Automated testing
- [ ] Documentation

---

**End of Document**
