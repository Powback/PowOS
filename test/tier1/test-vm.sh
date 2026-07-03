#!/bin/bash
# shellcheck disable=SC2016
# test-vm.sh - unit tests for the reciprocal-VM launch-config generation.
# Pure logic only (qemu command building, firmware discovery) — no VM launch,
# no disk access. Runs anywhere.

set -uo pipefail

LIB="/usr/lib/powos/vm.sh"
[[ -f "$LIB" ]] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/vm.sh"

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# shellcheck disable=SC1090
source "$LIB"

echo "== qemu command generation =="
cmd=$(vm_build_qemu_cmd /dev/sdX 8G 4 /ovmf/CODE.fd /ovmf/VARS.fd 0)
check "includes the passthrough disk"     'echo "$cmd" | grep -q "file=/dev/sdX,format=raw"'
check "boots UEFI (pflash + OVMF CODE)"    'echo "$cmd" | grep -q "pflash.*CODE.fd"'
check "uses writable NVRAM VARS"           'echo "$cmd" | grep -q "VARS.fd"'
check "KVM acceleration enabled"           'echo "$cmd" | grep -q -- "-enable-kvm"'
check "AHCI (native Windows disk driver)"  'echo "$cmd" | grep -q "ide-hd,drive=osdisk"'
check "requested RAM applied"              'echo "$cmd" | grep -q -- "-m 8G"'
check "requested vCPUs applied"            'echo "$cmd" | grep -q -- "-smp 4"'
check "no-GPU path uses virtio-vga"        'echo "$cmd" | grep -q "virtio-vga"'

cmd_gpu=$(vm_build_qemu_cmd /dev/sdX 16G 8 /ovmf/CODE.fd /ovmf/VARS.fd 1)
check "GPU path adds vfio-pci"             'echo "$cmd_gpu" | grep -q "vfio-pci"'
check "GPU path drops virtio-vga"          '! echo "$cmd_gpu" | grep -q "virtio-vga"'

echo "== firmware discovery =="
tmp="$(mktemp -d)"; touch "$tmp/second.fd"
check "finds first existing candidate"     '[[ "$(vm_find_first_existing "$tmp/missing.fd" "$tmp/second.fd")" == "$tmp/second.fd" ]]'
check "returns non-zero when none exist"    '! vm_find_first_existing "$tmp/nope1" "$tmp/nope2"'
rm -rf "$tmp"

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
