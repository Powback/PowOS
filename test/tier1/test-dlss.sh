#!/bin/bash
# test-dlss.sh — unit tests for lib/dlss.sh (DLSS 4 presets + DLSS 5 NR plumbing).
#
# SCOPE: pure logic only. The parts that matter most — whether NVIDIA's NR runtime
# actually evaluates on a given driver — CANNOT be tested here: it needs an RTX 50
# card, the proprietary runtime, a DXVK-NVAPI Proton and a live Vulkan loader. That
# is exactly why `powos dlss doctor` and `powos dlss nr smoke` exist: they measure
# on real hardware. What IS testable is covered here: capability probes via their
# env seams, PE validation, hash gating, preset mapping, and that every verb the
# usage text documents actually dispatches.
# NOTE: deliberately NO `pipefail`. These harnesses assert with
# `grep -q ... <<<"$out"`, and `grep -q` exits on its first match — which SIGPIPEs
# the writer, making the pipeline return 141 depending on scheduling. That produced
# random failures elsewhere in this suite. Last-command status is the correct
# semantics for an assertion anyway.
set -u
PASS=0; FAIL=0
ok(){ echo "  ok   - $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export POWOS_LIB="$DIR/lib"

# Redirect all per-machine state into a scratch dir so the test never touches the
# real runtime dir, the real Vulkan manifest dir, or /run/powos.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export DLSS_CACHE_DIR="$TMP/cache"
export DLSS_RUNTIME_DIR="$TMP/runtimes"
export DLSS_LAYER_MANIFEST_DIR="$TMP/implicit_layer.d"
export DLSS_SHIM_ENV_DIR="$TMP/verify"
mkdir -p "$DLSS_RUNTIME_DIR" "$DLSS_LAYER_MANIFEST_DIR" "$DLSS_SHIM_ENV_DIR"

source "$DIR/lib/dlss.sh" 2>/dev/null

echo "== DLSS 4 preset mapping =="
[[ "$(dlss_preset_code j)" == "0xA" ]] && ok "preset j -> 0xA (DLSS 4 transformer)" || no "preset j"
[[ "$(dlss_preset_code K)" == "0xB" ]] && ok "preset is case-insensitive" || no "preset case-insensitivity"
[[ "$(dlss_preset_code m)" == "0xD" ]] && ok "preset m -> 0xD (DLSS 4.5)" || no "preset m"
dlss_preset_code z >/dev/null 2>&1 && no "bogus preset accepted!" || ok "bogus preset rejected"

out="$(cmd_dlss4_preset j 2>&1)"
grep -q 'DXVK_NVAPI_DRS_ngx_dlss_sr_override_render_preset_selection=0xA' <<<"$out" \
    && ok "preset emits the DRS override" || no "DRS override missing"
grep -q 'DLSSIndicator=1024' <<<"$out" \
    && ok "preset emits the verification overlay" || no "DLSSIndicator missing"
grep -qi 'does not add frame generation' <<<"$out" \
    && ok "preset states it is upscaler-only" || no "missing the SR-only honesty line"
out="$(cmd_dlss4_preset zz 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "bad preset returns non-zero" || no "bad preset returned 0"

echo "== capability probes honour their env seams =="
POWOS_DLSS_GPU_NAME="NVIDIA GeForce RTX 5090" dlss_gpu_is_blackwell \
    && ok "RTX 5090 detected as Blackwell" || no "Blackwell detection"
POWOS_DLSS_GPU_NAME="NVIDIA GeForce RTX 4090" dlss_gpu_is_blackwell \
    && no "RTX 4090 wrongly called Blackwell!" || ok "RTX 4090 not Blackwell (model is 50-locked)"
POWOS_DLSS_NATIVE_NGX=1 dlss_native_ngx_ok && ok "native NGX seam: present" || no "native NGX seam present"
POWOS_DLSS_NATIVE_NGX=0 dlss_native_ngx_ok && no "native NGX seam: false positive" || ok "native NGX seam: absent"

mkdir -p "$TMP/winedir"
: > "$TMP/winedir/_nvngx.dll"
[[ "$(POWOS_DLSS_WINE_DIR="$TMP/winedir" dlss_nvidia_wine_dir)" == "$TMP/winedir" ]] \
    && ok "wine NGX dir seam" || no "wine NGX dir seam"

echo "== PE validation (a patched runtime must be refused) =="
# 64-bit PE, no certificate table -> valid arch, unsigned.
python3 - "$TMP/unsigned.dll" <<'PY'
import struct, sys
buf = bytearray(4096)
buf[0:2] = b"MZ"
struct.pack_into("<I", buf, 0x3C, 0x80)
buf[0x80:0x84] = b"PE\0\0"
struct.pack_into("<H", buf, 0x84, 0x8664)      # machine = x86-64
struct.pack_into("<H", buf, 0x80 + 24, 0x20b)  # PE32+
open(sys.argv[1], "wb").write(bytes(buf))      # cert table left zeroed
PY
[[ "$(dlss_pe_arch "$TMP/unsigned.dll")" == "x64" ]] && ok "PE arch reads x64" || no "PE arch x64"
dlss_pe_signed "$TMP/unsigned.dll" && no "unsigned PE reported as signed!" || ok "unsigned PE detected"

printf 'not a PE at all' > "$TMP/junk.dll"
[[ "$(dlss_pe_arch "$TMP/junk.dll")" == "notpe" ]] && ok "non-PE detected" || no "non-PE detection"

# import must refuse a non-PE outright (no prompt, no install)
out="$(cmd_dlss_runtime_import "$TMP/junk.dll" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "import refuses a non-64-bit file" || no "import accepted junk"
[[ ! -f "$DLSS_RUNTIME_DIR/nvngx_dlssnr.dll" ]] && ok "refused import installed nothing" || no "junk got installed!"

# ...and refuse an unsigned x64 PE, because NGX rejects it with 0xBAD00002 anyway
out="$(cmd_dlss_runtime_import "$TMP/unsigned.dll" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "import refuses an unsigned PE" || no "unsigned PE accepted"
grep -q '0xBAD00002' <<<"$out" && ok "refusal names the NGX error it would cause" || no "refusal lacks the NGX error"

echo "== hash gating =="
[[ "${#DLSS_NR_SHA256_RTX50}" -eq 64 ]] && ok "reference hash is a full sha256" || no "reference hash malformed"
[[ "$DLSS_NR_SIZE_RTX50" -eq 165840496 ]] && ok "reference size recorded" || no "reference size wrong"
echo -n "x" > "$DLSS_RUNTIME_DIR/nvngx_dlssnr.dll"
dlss_nr_runtime_present && ok "runtime presence detected" || no "runtime presence"
dlss_nr_runtime_verified && no "wrong-hash runtime passed verification!" || ok "wrong-hash runtime fails verification"
rm -f "$DLSS_RUNTIME_DIR/nvngx_dlssnr.dll"

echo "== layer manifest detection + conflict warning =="
dlss_layer_installed && no "layer reported installed with no manifest!" || ok "no manifest -> not installed"
: > "$DLSS_LAYER_MANIFEST_DIR/VK_LAYER_NV_dlssnr.x86_64.json"
dlss_layer_installed && ok "manifest -> installed" || no "manifest not detected"

echo "== enable/disable via the game shim (no LaunchOptions writer) =="
out="$(cmd_dlss_nr_enable 4242 2>&1)"
[[ -f "$DLSS_SHIM_ENV_DIR/4242.env" ]] && ok "per-game arm writes the shim env sentinel" || no "shim sentinel not written"
grep -q 'VKLayer_DLSS5=1' "$DLSS_SHIM_ENV_DIR/4242.env" 2>/dev/null \
    && ok "sentinel arms the layer" || no "sentinel missing VKLayer_DLSS5"
grep -q 'VK_LAYER_NV_dlssnr:VK_LAYER_NV_present' "$DLSS_SHIM_ENV_DIR/4242.env" 2>/dev/null \
    && ok "sentinel pins layer order (Smooth Motion coexistence)" || no "layer order not pinned"
cmd_dlss_nr_disable 4242 >/dev/null 2>&1
[[ ! -f "$DLSS_SHIM_ENV_DIR/4242.env" ]] && ok "disable removes the sentinel" || no "sentinel survived disable"

echo "== status renders without a driver, and does not claim capability =="
dlss_driver_ok(){ return 1; }   # shadow the probe: pretend there is no driver
out="$(cmd_dlss_status 2>&1)"
grep -qi 'no working NVIDIA driver' <<<"$out" && ok "status degrades honestly with no driver" || no "status no-driver path"
grep -qi 'verified\|installed' <<<"$out" && no "status claimed capability with no driver!" || ok "status claims nothing without a driver"
unset -f dlss_driver_ok
grep -qi 'frame generation\|Super Resolution\|SR/FG' <<<"$(cmd_dlss_usage 2>&1)" \
    && ok "usage states SR/FG cannot be universal" || no "usage omits the SR/FG limit"
grep -qi '50-60% fps\|50-60%' <<<"$(cmd_dlss_usage 2>&1)" \
    && ok "usage states the fps cost" || no "usage omits the fps cost"

echo "== every documented verb dispatches (the powos mods snapshot lesson) =="
# Guards against help promising a verb that was never wired.
for fn in cmd_dlss cmd_dlss_status cmd_dlss_doctor cmd_dlss_runtime \
          cmd_dlss_runtime_import cmd_dlss_runtime_list cmd_dlss_nr \
          cmd_dlss_nr_install cmd_dlss_nr_smoke cmd_dlss_nr_enable \
          cmd_dlss_nr_disable cmd_dlss4 cmd_dlss4_preset; do
    [[ "$(type -t "$fn")" == "function" ]] && ok "$fn defined" || no "$fn MISSING"
done
out="$(cmd_dlss nonsense 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "unknown verb returns non-zero" || no "unknown verb returned 0"

echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
