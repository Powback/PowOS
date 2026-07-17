#!/usr/bin/env bash
# build.sh — Build/install KZones into the overlay output directory.
#
# Environment variables provided by overlay-manager.sh:
#   OVERLAY_OUTPUT_DIR  — where to place built files
#   OVERLAY_NAME        — name of this overlay (powzones)
#
# The overlay system packs OUTPUT_DIR into a systemd-sysext image that merges
# into /usr at runtime. Files placed under OUTPUT_DIR/usr/share/... appear at
# /usr/share/... once the extension is enabled.
#
# KWin discovers scripts under /usr/share/kwin/scripts/<name>/ — so we extract
# kzones.kwinscript (a zip) directly into that path.
#
# // [powos.zones.install]
# KWin script installed by unpacking the upstream .kwinscript zip into
# /usr/share/kwin/scripts/kzones/ inside the overlay output directory.

set -euo pipefail

# shellcheck source=source.conf
source "$(dirname "$0")/source.conf"

OUTPUT_DIR="${1:-${OVERLAY_OUTPUT_DIR:-}}"
if [[ -z "$OUTPUT_DIR" ]]; then
    echo "ERROR: OUTPUT_DIR not set. Run via overlay-manager or pass as \$1." >&2
    exit 1
fi

echo "Building: $SOURCE_NAME  ($UPSTREAM_VERSION)"
echo "Output:   $OUTPUT_DIR"

TMP_ZIP="$(mktemp --suffix=.kwinscript)"
trap 'rm -f "$TMP_ZIP"' EXIT

echo "Downloading $KWINSCRIPT_URL ..."
curl -fsSL "$KWINSCRIPT_URL" -o "$TMP_ZIP"

# KWin loads scripts from /usr/share/kwin/scripts/<name>/
INSTALL_DIR="$OUTPUT_DIR/usr/share/kwin/scripts/kzones"
mkdir -p "$INSTALL_DIR"
unzip -q -o "$TMP_ZIP" -d "$INSTALL_DIR"

echo "✅ Built: $SOURCE_NAME"
echo "   Script: $INSTALL_DIR/"
