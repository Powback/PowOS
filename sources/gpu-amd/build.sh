#!/usr/bin/env bash
# build.sh - Build script for gpu-amd overlay

set -euo pipefail

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
NAME="${OVERLAY_NAME:-gpu-amd}"

echo "Building: $NAME"

mkdir -p "$OUTPUT_DIR/etc/environment.d"
mkdir -p "$OUTPUT_DIR/usr/lib/udev/rules.d"

# 1. Environment variables for AMD performance
cat > "$OUTPUT_DIR/etc/environment.d/amd-performance.conf" << 'EOF'
# Force AMDVLK or RADV (usually RADV is preferred for gaming)
AMD_VULKAN_ICD=radv
# Enable ACO compiler (usually default now, but good to ensure)
RADV_PERFTEST=aco
EOF

# 2. Udev rules for power management (optional, usually kernel handles this well)
cat > "$OUTPUT_DIR/usr/lib/udev/rules.d/30-amdgpu-pm.rules" << 'EOF'
# Example: set power profile to auto on battery
KERNEL=="card0", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/power_dpm_state}="balanced"
EOF

echo "✅ Built: $NAME"
