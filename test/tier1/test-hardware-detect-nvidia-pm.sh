#!/bin/bash
# test-hardware-detect-nvidia-pm.sh - systemd/powos-hardware-detect's NVIDIA runtime power management (RTD3) acts only
# on a hybrid (Optimus) laptop whose driver reports runtime D3, and is a no-op everywhere else - above all on a desktop
# multi-GPU box like gpu-195 (2x RTX 3090). Each case builds a fake sysfs/procfs (POWOS_SYSFS / POWOS_PROCFS), sources
# the script (functions only), and runs setup_nvidia with the form factor detect_form_factor reads from the fake DMI
# chassis type. Until 11-24 the block's `[[ -f glob ]]` test never matched, so it never ran anywhere (SC2144).
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/systemd/powos-hardware-detect"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /'; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Stubs for the commands setup_nvidia runs around the PM block (no real modules, no syslog in the test container).
mkdir -p "$TMP/bin"
for c in logger modprobe nvidia-smi; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"; done

# pci <case> <bdf> <vendor> <class> [runtime-D3 status line for /proc/driver/nvidia/gpus/<bdf>/power]
pci() {
  local d="$TMP/$1/sys/bus/pci/devices/$2"
  mkdir -p "$d/power"; echo "$3" > "$d/vendor"; echo "$4" > "$d/class"; echo on > "$d/power/control"
  if [ -n "${5:-}" ]; then mkdir -p "$TMP/$1/proc/driver/nvidia/gpus/$2"; echo "$5" > "$TMP/$1/proc/driver/nvidia/gpus/$2/power"; fi
}
chassis() { mkdir -p "$TMP/$1/sys/class/dmi/id"; echo "$2" > "$TMP/$1/sys/class/dmi/id/chassis_type"; }
run() {  # run <case>: detect the form factor, then setup_nvidia with it
  PATH="$TMP/bin:$PATH" POWOS_SYSFS="$TMP/$1/sys" POWOS_PROCFS="$TMP/$1/proc" \
    bash -c '. "$1"; form=$(detect_form_factor); echo "form=$form"; setup_nvidia "$form"' _ "$SCRIPT" 2>&1
}
ctl() { cat "$TMP/$1/sys/bus/pci/devices/$2/power/control"; }

D3_ON="Runtime D3 status:          Enabled (fine-grained)"
D3_NO="Runtime D3 status:          Not supported"

echo "== hybrid laptop with RTD3: applies =="
chassis laptop 10
pci laptop 0000:00:02.0 0x8086 0x030000             # Intel iGPU drives the panel
pci laptop 0000:01:00.0 0x10de 0x030200 "$D3_ON"    # NVIDIA dGPU (3D controller)
pci laptop 0000:01:00.1 0x10de 0x040300             # its HDMI audio function
out=$(run laptop); rc=$?
[ $rc = 0 ] && ok "laptop: rc 0" || bad "laptop: rc=$rc" "$out"
case $out in *form=laptop*) ok "laptop: chassis 10 -> laptop";; *) bad "laptop: form" "$out";; esac
[ "$(ctl laptop 0000:01:00.0)" = auto ] && ok "laptop: dGPU power/control auto" || bad "laptop: dGPU $(ctl laptop 0000:01:00.0)" "$out"
[ "$(ctl laptop 0000:01:00.1)" = auto ] && ok "laptop: dGPU audio function auto" || bad "laptop: audio $(ctl laptop 0000:01:00.1)" "$out"
[ "$(ctl laptop 0000:00:02.0)" = on ] && ok "laptop: iGPU untouched" || bad "laptop: iGPU changed" "$out"

echo "== desktop multi-GPU (gpu-195-like: 2x NVIDIA, RTD3 reported, an iGPU too): no-op =="
chassis desktop 3
pci desktop 0000:00:02.0 0x8086 0x030000
pci desktop 0000:01:00.0 0x10de 0x030000 "$D3_ON"
pci desktop 0000:01:00.1 0x10de 0x040300
pci desktop 0000:02:00.0 0x10de 0x030000 "$D3_ON"
pci desktop 0000:02:00.1 0x10de 0x040300
out=$(run desktop); rc=$?
[ $rc = 0 ] && ok "desktop: rc 0" || bad "desktop: rc=$rc" "$out"
case $out in *form=desktop*) ok "desktop: chassis 3 -> desktop";; *) bad "desktop: form" "$out";; esac
changed=$(grep -l auto "$TMP"/desktop/sys/bus/pci/devices/*/power/control 2>/dev/null)
[ -z "$changed" ] && ok "desktop: no power/control changed" || bad "desktop: changed $changed" "$out"

echo "== laptop without an iGPU (dGPU-only / MUX): no-op =="
chassis nomux 9
pci nomux 0000:01:00.0 0x10de 0x030000 "$D3_ON"
out=$(run nomux)
[ "$(ctl nomux 0000:01:00.0)" = on ] && ok "dGPU-only laptop: untouched" || bad "dGPU-only laptop: changed" "$out"

echo "== hybrid laptop whose driver says RTD3 not supported: no-op =="
chassis old 10
pci old 0000:00:02.0 0x8086 0x030000
pci old 0000:01:00.0 0x10de 0x030200 "$D3_NO"
pci old 0000:01:00.1 0x10de 0x040300
out=$(run old)
[ "$(ctl old 0000:01:00.0)" = on ] && [ "$(ctl old 0000:01:00.1)" = on ] && ok "RTD3 not supported: untouched" || bad "RTD3 not supported: changed" "$out"

echo "== server chassis: no-op =="
chassis server 23
pci server 0000:00:02.0 0x1a03 0x030000             # BMC VGA
pci server 0000:01:00.0 0x10de 0x030200 "$D3_ON"
out=$(run server)
[ "$(ctl server 0000:01:00.0)" = on ] && ok "server: untouched" || bad "server: changed" "$out"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ $FAIL -eq 0 ]
