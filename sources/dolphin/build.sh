#!/usr/bin/env bash
# build.sh - Build Dolphin file manager from source
#
# This creates a custom Dolphin build that overrides the system version.

set -euo pipefail

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
NAME="${OVERLAY_NAME:-dolphin}"
SRC_DIR="$(dirname "$0")"
UPSTREAM_DIR="$SRC_DIR/upstream"

echo "Building: $NAME"
echo "Output:   $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR/usr/bin"
mkdir -p "$OUTPUT_DIR/usr/lib64"
mkdir -p "$OUTPUT_DIR/usr/share/applications"
mkdir -p "$OUTPUT_DIR/usr/share/dolphin"

if [[ ! -d "$UPSTREAM_DIR" ]]; then
    echo "No upstream source. Run 'powos source get dolphin' first."
    exit 1
fi

cd "$UPSTREAM_DIR"

# Create build directory
mkdir -p build
cd build

# Configure with CMake
echo "Configuring Dolphin..."
cmake .. \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF

# Build
echo "Building Dolphin..."
make -j$(nproc)

# Install to overlay
echo "Installing to overlay..."
make install DESTDIR="$OUTPUT_DIR"

echo "Built: $NAME"
echo "   Binary: $OUTPUT_DIR/usr/bin/dolphin"
