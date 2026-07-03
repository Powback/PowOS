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
    ISV_DRY_RUN=0; ISV_ASSUME_YES=0; ISV_ERASE_CONFIRMED=0; ISV_MODE=""
    ISV_TARGET=""; ISV_SHARED_GB=""; ISV_FS="btrfs"
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

reset_globals
isv_parse_args --fs xfs >/dev/null 2>&1
check "--fs xfs rejected (allowlist)" '[[ $? -eq 1 ]]'

reset_globals
isv_parse_args --fs ext4 >/dev/null 2>&1
check "--fs ext4 accepted"           '[[ "$ISV_FS" == "ext4" ]]'

reset_globals
isv_parse_args --i-understand-data-loss >/dev/null 2>&1
check "--i-understand-data-loss sets flag" '[[ $ISV_ERASE_CONFIRMED -eq 1 ]]'

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

# The typed-model ERASE gate must NOT be satisfiable by --yes alone —
# non-interactive whole-disk erase additionally needs --i-understand-data-loss.
reset_globals; ISV_ASSUME_YES=1; ISV_ERASE_CONFIRMED=0
confirm "type model:" "Samsung 990" >/dev/null 2>&1
check "--yes alone does NOT pass typed erase gate" '[[ $? -ne 0 ]]'

reset_globals; ISV_ASSUME_YES=1; ISV_ERASE_CONFIRMED=1
confirm "type model:" "Samsung 990" >/dev/null 2>&1
check "--yes + --i-understand-data-loss passes gate" '[[ $? -eq 0 ]]'

reset_globals; ISV_ASSUME_YES=0; ISV_ERASE_CONFIRMED=1
confirm "type model:" "Samsung 990" >/dev/null 2>&1 <<< "wrong"
check "erase flag without --yes still requires typing" '[[ $? -ne 0 ]]'

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
reset_globals
free=$(isv_free_space_mib /dev/sdz)
check "picks largest free block (380000)"    '[[ "$free" == "380000" ]]'
read -r fb_start fb_end fb_size <<< "$(isv_free_block /dev/sdz)"
check "start of largest free block (120000)" '[[ "$fb_start" == "120000" ]]'
check "end of largest free block (500000)"   '[[ "$fb_end" == "500000" ]]'
check "size of largest free block (380000)"  '[[ "$fb_size" == "380000" ]]'
unset -f parted

# ── Free-block END math (dual-boot partition bounds) ──────────────
# Windows commonly puts a RECOVERY partition at the END of the disk, AFTER the
# free space. parted's 100% / -NMiB specs measure from the end of the DISK, so
# using them would overlap that partition. Assert the alongside plan bounds
# the new partitions by the free block's END instead.
echo "== Free-block END math (recovery partition after free space) =="

parted() {
    # Emulate both parted calls the alongside path makes.
    case "$*" in
        -m*)    # machine-readable print (isv_find_esp): partition 1 is the ESP
            cat <<'PARTED'
BYT;
/dev/sdz:500000MiB:scsi:512:512:gpt:Fake Disk:;
1:2.00MiB:202MiB:200MiB:fat32:EFI system partition:boot, esp;
2:202MiB:120000MiB:119798MiB:ntfs:Basic data partition:msftdata;
3:480000MiB:500000MiB:20000MiB:ntfs:Recovery:hidden, diag;
PARTED
            ;;
        *"print free"*)   # free block 120000–480000, recovery 480000–500000
            cat <<'PARTED'
Model: Fake Disk (scsi)
Disk /dev/sdz: 500000MiB
Number  Start      End        Size       Type     File system  Flags
 1      2.00MiB    202MiB     200MiB     primary  fat32        boot, esp
 2      202MiB     120000MiB  119798MiB  primary  ntfs
        120000MiB  480000MiB  360000MiB           Free Space
 3      480000MiB  500000MiB  20000MiB   primary  ntfs
PARTED
            ;;
    esac
    return 0
}
lsblk() {
    if [[ "$*" == *"-o PATH"* ]]; then
        printf '/dev/sdz\n/dev/sdz1\n/dev/sdz2\n/dev/sdz3\n'
    fi
}
blkid() { echo ""; }
mkfs.ntfs() { :; }   # make `command -v mkfs.ntfs` succeed for the shared path

reset_globals; ISV_DRY_RUN=1; ISV_TARGET=/dev/sdz; ISV_SHARED_GB=100
out=$(isv_install_alongside 2>&1)
check "root mkpart bounded by free-block end minus shared (377600)" \
    'echo "$out" | grep -q "mkpart PowOS btrfs 120000MiB 377600.00MiB"'
check "shared mkpart carved inside free block (ends 480000, not 100%)" \
    'echo "$out" | grep -q "mkpart POWOS-SHARED ntfs 377600.00MiB 480000MiB"'
check "no disk-end-relative specs (100% / -NMiB) in mkpart calls" \
    '! echo "$out" | grep "mkpart" | grep -Eq "100%|-[0-9]+MiB"'
check "dry-run plan never targets an existing partition with mkfs" \
    '! echo "$out" | grep -E "mkfs\.(btrfs|ext4)" | grep -q "sdz[0-9]"'
check "dry-run plan shows placeholder for the new partition" \
    'echo "$out" | grep -q "<new PowOS partition>"'

reset_globals; ISV_DRY_RUN=1; ISV_TARGET=/dev/sdz; ISV_SHARED_GB=0
out=$(isv_install_alongside 2>&1)
check "without shared: root ends at free-block end (480000MiB)" \
    'echo "$out" | grep -q "mkpart PowOS btrfs 120000MiB 480000MiB"'

reset_globals; ISV_DRY_RUN=1; ISV_TARGET=/dev/sdz; ISV_SHARED_GB=0; ISV_FS=ext4
out=$(isv_install_alongside 2>&1)
check "ext4 uses -F (mke2fs), not btrfs's -f" \
    'echo "$out" | grep -q "mkfs.ext4 -F"'

unset -f parted lsblk blkid mkfs.ntfs

# ── ESP selection by flag ─────────────────────────────────────────
# A vfat DATA partition sits BEFORE the flagged ESP: the finder must pick the
# flagged one, not the first vfat it sees.
echo "== ESP selection by esp/boot flag =="

parted() {
    cat <<'PARTED'
BYT;
/dev/sdy:500000MiB:scsi:512:512:gpt:Fake Disk:;
1:2MiB:5002MiB:5000MiB:fat32:Basic data partition:msftdata;
2:5002MiB:5202MiB:200MiB:fat32:EFI system partition:boot, esp;
3:5202MiB:120000MiB:114798MiB:ntfs:Windows:msftdata;
PARTED
}
lsblk() {
    if [[ "$*" == *"-o PATH"* ]]; then
        printf '/dev/sdy\n/dev/sdy1\n/dev/sdy2\n/dev/sdy3\n'
    fi
}
reset_globals
check "flagged ESP chosen over earlier vfat data partition" \
    '[[ "$(isv_find_esp /dev/sdy)" == "/dev/sdy2" ]]'

# legacy_boot alone must not count as the ESP 'boot' flag.
parted() {
    cat <<'PARTED'
BYT;
/dev/sdy:500000MiB:scsi:512:512:gpt:Fake Disk:;
1:2MiB:5002MiB:5000MiB:fat32:Basic data partition:legacy_boot;
2:5002MiB:5202MiB:200MiB:fat32:EFI system partition:esp;
PARTED
}
check "legacy_boot flag not mistaken for esp/boot" \
    '[[ "$(isv_find_esp /dev/sdy)" == "/dev/sdy2" ]]'

# No flagged ESP anywhere: the vfat heuristic needs explicit confirmation,
# and --yes must refuse rather than guess.
parted() {
    cat <<'PARTED'
BYT;
/dev/sdy:500000MiB:scsi:512:512:gpt:Fake Disk:;
1:2MiB:5002MiB:5000MiB:fat32:Basic data partition:msftdata;
2:5002MiB:120000MiB:114998MiB:ntfs:Windows:msftdata;
PARTED
}
blkid() {
    # emulate `blkid -o value -s TYPE <part>`
    case "${!#}" in
        /dev/sdy1) echo "vfat" ;;
        *)         echo "" ;;
    esac
}
isv_is_block() { return 0; }

reset_globals; ISV_ASSUME_YES=1
esp=$(isv_find_esp /dev/sdy 2>/dev/null); rc=$?
check "--yes refuses the vfat heuristic (no silent guess)" \
    '[[ $rc -ne 0 && -z "$esp" ]]'

reset_globals
esp=$(isv_find_esp /dev/sdy 2>/dev/null <<< "y")
check "interactive 'y' accepts the vfat heuristic candidate" \
    '[[ "$esp" == "/dev/sdy1" ]]'

reset_globals
esp=$(isv_find_esp /dev/sdy 2>/dev/null <<< "n"); rc=$?
check "interactive 'n' rejects the vfat heuristic" '[[ $rc -ne 0 ]]'

unset -f parted lsblk blkid isv_is_block

# ── Fallback-format guard ─────────────────────────────────────────
# When the partlabel lookup fails, "last partition" can resolve to a
# PRE-EXISTING partition (GPT fills numbering gaps). It must never be
# formatted if it carries a filesystem signature or its size is off.
echo "== Fallback format guard =="

blkid() { echo "ntfs"; }   # existing filesystem signature
check "existing signature → refuse to format" \
    '! isv_verify_new_partition /dev/sdz3 1000 2>/dev/null'

blkid() { echo ""; }
lsblk() { echo $(( 1000 * 1048576 )); }   # emulate `lsblk -bnd -o SIZE` (bytes)
check "clean signature + matching size → allowed" \
    'isv_verify_new_partition /dev/sdz3 1000 2>/dev/null'

lsblk() { echo $(( 5000 * 1048576 )); }
check "size far off what was just created → refuse" \
    '! isv_verify_new_partition /dev/sdz3 1000 2>/dev/null'

lsblk() { echo $(( 1010 * 1048576 )); }
check "small alignment delta (<=64MiB) tolerated" \
    'isv_verify_new_partition /dev/sdz3 1000 2>/dev/null'

unset -f blkid lsblk

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
