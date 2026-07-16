#!/usr/bin/env bash
# build.sh - PowStream Vulkan capture layer → system overlay
#
# Builds libvklayer_powstream_capture.so from the PowStream repo and lays
# out the SYSTEM-WIDE equivalents of what layers/vk-capture/install.sh
# does per-user:
#
#   per-user (install.sh)                    → this overlay (/usr, sysext)
#   ~/.local/lib/powstream/*.so              → /usr/lib/powstream/*.so
#   ~/.local/share/vulkan/implicit_layer.d/  → /usr/share/vulkan/implicit_layer.d/
#   ~/.config/environment.d/powstream.conf   → /usr/lib/environment.d/powstream.conf
#
# Source resolution: uses ~/Projects/PowStream if present (dev box),
# otherwise clones UPSTREAM_URL from source.conf into upstream/.
#
# Requires: cargo (rust toolchain). The layer builds fine without a GPU;
# the GPU is only needed at runtime.

set -euo pipefail

OUTPUT_DIR="${1:-$OVERLAY_OUTPUT_DIR}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/source.conf"

# ── Resolve PowStream source ────────────────────────────────────────
SRC=""
if [[ -d "${LOCAL_CHECKOUT}/layers/vk-capture" ]]; then
    SRC="$LOCAL_CHECKOUT"
elif [[ -d "$SCRIPT_DIR/upstream/layers/vk-capture" ]]; then
    SRC="$SCRIPT_DIR/upstream"
else
    echo "Cloning $UPSTREAM_URL..."
    git clone --depth 1 "$UPSTREAM_URL" "$SCRIPT_DIR/upstream"
    SRC="$SCRIPT_DIR/upstream"
fi
echo "PowStream source: $SRC"

# ── Build the layer ─────────────────────────────────────────────────
command -v cargo >/dev/null 2>&1 || {
    echo "ERROR: cargo not found. Install rust (powos install rust) and retry." >&2
    exit 1
}
SO="$SRC/target/release/libvklayer_powstream_capture.so"
if [[ ! -f "$SO" ]]; then
    (cd "$SRC" && cargo build --release -p powstream-vklayer-capture)
fi
[[ -f "$SO" ]] || { echo "ERROR: build produced no $SO" >&2; exit 1; }

# ── Lay out the overlay ─────────────────────────────────────────────
LIB_DIR="$OUTPUT_DIR/usr/lib/powstream"
MANIFEST_DIR="$OUTPUT_DIR/usr/share/vulkan/implicit_layer.d"
ENV_DIR="$OUTPUT_DIR/usr/lib/environment.d"
mkdir -p "$LIB_DIR" "$MANIFEST_DIR" "$ENV_DIR"

install -m 0755 "$SO" "$LIB_DIR/"

sed "s|@LIBRARY_PATH@|/usr/lib/powstream/libvklayer_powstream_capture.so|" \
    "$SRC/layers/vk-capture/VkLayer_POWSTREAM_capture.json.in" \
    > "$MANIFEST_DIR/VkLayer_POWSTREAM_capture.json"

# Global capture flag — layer stays dormant unless the PowStream server
# sentinel (/tmp/depthcap/streaming.active) exists.
cat > "$ENV_DIR/powstream.conf" <<'CONF'
POWSTREAM_CAPTURE=1
CONF

echo "✅ Built: powstream overlay"
echo "   /usr/lib/powstream/libvklayer_powstream_capture.so"
echo "   /usr/share/vulkan/implicit_layer.d/VkLayer_POWSTREAM_capture.json"
echo "   /usr/lib/environment.d/powstream.conf"
echo ""
echo "NOTE: if the per-user install was ever run, remove it to avoid a"
echo "double-loaded layer:"
echo "   rm -f ~/.local/share/vulkan/implicit_layer.d/VkLayer_POWSTREAM_capture.json"
echo "   rm -f ~/.config/environment.d/powstream.conf"
