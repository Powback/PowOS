#!/bin/bash
# test-gpu.sh — unit tests for lib/gpu.sh + `vm --gpu` passthrough generation.
#
# SCOPE: pure logic only (PCI/slot detection, qemu device generation). Real GPU
# passthrough needs hardware — a live IOMMU, vfio-pci binding, and an actual card
# — none of which exist in a container/CI. So the bind/unbind sysfs paths and the
# in-use safety guard are NOT exercised here; they're validated on real hardware
# (`powos gpu status` + a TTY safety net). This covers everything testable.
set -uo pipefail
PASS=0; FAIL=0
ok(){ echo "  ok   - $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export POWOS_LIB="$DIR/lib"

# Mock lspci -Dn: an NVIDIA 5090 (VGA 01:00.0 + HDMI-audio 01:00.1) + AMD iGPU.
lspci(){ cat <<'EOF'
0000:01:00.0 0300: 10de:2b85 (rev a1)
0000:01:00.1 0403: 10de:22e8 (rev a1)
0000:78:00.0 0300: 1002:13c0 (rev e5)
EOF
}
export -f lspci
source "$DIR/lib/gpu.sh" 2>/dev/null

echo "== gpu.sh PCI/slot detection =="
[[ "$(gpu_dgpu_bdf)" == "0000:01:00.0" ]] && ok "dGPU = first NVIDIA VGA" || no "dGPU detection"
mapfile -t slots < <(gpu_slot_bdfs "0000:01:00.0")
[[ "${slots[*]}" == "0000:01:00.0 0000:01:00.1" ]] && ok "slot = GPU + audio function together" || no "slot functions (got: ${slots[*]})"

echo "== vm --gpu qemu device generation =="
source "$DIR/lib/vm.sh" 2>/dev/null
out="$(vm_build_qemu_cmd /dev/x 8G 4 /code /vars 1 2>/dev/null)"
grep -q 'vfio-pci,host=01:00.0' <<<"$out" && ok "passes the GPU function" || no "GPU function missing"
grep -q 'vfio-pci,host=01:00.1' <<<"$out" && ok "passes the HDMI-audio function" || no "audio function missing"
grep -q 'GPU_PCI_ADDR' <<<"$out" && no "leftover placeholder!" || ok "no leftover placeholder"
out0="$(vm_build_qemu_cmd /dev/x 8G 4 /code /vars 0 2>/dev/null)"
grep -q 'virtio-vga-gl' <<<"$out0" && ok "no-gpu path uses virtio-vga" || no "virtio-vga fallback missing"
grep -q 'vfio-pci' <<<"$out0" && no "no-gpu path leaked vfio!" || ok "no-gpu path has no passthrough"

echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
