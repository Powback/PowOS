#!/usr/bin/env bash
# build.sh for device-legion-go
# Sourced from upstream bazzite-fork

set -euo pipefail
source "${POWOS_ROOT}/lib/build-helpers.sh"

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
NAME="device-legion-go"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAZZITE_SRC="/tmp/bazzite/system_files/deck/shared/usr/lib/udev/rules.d"

echo "Building: $NAME"
mkdir -p "$OUTPUT_DIR/usr/bin"
mkdir -p "$OUTPUT_DIR/usr/lib"

install_packages "$OUTPUT_DIR" "$SCRIPT_DIR/packages.txt"

# Sync upstream rules specific to Legion
if [[ -d "$BAZZITE_SRC" ]]; then
    mkdir -p "$OUTPUT_DIR/usr/lib/udev/rules.d"
    # Copy Legion specific rules
    find "$BAZZITE_SRC" -name "*legion*" -exec cp {} "$OUTPUT_DIR/usr/lib/udev/rules.d/" \;
fi

copy_overlay_files "$SCRIPT_DIR" "$OUTPUT_DIR"

echo "✅ Built: $NAME"
