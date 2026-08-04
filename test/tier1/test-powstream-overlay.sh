#!/bin/bash
# test-powstream-overlay.sh - Does the PowStream overlay lay out what the unit
# actually points at?
#
# WHY THIS EXISTS: PowStream's server gained an /atw route whose web root came
# from a RELATIVE path. That resolved in a dev checkout and nowhere else — under
# our systemd unit the CWD is not the repo, so /atw 404'd on every PowOS
# install. The route that does depth reprojection was dead in the field and
# every test upstream had passed, because upstream tests the SERVER, not
# PowOS's PACKAGING of the server.
#
# The general form of that bug: **the unit's ExecStart names a path the overlay
# never shipped.** That is what this file exists to catch, and it is asserted
# generically (parse every --*-root out of ExecStart, require each to exist)
# rather than by hardcoding the roots we happen to know about today. A new
# --foo-root added upstream is caught without touching this test.
#
# It runs against a STUB PowStream source tree, so it needs:
#   no Rust toolchain (the image has no cargo — that's why the container can't
#   build the real overlay), no GPU, no Vulkan loader, and no access to the
#   private PowStream repo.
#
# Scope: LAYOUT only. Layout != loader pickup != unit activation.
#   pickup/activation need a booted session — see test/tier2.
#
# Usage:  bash test/tier1/test-powstream-overlay.sh

# NOTE: deliberately NO `pipefail` — see the note in the other tier-1 harnesses
# (grep -q SIGPIPEs its writer and makes assertions non-deterministic).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
BUILD_SH="$REPO_ROOT/sources/powstream/build.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
skip() { echo "  skip - $1"; SKIP=$((SKIP+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

echo "== test-powstream-overlay.sh =="
[[ -f "$BUILD_SH" ]] || { echo "FATAL: $BUILD_SH not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Stub PowStream source tree ───────────────────────────────────────────
# source.conf resolves LOCAL_CHECKOUT as "${HOME}/Projects/PowStream", so we
# point HOME at the sandbox rather than patching the build script.
STUB_HOME="$TMP/home"
SRC="$STUB_HOME/Projects/PowStream"
mkdir -p "$SRC"/{layers/vk-capture,target/release,web/webrtc,stream/static}

# The layer .so must pre-exist or build.sh tries to invoke cargo.
: > "$SRC/target/release/libvklayer_powstream_capture.so"
# ship_bin looks in target/release then host-bins.
for b in powstream-webrtc-server powlens-detector-sidecar; do
    : > "$SRC/target/release/$b"; chmod +x "$SRC/target/release/$b"
done
cat > "$SRC/layers/vk-capture/VkLayer_POWSTREAM_capture.json.in" <<'JSON'
{
  "file_format_version": "1.0.0",
  "layer": {
    "name": "VK_LAYER_POWSTREAM_capture",
    "type": "GLOBAL",
    "library_path": "@LIBRARY_PATH@",
    "api_version": "1.3.0",
    "implementation_version": "1",
    "description": "PowStream capture (stub for layout test)"
  }
}
JSON
echo "<html>web</html>" > "$SRC/web/webrtc/index.html"
echo "<html>atw</html>" > "$SRC/stream/static/index.html"

OUT="$TMP/out"
mkdir -p "$OUT"

echo
echo "-- build --"
BUILD_LOG="$TMP/build.log"
HOME="$STUB_HOME" bash "$BUILD_SH" "$OUT" > "$BUILD_LOG" 2>&1
BUILD_RC=$?
check "build.sh succeeds against a stub source tree" '[[ $BUILD_RC -eq 0 ]]'
if (( BUILD_RC != 0 )); then
    echo "      --- build log ---"; sed 's/^/      /' "$BUILD_LOG" | tail -20
fi
check "build.sh did NOT need cargo" '! grep -qi "cargo not found\|cargo build" "$BUILD_LOG"'

echo
echo "-- Vulkan capture layer (the hard requirement) --"
SO="$OUT/usr/lib/powstream/libvklayer_powstream_capture.so"
MANIFEST="$OUT/usr/share/vulkan/implicit_layer.d/VkLayer_POWSTREAM_capture.json"
check "layer .so installed"          '[[ -f "$SO" ]]'
check "layer .so is executable"      '[[ -x "$SO" ]]'
check "implicit-layer manifest installed" '[[ -f "$MANIFEST" ]]'
# A manifest whose library_path never got substituted is the classic silent
# failure: the loader finds the JSON, can't resolve the .so, and capture simply
# never starts with no error anyone sees.
check "manifest has no unsubstituted @LIBRARY_PATH@" '! grep -q "@LIBRARY_PATH@" "$MANIFEST"'
check "manifest library_path is ABSOLUTE"  'grep -q "\"library_path\"[[:space:]]*:[[:space:]]*\"/" "$MANIFEST"'
if [[ -f "$MANIFEST" ]]; then
    LIBPATH="$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST")"
    check "manifest library_path points at the shipped .so" \
          '[[ -f "$OUT${LIBPATH}" ]]'
fi

echo
echo "-- capture is PER-GAME opt-in, NOT session-global --"
ENVCONF="$OUT/usr/lib/environment.d/powstream.conf"
check "environment.d conf installed"       '[[ -f "$ENVCONF" ]]'
# The implicit Vulkan layer must NOT be enabled globally — a global
# POWSTREAM_CAPTURE=1 loads the game-memory-hooking layer into every Vulkan app,
# including anti-cheat titles (ban risk). It must be an ACTIVE (non-comment)
# line that is absent; only a commented example is allowed.
check "does NOT globally enable capture"   '! grep -qE "^[[:space:]]*POWSTREAM_CAPTURE=1" "$ENVCONF"'
check "documents per-game opt-in"          'grep -qi "per-game" "$ENVCONF"'

echo
echo "-- runtime binaries --"
for b in powstream-webrtc-server powlens-detector-sidecar; do
    check "ships $b" '[[ -x "$OUT/usr/lib/powstream/bin/$b" ]]'
done

echo
echo "-- systemd user units --"
UNIT_DIR="$OUT/usr/lib/systemd/user"
SERVER_UNIT="$UNIT_DIR/powstream-webrtc-server.service"
SIDECAR_UNIT="$UNIT_DIR/powlens-sidecar.service"
check "server unit installed"   '[[ -f "$SERVER_UNIT" ]]'
check "sidecar unit installed"  '[[ -f "$SIDECAR_UNIT" ]]'
check "server unit autostarts"  '[[ -L "$UNIT_DIR/default.target.wants/powstream-webrtc-server.service" ]]'
check "sidecar unit autostarts" '[[ -L "$UNIT_DIR/default.target.wants/powlens-sidecar.service" ]]'
# Real login sessions only — never the plasmalogin greeter.
check "server unit gated ConditionUser=!@system"  'grep -qx "ConditionUser=!@system" "$SERVER_UNIT"'
check "sidecar unit gated ConditionUser=!@system" 'grep -qx "ConditionUser=!@system" "$SIDECAR_UNIT"'
# NO_AUTH is load-bearing: /ws is cookie-gated and the ATW client has no login
# flow, so removing it breaks /atw with "HTTP Authentication failed".
check "server unit sets POWSTREAM_NO_AUTH=1" 'grep -q "POWSTREAM_NO_AUTH=1" "$SERVER_UNIT"'

echo
echo "-- THE GUARD: every root ExecStart names must be shipped --"
#
# Generic, not hardcoded. Any `--<something>-root <path>` in ExecStart must
# exist in the output tree. This is the general form of the /atw bug.
if [[ -f "$SERVER_UNIT" ]]; then
    EXECSTART="$(grep -m1 '^ExecStart=' "$SERVER_UNIT")"
    ROOTS="$(grep -oE -- '--[a-z-]+-root[= ]+[^ ]+' <<< "$EXECSTART" \
             | sed -E 's/^--[a-z-]+-root[= ]+//')"
    check "ExecStart declares at least one --*-root" '[[ -n "$ROOTS" ]]'
    while read -r r; do
        [[ -n "$r" ]] || continue
        check "root shipped: $r" '[[ -d "$OUT$r" ]]'
        check "root non-empty:  $r" '[[ -n "$(ls -A "$OUT$r" 2>/dev/null)" ]]'
    done <<< "$ROOTS"

    # Named regression: /atw specifically. This is the route that does depth
    # reprojection and it 404'd on every install.
    check "ExecStart passes --atw-root"       'grep -q -- "--atw-root" <<< "$EXECSTART"'
    check "ATW client tree actually shipped"  '[[ -s "$OUT/usr/lib/powstream/atw/index.html" ]]'
    check "web client tree actually shipped"  '[[ -s "$OUT/usr/lib/powstream/web/index.html" ]]'
else
    skip "ExecStart root guard — server unit missing"
fi

echo
echo "-- degraded build: missing ATW tree must WARN, not ship silently --"
#
# If upstream moves stream/static, we must not quietly produce an overlay whose
# /atw is dead. That regression has to be loud at build time.
SRC2="$TMP/home2/Projects/PowStream"
mkdir -p "$SRC2"/{layers/vk-capture,target/release,web/webrtc}
: > "$SRC2/target/release/libvklayer_powstream_capture.so"
for b in powstream-webrtc-server powlens-detector-sidecar; do
    : > "$SRC2/target/release/$b"; chmod +x "$SRC2/target/release/$b"
done
cp "$SRC/layers/vk-capture/VkLayer_POWSTREAM_capture.json.in" "$SRC2/layers/vk-capture/"
echo "<html>web</html>" > "$SRC2/web/webrtc/index.html"
OUT2="$TMP/out2"; mkdir -p "$OUT2"
LOG2="$TMP/build2.log"
HOME="$TMP/home2" bash "$BUILD_SH" "$OUT2" > "$LOG2" 2>&1
check "build still succeeds without the ATW tree" '[[ $? -eq 0 || -f "$OUT2/usr/lib/powstream/libvklayer_powstream_capture.so" ]]'
check "but WARNS that /atw will 404" 'grep -qi "atw" "$LOG2" && grep -qi "warn\|404" "$LOG2"'

echo
echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
if [[ $FAIL -gt 0 ]]; then echo "TESTS FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
