#!/usr/bin/env bash
# build.sh - build powos-shell (and install shell/, the web UI) into OUTPUT_DIR: usr/bin/powos-shell,
# usr/share/applications/org.powos.shell.desktop, usr/share/powos/shell/.
#
#   sources/powos-shell/build.sh OUTPUT_DIR          (or OVERLAY_OUTPUT_DIR, from overlay-manager.sh)
#
# Needs source.conf's BUILD_DEPS; image-build.sh installs them in the image build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=source.conf
source "$HERE/source.conf"
OUTPUT_DIR="${1:-${OVERLAY_OUTPUT_DIR:-}}"
[[ -n "$OUTPUT_DIR" ]] || { echo "usage: build.sh OUTPUT_DIR" >&2; exit 1; }
# shell/ is the repo's (../../shell); POWOS_SHELL_WEB overrides it (the image build copies it elsewhere).
WEB="${POWOS_SHELL_WEB:-$HERE/../../shell}"
[[ -f "$WEB/index.html" ]] || { echo "build.sh: no shell/ at $WEB" >&2; exit 1; }
BUILD="${POWOS_SHELL_BUILD_DIR:-$(mktemp -d)}"

echo "Building: $SOURCE_NAME -> $OUTPUT_DIR"
cmake -S "$HERE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr \
    -DPOWOS_SHELL_WEB="$(cd "$WEB" && pwd)"
ninja -C "$BUILD"
DESTDIR="$OUTPUT_DIR" ninja -C "$BUILD" install
echo "Built: $SOURCE_NAME ($(du -sh "$OUTPUT_DIR/usr/bin/powos-shell" | cut -f1) binary)"
