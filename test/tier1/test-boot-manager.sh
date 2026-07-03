#!/bin/bash
# test-boot-manager.sh - unit tests for `powos boot` UEFI entry parsing.
# Pure logic (parsing efibootmgr output). No efibootmgr, no reboot.

set -uo pipefail

LIB="/usr/lib/powos/boot-manager.sh"
[[ -f "$LIB" ]] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/boot-manager.sh"
# shellcheck disable=SC1090
source "$LIB"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1 (got: ${2:-})"; FAIL=$((FAIL+1)); }

# Realistic efibootmgr output (tab between label and device path).
OUT="$(printf '%s\n' \
'BootCurrent: 0001' \
'Timeout: 1 seconds' \
'BootOrder: 0001,0000,0002' \
"Boot0000* Windows Boot Manager	HD(1,GPT,abcd)/File(\\EFI\\Microsoft\\Boot\\bootmgfw.efi)" \
"Boot0001* Fedora	HD(1,GPT,abcd)/File(\\EFI\\fedora\\shimx64.efi)" \
"Boot0002* UEFI: USB SanDisk	PciRoot(0x0)/Pci(0x14,0x0)")"

echo "== find entry by name =="
[[ "$(bm_find_entry 'windows|microsoft' "$OUT")" == "0000" ]] && ok "finds Windows Boot Manager → 0000" || bad "windows" "$(bm_find_entry 'windows|microsoft' "$OUT")"
[[ "$(bm_find_entry 'fedora' "$OUT")" == "0001" ]] && ok "finds Fedora → 0001" || bad "fedora"
[[ "$(bm_find_entry 'usb' "$OUT")" == "0002" ]] && ok "finds USB → 0002" || bad "usb"
[[ -z "$(bm_find_entry 'nonexistent' "$OUT")" ]] && ok "no match → empty" || bad "empty"

echo "== case-insensitive =="
[[ "$(bm_find_entry 'WINDOWS' "$OUT")" == "0000" ]] && ok "uppercase query matches" || bad "case"

echo "== entry label extraction =="
lbl="$(bm_entry_label 0000 "$OUT")"
[[ "$lbl" == "Windows Boot Manager" ]] && ok "label for 0000 = 'Windows Boot Manager'" || bad "label" "$lbl"

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
