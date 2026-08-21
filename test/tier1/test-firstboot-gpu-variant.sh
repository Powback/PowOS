#!/bin/bash
# test-firstboot-gpu-variant.sh - Tier-1 tests for automatic GPU-variant selection.
#
# The install media is ONE image that boots anywhere, so the installed machine
# can be running the wrong variant for its hardware. The wizard detects the GPU
# and records POWOS_GPU_FLAVOR; firstboot maps that onto a published image tag
# and `bootc switch`es to it.
#
# Until 2026-08-21 POWOS_GPU_FLAVOR was written to install.conf and read by
# NOTHING, so every install silently stayed on whatever variant the USB had.
# These tests pin the mapping and the switch behaviour.
#
# No root, no bootc, no real hardware: bootc/rpm-ostree/DMI are all shadowed.
#
# Usage:  bash test/tier1/test-firstboot-gpu-variant.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FB="$(cd "$HERE/../../bin" && pwd)/powos-firstboot-apply"
[[ -f "$FB" ]] || FB="/usr/bin/powos-firstboot-apply"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && echo "         $2"; }

# Source the script without running main: it only calls fb_main when executed.
# shellcheck source=/dev/null
source "$FB" 2>/dev/null || { echo "cannot source $FB"; exit 1; }

# ── Shadows ────────────────────────────────────────────────────────────────
IS_DECK=1              # 1 = not a deck (shell truth), 0 = deck
CURRENT_REF=""
SWITCH_CALLED=""
SWITCH_RC=0

fb_is_steam_deck()     { return $IS_DECK; }
fb_current_image_ref() { printf '%s\n' "$CURRENT_REF"; }
bootc() {
    if [[ "${1:-}" == "switch" ]]; then SWITCH_CALLED="${2:-}"; return $SWITCH_RC; fi
    return 0
}

reset_state() { SWITCH_CALLED=""; SWITCH_RC=0; IS_DECK=1; CURRENT_REF="ghcr.io/powback/powos:main"; }

# ── Mapping ────────────────────────────────────────────────────────────────

t_map() {
    local flavor="$1" want="$2" deck="${3:-1}" got
    IS_DECK="$deck"
    got=$(fb_variant_for_flavor "$flavor")
    if [[ "$got" == "$want" ]]; then
        ok "flavor '$flavor'$([[ $deck == 0 ]] && echo ' on Deck hardware') → '$want'"
    else
        bad "flavor '$flavor' → '$want'" "got '$got'"
    fi
}

echo "== flavor → published image tag =="
reset_state
t_map nvidia-open nvidia-open
t_map nvidia      nvidia-open
t_map amd         main
t_map intel       main
t_map main        main
t_map deck        deck
t_map ""          main
t_map "garbage"   main
# Deck hardware overrides whatever the GPU probe said.
t_map amd         deck 0
t_map nvidia-open deck 0

# ── Switch behaviour ───────────────────────────────────────────────────────

echo ""
echo "== bootc switch behaviour =="

reset_state
POWOS_GPU_FLAVOR="nvidia-open"
CURRENT_REF="ghcr.io/powback/powos:main"
fb_apply_gpu_flavor >/dev/null 2>&1
if [[ "$SWITCH_CALLED" == "ghcr.io/powback/powos:nvidia-open" ]]; then
    ok "wrong variant → switches to the right tag on the same repo"
else
    bad "wrong variant → switches to the right tag" "switch called with '$SWITCH_CALLED'"
fi

reset_state
POWOS_GPU_FLAVOR="amd"
CURRENT_REF="ghcr.io/powback/powos:main"
fb_apply_gpu_flavor >/dev/null 2>&1
if [[ -z "$SWITCH_CALLED" ]]; then
    ok "already on the right variant → no switch (idempotent)"
else
    bad "already on the right variant → no switch" "switch called with '$SWITCH_CALLED'"
fi

reset_state
POWOS_GPU_FLAVOR=""
fb_apply_gpu_flavor >/dev/null 2>&1
if [[ -z "$SWITCH_CALLED" ]]; then
    ok "no flavor recorded → leaves the image alone"
else
    bad "no flavor recorded → leaves the image alone" "switch called with '$SWITCH_CALLED'"
fi

reset_state
POWOS_GPU_FLAVOR="nvidia-open"
CURRENT_REF=""     # bootc/rpm-ostree unreadable
fb_apply_gpu_flavor >/dev/null 2>&1
if [[ -z "$SWITCH_CALLED" ]]; then
    ok "unreadable image ref → does not guess, does not switch"
else
    bad "unreadable image ref → does not switch" "switch called with '$SWITCH_CALLED'"
fi

reset_state
POWOS_GPU_FLAVOR="nvidia-open"
CURRENT_REF="/some/local/oci-archive"   # not a registry ref
fb_apply_gpu_flavor >/dev/null 2>&1
if [[ -z "$SWITCH_CALLED" ]]; then
    ok "non-registry image ref → does not switch"
else
    bad "non-registry image ref → does not switch" "switch called with '$SWITCH_CALLED'"
fi

# A failing switch must NEVER fail the step — firstboot must always reach its
# cleanup, or the config (holding a password hash) is left on disk.
reset_state
POWOS_GPU_FLAVOR="nvidia-open"
CURRENT_REF="ghcr.io/powback/powos:main"
SWITCH_RC=1
rc=0
fb_apply_gpu_flavor >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 0 ]]; then
    ok "a failed bootc switch is non-fatal (firstboot still completes)"
else
    bad "a failed bootc switch is non-fatal" "returned $rc"
fi

# The repo must be preserved — a fork or private mirror must not be rewritten
# to ghcr.io/powback.
reset_state
POWOS_GPU_FLAVOR="nvidia-open"
CURRENT_REF="registry.example.com/team/powos:main"
fb_apply_gpu_flavor >/dev/null 2>&1
if [[ "$SWITCH_CALLED" == "registry.example.com/team/powos:nvidia-open" ]]; then
    ok "switch stays on the SAME repo (forks/mirrors are not rewritten)"
else
    bad "switch stays on the same repo" "switch called with '$SWITCH_CALLED'"
fi

# Digest-pinned refs: strip the digest, not just the tag.
reset_state
POWOS_GPU_FLAVOR="nvidia-open"
CURRENT_REF="ghcr.io/powback/powos@sha256:abc123"
fb_apply_gpu_flavor >/dev/null 2>&1
if [[ "$SWITCH_CALLED" == "ghcr.io/powback/powos:nvidia-open" || -z "$SWITCH_CALLED" ]]; then
    ok "digest-pinned ref handled without producing a malformed target"
else
    bad "digest-pinned ref handled" "switch called with '$SWITCH_CALLED'"
fi

echo ""
echo "== offline behaviour (no network at first boot) =="

TMPD=$(mktemp -d)
POWOS_PENDING_VARIANT="$TMPD/pending-variant"

# Matching variant + no network = no switch attempted at all. This is the
# guarantee that flashing the right image installs FULLY OFFLINE.
reset_state
POWOS_GPU_FLAVOR="deck"; IS_DECK=0
CURRENT_REF="ghcr.io/powback/powos:deck"
SWITCH_RC=1     # pretend the registry is unreachable
fb_apply_gpu_flavor >/dev/null 2>&1
if [[ -z "$SWITCH_CALLED" && ! -f "$POWOS_PENDING_VARIANT" ]]; then
    ok "right image flashed → no switch, no network, no pending marker"
else
    bad "right image flashed → no switch at all" "switch='$SWITCH_CALLED' marker=$([[ -f $POWOS_PENDING_VARIANT ]] && echo yes || echo no)"
fi

# Wrong variant + offline: must record the intent, because install.conf is
# deleted straight after and the answer would otherwise be lost forever.
reset_state
rm -f "$POWOS_PENDING_VARIANT"
POWOS_GPU_FLAVOR="nvidia-open"
CURRENT_REF="ghcr.io/powback/powos:main"
SWITCH_RC=1
fb_apply_gpu_flavor >/dev/null 2>&1
if [[ "$(cat "$POWOS_PENDING_VARIANT" 2>/dev/null)" == "ghcr.io/powback/powos:nvidia-open" ]]; then
    ok "offline switch failure records the target for retry"
else
    bad "offline switch failure records the target" "marker='$(cat "$POWOS_PENDING_VARIANT" 2>/dev/null)'"
fi

# The retry succeeds later and clears the marker (self-disabling unit).
reset_state
printf 'ghcr.io/powback/powos:nvidia-open\n' > "$POWOS_PENDING_VARIANT"
SWITCH_RC=0
fb_retry_variant >/dev/null 2>&1
if [[ "$SWITCH_CALLED" == "ghcr.io/powback/powos:nvidia-open" && ! -f "$POWOS_PENDING_VARIANT" ]]; then
    ok "retry switches and removes the marker on success"
else
    bad "retry switches and clears the marker" "switch='$SWITCH_CALLED' marker still $([[ -f $POWOS_PENDING_VARIANT ]] && echo present || echo gone)"
fi

# Still offline on the retry → marker must survive for the boot after that.
reset_state
printf 'ghcr.io/powback/powos:nvidia-open\n' > "$POWOS_PENDING_VARIANT"
SWITCH_RC=1
fb_retry_variant >/dev/null 2>&1
if [[ -f "$POWOS_PENDING_VARIANT" ]]; then
    ok "retry that fails again keeps the marker for a later boot"
else
    bad "retry that fails again keeps the marker" "marker was removed"
fi

reset_state
rm -f "$POWOS_PENDING_VARIANT"
fb_retry_variant >/dev/null 2>&1
if [[ -z "$SWITCH_CALLED" ]]; then
    ok "retry with no marker is a clean no-op"
else
    bad "retry with no marker is a no-op" "switch called with '$SWITCH_CALLED'"
fi

reset_state
printf 'not-a-ref\n' > "$POWOS_PENDING_VARIANT"
fb_retry_variant >/dev/null 2>&1
if [[ -z "$SWITCH_CALLED" && ! -f "$POWOS_PENDING_VARIANT" ]]; then
    ok "malformed marker is discarded, not retried forever"
else
    bad "malformed marker is discarded" "switch='$SWITCH_CALLED'"
fi

rm -rf "$TMPD"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
