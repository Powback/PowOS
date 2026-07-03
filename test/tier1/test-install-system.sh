#!/bin/bash
# shellcheck disable=SC2016,SC2034
# (assertions are single-quoted on purpose — check() eval's them later; the
#  ISV_* globals are read inside those eval'd strings, not statically.)
# test-install-system.sh - Tier-1 unit tests for the to-disk installer logic.
#
# Runs on any Linux box (no root, no real disks) by shadowing the external
# tools (lsblk/parted/blkid/bootc) with bash functions. Covers the parts where
# a bug would be dangerous: argument parsing, dry-run gating of destructive
# commands, confirmation logic, free-space parsing, and live-disk exclusion.
#
# It does NOT (and cannot) validate real partitioning or boot menus — that
# needs the QEMU/hardware checklist in test/e2e/. See TODO(hw) in the lib.
#
# Usage:  bash test/tier1/test-install-system.sh
#   Docker: docker exec powos bash /test/tier1/test-install-system.sh

set -uo pipefail

# Locate the lib relative to this test, or the installed path.
LIB="/usr/lib/powos/install-system.sh"
if [[ ! -f "$LIB" ]]; then
    LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/install-system.sh"
fi

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

echo "== Sourcing installer lib: $LIB =="
# shellcheck disable=SC1090
source "$LIB" || { echo "cannot source lib"; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────
echo "== Argument parsing =="

reset_globals() {
    ISV_DRY_RUN=0; ISV_ASSUME_YES=0; ISV_MODE=""; ISV_TARGET=""
    ISV_SHARED_GB=""; ISV_FS="btrfs"
}

reset_globals
isv_parse_args --alongside --disk /dev/sdz --shared-gb 100 --dry-run >/dev/null 2>&1
check "mode set to alongside"        '[[ "$ISV_MODE" == "alongside" ]]'
check "target set to /dev/sdz"       '[[ "$ISV_TARGET" == "/dev/sdz" ]]'
check "shared-gb captured"           '[[ "$ISV_SHARED_GB" == "100" ]]'
check "dry-run flag set"             '[[ "$ISV_DRY_RUN" -eq 1 ]]'

reset_globals
isv_parse_args --whole-disk >/dev/null 2>&1
check "mode set to whole-disk"       '[[ "$ISV_MODE" == "whole-disk" ]]'

reset_globals
isv_parse_args --help >/dev/null 2>&1
check "--help returns code 2"        '[[ $? -eq 2 ]]'

reset_globals
isv_parse_args --bogus >/dev/null 2>&1
check "bad option returns code 1"    '[[ $? -eq 1 ]]'

# ── Dry-run gates destructive commands ────────────────────────────
echo "== Dry-run safety gate =="

SENTINEL=0
danger() { SENTINEL=1; }   # stands in for a real disk-wiping command

reset_globals; ISV_DRY_RUN=1; SENTINEL=0
run_step "would wipe" danger >/dev/null 2>&1
check "dry-run does NOT run destructive cmd" '[[ $SENTINEL -eq 0 ]]'

reset_globals; ISV_DRY_RUN=0; SENTINEL=0
run_step "really run" danger >/dev/null 2>&1
check "non-dry-run DOES run cmd"             '[[ $SENTINEL -eq 1 ]]'

# ── Confirmation logic ────────────────────────────────────────────
echo "== Confirmation =="

reset_globals; ISV_ASSUME_YES=1
confirm "auto?" >/dev/null 2>&1
check "--yes auto-confirms"                  '[[ $? -eq 0 ]]'

reset_globals
confirm "type model:" "Samsung 990" >/dev/null 2>&1 <<< "Samsung 990"
check "matching typed confirmation passes"   '[[ $? -eq 0 ]]'

reset_globals
confirm "type model:" "Samsung 990" >/dev/null 2>&1 <<< "wrong"
check "mismatched confirmation fails"         '[[ $? -ne 0 ]]'

# ── Free-space parsing (parted output) ────────────────────────────
echo "== Free-space parsing =="

parted() {
    # Emulate `parted <dev> unit MiB print free` with two free blocks.
    cat <<'PARTED'
Model: Fake Disk (scsi)
Disk /dev/sdz: 500000MiB
Number  Start      End        Size       Type     File system  Flags
        1.00MiB    2.00MiB    1.00MiB             Free Space
 1      2.00MiB    202.00MiB  200.00MiB  primary  fat32        boot, esp
 2      202.00MiB  120000MiB  119798MiB  primary  ntfs
        120000MiB  500000MiB  380000MiB           Free Space
PARTED
}
reset_globals; ISV_TARGET=/dev/sdz
free=$(isv_free_space_mib)
check "picks largest free block (380000)"    '[[ "$free" == "380000" ]]'
start=$(isv_free_block_start)
check "start of largest free block (120000)" '[[ "$start" == "120000" ]]'
unset -f parted

# ── Partition lookup by GPT label ─────────────────────────────────
# The lookup enumerates partitions via `lsblk -o PATH` and reads the GPT label
# via `blkid` (robust vs. udev). Stub all three seams: lsblk, blkid, is-block.
echo "== Partition lookup by label =="
lsblk() {
    if [[ "$*" == *"-o PATH"* ]]; then
        printf '/dev/sdz\n/dev/sdz1\n/dev/sdz2\n/dev/sdz5\n/dev/sdz6\n'
    fi
}
blkid() {
    # emulate `blkid -o value -s PARTLABEL <part>`
    case "${!#}" in
        /dev/sdz1) echo "" ;;
        /dev/sdz2) echo "Basic data partition" ;;
        /dev/sdz5) echo "PowOS" ;;
        /dev/sdz6) echo "POWOS-SHARED" ;;
    esac
}
isv_is_block() { return 0; }   # pretend every path is a block device
check "finds PowOS root by partlabel"        '[[ "$(isv_part_by_partlabel /dev/sdz PowOS)" == "/dev/sdz5" ]]'
check "finds POWOS-SHARED by partlabel"      '[[ "$(isv_part_by_partlabel /dev/sdz POWOS-SHARED)" == "/dev/sdz6" ]]'
check "missing label returns empty"          '[[ -z "$(isv_part_by_partlabel /dev/sdz NOPE)" ]]'
unset -f lsblk blkid isv_is_block

# ── Live-disk exclusion ───────────────────────────────────────────
echo "== Candidate disk exclusion =="

# Pretend we booted from /dev/sdb; it must not appear as an install target.
isv_live_device() { echo "/dev/sdb"; }
lsblk() {
    # Only emulate the exact call isv_candidate_disks makes.
    if [[ "$*" == *"-dn -o NAME,SIZE,MODEL,TRAN,TYPE"* ]]; then
        cat <<'LSBLK'
sda   500G Samsung_SSD   sata  disk
sdb    32G Kingston_USB  usb   disk
loop0  25G               ""    loop
LSBLK
    fi
}
isv_detect_windows() { return 1; }   # no windows, keep output simple

reset_globals
out=$(isv_candidate_disks)
check "internal /dev/sda is a candidate"     'echo "$out" | grep -q "/dev/sda"'
check "live USB /dev/sdb is excluded"        '! echo "$out" | grep -q "/dev/sdb"'
check "loop device excluded"                 '! echo "$out" | grep -q "loop"'
unset -f isv_live_device lsblk isv_detect_windows

# ── Summary ───────────────────────────────────────────────────────
echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
