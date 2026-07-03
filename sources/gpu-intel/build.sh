#!/usr/bin/env bash
# build.sh - Build script for gpu-intel overlay

set -euo pipefail

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
NAME="${OVERLAY_NAME:-gpu-intel}"

echo "Building: $NAME"

mkdir -p "$OUTPUT_DIR/etc/environment.d"

# 1. Environment variables for Intel media
cat > "$OUTPUT_DIR/etc/environment.d/intel-media.conf" << 'EOF'
# Prefer Intel media driver
LIBVA_DRIVER_NAME=iHD
EOF

echo "✅ Built: $NAME"
