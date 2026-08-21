#!/bin/bash
# test-variant-select.sh - initramfs multi-variant base selection.
#
# powos_select_base_variant() in lib/dracut/90powos-ramboot/ramboot-setup.sh
# decides WHICH OS BOOTS off a multi-variant live USB. It shipped carrying
# "TODO(hw): validate on real hardware / a VM — this is boot-critical" and had
# no tests at all. A wrong answer here boots the wrong base, or none.
#
# The function is extracted and sourced in isolation rather than sourcing
# ramboot-setup.sh, which would execute real boot logic (tmpfs mounts,
# pivot_root) on the test machine.
#
# Covers the precedence chain it documents:
#   explicit override / persistent default > GPU auto-detect > main > first
# plus the guarantee that a single-variant USB behaves exactly as before.
#
# Usage:  bash test/tier1/test-variant-select.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/lib/dracut/90powos-ramboot/ramboot-setup.sh"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && echo "         $2"; }

[[ -f "$SRC" ]] || { echo "missing $SRC"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Extract just the two functions under test.
EXTRACT="$TMP/select.sh"
# _powos_variant_in is a ONE-LINER ending in '}', so a sed range starting at it
# runs on to the next line beginning with '}' — the end of the other function —
# swallowing both into one mangled definition. Grab them separately.
grep '^_powos_variant_in()' "$SRC" > "$EXTRACT"
sed -n '/^powos_select_base_variant()/,/^}/p' "$SRC" >> "$EXTRACT"
if ! grep -q 'powos_select_base_variant' "$EXTRACT"; then
    echo "  FAIL - could not extract powos_select_base_variant from ramboot-setup.sh"
    echo "== Results: 0 passed, 1 failed =="
    exit 1
fi

# ── Harness ────────────────────────────────────────────────────────────────
USB_LAYERS="$TMP/usb"
NEWROOT="$TMP/newroot"
BASE_LAYER="$NEWROOT"
CMDLINE_VARIANT=""
HAS_NVIDIA=0

info() { :; }
getarg() {
    # dracut's getarg prints the value and returns 0 when present.
    case "$1" in
        rd.powos.variant=) [[ -n "$CMDLINE_VARIANT" ]] && { printf '%s\n' "$CMDLINE_VARIANT"; return 0; }; return 1 ;;
    esac
    return 1
}
lspci() { [[ "$HAS_NVIDIA" == "1" ]] && echo "01:00.0 VGA compatible controller: NVIDIA Corporation GA104"; return 0; }
command() {
    # Make `command -v lspci` reflect the fixture rather than the host.
    if [[ "${1:-}" == "-v" && "${2:-}" == "lspci" ]]; then
        [[ "$HAS_NVIDIA" == "skip" ]] && return 1
        echo lspci; return 0
    fi
    builtin command "$@"
}

# shellcheck source=/dev/null
source "$EXTRACT"

setup() {
    rm -rf "$USB_LAYERS" "$NEWROOT"
    mkdir -p "$USB_LAYERS/layers" "$NEWROOT"
    local v
    for v in "$@"; do mkdir -p "$USB_LAYERS/layers/base-$v"; done
    BASE_LAYER="$NEWROOT"
    CMDLINE_VARIANT=""
    HAS_NVIDIA=0
    rm -f "$USB_LAYERS/.powos-default-variant"
}

chose() { echo "${BASE_LAYER##*/base-}"; }

# ── Tests ──────────────────────────────────────────────────────────────────
echo "== single-variant USB (must behave exactly as before) =="

setup    # no base-* dirs at all
powos_select_base_variant
[[ "$BASE_LAYER" == "$NEWROOT" ]] \
    && ok "no base-*/ dirs → BASE_LAYER untouched (unchanged single-variant boot)" \
    || bad "no base-*/ dirs → BASE_LAYER untouched" "got '$BASE_LAYER'"

echo ""
echo "== GPU auto-detect =="

setup main nvidia-open
HAS_NVIDIA=1
powos_select_base_variant
[[ "$(chose)" == "nvidia-open" ]] \
    && ok "NVIDIA present → nvidia-open" \
    || bad "NVIDIA present → nvidia-open" "got '$(chose)'"

setup main nvidia-open
HAS_NVIDIA=0
powos_select_base_variant
[[ "$(chose)" == "main" ]] \
    && ok "no NVIDIA → main" \
    || bad "no NVIDIA → main" "got '$(chose)'"

setup main nvidia-open
HAS_NVIDIA=skip     # lspci absent entirely
powos_select_base_variant
[[ "$(chose)" == "main" ]] \
    && ok "lspci missing → main (no crash, no wrong guess)" \
    || bad "lspci missing → main" "got '$(chose)'"

echo ""
echo "== explicit override beats auto-detect =="

setup main nvidia-open deck
HAS_NVIDIA=1
CMDLINE_VARIANT="deck"
powos_select_base_variant
[[ "$(chose)" == "deck" ]] \
    && ok "rd.powos.variant=deck wins over NVIDIA autodetect" \
    || bad "override wins over autodetect" "got '$(chose)'"

setup main nvidia-open
HAS_NVIDIA=1
CMDLINE_VARIANT="auto"
powos_select_base_variant
[[ "$(chose)" == "nvidia-open" ]] \
    && ok "rd.powos.variant=auto falls through to autodetect" \
    || bad "auto falls through to autodetect" "got '$(chose)'"

# An override naming a variant that is NOT on the stick must not brick the
# boot — fall back to the detected one rather than a nonexistent directory.
setup main nvidia-open
HAS_NVIDIA=0
CMDLINE_VARIANT="deck"
powos_select_base_variant
[[ "$(chose)" == "main" && -d "$BASE_LAYER" ]] \
    && ok "override for an ABSENT variant falls back to a real base" \
    || bad "override for an absent variant falls back" "got '$(chose)'"

echo ""
echo "== persistent default =="

setup main nvidia-open deck
HAS_NVIDIA=1
echo "deck" > "$USB_LAYERS/.powos-default-variant"
powos_select_base_variant
[[ "$(chose)" == "deck" ]] \
    && ok ".powos-default-variant beats autodetect" \
    || bad ".powos-default-variant beats autodetect" "got '$(chose)'"

setup main nvidia-open deck
HAS_NVIDIA=1
echo "deck" > "$USB_LAYERS/.powos-default-variant"
CMDLINE_VARIANT="main"
powos_select_base_variant
[[ "$(chose)" == "main" ]] \
    && ok "cmdline beats the persistent default" \
    || bad "cmdline beats the persistent default" "got '$(chose)'"

echo ""
echo "== fallbacks =="

setup nvidia-open        # no 'main' on the stick, no NVIDIA in the box
HAS_NVIDIA=0
powos_select_base_variant
[[ "$(chose)" == "nvidia-open" && -d "$BASE_LAYER" ]] \
    && ok "no 'main' available → first available, never a missing dir" \
    || bad "no 'main' available → first available" "got '$(chose)'"

setup deck
HAS_NVIDIA=1
powos_select_base_variant
[[ -d "$BASE_LAYER" ]] \
    && ok "single base-* present → that one, and it exists on disk" \
    || bad "single base-* present" "got '$BASE_LAYER'"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
