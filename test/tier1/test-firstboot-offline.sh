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
check "installer seeds hardware fixups"   'declare -F isv_seed_hardware_fixups'
check "a Deck (Jupiter) gets amd_iommu=off" \
      'd=$(mktemp -d); printf Jupiter > "$d/product_name"
       ISV_DMI=$d isv_hardware_kargs | grep -qx "amd_iommu=off"; r=$?; rm -rf "$d"; exit $r'
check "a Deck OLED (Galileo) gets amd_iommu=off" \
      'd=$(mktemp -d); printf Galileo > "$d/product_name"
       ISV_DMI=$d isv_hardware_kargs | grep -qx "amd_iommu=off"; r=$?; rm -rf "$d"; exit $r'
check "a desktop does NOT get amd_iommu=off" \
      'd=$(mktemp -d); printf "System Product Name" > "$d/product_name"
       ISV_DMI=$d isv_hardware_kargs | grep -qx "amd_iommu=off" && r=1 || r=0; rm -rf "$d"; exit $r'
check "every machine gets bluetooth.disable_ertm=1 (it is unconditional upstream)" \
      'd=$(mktemp -d); printf "System Product Name" > "$d/product_name"
       ISV_DMI=$d isv_hardware_kargs | grep -qx "bluetooth.disable_ertm=1"; r=$?; rm -rf "$d"; exit $r'
check "fixups land in the DEPLOYMENT etc, never the partition root" \
      'm=$(mktemp -d); mkdir -p "$m/ostree/deploy/d/deploy/a.0/etc" "$m/etc"
       isv_seed_hardware_fixups "$m" &&
       [ -f "$m/ostree/deploy/d/deploy/a.0/etc/bazzite/fixups/gttsize" ] &&
       [ ! -e "$m/etc/bazzite" ]; r=$?; rm -rf "$m"; exit $r'

# The other half needs the real script, which exists inside the image.
if [[ ! -r "$HWS" ]]; then
    echo "  skip - replay against $HWS (not on this host; runs in the container stage)"
else
    sim() { # $1=cmdline $2=seed|noseed  -> prints NEEDED_KARGS count
        local stub fake a b
        stub=$(mktemp -d); fake=$(mktemp -d); mkdir -p "$fake/etc/bazzite/fixups"
        [[ "$2" == seed ]] && { local f
            while read -r f; do : > "$fake/etc/bazzite/fixups/$f"; done < <(isv_hardware_fixups); }
        printf '#!/bin/bash\nexit 0\n'      > "$stub/valve-hardware"
        printf '#!/bin/bash\necho Jupiter\n' > "$stub/sysid"
        chmod +x "$stub"/*
        a=$(grep -n '^# GLOBAL' "$HWS" | head -1 | cut -d: -f1)
        b=$(grep -n 'Removing nomodeset' "$HWS" | head -1 | cut -d: -f1)
        sed -n "${a},$((b+3))p" "$HWS" \
          | sed "s#/usr/libexec/hwsupport/#$stub/#g; s#/etc/bazzite/#$fake/etc/bazzite/#g" \
          | sed "s|^KARGS=.*|:|; s|^SYS_ID=.*|SYS_ID=Jupiter|" > "$stub/slice.sh"
        ( IMAGE_NAME=powos-deck; KARGS="$1"; NEEDED_KARGS=()
          # shellcheck disable=SC1090
          source "$stub/slice.sh" >/dev/null 2>&1; echo "${#NEEDED_KARGS[@]}" )
        rm -rf "$stub" "$fake"
    }
    BASE="root=UUID=x rw ostree=/ostree/boot.1/default/x/0 rd.powos.ramboot=0 plymouth.enable=0"
    # The replay is a Deck, so the cmdline must be the one the installer would
    # produce ON a Deck -- not the one for whatever host is running the tests.
    _d=$(mktemp -d); printf Jupiter > "$_d/product_name"
    POST="$BASE $(ISV_DMI=$_d isv_hardware_kargs | tr '\n' ' ')"
    rm -rf "$_d"

    check "a fresh Deck WOULD need the network without the fix" \
          '[ "$(sim "'"$BASE"'" noseed)" != 0 ]'
    check "pre-applied kargs alone are NOT enough (gttsize is gated on the marker only)" \
          '[ "$(sim "'"$POST"'" noseed)" != 0 ]'
    check "kargs + markers together leave NOTHING to do -> no rpm-ostree, no network" \
          '[ "$(sim "'"$POST"'" seed)" = 0 ]'
fi

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
