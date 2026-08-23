#!/bin/bash
# test-variants-store-lookup.sh - Tier-1 tests for finding the offline variant
# store on a live medium.
#
# The medium's own fstab mounts POWOS-DATA's @powos/containers subvolume at
# /var/lib/containers, to give the install somewhere with room to unpack. That
# makes /var/lib/containers the first — and usually only — mountpoint findmnt
# reports for that device, and it exposes exactly ONE subvolume, which is not
# the one carrying the store. Trusting it produced
#
#     No offline variant store on this media.
#     Variant 'deck' is not on this media.
#
# on a stick whose store had been verified byte for byte minutes earlier, and
# it stopped an install on the hardware it was built for.
#
# Runs anywhere: blkid/findmnt/mount are shadowed and the "device" is a
# directory tree.
#
# Usage:  bash test/tier1/test-variants-store-lookup.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$ROOT/lib/variants.sh"
[[ -f "$LIB" ]] || LIB=/usr/lib/powos/variants.sh

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && echo "         $2"; }

# shellcheck source=/dev/null
source "$LIB" 2>/dev/null || { echo "cannot source $LIB"; exit 1; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

FS_ROOT="$SCRATCH/fsroot"          # what a subvolid=5 mount would expose
SUBVOL_ONLY="$SCRATCH/containers"  # what /var/lib/containers exposes
mkdir -p "$FS_ROOT/@powos/variants" "$FS_ROOT/@powos/containers" "$SUBVOL_ONLY/storage"
echo '{"manifests":[]}' > "$FS_ROOT/@powos/variants/index.json"

MOUNTS=""            # what findmnt reports for the device
MOUNT_CALLS=0
blkid()  { [[ "$*" == *POWOS-DATA* ]] && echo /dev/fake5; return 0; }
findmnt() {
    # Two different questions get asked of findmnt here, and the stub has to
    # answer both faithfully or it stops reproducing the bug:
    #   "where is this DEVICE mounted?"  — the arg is /dev/...
    #   "is this PATH a mountpoint?"     — the arg is a directory
    # The pre-fix code asked the first with `-o TARGET <dev>` and the fixed
    # code asks it with `--source <dev>`; both must get the mount list, or the
    # test quietly stops testing the thing it was written for.
    local last="${*: -1}"
    if [[ "$*" == *--source* || "$last" == /dev/* ]]; then
        printf '%s\n' $MOUNTS; return 0
    fi
    return 1
}
# pv_variants_dir calls pv_data_mount inside $( ), so anything the stub records
# in a variable is lost with the subshell. Record to a file.
mount() {
    printf '%s\n' "$*" >> "$SCRATCH/mount.log"
    # Emulate: mounting the device root exposes the whole filesystem.
    local dst="${@: -1}"
    mkdir -p "$dst" 2>/dev/null
    cp -a "$FS_ROOT/." "$dst/" 2>/dev/null
    return 0
}

reset() {
    MOUNTS=""; : > "$SCRATCH/mount.log"
    POWOS_VARIANTS_MNT="$SCRATCH/mnt"; rm -rf "$POWOS_VARIANTS_MNT"
}
mount_calls() { grep -c . "$SCRATCH/mount.log" 2>/dev/null; }
mount_args()  { cat "$SCRATCH/mount.log" 2>/dev/null; }

# ── Tests ──────────────────────────────────────────────────────────────────

t_ignores_a_subvolume_only_mount() {
    reset
    MOUNTS="$SUBVOL_ONLY"          # exactly what the live medium looks like
    local got; got=$(pv_variants_dir)
    if [[ -n "$got" && -f "$got/index.json" ]]; then
        ok "a mount exposing only @powos/containers is not mistaken for the store"
    else
        bad "a mount exposing only @powos/containers is not mistaken for the store" \
            "pv_variants_dir gave '${got:-<nothing>}'"
    fi
}

t_mounts_the_filesystem_root() {
    reset
    MOUNTS="$SUBVOL_ONLY"
    pv_variants_dir >/dev/null
    if [[ "$(mount_calls)" -ge 1 && "$(mount_args)" == *subvolid=5* ]]; then
        ok "falls back to mounting the filesystem ROOT (subvolid=5)"
    else
        bad "falls back to mounting the filesystem ROOT" \
            "calls=$(mount_calls) args='$(mount_args)'"
    fi
}

t_uses_a_good_existing_mount() {
    reset
    MOUNTS="$FS_ROOT"              # already mounted somewhere useful
    local got; got=$(pv_variants_dir)
    if [[ "$got" == "$FS_ROOT/@powos/variants" && "$(mount_calls)" -eq 0 ]]; then
        ok "an existing mount that DOES show the store is used as-is, with no remount"
    else
        bad "an existing mount that shows the store is used as-is" \
            "got '$got' after $(mount_calls) mount call(s)"
    fi
}

t_picks_the_right_one_of_several() {
    reset
    MOUNTS="$SUBVOL_ONLY
$FS_ROOT"
    local got; got=$(pv_variants_dir)
    if [[ "$got" == "$FS_ROOT/@powos/variants" ]]; then
        ok "with several mounts of the device, the one carrying the store wins"
    else
        bad "with several mounts, the one carrying the store wins" "got '$got'"
    fi
}

t_lists_variants_through_the_fallback() {
    reset
    MOUNTS="$SUBVOL_ONLY"
    python3 - "$FS_ROOT/@powos/variants/index.json" <<'PY'
import json,sys
json.dump({"manifests":[
    {"annotations":{"org.opencontainers.image.ref.name":"main"}},
    {"annotations":{"org.opencontainers.image.ref.name":"deck"}}]},
    open(sys.argv[1],"w"))
PY
    if pv_have_variant deck; then
        ok "'deck' is found on the medium again (the reported failure)"
    else
        bad "'deck' is found on the medium" "pv_list gave: $(pv_list | tr '\n' ' ')"
    fi
}

t_no_device_still_fails_cleanly() {
    reset
    blkid() { return 0; }         # no POWOS-DATA at all
    if pv_variants_dir >/dev/null 2>&1; then
        bad "no POWOS-DATA reports no store"
    else
        ok "no POWOS-DATA still reports no store, without mounting anything"
    fi
    blkid() { [[ "$*" == *POWOS-DATA* ]] && echo /dev/fake5; return 0; }
}

t_ignores_a_subvolume_only_mount
t_mounts_the_filesystem_root
t_uses_a_good_existing_mount
t_picks_the_right_one_of_several
t_lists_variants_through_the_fallback
t_no_device_still_fails_cleanly

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
