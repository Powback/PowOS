#!/bin/bash
# powstream-packaging-e2e.sh — does PowOS's PACKAGING of PowStream actually work?
#
# Upstream tests the SERVER. This tests OUR OVERLAY: real source -> real cargo
# build -> sources/powstream/build.sh -> install into the real PowOS image ->
# the server's own `--check-install` gate, plus negative cases proving the gate
# detects breakage rather than always saying ok.
#
# It exists because the class of bug it catches was invisible to everyone:
# PowStream's /atw route took its web root from a RELATIVE path, which resolved
# in a dev checkout and nowhere else. Under our systemd unit the CWD is /, so
# the one route that does depth reprojection 404'd on every PowOS install.
# Every upstream test passed. NEGATIVE 1 below reproduces it exactly.
#
# Tier 2, not tier 1: needs docker, the private PowStream repo, and a ~14GB
# PowOS image. test/tier1/test-powstream-overlay.sh covers the layout half with
# a stub source and no dependencies — run that on every PR, this one nightly or
# by hand.
#
# SAFETY: never writes to the PowStream checkout. The source is copied into a
# docker volume and built there, so a developer's working tree (and its
# target/) is untouched.
#
# Usage:
#   test/tier2/powstream-packaging-e2e.sh [--src DIR] [--keep]
#
#   --src DIR   PowStream checkout to copy from. Default: clone fresh into a
#               temp dir via `gh` (needs access; the repo is private).
#   --keep      Leave the build volume around for a faster re-run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."

POWOS_IMAGE="${POWOS_IMAGE:-ghcr.io/powback/powos:nvidia-open}"
DEV_IMAGE="${POWSTREAM_DEV_IMAGE:-powstream-dev:local}"
VOLUME="${POWSTREAM_BUILD_VOLUME:-ps-build}"
SRC_DIR=""; KEEP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)  SRC_DIR="${2:-}"; shift 2 ;;
        --keep) KEEP=true; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
skip() { echo "  skip - $1"; SKIP=$((SKIP+1)); }
step() { echo; echo "── $* ──"; }

echo "== powstream-packaging-e2e =="

# ── Preflight ────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || { skip "docker not available"; echo "== Results: 0 passed, 0 failed, 1 skipped =="; exit 0; }
docker image inspect "$POWOS_IMAGE" >/dev/null 2>&1 || {
    skip "PowOS image absent: $POWOS_IMAGE  (docker pull it first)"
    echo "== Results: 0 passed, 0 failed, 1 skipped =="; exit 0; }

CLEAN_SRC=""
if [[ -z "$SRC_DIR" ]]; then
    command -v gh >/dev/null 2>&1 || { skip "no --src and gh unavailable"; exit 0; }
    CLEAN_SRC="$(mktemp -d)"
    echo "  cloning PowStream (private) into $CLEAN_SRC…"
    gh repo clone Powback/PowStream "$CLEAN_SRC/PowStream" -- --depth 1 >/dev/null 2>&1 || {
        skip "cannot clone Powback/PowStream — private repo, needs access"
        echo "== Results: 0 passed, 0 failed, 1 skipped =="; exit 0; }
    SRC_DIR="$CLEAN_SRC/PowStream"
fi
[[ -f "$SRC_DIR/Cargo.toml" ]] || { bad "not a PowStream checkout: $SRC_DIR"; exit 1; }

docker image inspect "$DEV_IMAGE" >/dev/null 2>&1 || {
    echo "  building $DEV_IMAGE (one-time)…"
    docker build -q -f "$SRC_DIR/Dockerfile.dev" -t "$DEV_IMAGE" "$SRC_DIR" >/dev/null 2>&1 \
        || { skip "could not build the PowStream dev image"; exit 0; }
}

WORK="$(mktemp -d)"
cleanup() {
    [[ -n "${HELPER:-}" ]] && docker rm -f "$HELPER" >/dev/null 2>&1
    $KEEP || docker volume rm "$VOLUME" >/dev/null 2>&1
    rm -rf "$WORK" "$CLEAN_SRC"
}
trap cleanup EXIT

# ── Build in a VOLUME, never in the developer's checkout ─────────────────
step "build (in a docker volume — the source tree is never written to)"
docker volume create "$VOLUME" >/dev/null 2>&1
HELPER="$(docker run -d --security-opt label=disable -v "$VOLUME":/w "$DEV_IMAGE" sleep 3600 2>/dev/null | tail -1)"
[[ -n "$HELPER" ]] || { bad "could not start build helper"; exit 1; }

tar -C "$SRC_DIR" -cf - . | docker exec -i "$HELPER" tar -C /w -xf - 2>/dev/null
docker exec "$HELPER" bash -c '[[ -f /w/Cargo.toml ]]' \
    && ok "source staged into volume" || { bad "source staging failed"; exit 1; }

docker exec "$HELPER" bash -c 'cd /w && cargo build --release \
    -p powstream-vklayer-capture -p powstream-webrtc-server -p powlens-detector-sidecar' \
    >"$WORK/build.log" 2>&1
BRC=$?
[[ $BRC -eq 0 ]] && ok "cargo build succeeded" || { bad "cargo build failed"; tail -15 "$WORK/build.log" | sed 's/^/      /'; exit 1; }

# ── Assemble the overlay exactly as PowOS would ──────────────────────────
step "overlay build (sources/powstream/build.sh, real artifacts)"
STAGE="$WORK/psroot/Projects/PowStream"
mkdir -p "$STAGE/target/release"
# Only the inputs build.sh reads — copied OUT of the volume, not from $SRC_DIR.
for f in libvklayer_powstream_capture.so powstream-webrtc-server powlens-detector-sidecar; do
    docker exec "$HELPER" cat "/w/target/release/$f" > "$STAGE/target/release/$f" 2>/dev/null
    chmod +x "$STAGE/target/release/$f"
done
for d in layers/vk-capture web/webrtc stream/static; do
    mkdir -p "$STAGE/$(dirname "$d")"
    cp -r "$SRC_DIR/$d" "$STAGE/$d" 2>/dev/null
done

OVL="$WORK/overlay"; mkdir -p "$OVL"
HOME="$WORK/psroot" bash "$REPO_ROOT/sources/powstream/build.sh" "$OVL" >"$WORK/ovl.log" 2>&1
[[ $? -eq 0 ]] && ok "overlay built" || { bad "overlay build failed"; tail -10 "$WORK/ovl.log" | sed 's/^/      /'; }
[[ -s "$OVL/usr/lib/powstream/libvklayer_powstream_capture.so" ]] && ok "layer .so shipped" || bad "layer .so missing"
[[ -n "$(ls -A "$OVL/usr/lib/powstream/atw" 2>/dev/null)" ]] && ok "ATW tree shipped" || bad "ATW tree missing"

tar -C "$OVL" -cf "$WORK/overlay.tar" .

# ── The gate: run the server's own check inside the REAL PowOS image ─────
step "--check-install inside $POWOS_IMAGE"
run_in_powos() {  # stdin = overlay tar; $1 = script
    docker run --rm -i --security-opt label=disable "$POWOS_IMAGE" bash -c "
        tar -C / -xf - 2>/dev/null
        $1" < "$WORK/overlay.tar" 2>&1
}
CHECK='mkdir -p /tmp/depthcap
/usr/lib/powstream/bin/powstream-webrtc-server --check-install \
  --web-root /usr/lib/powstream/web --atw-root /usr/lib/powstream/atw'
OUT="$(run_in_powos "$CHECK")"
grep -q "install OK" <<< "$OUT" && ok "check-install passes on a real PowOS image" \
    || { bad "check-install failed"; sed 's/^/      /' <<< "$OUT" | head -10; }
for k in web_root atw_root sentinel_dir vulkan_layer; do
    grep -qE "^ok +$k" <<< "$OUT" && ok "  $k ok" || bad "  $k not ok"
done

# ── Negatives: the gate must DETECT breakage, not just say ok ────────────
step "negative cases"

# NEGATIVE 1 — the bug exactly as it shipped: a RELATIVE atw root.
OUT="$(run_in_powos 'mkdir -p /tmp/depthcap
/usr/lib/powstream/bin/powstream-webrtc-server --check-install \
  --web-root /usr/lib/powstream/web --atw-root stream/static')"
grep -qE "FAIL.*atw_root" <<< "$OUT" \
    && ok "relative --atw-root is caught (the shipped /atw bug)" \
    || bad "relative --atw-root NOT caught — the original bug would ship again"

# NEGATIVE 2 — per-user manifest beside the system one = double-loaded layer.
OUT="$(run_in_powos 'mkdir -p /tmp/depthcap /tmp/xdg/vulkan/implicit_layer.d
cp /usr/share/vulkan/implicit_layer.d/VkLayer_POWSTREAM_capture.json /tmp/xdg/vulkan/implicit_layer.d/
XDG_DATA_HOME=/tmp/xdg /usr/lib/powstream/bin/powstream-webrtc-server --check-install \
  --web-root /usr/lib/powstream/web --atw-root /usr/lib/powstream/atw')"
grep -qiE "2 manifests|loaded twice" <<< "$OUT" \
    && ok "double-loaded layer is caught" \
    || bad "double-loaded layer NOT caught"

# NEGATIVE 3 — no sentinel dir means the capture layer never wakes.
OUT="$(run_in_powos '/usr/lib/powstream/bin/powstream-webrtc-server --check-install \
  --web-root /usr/lib/powstream/web --atw-root /usr/lib/powstream/atw')"
grep -qE "FAIL.*sentinel" <<< "$OUT" \
    && ok "missing sentinel dir is caught" \
    || bad "missing sentinel dir NOT caught"

# ── Runtime deps that only bite at connect time ──────────────────────────
step "runtime deps present in the image"
# webrtcbin negotiates ICE through libnice. Without it the stream hangs at
# "Negotiating" with "missing a plug-in" — and it hangs at CONNECT time, so
# neither --check-install nor a startup smoke test can see it.
OUT="$(docker run --rm "$POWOS_IMAGE" bash -c 'gst-inspect-1.0 nicesink >/dev/null 2>&1 && echo HAVE || echo MISSING' 2>&1 | tail -1)"
if grep -q HAVE <<< "$OUT"; then
    ok "libnice GStreamer plugin present (webrtcbin can negotiate)"
else
    bad "libnice plugin MISSING — WebRTC will hang at 'Negotiating'" \
        "image predates Containerfile commit 70b42b8; needs a rebuild"
fi

echo
echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
[[ $FAIL -gt 0 ]] && { echo "TESTS FAILED"; exit 1; }
echo "ALL CHECKS PASSED"
