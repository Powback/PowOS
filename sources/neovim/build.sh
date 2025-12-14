#!/usr/bin/env bash
# build.sh - Build Neovim from source
#
# This creates a custom Neovim build that overrides the system version.

set -euo pipefail

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
NAME="${OVERLAY_NAME:-neovim}"
SRC_DIR="$(dirname "$0")"
UPSTREAM_DIR="$SRC_DIR/upstream"

echo "Building: $NAME"
echo "Output:   $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR/usr/bin"
mkdir -p "$OUTPUT_DIR/usr/share/nvim"

if [[ ! -d "$UPSTREAM_DIR" ]]; then
    echo "No upstream source. Run 'powos source get neovim' first."
    exit 1
fi

cd "$UPSTREAM_DIR"

# Build Neovim
echo "Configuring Neovim..."
make CMAKE_BUILD_TYPE=Release CMAKE_INSTALL_PREFIX=/usr

echo "Building Neovim..."
make -j$(nproc)

echo "Installing to overlay..."
make install DESTDIR="$OUTPUT_DIR"

echo "✅ Built: $NAME"
echo "   Binary: $OUTPUT_DIR/usr/bin/nvim"
