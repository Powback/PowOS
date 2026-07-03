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

echo "== windows-setup script generation (GPT) =="
guid="12345678-abcd-ef01-2345-6789abcdef01"
ps1=$(vm_build_windows_setup_ps1 "$guid" "Lexar NM790" "4000787030016" "PowOS")
check "first line requires admin"          '[[ "$(echo "$ps1" | head -1)" == "#Requires -RunAsAdministrator" ]]'
check "embeds the GPT disk GUID"           'echo "$ps1" | grep -q "$guid"'
check "GUID braced for Windows Get-Disk"   'echo "$ps1" | grep -q "{$guid}"'
check "locates disk via Get-Disk .Guid"    'echo "$ps1" | grep -q "Get-Disk | Where-Object.*Guid"'
check "raw disk built from PhysicalDrive"  'echo "$ps1" | grep -q "PhysicalDrive"'
check "PhysicalDrive number from Disk obj" 'echo "$ps1" | grep -q "PhysicalDrive.*Disk.Number"'
check "creates raw VMDK"                   'echo "$ps1" | grep -q "internalcommands createrawvmdk"'
check "registers VM as Fedora_64"          'echo "$ps1" | grep -q -- "--ostype Fedora_64 --register"'
check "EFI firmware enabled"               'echo "$ps1" | grep -q -- "--firmware efi"'
check "AHCI SATA controller"               'echo "$ps1" | grep -q -- "--controller IntelAhci"'
check "requires typed YES confirmation"    'echo "$ps1" | grep -q "Read-Host" && echo "$ps1" | grep -q "cne .YES."'
check "VBoxManage default-path fallback"   'echo "$ps1" | grep -q "Oracle.VirtualBox.VBoxManage.exe"'
check "prints startvm as final step"       'echo "$ps1" | grep -q "startvm"'
check "no leftover placeholders"           '! echo "$ps1" | grep -q "__POWOS_"'
check "no bash variable leakage"           '! echo "$ps1" | grep -qE "[$][{]|[$]guid|[$]model|[$]size_bytes|[$]vm_name"'
check "GPT path has no MBR warning"        '! echo "$ps1" | grep -q "MANUAL VERIFICATION REQUIRED"'

echo "== windows-setup script generation (MBR fallback) =="
ps1_mbr=$(vm_build_windows_setup_ps1 "" "Lexar NM790" "4000787030016" "PowOS")
check "MBR: manual-verification warning"   'echo "$ps1_mbr" | grep -q "MANUAL VERIFICATION REQUIRED"'
check "MBR: matches by exact size"         'echo "$ps1_mbr" | grep -q "targetBytes = 4000787030016"'
check "MBR: matches by model"              'echo "$ps1_mbr" | grep -q "targetModel = .Lexar NM790."'
check "MBR: no GUID match block"           '! echo "$ps1_mbr" | grep -q "Guid) -eq"'
check "MBR: still requires admin"          '[[ "$(echo "$ps1_mbr" | head -1)" == "#Requires -RunAsAdministrator" ]]'
check "MBR: no leftover placeholders"      '! echo "$ps1_mbr" | grep -q "__POWOS_"'

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
