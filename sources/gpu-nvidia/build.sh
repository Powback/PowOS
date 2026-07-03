#!/usr/bin/env bash
# build.sh - Build script for gpu-nvidia overlay
#
# This overlay applies NVIDIA-specific configurations.
# Note: The actual kernel drivers must be present in the base image or layered via rpm-ostree.
# This overlay manages runtime configuration, udev rules, and power management.

set -euo pipefail

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
NAME="${OVERLAY_NAME:-gpu-nvidia}"

echo "Building: $NAME"

# 1. Create directory structure
mkdir -p "$OUTPUT_DIR/usr/lib/udev/rules.d"
mkdir -p "$OUTPUT_DIR/usr/bin"

# 2. Add Power Management Udev Rules
# Automatically enable runtime power management for Turing+ GPUs
cat > "$OUTPUT_DIR/usr/lib/udev/rules.d/80-nvidia-pm.rules" << 'EOF'
# Enable runtime PM for NVIDIA VGA/3D controller devices on driver bind
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"

# Disable runtime PM for NVIDIA VGA/3D controller devices on driver unbind
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="on"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="on"
EOF

# NOTE: systemd-sysext only merges /usr (and /opt) — files under etc/ in an
# extension are silently ignored (see lib/build-helpers.sh:104-108). Modprobe
# options (nvidia-drm modeset, NVreg_DynamicPowerManagement) therefore cannot
# be shipped from this overlay; set them via kernel args (config/bootc/kargs.d/)
# or the base image instead.

# 3. Add a helper script
cat > "$OUTPUT_DIR/usr/bin/powos-nvidia-status" << 'EOF'
#!/bin/bash
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi
else
    echo "NVIDIA drivers not loaded or nvidia-smi not found."
    echo "This overlay provides configuration, but the kernel module must be present."
fi
EOF
chmod +x "$OUTPUT_DIR/usr/bin/powos-nvidia-status"

echo "✅ Built: $NAME"
