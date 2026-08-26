#!/usr/bin/env bash
# First boot must not require a network.
#
# bazzite-hardware-setup runs on first boot and ends with:
#
#     rpm-ostree kargs ${NEEDED_KARGS[*]} || exit 1
#     ...
#     echo $HWS_VER > $HWS_VER_FILE          # <- skipped by that exit 1
#
# On a registry-origin system, changing kargs writes a new deployment and
# therefore wants the REGISTRY. With no network that call fails, the `exit 1`
# skips the "already ran" markers, and the next boot repeats the whole thing.
# That is a boot loop on any handheld first booted away from wifi: a fresh Deck
# cycled until ethernet was plugged in, then converged in one reboot.
#
# The installer pre-satisfies it (isv_hardware_kargs + isv_seed_hardware_fixups)
# so NEEDED_KARGS comes out EMPTY and the networked call never happens.
#
# This test does not restate that logic — restating it is how it would drift.
# It extracts the decision branches VERBATIM from the installed script and runs
# them as a fresh Steam Deck. If upstream adds a branch we do not pre-satisfy,
# this goes red.
set -uo pipefail
PASS=0; FAIL=0
check() { if ( eval "$2" ) >/dev/null 2>&1; then echo "  ok   - $1"; PASS=$((PASS+1));
          else echo "  FAIL - $1"; FAIL=$((FAIL+1)); fi }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/lib/install-system.sh"; [[ -f "$LIB" ]] || LIB=/usr/lib/powos/install-system.sh
HWS=/usr/libexec/bazzite-hardware-setup

echo "== first boot needs no network =="

# The installer half is testable anywhere.
# shellcheck disable=SC1090
source "$LIB" >/dev/null 2>&1
check "installer computes hardware kargs" 'declare -F isv_hardware_kargs'
check "BOTH install paths get the kargs, not just whole-disk" \
      'n=$(grep -c "isv_hardware_kargs)" "$LIB"); [ "$n" -ge 2 ]'
check "the alongside path passes them to bootc install to-filesystem" \
      'grep -q "_hwk2\[@\]" "$LIB"'
check "installer seeds hardware fixups"   'declare -F isv_seed_hardware_fixups'
# NOTE: capture into a variable rather than piping into `grep -q`. Under
# `set -o pipefail`, grep -q exits at the first match, the producer is killed
# mid-write, and the pipeline reports 141 (SIGPIPE). That reads as a failing
# assertion. It bit the ppfeaturemask check deterministically, because that is
# the FIRST line emitted, while the later-matching checks passed on timing --
# a flaky test waiting to happen.
check "DMI fallback: a Deck (Jupiter) gets amd_iommu=off" \
      'd=$(mktemp -d); printf Jupiter > "$d/product_name"
       o=$(ISV_DMI=$d ISV_HWSUPPORT=$d/absent isv_hardware_kargs)
       grep -qx "amd_iommu=off" <<< "$o"; r=$?; rm -rf "$d"; exit $r'
check "DMI fallback: a Deck OLED (Galileo) gets amd_iommu=off" \
      'd=$(mktemp -d); printf Galileo > "$d/product_name"
       o=$(ISV_DMI=$d ISV_HWSUPPORT=$d/absent isv_hardware_kargs)
       grep -qx "amd_iommu=off" <<< "$o"; r=$?; rm -rf "$d"; exit $r'
check "a desktop does NOT get amd_iommu=off" \
      'd=$(mktemp -d); printf "System Product Name" > "$d/product_name"
       o=$(ISV_DMI=$d ISV_HWSUPPORT=$d/absent isv_hardware_kargs)
       grep -qx "amd_iommu=off" <<< "$o" && r=1 || r=0; rm -rf "$d"; exit $r'
check "every machine gets bluetooth.disable_ertm=1 (it is unconditional upstream)" \
      'd=$(mktemp -d); printf "System Product Name" > "$d/product_name"
       o=$(ISV_DMI=$d ISV_HWSUPPORT=$d/absent isv_hardware_kargs)
       grep -qx "bluetooth.disable_ertm=1" <<< "$o"; r=$?; rm -rf "$d"; exit $r'
check "upstream's own detector wins over the DMI fallback when present" \
      'd=$(mktemp -d); printf Jupiter > "$d/product_name"
       printf "#!/bin/bash\nexit 1\n" > "$d/valve-hardware"; chmod +x "$d/valve-hardware"
       o=$(ISV_DMI=$d ISV_HWSUPPORT=$d isv_hardware_kargs)
       grep -qx "amd_iommu=off" <<< "$o" && r=1 || r=0; rm -rf "$d"; exit $r'
check "a handheld gets ppfeaturemask, computed as upstream computes it" \
      'd=$(mktemp -d); printf "#!/bin/bash\nexit 0\n" > "$d/valve-hardware"
       chmod +x "$d/valve-hardware"; echo 4294508543 > "$d/ppf"
       want=$(printf "amdgpu.ppfeaturemask=0x%x" $(( 4294508543 | 0x4000 )))
       o=$(ISV_HWSUPPORT=$d ISV_PPFEATUREMASK_FILE=$d/ppf isv_hardware_kargs)
       grep -qx "$want" <<< "$o"; r=$?; rm -rf "$d"; exit $r'
check "a desktop gets NO ppfeaturemask" \
      'd=$(mktemp -d); printf "System Product Name" > "$d/product_name"
       o=$(ISV_DMI=$d ISV_HWSUPPORT=$d/absent isv_hardware_kargs)
       grep -q "ppfeaturemask" <<< "$o" && r=1 || r=0; rm -rf "$d"; exit $r'
check "fixups land in the DEPLOYMENT etc, never the partition root" \
      'm=$(mktemp -d); mkdir -p "$m/ostree/deploy/d/deploy/a.0/etc" "$m/etc"
       isv_seed_hardware_fixups "$m" &&
       [ -f "$m/ostree/deploy/d/deploy/a.0/etc/bazzite/fixups/gttsize" ] &&
       [ ! -e "$m/etc/bazzite" ]; r=$?; rm -rf "$m"; exit $r'

# The other half needs the real script, which exists inside the image.
#
# The branches MOVE between script versions: v71 (desktop images) has the
# gttsize fixup gates and no ppfeaturemask; v72 (the deck image) is the
# reverse. So replay whatever is actually installed instead of asserting a
# remembered shape -- reading one version on the build host and generalising
# is exactly how this was got wrong once.
if [[ ! -r "$HWS" ]]; then
    echo "  skip - replay against $HWS (not on this host; runs in the container stage)"
else
    STUB=$(mktemp -d)
    printf '#!/bin/bash\nexit 0\n' > "$STUB/valve-hardware"
    printf '#!/bin/bash\nexit 1\n' > "$STUB/non-valve-handheld-hardware"
    printf '#!/bin/bash\necho Jupiter\n' > "$STUB/sysid"
    chmod +x "$STUB"/*
    PPF=$(mktemp); echo 4294508543 > "$PPF"          # a plausible amdgpu default
    DMI=$(mktemp -d); printf Jupiter > "$DMI/product_name"

    # The kargs the installer would compute ON a Deck. This MUST use the same
    # stubs the replay does, or we compare a desktop's answer against a
    # handheld's question and the mismatch looks like a broken fix.
    deck_kargs() {
        ISV_DMI="$DMI" ISV_HWSUPPORT="$STUB" ISV_PPFEATUREMASK_FILE="$PPF" \
            isv_hardware_kargs
    }

    sim() {  # $1 = cmdline, $2 = seed|noseed -> prints NEEDED_KARGS count
        local fake f a b n
        fake=$(mktemp -d); mkdir -p "$fake/etc/bazzite/fixups"
        if [[ "$2" == seed ]]; then
            while read -r f; do : > "$fake/etc/bazzite/fixups/$f"; done \
                < <(isv_hardware_fixups)
        fi
        a=$(grep -n '^# GLOBAL' "$HWS" | head -1 | cut -d: -f1)
        b=$(grep -n 'Removing nomodeset' "$HWS" | head -1 | cut -d: -f1)
        sed -n "${a},$((b+3))p" "$HWS" \
          | sed "s#/usr/libexec/hwsupport/#$STUB/#g; s#/etc/bazzite/#$fake/etc/bazzite/#g" \
          | sed "s|^KARGS=.*|:|; s|^SYS_ID=.*|SYS_ID=Jupiter|" > "$fake/slice.sh"
        n=$( IMAGE_NAME=powos-deck; KARGS="$1"; NEEDED_KARGS=()
             # shellcheck disable=SC1090
             source "$fake/slice.sh" >/dev/null 2>&1; echo "${#NEEDED_KARGS[@]}" )
        rm -rf "$fake"
        echo "$n"
    }

    BASE="root=UUID=x rw ostree=/ostree/boot.1/default/x/0 rd.powos.ramboot=0 plymouth.enable=0"
    POST="$BASE $(deck_kargs | tr '\n' ' ')"

    check "a fresh Deck WOULD need the network without the fix" \
          '[ "$(sim "$BASE" noseed)" != 0 ]'
    check "with the fix there is NOTHING to do -> no rpm-ostree, no network" \
          '[ "$(sim "$POST" seed)" = 0 ]'

    # Only meaningful on script versions that gate cleanup on the markers.
    if grep -q 'fixups/' "$HWS"; then
        check "markers matter: pre-applied kargs alone are not enough" \
              '[ "$(sim "$POST" noseed)" != 0 ]'
    else
        echo "  skip - marker-gated cleanup (absent from this script version)"
    fi

    # Whatever this version asks for, we must be able to supply it.
    check "every karg this script wants is one the installer pre-applies" \
          'miss=$(sim "$POST" seed); [ "$miss" = 0 ]'
    rm -rf "$STUB" "$PPF" "$DMI"
fi

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
