#!/usr/bin/env bash
# build.sh - Build btop from source
#
# This creates a custom btop build that overrides the system version.

set -euo pipefail

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
NAME="${OVERLAY_NAME:-btop}"
SRC_DIR="$(dirname "$0")"
UPSTREAM_DIR="$SRC_DIR/upstream"

echo "Building: $NAME"
echo "Output:   $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR/usr/bin"
mkdir -p "$OUTPUT_DIR/usr/share/btop/themes"

if [[ ! -d "$UPSTREAM_DIR" ]]; then
    echo "No upstream source. Run 'powos source get btop' first."
    exit 1
fi

cd "$UPSTREAM_DIR"

# Build btop
echo "Building btop..."
make -j$(nproc)

echo "Installing to overlay..."
make install PREFIX=/usr DESTDIR="$OUTPUT_DIR"

echo "✅ Built: $NAME"
echo "   Binary: $OUTPUT_DIR/usr/bin/btop"
