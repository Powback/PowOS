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
SO="$SRC/target/release/libvklayer_powstream_capture.so"
if [[ ! -f "$SO" ]]; then
    command -v cargo >/dev/null 2>&1 || {
        echo "ERROR: no prebuilt $SO and cargo not found." >&2
        echo "Either build it in the repo (./scripts/build-rust.sh, Docker) or install rust (powos install rust) and retry." >&2
        exit 1
    }
    (cd "$SRC" && cargo build --release -p powstream-vklayer-capture)
fi
[[ -f "$SO" ]] || { echo "ERROR: build produced no $SO" >&2; exit 1; }

# ── Build the runtime binaries (best-effort) ────────────────────────
# The server + sidecar need GStreamer/pipewire dev libs at build time. When
# those are present (CI image build, dev container) compile them so the image
# ships a complete pipeline; otherwise fall back to any prebuilt binaries
# (target/release or host-bins) and let ship_bin warn. Never fail the overlay
# build over these — the capture layer above is the hard requirement.
if command -v cargo >/dev/null 2>&1; then
    for pkg in powstream-webrtc-server powlens-detector-sidecar; do
        [[ -f "$SRC/target/release/$pkg" || -f "$SRC/host-bins/$pkg" ]] && continue
        echo "Building $pkg (best-effort)…"
        (cd "$SRC" && cargo build --release -p "$pkg") \
            || echo "WARN: $pkg build failed (missing gstreamer/pipewire dev libs?) — will use prebuilt if available" >&2
    done
fi

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

# ── Runtime services: WebRTC server + detector sidecar ──────────────
# Ship the binaries and user units so the pipeline is up after login —
# nobody should have to hand-start these to connect (friction 2026-07-16).
BIN_OUT="$OUTPUT_DIR/usr/lib/powstream/bin"
UNIT_DIR="$OUTPUT_DIR/usr/lib/systemd/user"
WANTS_DIR="$UNIT_DIR/default.target.wants"
mkdir -p "$BIN_OUT" "$UNIT_DIR" "$WANTS_DIR"

ship_bin() { # <name>  (looks in target/release, then host-bins — the Docker
    # build writes target/ into a named volume, so host-side copies land in
    # host-bins/ via scripts/build-rust.sh or a manual container cp)
    local p
    for p in "$SRC/target/release/$1" "$SRC/host-bins/$1"; do
        [[ -f "$p" ]] && { install -m 0755 "$p" "$BIN_OUT/$1"; return 0; }
    done
    echo "WARN: $1 not built — service skipped" >&2
    return 1
}

# Browser client (ATW viewer + dashboards) — the server serves this via --web-root.
if [[ -d "$SRC/web/webrtc" ]]; then
    mkdir -p "$OUTPUT_DIR/usr/lib/powstream/web"
    cp -r "$SRC/web/webrtc/." "$OUTPUT_DIR/usr/lib/powstream/web/"
fi

if ship_bin powstream-webrtc-server; then
    cat > "$UNIT_DIR/powstream-webrtc-server.service" <<'UNIT'
[Unit]
Description=PowStream WebRTC streaming server (depth + camera ATW)
# Real login sessions only — never the plasmalogin greeter or other
# system-user managers (see the traefik users/ lesson, 2026-07-16).
ConditionUser=!@system

[Service]
ExecStartPre=/usr/bin/mkdir -p /tmp/depthcap
# 120fps halves the pacer's frame-quantization latency vs 60 (~16ms→~8ms) on
# high-refresh displays; 20Mbps keeps per-frame quality since bits/frame
# otherwise halve at 120fps. Both overridable via a drop-in.
Environment=POWSTREAM_FPS=120 POWSTREAM_BITRATE=20000
ExecStart=/usr/lib/powstream/bin/powstream-webrtc-server --web-root /usr/lib/powstream/web --fps ${POWSTREAM_FPS} --bitrate ${POWSTREAM_BITRATE}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT
    ln -sfn ../powstream-webrtc-server.service "$WANTS_DIR/powstream-webrtc-server.service"
fi

if ship_bin powlens-detector-sidecar; then
    cat > "$UNIT_DIR/powlens-sidecar.service" <<'UNIT'
[Unit]
Description=PowLens detector sidecar (FOV/VP detection, :8791)
ConditionUser=!@system

[Service]
ExecStartPre=/usr/bin/mkdir -p /tmp/depthcap
ExecStart=/usr/lib/powstream/bin/powlens-detector-sidecar /tmp/depthcap
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT
    ln -sfn ../powlens-sidecar.service "$WANTS_DIR/powlens-sidecar.service"
fi

echo "✅ Built: powstream overlay"
echo "   /usr/lib/powstream/libvklayer_powstream_capture.so"
echo "   /usr/share/vulkan/implicit_layer.d/VkLayer_POWSTREAM_capture.json"
echo "   /usr/lib/environment.d/powstream.conf"
echo ""
echo "NOTE: if the per-user install was ever run, remove it to avoid a"
echo "double-loaded layer:"
echo "   rm -f ~/.local/share/vulkan/implicit_layer.d/VkLayer_POWSTREAM_capture.json"
echo "   rm -f ~/.config/environment.d/powstream.conf"
