#!/usr/bin/env bash
# Sleep policy must not contradict itself.
#
# PowOS ships PowerButtonAction=1 (suspend-to-RAM) so a Deck's power button
# behaves like stock SteamOS. It ALSO masked every sleep target, for infra
# boxes where a suspend kills Traefik and container workloads. Both shipped in
# the same image, so PowerDevil asked logind to suspend, logind started a
# masked target, the request failed, and each attempt tore down and
# re-initialised the display — the moment amdgpu logs
#
#     [drm] Failed to add display topology, DTM TA is not initialized.
#
# The screen blanked and returned over and over and the machine looked wedged.
# The DTM line is benign in itself; it fires on every GPU resume and connector
# re-probe, which is why it is a good MARKER for a display re-init loop and a
# bad thing to dismiss as noise.
set -uo pipefail
PASS=0; FAIL=0
check() { if ( eval "$2" ) >/dev/null 2>&1; then echo "  ok   - $1"; PASS=$((PASS+1));
          else echo "  FAIL - $1"; FAIL=$((FAIL+1)); fi }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
CF="$ROOT/Containerfile"
PD="$ROOT/config/skel/.config/powerdevilrc"

echo "== sleep policy is coherent per variant =="
check "the power button is configured to suspend"        'grep -q "^PowerButtonAction=1" "$PD"'
check "sleep targets are masked for NON-deck variants"   'grep -q "ln -sf /dev/null /etc/systemd/system/sleep.target" "$CF"'
check "and UNMASKED for the deck variant"                'grep -q "rm -f /etc/systemd/system/sleep.target" "$CF"'
check "the deck also drops the logind no-suspend file" \
      'grep -q "rm -f /etc/systemd/logind.conf.d/50-powos-no-suspend.conf" "$CF"'
check "non-deck neutralises PowerButtonAction so nothing asks for a masked suspend" \
      'grep -q "PowerButtonAction=1/PowerButtonAction=0" "$CF"'
check "the decision is keyed on the variant, not the host" \
      'grep -q "os-release" "$CF" && grep -q "\*deck\*" "$CF"'

# The invariant: on ANY variant, "may suspend" and "is asked to suspend" agree.
check "no variant both masks sleep AND asks PowerDevil to suspend" \
      'awk "/sleep: ALLOWED/{a=1} /sleep: BLOCKED/{b=1} END{exit !(a&&b)}" "$CF"'

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
