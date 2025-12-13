# PowOS Overlays - Quick Start Guide

## For Developers: Building Overlays

### 1. Prerequisites

```bash
# Install required tools
sudo dnf install erofs-utils dnf5
```

### 2. Build All Overlays

```bash
cd /projects/ML/Private/PowOS/overlays
make all
```

This creates `.raw` overlay images in `output/`.

### 3. Build Specific Overlay

```bash
# Just Steam Deck Jupiter
make build-steamdeck-jupiter

# Or use the build script directly
./build-overlay.sh steamdeck-jupiter
```

### 4. Check Build Output

```bash
ls -lh output/
cat output/steamdeck-jupiter.manifest
```

## For Container Builds: Integration

### Add to Containerfile

```dockerfile
# Copy and build overlays
COPY overlays/ /tmp/overlays/
RUN cd /tmp/overlays && \
    make all && \
    make install && \
    rm -rf /tmp/overlays

# Create hardware detection service
COPY overlays/systemd/powos-hardware-detect.service /usr/lib/systemd/system/
RUN systemctl enable powos-hardware-detect.service
```

### Create the systemd service file

Create `overlays/systemd/powos-hardware-detect.service`:

```ini
[Unit]
Description=PowOS Hardware Detection and Overlay Activation
After=systemd-sysext.service local-fs.target
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/powos-hardware-detect
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

## For Users: Testing Overlays

### Manual Activation (Testing)

```bash
# 1. Build an overlay
./build-overlay.sh steamdeck-jupiter

# 2. Copy to system extensions directory
sudo cp output/steamdeck-jupiter.raw /var/lib/extensions/

# 3. Activate overlay
sudo systemd-sysext refresh

# 4. Check status
systemd-sysext status

# 5. Verify merged files
systemd-sysext list
```

### Check Active Overlays

```bash
# See what's active
systemd-sysext status

# See what's available
ls -lh /usr/share/powos/overlays/

# See what's linked
ls -lh /var/lib/extensions/
```

### Deactivate Overlays

```bash
# Unmerge all overlays
sudo systemd-sysext unmerge

# Remove specific overlay
sudo rm /var/lib/extensions/steamdeck-jupiter.raw

# Refresh
sudo systemd-sysext refresh
```

## For Contributors: Adding Device Support

### 1. Create Overlay Directory

```bash
cd overlays
mkdir -p my-device/{services,configs,extension-release.d}
```

### 2. Define Metadata

Create `my-device/metadata.env`:

```bash
OVERLAY_VERSION="1.0.0"
OS_VERSION="43"
OVERLAY_TYPE="device-hardware"
DMI_MATCH="Device Product Name"
DEVICE_NAME="My Device"
```

### 3. List Required Packages

Create `my-device/packages.txt`:

```
# Device-specific packages
my-device-driver
my-device-utils
```

### 4. Add Extension Metadata

Create `my-device/extension-release.d/custom-fields`:

```
POWOS_DMI_MATCH=Device Product Name
POWOS_DEVICE_NAME=My Device
POWOS_VENDOR=Manufacturer
POWOS_FORM_FACTOR=handheld
```

### 5. Create Build Script

Create `my-device/build.sh`:

```bash
#!/usr/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/../build-overlay.sh" "my-device"
```

Make it executable:

```bash
chmod +x my-device/build.sh
```

### 6. Update Hardware Detection

Edit `detect-and-enable.sh` and add detection logic:

```bash
# Check for My Device
elif [[ "$DMI_PRODUCT_NAME" =~ "My Device" ]]; then
    log_info "Detected: My Device"
    activate_overlay "my-device"
    enable_services my-device.service
    DEVICE_DETECTED=true
```

### 7. Test Build

```bash
./build-overlay.sh my-device
ls -lh output/my-device.raw
cat output/my-device.manifest
```

### 8. Submit Pull Request

- Test on real hardware
- Document tested configurations
- Include detection logic changes
- Add device to README.md device list

## Hardware Detection Reference

### Find Your Device Info

```bash
# Product name
cat /sys/devices/virtual/dmi/id/product_name

# Board name
cat /sys/devices/virtual/dmi/id/board_name

# Vendor
cat /sys/devices/virtual/dmi/id/chassis_vendor

# Chassis type
cat /sys/devices/virtual/dmi/id/chassis_type

# All DMI info
cat /sys/devices/virtual/dmi/id/*
```

### Common Chassis Types

- `8` = Portable
- `9` = Laptop
- `10` = Notebook
- `30` = Tablet
- `31` = Convertible

## Troubleshooting

### Build Fails: Missing erofs-utils

```bash
sudo dnf install erofs-utils
# OR
sudo dnf install squashfs-tools
```

### Overlay Won't Activate: Version Mismatch

Check that overlay `VERSION_ID` matches base OS:

```bash
# Check OS version
cat /usr/lib/os-release | grep VERSION_ID

# Update metadata.env to match
OS_VERSION="43"  # Must match OS VERSION_ID
```

### Services Not Available: Check Overlay

```bash
# List files in overlay
erofs-dump output/my-device.raw

# Check service files
systemctl list-unit-files | grep my-device
```

### Files Not Merging: Wrong Directory

systemd-sysext only merges `/usr`. Put files in:
- `configs/usr/` (NOT `configs/etc/`)

## Common Use Cases

### Add Audio Profile for New Device

```bash
# 1. Create overlay
mkdir -p overlays/my-device/audio-profiles/{pipewire,wireplumber}

# 2. Copy audio configs
cp /path/to/device/pipewire/* overlays/my-device/audio-profiles/pipewire/
cp /path/to/device/wireplumber/* overlays/my-device/audio-profiles/wireplumber/

# 3. Build
./build-overlay.sh my-device
```

### Add Systemd Service

```bash
# 1. Create service file
cat > overlays/my-device/services/my-device.service <<EOF
[Unit]
Description=My Device Service

[Service]
Type=oneshot
ExecStart=/usr/bin/my-device-setup

[Install]
WantedBy=multi-user.target
EOF

# 2. Build
./build-overlay.sh my-device

# 3. Enable in detection script
enable_services my-device.service
```

## Next Steps

- Read full documentation: [README.md](README.md)
- Review architecture: [../docs/OVERLAY-ARCHITECTURE.md](../docs/OVERLAY-ARCHITECTURE.md)
- See removed packages: [../docs/REMOVED-FOR-OVERLAYS.md](../docs/REMOVED-FOR-OVERLAYS.md)
- Check Bazzite analysis: [../docs/BAZZITE-ANALYSIS.md](../docs/BAZZITE-ANALYSIS.md)

---

**Need Help?** Open an issue on GitHub!
