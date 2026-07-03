#!/usr/bin/env bash
# build.sh for device-steamdeck
# Sourced from upstream bazzite-fork

set -euo pipefail
source "${POWOS_ROOT}/lib/build-helpers.sh"

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
NAME="device-steamdeck"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAZZITE_SRC="/tmp/bazzite/system_files/deck"

echo "Building: $NAME"
mkdir -p "$OUTPUT_DIR/usr/bin"
mkdir -p "$OUTPUT_DIR/usr/lib"

# 1. Install packages from local list (if we have unique ones)
install_packages "$OUTPUT_DIR" "$SCRIPT_DIR/packages.txt"

# 2. Copy UPSTREAM Bazzite files (The "Link" to the repo)
if [[ -d "$BAZZITE_SRC" ]]; then
    echo "Syncing from upstream Bazzite..."
    
    # Copy shared deck files (udev rules, etc)
    if [[ -d "$BAZZITE_SRC/shared/usr" ]]; then
        cp -r "$BAZZITE_SRC/shared/usr/"* "$OUTPUT_DIR/usr/"
    fi
    
    # We ignore /etc from bazzite for now as sysexts don't support it easily,
    # but we captured the udev rules which are critical.
else
    echo "WARNING: Upstream bazzite-fork not found at $BAZZITE_SRC"
fi

# 3. Copy local overrides (if we have any custom powos specific tweaks)
copy_overlay_files "$SCRIPT_DIR" "$OUTPUT_DIR"

echo "✅ Built: $NAME"
