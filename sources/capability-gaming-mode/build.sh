#!/usr/bin/env bash
# build.sh for capability-gaming-mode

set -euo pipefail
source "${POWOS_ROOT}/lib/build-helpers.sh"

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
NAME="capability-gaming-mode"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building: $NAME"
mkdir -p "$OUTPUT_DIR/usr/bin"
mkdir -p "$OUTPUT_DIR/usr/lib"

install_packages "$OUTPUT_DIR" "$SCRIPT_DIR/packages.txt"
copy_overlay_files "$SCRIPT_DIR" "$OUTPUT_DIR"

echo "✅ Built: $NAME"