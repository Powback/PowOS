#!/usr/bin/env bash
# build.sh - Build KDE applications from source
#
# Workflow:
#   1. powos source get kde:dolphin     # Fetch source
#   2. Edit files in sources/kde/upstream/dolphin/
#   3. powos source build kde:dolphin   # Build your modified version
#   4. powos source save kde:dolphin    # (Optional) Save changes as patches
#
# Your edits are built directly - no manual patch creation needed!

set -euo pipefail

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
FULL_NAME="${OVERLAY_NAME:-kde}"
SRC_DIR="$(dirname "$0")"

# Parse app name from kde:appname format
if [[ "$FULL_NAME" == *":"* ]]; then
    APP_NAME="${FULL_NAME#*:}"
else
    # Called without app name (e.g., during build-all) - skip gracefully
    echo "kde: meta-overlay (requires app name)"
    echo "  Use: powos source build kde:<app>"
    echo "  Apps: dolphin konsole kate gwenview okular spectacle ark"
    exit 0  # Exit success - this isn't a failure
fi

echo "Building: KDE $APP_NAME"
echo "Output:   $OUTPUT_DIR"

UPSTREAM_DIR="$SRC_DIR/upstream"
APP_DIR="$UPSTREAM_DIR/$APP_NAME"
PATCHES_DIR="$SRC_DIR/patches/$APP_NAME"

# Check if app source exists - auto-fetch if not
if [[ ! -d "$APP_DIR" ]]; then
    echo "Source not found, fetching $APP_NAME..."
    mkdir -p "$UPSTREAM_DIR"
    source "$SRC_DIR/source.conf"

    # Map apps to KDE Invent categories
    declare -A APP_CATEGORIES=(
        [dolphin]="system"
        [gwenview]="graphics"
        [spectacle]="graphics"
        [ark]="utilities"
        [konsole]="utilities"
        [kate]="utilities"
        [okular]="graphics"
    )
    category="${APP_CATEGORIES[$APP_NAME]:-system}"

    git clone "$KDE_INVENT_URL/$category/$APP_NAME.git" "$APP_DIR" 2>/dev/null || \
    git clone "$KDE_INVENT_URL/system/$APP_NAME.git" "$APP_DIR" 2>/dev/null || \
    git clone "$KDE_INVENT_URL/utilities/$APP_NAME.git" "$APP_DIR"

    echo "✓ Source fetched"
    echo ""
fi

# Check for uncommitted changes (user's edits)
cd "$APP_DIR"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📝 Building with your local modifications"
    git status --short | head -10
    echo ""
fi

# Apply saved patches only on fresh clone (no local changes)
if [[ -z "$(git status --porcelain 2>/dev/null)" ]] && [[ -d "$PATCHES_DIR" ]] && ls "$PATCHES_DIR"/*.patch 1>/dev/null 2>&1; then
    echo "Applying saved patches..."
    for patch in "$PATCHES_DIR"/*.patch; do
        [[ -f "$patch" ]] || continue
        echo "  $(basename "$patch")"
        git apply "$patch" 2>/dev/null || patch -p1 < "$patch" || true
    done
    echo ""
fi

# Prepare output directories
mkdir -p "$OUTPUT_DIR/usr/bin"
mkdir -p "$OUTPUT_DIR/usr/lib64"
mkdir -p "$OUTPUT_DIR/usr/share/applications"

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

echo ""
echo "✅ Built: KDE $APP_NAME"
echo "   Location: $OUTPUT_DIR"
echo ""
echo "💡 To save your changes: powos source save kde:$APP_NAME"
