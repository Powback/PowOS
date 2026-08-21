#!/bin/bash
# test-install-wizard-disks.sh - Tier-1 tests for installer disk enumeration.
#
# This is the code path that erased a Steam Deck's SD card. whiptail/kdialog
# pre-highlight the FIRST menu entry, and lsblk's natural order puts mmcblk0
# (the card slot) ahead of nvme0n1 (the internal SSD) — so pressing Enter on
# "choose the target disk" installed onto the card and wiped the games on it.
#
# The ordering of iwz_list_disks is therefore a SAFETY property, not cosmetics:
# internal disks first, removable media last and flagged. These tests pin it.
#
# Runs anywhere, no root, no real disks: lsblk/blkid are shadowed.
#
# Usage:  bash test/tier1/test-install-wizard-disks.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB=$(cd "$HERE/../../lib" && pwd)/install-wizard.sh
[[ -f "$LIB" ]] || LIB="/usr/lib/powos/install-wizard.sh"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && echo "         $2"; }

# shellcheck source=/dev/null
source "$LIB" 2>/dev/null || { echo "cannot source $LIB"; exit 1; }

# ── Shadows ────────────────────────────────────────────────────────────────
# LSBLK_OUT is what our fake `lsblk -dn -o NAME,SIZE,TYPE,RM,HOTPLUG,TRAN,MODEL`
# prints. BLKID_OUT is the POWOS-DATA lookup (the live USB to exclude).
LSBLK_OUT=""
BLKID_OUT=""
lsblk() {
    # PKNAME lookup (used to resolve the live USB's parent disk)
    if [[ "$*" == *PKNAME* ]]; then printf '%s\n' "${PKNAME_OUT:-}"; return 0; fi
    printf '%s\n' "$LSBLK_OUT"
}
blkid() { [[ -n "$BLKID_OUT" ]] && printf '%s\n' "$BLKID_OUT"; return 0; }
PKNAME_OUT=""

# A Steam Deck: internal NVMe + an SD card. lsblk lists mmcblk FIRST, which is
# exactly the trap.
deck_layout() {
    LSBLK_OUT='mmcblk0 477G disk 0 1 mmc  SD Card Reader
nvme0n1 931G disk 0 0 nvme WD PC SN740 1TB'
    BLKID_OUT=""
    PKNAME_OUT=""
}

# ── Tests ──────────────────────────────────────────────────────────────────

t_internal_first() {
    deck_layout
    local first
    first=$(iwz_list_disks | head -1 | cut -f1)
    if [[ "$first" == "/dev/nvme0n1" ]]; then
        ok "internal disk is listed FIRST (a bare Enter cannot pick the SD card)"
    else
        bad "internal disk is listed FIRST" "got '$first', expected /dev/nvme0n1"
    fi
}

t_removable_last() {
    deck_layout
    local last
    last=$(iwz_list_disks | tail -1 | cut -f1)
    if [[ "$last" == "/dev/mmcblk0" ]]; then
        ok "removable media is listed LAST"
    else
        bad "removable media is listed LAST" "got '$last'"
    fi
}

t_mmcblk_flagged_removable() {
    deck_layout
    # Note rm=0 in the fixture: some SD controllers report non-removable.
    local flag
    flag=$(iwz_list_disks | awk -F'\t' '$1=="/dev/mmcblk0"{print $4}')
    if [[ "$flag" == "yes" ]]; then
        ok "mmcblk is flagged removable even when lsblk says rm=0"
    else
        bad "mmcblk is flagged removable even when lsblk says rm=0" "got '$flag'"
    fi
}

t_nvme_not_removable() {
    deck_layout
    local flag
    flag=$(iwz_list_disks | awk -F'\t' '$1=="/dev/nvme0n1"{print $4}')
    if [[ "$flag" == "no" ]]; then
        ok "internal NVMe is not flagged removable"
    else
        bad "internal NVMe is not flagged removable" "got '$flag'"
    fi
}

t_usb_flagged_removable() {
    LSBLK_OUT='sda 57G disk 1 1 usb SanDisk Ultra
nvme0n1 931G disk 0 0 nvme WD PC SN740 1TB'
    BLKID_OUT=""; PKNAME_OUT=""
    local flag first
    flag=$(iwz_list_disks | awk -F'\t' '$1=="/dev/sda"{print $4}')
    first=$(iwz_list_disks | head -1 | cut -f1)
    if [[ "$flag" == "yes" && "$first" == "/dev/nvme0n1" ]]; then
        ok "USB stick flagged removable and sorted after the internal disk"
    else
        bad "USB stick flagged removable and sorted after the internal disk" "flag='$flag' first='$first'"
    fi
}

t_live_usb_excluded() {
    # The stick we booted from must never be offered as a target.
    LSBLK_OUT='sda 57G disk 1 1 usb SanDisk Ultra
nvme0n1 931G disk 0 0 nvme WD PC SN740 1TB'
    BLKID_OUT="/dev/sda3"
    PKNAME_OUT="sda"
    if iwz_list_disks | cut -f1 | grep -qx '/dev/sda'; then
        bad "the live USB is excluded from the target list" "sda was offered"
    else
        ok "the live USB is excluded from the target list"
    fi
}

t_model_with_spaces() {
    deck_layout
    local model
    model=$(iwz_list_disks | awk -F'\t' '$1=="/dev/nvme0n1"{print $3}')
    if [[ "$model" == "WD PC SN740 1TB" ]]; then
        ok "a model name containing spaces survives intact"
    else
        bad "a model name containing spaces survives intact" "got '$model'"
    fi
}

t_is_removable_helper() {
    deck_layout
    local r=0
    iwz__is_removable /dev/mmcblk0 || r=1
    local r2=0
    iwz__is_removable /dev/nvme0n1 || r2=1
    if [[ $r -eq 0 && $r2 -eq 1 ]]; then
        ok "iwz__is_removable: yes for the SD card, no for the NVMe"
    else
        bad "iwz__is_removable: yes for the SD card, no for the NVMe" "mmcblk=$r nvme=$r2"
    fi
}

t_no_disks_is_empty() {
    LSBLK_OUT=""; BLKID_OUT=""; PKNAME_OUT=""
    local n
    n=$(iwz_list_disks | grep -c . || true)
    if [[ "$n" == "0" ]]; then
        ok "no enumerable disks yields an empty list (wizard falls back to asking)"
    else
        bad "no enumerable disks yields an empty list" "got $n lines"
    fi
}

t_partitions_and_loops_ignored() {
    LSBLK_OUT='loop0 100M loop 0 0
zram0 8G disk 0 0
sr0 1024M rom 1 1
nvme0n1 931G disk 0 0 nvme WD PC SN740 1TB'
    BLKID_OUT=""; PKNAME_OUT=""
    local list
    list=$(iwz_list_disks | cut -f1 | tr '\n' ' ')
    if [[ "$list" == "/dev/nvme0n1 " ]]; then
        ok "loop/zram/optical devices are ignored"
    else
        bad "loop/zram/optical devices are ignored" "got '$list'"
    fi
}

echo "== installer disk enumeration =="
t_internal_first
t_removable_last
t_mmcblk_flagged_removable
t_nvme_not_removable
t_usb_flagged_removable
t_live_usb_excluded
t_model_with_spaces
t_is_removable_helper
t_no_disks_is_empty
t_partitions_and_loops_ignored

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
