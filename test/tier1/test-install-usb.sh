#!/bin/bash
# test-install-usb.sh - Tier-1 unit tests for install-to-usb.sh's SOURCEABLE
# helpers: BLS entry writing and first-boot disk self-completion.
#
# Runs on any Linux box AND Git Bash (no root, no real disks) by SOURCING
# install-to-usb.sh — which is guarded so sourcing does NOT run main() — and
# shadowing the block-device tools (blkid/findmnt/lsblk) plus the heavy helpers
# (add_data_partition/setup_persistence/write_bls_entries) with bash functions.
#
# It CANNOT validate real partitioning/boot menus — that needs the QEMU/hardware
# checklist. It DOES pin the dangerous-if-wrong logic: the install/recovery
# kargs, boot-disk resolution, single-disk safety refusals, and the
# "POWOS-DATA already exists → no-op" idempotency gate.
#
# Usage:  bash test/tier1/test-install-usb.sh
#   Docker: docker exec powos bash /test/tier1/test-install-usb.sh

set -uo pipefail

# Locate install-to-usb.sh relative to this test, or an installed/bundled copy.
LIB=""
for cand in \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../build" 2>/dev/null && pwd)/install-to-usb.sh" \
    /var/lib/powos/src/build/install-to-usb.sh \
    /usr/lib/powos/build/install-to-usb.sh \
    /usr/lib/powos/install-to-usb.sh; do
    if [[ -n "$cand" && -f "$cand" ]]; then LIB="$cand"; break; fi
done
[[ -z "$LIB" ]] && { echo "cannot find install-to-usb.sh"; exit 1; }

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

echo "== Sourcing install-to-usb.sh: $LIB =="
# The bottom-of-file guard (BASH_SOURCE == $0) means this does NOT run main().
# shellcheck disable=SC1090
source "$LIB" || { echo "cannot source lib"; exit 1; }
# install-to-usb.sh sets `set -euo pipefail`; neutralise -e so a mock returning
# nonzero inside a test does not abort the whole run.
set +e

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ──────────────────────────────────────────────────────────────────
# write_bls_entries: install + two recovery entries from a template.
# ──────────────────────────────────────────────────────────────────
echo "== write_bls_entries =="

ENTRIES="$WORK/loader/entries"
mkdir -p "$ENTRIES"
# A realistic BLS live-boot entry (has the mandatory `options` line).
cat > "$ENTRIES/01-powos-live.conf" <<'EOF'
title PowOS Live
linux /vmlinuz
initrd /initramfs.img
options root=UUID=deadbeef rw quiet rd.powos.ramboot=1
EOF

write_bls_entries "$ENTRIES" >/dev/null 2>&1

check "install entry created"        '[[ -f "$ENTRIES/powos-install.conf" ]]'
check "safe entry created"           '[[ -f "$ENTRIES/powos-safe.conf" ]]'
check "aidebug entry created"        '[[ -f "$ENTRIES/powos-aidebug.conf" ]]'

check "install entry carries powos.install=1" \
    'grep -q "powos.install=1" "$ENTRIES/powos-install.conf"'
check "install entry keeps root= from template" \
    'grep -q "root=UUID=deadbeef" "$ENTRIES/powos-install.conf"'
check "install entry retitled" \
    'grep -q "^title Install PowOS to disk" "$ENTRIES/powos-install.conf"'

check "safe entry carries powos.mode=safe" \
    'grep -q "powos.mode=safe" "$ENTRIES/powos-safe.conf"'
check "safe entry forces ramboot off" \
    'grep -q "rd.powos.ramboot=0" "$ENTRIES/powos-safe.conf"'

check "aidebug entry carries powos.mode=aidebug" \
    'grep -q "powos.mode=aidebug" "$ENTRIES/powos-aidebug.conf"'
check "aidebug entry forces ramboot off" \
    'grep -q "rd.powos.ramboot=0" "$ENTRIES/powos-aidebug.conf"'

# Idempotency: re-run must not template off its own generated entries.
write_bls_entries "$ENTRIES" >/dev/null 2>&1
check "re-run keeps a single powos.install=1 in install entry" \
    '[[ "$(grep -c "powos.install=1" "$ENTRIES/powos-install.conf")" == "1" ]]'

# No `options` line in the template → refuse (would be unbootable), no files.
BADENTRIES="$WORK/bad/entries"
mkdir -p "$BADENTRIES"
printf 'title Broken\nlinux /vmlinuz\n' > "$BADENTRIES/bad.conf"
write_bls_entries "$BADENTRIES" >/dev/null 2>&1
check "no options line → no install entry written" \
    '[[ ! -f "$BADENTRIES/powos-install.conf" ]]'

# ──────────────────────────────────────────────────────────────────
# self_complete_boot_disk: boot-disk resolution + add-only orchestration.
# ──────────────────────────────────────────────────────────────────
echo "== self_complete_boot_disk =="

CALLS="$WORK/calls.log"

# Shadow the heavy helpers so we assert *what* self-complete calls, not real IO.
add_data_partition() { echo "ADP:$1" >> "$CALLS"; }
setup_persistence()  { echo "SP:$1"  >> "$CALLS"; }
write_bls_entries()  { echo "BLS:$1" >> "$CALLS"; }   # isolate from disk state

reset_calls() { : > "$CALLS"; }

# Happy path: /boot/efi is on /dev/sdb1 → parent disk /dev/sdb.
mock_happy() {
    blkid()  { return 1; }                              # POWOS-DATA absent
    findmnt(){ case "$*" in *'/boot/efi'*) echo /dev/sdb1;; *'/boot'*) echo /dev/sdb1;; *) return 1;; esac; }
    lsblk()  {
        case "$*" in
            *'-no PKNAME'*)  echo sdb ;;                # parent of /dev/sdb1
            *'-dno TYPE'*)   echo disk ;;              # /dev/sdb is a whole disk
            *'-ln -o PATH'*) printf '/dev/sdb\n/dev/sdb1\n/dev/sdb2\n' ;;
        esac
    }
}

reset_calls; mock_happy
self_complete_boot_disk >/dev/null 2>&1
check "add_data_partition called with resolved disk /dev/sdb" \
    'grep -qx "ADP:/dev/sdb" "$CALLS"'
check "setup_persistence called with resolved disk /dev/sdb" \
    'grep -qx "SP:/dev/sdb" "$CALLS"'

# Idempotent no-op: POWOS-DATA already present → do nothing.
reset_calls
blkid() { echo /dev/sdb3; return 0; }    # label found
self_complete_boot_disk >/dev/null 2>&1
check "no add_data_partition when POWOS-DATA already exists" \
    '! grep -q "ADP:" "$CALLS"'
check "no setup_persistence when POWOS-DATA already exists" \
    '! grep -q "SP:" "$CALLS"'

# Abort safely: boot source cannot be resolved → no destructive calls.
reset_calls
blkid()  { return 1; }
findmnt(){ return 1; }                    # neither /boot/efi nor /boot resolves
self_complete_boot_disk >/dev/null 2>&1
check "unresolved boot source → no add_data_partition" \
    '! grep -q "ADP:" "$CALLS"'
check "unresolved boot source → no setup_persistence" \
    '! grep -q "SP:" "$CALLS"'

# Abort safely: parent node is not a whole disk (TYPE=part) → refuse.
reset_calls
blkid()  { return 1; }
findmnt(){ echo /dev/sdb1; }
lsblk()  { case "$*" in *'-no PKNAME'*) echo sdb;; *'-dno TYPE'*) echo part;; *'-ln -o PATH'*) printf '/dev/sdb1\n';; esac; }
self_complete_boot_disk >/dev/null 2>&1
check "non-whole-disk parent → no destructive calls" \
    '! grep -qE "ADP:|SP:" "$CALLS"'

# Abort safely: boot source is NOT a partition of the resolved disk → refuse
# to guess (single-disk verification).
reset_calls
blkid()  { return 1; }
findmnt(){ echo /dev/sdb1; }
lsblk()  { case "$*" in *'-no PKNAME'*) echo sdb;; *'-dno TYPE'*) echo disk;; *'-ln -o PATH'*) printf '/dev/sdb\n/dev/sdc9\n';; esac; }
self_complete_boot_disk >/dev/null 2>&1
check "boot source not on resolved disk → no destructive calls" \
    '! grep -qE "ADP:|SP:" "$CALLS"'

# ──────────────────────────────────────────────────────────────────
echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
