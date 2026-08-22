#!/bin/bash
# test-install-wizard-gpu.sh - Tier-1 tests for the GPU-flavor step.
#
# The menu must offer only flavors the BOOT MEDIUM can actually install.
# install-system does not fall back: asked for a variant the stick does not
# carry, it aborts with "Variant 'X' is not on this media" — and it does that
# after every remaining question has already been answered, at the point where
# the user expects the disk to start being written.
#
# Runs anywhere: pv_list and the UI are shadowed, no medium required.
#
# Usage:  bash test/tier1/test-install-wizard-gpu.sh

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
# iwz_menu runs inside $(...), so the menu it was handed has to leave the
# subshell through a file rather than a variable.
CAPFILE=$(mktemp)
iwz_menu() { shift; printf '%s' "$*" > "$CAPFILE"; printf '%s\n' "$1"; }
iwz_step() { :; }; iwz_log() { :; }; iwz_ok() { :; }
DECK_RC=1
FAKE_GPU=amd
iwz_is_steam_deck()     { return "$DECK_RC"; }
iwz_detect_gpu_flavor() { printf '%s\n' "$FAKE_GPU"; }
menu_text() { cat "$CAPFILE"; }

# ── Tests ──────────────────────────────────────────────────────────────────

t_hides_absent_variants() {
    pv_list() { printf 'main\ndeck\n'; }
    DECK_RC=1; FAKE_GPU=amd
    iwz_step_gpu >/dev/null 2>&1
    if [[ "$(menu_text)" != *nvidia-open* ]]; then
        ok "a flavor whose variant is not on the stick is not offered"
    else
        bad "a flavor whose variant is not on the stick is not offered" "$(menu_text)"
    fi
}

t_keeps_installable_variants() {
    pv_list() { printf 'main\ndeck\n'; }
    DECK_RC=1; FAKE_GPU=amd
    iwz_step_gpu >/dev/null 2>&1
    local m; m=$(menu_text)
    if [[ "$m" == *deck* && "$m" == *intel* ]]; then
        ok "flavors the stick CAN install are still offered"
    else
        bad "flavors the stick CAN install are still offered" "$m"
    fi
}

t_follows_the_medium() {
    pv_list() { printf 'main\nnvidia-open\n'; }
    DECK_RC=1; FAKE_GPU=amd
    iwz_step_gpu >/dev/null 2>&1
    local m; m=$(menu_text)
    if [[ "$m" == *nvidia-open* && "$m" != *"Steam Deck"* ]]; then
        ok "the offered list follows the medium, not a hardcoded set"
    else
        bad "the offered list follows the medium" "$m"
    fi
}

t_unreadable_medium_offers_everything() {
    pv_list() { return 1; }
    DECK_RC=1; FAKE_GPU=amd
    iwz_step_gpu >/dev/null 2>&1
    local m; m=$(menu_text)
    if [[ "$m" == *nvidia-open* && "$m" == *"Steam Deck"* ]]; then
        ok "no readable medium (dev box) leaves every flavor on offer"
    else
        bad "no readable medium leaves every flavor on offer" "$m"
    fi
}

t_detected_default_leads() {
    pv_list() { printf 'main\ndeck\n'; }
    DECK_RC=0                       # Steam Deck hardware
    iwz_step_gpu >/dev/null 2>&1
    if [[ "$(menu_text)" == deck\ * && "${IWZ_GPU_FLAVOR:-}" == deck ]]; then
        ok "the detected default leads the menu, so a bare Enter picks it"
    else
        bad "the detected default leads the menu" "$(menu_text)"
    fi
}

t_no_duplicate_default() {
    pv_list() { printf 'main\ndeck\n'; }
    DECK_RC=1; FAKE_GPU=amd
    iwz_step_gpu >/dev/null 2>&1
    # The default row already says "(amd)"; what must not also appear is amd's
    # own separate row further down.
    if [[ "$(menu_text)" != *"AMD (Mesa)"* ]]; then
        ok "the detected flavor is not listed a second time"
    else
        bad "the detected flavor is not listed a second time" "$(menu_text)"
    fi
}

t_hides_absent_variants
t_keeps_installable_variants
t_follows_the_medium
t_unreadable_medium_offers_everything
t_detected_default_leads
t_no_duplicate_default

rm -f "$CAPFILE"
echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
