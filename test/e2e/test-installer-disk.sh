#!/bin/bash
# test-installer-disk.sh - REAL block-device validation of the installer's
# partitioning logic, using a loop device that simulates a Windows disk.
#
# This covers the disk-touching operations that tier-1 unit tests can't (they
# mock parted/mkfs): GPT parsing, ESP + Windows detection, free-block math on a
# real table, parted negative-offset mkpart, partprobe timing, mkfs.ntfs, and
# GPT PARTLABEL lookup. It does NOT run `bootc install` or boot anything —
# those still require a full image build + VM (see INSTALL-VALIDATION.md).
#
# Requires: privileged container + parted, ntfsprogs, dosfstools, util-linux.
#   docker run --rm --privileged -v "$PWD:/powos" fedora:latest \
#     bash -c 'dnf install -y parted ntfsprogs dosfstools util-linux >/dev/null &&
#              bash /powos/test/e2e/test-installer-disk.sh'

set -uo pipefail

PASS=0; FAIL=0; SKIP=0
pass() { echo "  ok   - $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
skip() { echo "  skip - $1"; SKIP=$((SKIP+1)); }

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/install-system.sh"

# Preconditions
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    skip "needs root + privileged (loop devices)"; echo "$PASS/$FAIL/$SKIP"; exit 0
fi
for t in parted mkfs.ntfs mkfs.vfat losetup partprobe blkid lsblk; do
    command -v "$t" >/dev/null || { skip "missing tool: $t"; echo "== $PASS passed, $FAIL failed, $SKIP skipped =="; exit 0; }
done

# shellcheck disable=SC1090
source "$LIB"

# ── udev simulation ───────────────────────────────────────────────
# This minimal container has no running udev and the loop driver has
# max_part=0, so the kernel registers new partitions in /proc/partitions but
# never creates their /dev nodes. A real booted PowOS system has udev and does
# this automatically. Override isv_settle to also mknod the missing nodes, so
# the test faithfully exercises the installer's real code paths (parted mkpart,
# mkfs.ntfs, label lookup) against actual block devices.
isv_settle() {
    local dev="$1"
    partprobe "$dev" 2>/dev/null || true
    partx -a "$dev" 2>/dev/null || true
    partx -u "$dev" 2>/dev/null || true
    local base; base="$(basename "$dev")"
    awk -v b="$base" '$4 ~ "^"b"p[0-9]+$" {print $1, $2, $4}' /proc/partitions 2>/dev/null \
        | while read -r maj min nm; do
            [[ -e "/dev/$nm" ]] || mknod "/dev/$nm" b "$maj" "$min"
          done
    sleep 1
}

IMG=""; LOOP=""
cleanup() {
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null || true
    [[ -n "$IMG" ]] && rm -f "$IMG" 2>/dev/null || true
}
trap cleanup EXIT

echo "== Building a fake 2GB Windows disk on a loop device =="
IMG="$(mktemp /tmp/powos-disk.XXXXXX.img)"
truncate -s 2G "$IMG"
LOOP="$(losetup -P --find --show "$IMG")"
echo "  loop: $LOOP"

parted -s "$LOOP" mklabel gpt
parted -s "$LOOP" mkpart EFI fat32 1MiB 101MiB
parted -s "$LOOP" set 1 esp on
parted -s "$LOOP" mkpart Windows ntfs 101MiB 700MiB
isv_settle "$LOOP"                    # create the /dev nodes (udev sim)

# If the kernel can't give us usable partition nodes (loop max_part=0 + no udev,
# common in minimal containers), skip rather than false-fail. This test needs a
# udev-enabled environment or a real VM — see INSTALL-VALIDATION.md.
if [[ ! -b "${LOOP}p1" ]]; then
    skip "no usable partition nodes (loop max_part=0 / no udev) — run in a VM"
    echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
    exit 0
fi

mkfs.vfat "${LOOP}p1" >/dev/null 2>&1
mkfs.ntfs -f "${LOOP}p2" >/dev/null 2>&1

ISV_TARGET="$LOOP"; ISV_DRY_RUN=0; ISV_ASSUME_YES=1

echo "== Detection on a real table =="
esp="$(isv_find_esp "$LOOP")"
[[ "$esp" == "${LOOP}p1" ]] && pass "isv_find_esp finds the ESP ($esp)" || fail "isv_find_esp got '$esp'"

if isv_detect_windows "$LOOP"; then pass "isv_detect_windows detects Windows (NTFS present)"; else fail "isv_detect_windows missed the NTFS partition"; fi

start="$(isv_free_block_start)"
if [[ -n "$start" ]] && (( start >= 700 )); then pass "isv_free_block_start = ${start}MiB (past Windows)"; else fail "isv_free_block_start = '$start'"; fi

echo "== Real shared-partition creation (parted negative offset + mkfs.ntfs) =="
ISV_SHARED_GB=1
# Reserve the last 1GiB as the shared partition (mirrors the alongside flow's tail).
isv_create_shared_partition "$LOOP" "-1024MiB" "100%" >/dev/null 2>&1

sp="$(isv_part_by_partlabel "$LOOP" "POWOS-SHARED")"
if [[ -b "$sp" ]]; then pass "POWOS-SHARED partition created + found by label ($sp)"; else fail "POWOS-SHARED not found (got '$sp')"; fi

if [[ -b "$sp" ]]; then
    fstype="$(blkid -o value -s TYPE "$sp" 2>/dev/null)"
    label="$(blkid -o value -s LABEL "$sp" 2>/dev/null)"
    [[ "$fstype" == "ntfs" ]] && pass "shared partition is NTFS" || fail "shared fstype='$fstype'"
    [[ "$label" == "POWOS-SHARED" ]] && pass "shared partition label is POWOS-SHARED" || fail "shared label='$label'"
fi

# The original Windows partitions must be untouched.
wtype="$(blkid -o value -s TYPE "${LOOP}p2" 2>/dev/null)"
[[ "$wtype" == "ntfs" ]] && pass "existing Windows partition intact" || fail "Windows partition damaged (type='$wtype')"

echo
echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
[[ $FAIL -eq 0 ]]
