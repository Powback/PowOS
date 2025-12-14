#!/usr/bin/env bash
# build.sh - Build KDE applications from source
#
# Usage:
#   OVERLAY_NAME=kde:dolphin ./build.sh    # Build Dolphin
#   OVERLAY_NAME=kde:konsole ./build.sh    # Build Konsole
#
# This script builds individual KDE apps from the shared KDE source.

set -euo pipefail

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
FULL_NAME="${OVERLAY_NAME:-kde}"
SRC_DIR="$(dirname "$0")"

# Parse app name from kde:appname format
if [[ "$FULL_NAME" == *":"* ]]; then
    APP_NAME="${FULL_NAME#*:}"
else
    echo "Usage: powos source build kde:<app>"
    echo ""
    echo "Available apps:"
    for app in dolphin konsole kate gwenview okular spectacle ark; do
        echo "  kde:$app"
    done
    exit 1
fi

echo "Building: KDE $APP_NAME"
echo "Output:   $OUTPUT_DIR"

UPSTREAM_DIR="$SRC_DIR/upstream"
APP_DIR="$UPSTREAM_DIR/$APP_NAME"
PATCHES_DIR="$SRC_DIR/patches/$APP_NAME"

# Check if app source exists
if [[ ! -d "$APP_DIR" ]]; then
    echo "App source not found: $APP_DIR"
    echo "Run 'powos source get kde' first, or fetching now..."

    # Fetch just this app
    mkdir -p "$UPSTREAM_DIR"
    source "$SRC_DIR/source.conf"

    echo "Cloning $APP_NAME..."
    case "$APP_NAME" in
        dolphin|gwenview|spectacle|ark)
            git clone --depth 1 "$KDE_INVENT_URL/system/$APP_NAME.git" "$APP_DIR"
            ;;
        konsole|kate|okular)
            git clone --depth 1 "$KDE_INVENT_URL/utilities/$APP_NAME.git" "$APP_DIR"
            ;;
        *)
            # Try system first, then utilities
            git clone --depth 1 "$KDE_INVENT_URL/system/$APP_NAME.git" "$APP_DIR" 2>/dev/null || \
            git clone --depth 1 "$KDE_INVENT_URL/utilities/$APP_NAME.git" "$APP_DIR"
            ;;
    esac
fi

# Apply patches if any exist
if [[ -d "$PATCHES_DIR" ]] && ls "$PATCHES_DIR"/*.patch 1>/dev/null 2>&1; then
    echo "Applying patches..."
    cd "$APP_DIR"
    for patch in "$PATCHES_DIR"/*.patch; do
        [[ -f "$patch" ]] || continue
        echo "  $(basename "$patch")"
        git apply "$patch" 2>/dev/null || patch -p1 < "$patch" || true
    done
    cd - >/dev/null
fi

# Prepare output directories
mkdir -p "$OUTPUT_DIR/usr/bin"
mkdir -p "$OUTPUT_DIR/usr/lib64"
mkdir -p "$OUTPUT_DIR/usr/share/applications"

cd "$APP_DIR"

# Create build directory
rm -rf build
mkdir -p build
cd build

# Configure with CMake
echo "Configuring $APP_NAME..."
cmake .. \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF

# Build
echo "Building $APP_NAME..."
make -j$(nproc)

# Install to overlay
echo "Installing to overlay..."
make install DESTDIR="$OUTPUT_DIR"

echo "✅ Built: KDE $APP_NAME"
echo "   Location: $OUTPUT_DIR"
