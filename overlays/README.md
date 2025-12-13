# PowOS Systemd-Sysext Overlay System

This directory contains the systemd-sysext overlay build system for PowOS. Overlays provide device-specific hardware support and optional features that are automatically activated based on detected hardware.

## Overview

PowOS uses a **base + overlay** architecture:
- **Base images** (`powos-base-mesa` and `powos-base-nvidia`) contain only essential, hardware-agnostic components
- **Overlays** provide device-specific functionality, loaded at boot based on hardware detection

This approach provides:
- Smaller base images (~160-240MB smaller vs monolithic images)
- Modular updates (update base OR overlays independently)
- Easy community contributions (add new device support without rebuilding base)
- User customization (enable/disable features at runtime)

## Directory Structure

```
overlays/
├── build-overlay.sh          # Generic overlay build script
├── detect-and-enable.sh      # Hardware detection and activation script
├── Makefile                  # Build all overlays
├── README.md                 # This file
│
├── output/                   # Built .raw overlay images
│   ├── steamdeck-jupiter.raw
│   ├── gaming-mode.raw
│   └── ...
│
├── steamdeck-jupiter/        # Steam Deck LCD overlay
│   ├── metadata.env          # Overlay metadata
│   ├── packages.txt          # Packages to install
│   ├── services/             # Systemd services
│   ├── configs/              # Configuration files
│   ├── audio-profiles/       # Device-specific audio configs
│   ├── extension-release.d/  # Extension metadata
│   └── build.sh              # Overlay-specific build script
│
├── steamdeck-galileo/        # Steam Deck OLED overlay
├── rog-ally/                 # ASUS ROG Ally overlay
├── legion-go/                # Lenovo Legion Go overlay
├── gaming-mode/              # Console gaming UI overlay
├── laptop-power/             # Laptop power management (planned)
└── desktop-perf/             # Desktop performance mode (planned)
```

## Building Overlays

### Prerequisites

- Fedora-based system (or container)
- `dnf` package manager
- `mkfs.erofs` (from `erofs-utils`) OR `mksquashfs` (from `squashfs-tools`)
- Root/sudo access (for package installation)

### Build All Overlays

```bash
cd /projects/ML/Private/PowOS/overlays
make all
```

This builds all defined overlays and places `.raw` images in `output/`.

### Build Specific Overlay

```bash
make build-steamdeck-jupiter
# OR
./build-overlay.sh steamdeck-jupiter
```

### Clean Build Artifacts

```bash
make clean
```

### List Available Overlays

```bash
make list
```

## Available Overlays

### Device-Specific Hardware Overlays

#### `steamdeck-jupiter.raw` - Steam Deck (LCD)
**Detection:** DMI Product Name = "Jupiter"
**Packages:**
- `jupiter-fan-control` - Steam Deck fan control
- `vpower` - Virtual power device
- `steamdeck-dsp` - Audio DSP profiles
- `powerbuttond` - Power button daemon
- Audio profiles for Steam Deck

**Services Enabled:**
- `jupiter-fan-control.service`
- `vpower.service`
- `pipewire-workaround.service`
- `wireplumber-workaround.service`

#### `steamdeck-galileo.raw` - Steam Deck (OLED)
**Detection:** DMI Product Name = "Galileo"
**Packages:** Same as Jupiter, plus:
- `galileo-mura` - OLED display calibration

#### `rog-ally.raw` - ASUS ROG Ally
**Detection:** DMI Product Name contains "ROG Ally"
**Features:**
- Device-specific audio profiles
- Pipewire/Wireplumber configurations

#### `legion-go.raw` - Lenovo Legion Go
**Detection:** DMI Board Name = "83E1"
**Features:**
- Device-specific audio profiles
- Lenovo-specific configurations

### Mode Overlays

#### `gaming-mode.raw` - Console Gaming Interface
**Purpose:** Provides Steam Big Picture console-like experience
**Packages:**
- `gamescope-session-plus` - Gamescope-based gaming session
- `gamescope-session-steam` - Steam integration
- `steamos-manager` - SteamOS-like system manager
- `hhd` / `hhd-ui` - Handheld Daemon (universal controller support)

**Services Enabled:**
- `hhd.service` - Handheld daemon
- `bazzite-autologin.service` - Auto-login to gaming mode

**Services Disabled:**
- `input-remapper.service` - Conflicts with hhd
- `uupd.timer` - Gaming mode handles updates differently

**Activation:** Automatic for detected handhelds, manual for desktop (`ujust enable-gaming-mode`)

### Form Factor Overlays (Planned)

#### `laptop-power.raw` - Laptop Power Management
**Purpose:** TLP/power-profiles-daemon optimizations for laptops
**Status:** Planned

#### `desktop-perf.raw` - Desktop Performance Mode
**Purpose:** Performance tuning, no power saving
**Status:** Planned

## How Overlays Work

### 1. Boot-Time Activation

At boot, the `powos-hardware-detect.service` runs:

1. **Hardware Detection:**
   - DMI/SMBIOS data (`/sys/devices/virtual/dmi/id/`)
   - CPU vendor (`/proc/cpuinfo`)
   - GPU vendor (`lspci`)

2. **Overlay Selection:**
   - Matches detected hardware against overlay metadata
   - Creates symlinks in `/var/lib/extensions/`

3. **systemd-sysext Refresh:**
   - Activates overlays by merging them into `/usr`
   - Services from overlays become available

4. **Service Management:**
   - Enables device-specific services
   - Disables conflicting services

### 2. Overlay Structure

Each overlay is a `.raw` filesystem image (erofs or squashfs) containing:

```
overlay.raw/
└── usr/
    ├── bin/                              # Binaries
    ├── lib64/                            # Libraries
    ├── lib/
    │   ├── systemd/system/               # Systemd services
    │   └── extension-release.d/
    │       └── extension-release.<name>  # Required metadata
    └── share/
        ├── pipewire/hardware-profiles/   # Audio profiles
        └── wireplumber/hardware-profiles/
```

### 3. Extension Metadata

Each overlay must have an `extension-release` file:

```ini
ID=fedora
VERSION_ID=43
SYSEXT_LEVEL=1.0
ARCHITECTURE=x86-64
POWOS_OVERLAY_VERSION=1.0.0
POWOS_OVERLAY_TYPE=device-hardware
POWOS_DMI_MATCH=Jupiter
POWOS_DEVICE_NAME=Steam Deck (LCD)
```

This ensures overlays match the base OS version.

## Creating a New Overlay

### Step 1: Create Directory Structure

```bash
mkdir -p overlays/my-device/{services,configs,extension-release.d}
```

### Step 2: Create Metadata

Create `overlays/my-device/metadata.env`:

```bash
OVERLAY_VERSION="1.0.0"
OS_VERSION="43"
OVERLAY_TYPE="device-hardware"
DMI_MATCH="My Device Name"
DEVICE_NAME="My Awesome Device"
```

### Step 3: List Packages

Create `overlays/my-device/packages.txt`:

```
# My Device Hardware Packages
device-specific-driver
device-audio-package
```

### Step 4: Add Custom Metadata

Create `overlays/my-device/extension-release.d/custom-fields`:

```
POWOS_DMI_MATCH=My Device Name
POWOS_DEVICE_NAME=My Awesome Device
POWOS_VENDOR=Device Manufacturer
POWOS_FORM_FACTOR=handheld
```

### Step 5: Add Services (Optional)

Create systemd services in `overlays/my-device/services/`:

```ini
[Unit]
Description=My Device Service

[Service]
Type=oneshot
ExecStart=/usr/bin/my-device-setup

[Install]
WantedBy=multi-user.target
```

### Step 6: Add Audio Profiles (Optional)

Copy device-specific audio profiles to:
- `overlays/my-device/audio-profiles/pipewire/`
- `overlays/my-device/audio-profiles/wireplumber/`

### Step 7: Create Build Script

Create `overlays/my-device/build.sh`:

```bash
#!/usr/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/../build-overlay.sh" "my-device"
```

### Step 8: Update Detection Script

Edit `detect-and-enable.sh` to detect your device:

```bash
# Check for My Device
elif [[ "$DMI_PRODUCT_NAME" =~ "My Device" ]]; then
    log_info "Detected: My Device"
    activate_overlay "my-device"
    enable_services my-device.service
    DEVICE_DETECTED=true
```

### Step 9: Build and Test

```bash
./build-overlay.sh my-device
```

## Hardware Detection Reference

### DMI Paths

```bash
# Product name (most reliable for devices)
cat /sys/devices/virtual/dmi/id/product_name

# Board name (alternative identifier)
cat /sys/devices/virtual/dmi/id/board_name

# Chassis vendor
cat /sys/devices/virtual/dmi/id/chassis_vendor

# Chassis type (form factor)
# 8 = Portable, 9 = Laptop, 10 = Notebook, 30 = Tablet, 31 = Convertible
cat /sys/devices/virtual/dmi/id/chassis_type
```

### Known DMI Values

| Device | Product Name | Board Name |
|--------|--------------|------------|
| Steam Deck LCD | Jupiter | - |
| Steam Deck OLED | Galileo | - |
| ROG Ally | ROG Ally RC71L | - |
| Legion Go | - | 83E1 |

## Testing Overlays

### 1. Test Build

```bash
./build-overlay.sh my-device
ls -lh output/my-device.raw
```

### 2. Check Manifest

```bash
cat output/my-device.manifest
```

### 3. Test Activation (Manual)

```bash
# Copy to extensions directory
sudo cp output/my-device.raw /var/lib/extensions/

# Refresh systemd-sysext
sudo systemd-sysext refresh

# Check status
systemd-sysext status

# List merged files
systemd-sysext list
```

### 4. Test Service Activation

```bash
# Check if services are available
systemctl list-unit-files | grep my-device

# Enable and start service
sudo systemctl enable my-device.service
sudo systemctl start my-device.service

# Check status
systemctl status my-device.service
```

### 5. Test Deactivation

```bash
# Unmerge overlays
sudo systemd-sysext unmerge

# Remove overlay
sudo rm /var/lib/extensions/my-device.raw

# Refresh again
sudo systemd-sysext refresh
```

## Troubleshooting

### Overlay Won't Activate

**Check version matching:**
```bash
# Check OS version
cat /usr/lib/os-release | grep VERSION_ID

# Check overlay metadata
erofs-dump output/my-device.raw | grep extension-release -A 10
# OR for squashfs
unsquashfs -ll output/my-device.raw | grep extension-release
```

**Ensure VERSION_ID matches!**

### Services Not Enabling

Services in overlays aren't auto-enabled. You must:
1. Use the hardware detection script to enable them
2. Create systemd presets in the overlay
3. Manually enable via `systemctl enable`

### Files Not Appearing

systemd-sysext only merges `/usr`. Files in `/etc` won't work.

**Solution:** Use systemd-confext for `/etc` configs (future enhancement)

### Build Fails

**Missing packages:**
```bash
# Install erofs-utils
sudo dnf install erofs-utils

# OR squashfs-tools
sudo dnf install squashfs-tools
```

**Permission errors:**
Build script needs root to install packages via dnf.

## Integration with PowOS Build

### In Containerfile

Add to the PowOS Containerfile:

```dockerfile
# Build overlays
COPY overlays/ /tmp/overlays/
RUN cd /tmp/overlays && \
    make all && \
    make install && \
    rm -rf /tmp/overlays
```

This:
1. Copies overlay source to container
2. Builds all overlays
3. Installs to `/usr/share/powos/overlays/`
4. Installs detection script to `/usr/libexec/powos-hardware-detect`
5. Cleans up build files

### Enable Hardware Detection Service

Create systemd service in base image:

```ini
[Unit]
Description=PowOS Hardware Detection and Overlay Activation
After=systemd-sysext.service
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/powos-hardware-detect
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

## Contributing

### Adding New Device Support

1. Fork the PowOS repository
2. Create a new overlay in `overlays/`
3. Follow the "Creating a New Overlay" guide above
4. Test on real hardware
5. Submit a pull request with:
   - Overlay files
   - Detection logic update
   - Documentation of tested hardware

### Community Overlays

Users can create and share overlays without rebuilding base images:

1. Build your overlay: `./build-overlay.sh my-device`
2. Share the `.raw` file
3. Users install: `sudo cp my-device.raw /var/lib/extensions/`
4. Reboot or `sudo systemd-sysext refresh`

## References

- [systemd-sysext documentation](https://www.freedesktop.org/software/systemd/man/systemd-sysext.html)
- [PowOS Architecture](../docs/OVERLAY-ARCHITECTURE.md)
- [Bazzite Hardware Detection](../docs/BAZZITE-ANALYSIS.md)
- [Removed Packages](../docs/REMOVED-FOR-OVERLAYS.md)

## License

Same as PowOS (check root LICENSE file)

---

**Questions?** Open an issue on the PowOS GitHub repository.
