#!/bin/bash
# test-units-shipped.sh - units the boot menu depends on must reach the image.
#
# systemd/ holds 17 unit files; the Containerfile COPYs a handful. A unit that
# is not COPYed exists only in /usr/lib/powos/src/systemd (the source snapshot)
# and is never installed, so systemd never sees it.
#
# This shipped as a silent, total failure: install-to-usb.sh writes an "Install
# PowOS to disk" boot entry that appends powos.install=1 and boots
# multi-user.target, and powos-installer.service — the unit whose entire job is
# to run the wizard on that karg — was missing. Choosing the entry booted to a
# blank console. The Safe mode / AI Debug entries were dead the same way.
#
# Only units something else actively depends on are REQUIRED here. The rest are
# reported so the gap stays visible rather than being silently forgotten.
#
# Usage:  bash test/tier1/test-units-shipped.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CF="$ROOT/Containerfile"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
bad() { echo -e "${RED}✗${NC} $1"; [[ -n "${2:-}" ]] && echo "    $2"; FAIL=$((FAIL+1)); }

# Units that MUST be installed, and why. Each is depended on by something that
# ships to users: a boot-menu entry, or the guided installer's handoff.
declare -A REQUIRED=(
  [powos-installer.service]="the boot menu's 'Install PowOS to disk' entry (powos.install=1) starts nothing without it"
  [powos-safemode.service]="the 'Recovery — Safe mode' and 'AI Debug' entries (powos.mode=) do nothing without it"
  [powos-firstboot.service]="applies the wizard's hostname/user/password/SSH/ramboot/AI/restore choices"
  [powos-variant-retry.service]="retries a GPU-variant switch that had no network at first boot"
)

echo "== units the shipped boot menu depends on =="
for u in "${!REQUIRED[@]}"; do
  if grep -qF "COPY systemd/$u " "$CF"; then
    if grep -qE "systemctl enable +$u" "$CF"; then
      ok "$u is COPYed and enabled"
    else
      bad "$u is COPYed but never enabled" "${REQUIRED[$u]}"
    fi
  else
    bad "$u is NOT copied into the image" "${REQUIRED[$u]}"
  fi
done

# powos-boot-entries must be gated on the live-medium marker, or it also runs on
# an INSTALLED system and adds installer entries to that machine's boot menu.
if grep -q 'ConditionPathExists=/etc/powos/.live-medium' "$ROOT/systemd/powos-boot-entries.service"; then
    ok "powos-boot-entries only runs on a live medium"
else
    bad "powos-boot-entries is not gated on the live-medium marker" \
        "it would add Install/Recovery entries to an installed system's own menu"
fi

# powos-firstboot CREATES THE USER ACCOUNT. Two properties decide whether a
# freshly installed machine is usable on its first boot:
#
#   * ordered before the greeter — otherwise the login screen can appear with
#     no account on it, which is what a user sees as "the install failed"; and
#   * not waiting on network-online — a fresh Deck has no wifi configured, so
#     pulling that in spent NetworkManager-wait-online's entire timeout before
#     the account was created, with the greeter already on screen.
FB_UNIT="$ROOT/systemd/powos-firstboot.service"
if grep -qE '^Before=.*display-manager\.service' "$FB_UNIT"; then
    ok "powos-firstboot is ordered before the display manager"
else
    bad "powos-firstboot is not ordered before the display manager" \
        "the greeter can come up before the user account exists"
fi
if grep -qE '^(After|Wants|Requires)=.*network-online\.target' "$FB_UNIT"; then
    bad "powos-firstboot waits on network-online.target" \
        "a first boot with no wifi stalls the whole unit before the user is created"
else
    ok "powos-firstboot does not wait on the network to create the user"
fi
if grep -qE '^TimeoutStartSec=' "$FB_UNIT"; then
    ok "powos-firstboot is time-bounded (the greeter is ordered after it)"
else
    bad "powos-firstboot has no TimeoutStartSec" \
        "anything that hangs in it now delays the desktop indefinitely"
fi

echo ""
echo "== units present in systemd/ but not installed (visibility, not a failure) =="
shopt -s nullglob
unshipped=0
for f in "$ROOT"/systemd/*.service "$ROOT"/systemd/*.timer; do
  u=$(basename "$f")
  [[ -n "${REQUIRED[$u]:-}" ]] && continue
  grep -qF "COPY systemd/$u " "$CF" && continue
  echo -e "  ${YELLOW}not installed${NC}: $u"
  unshipped=$((unshipped+1))
done
[[ $unshipped -eq 0 ]] && echo "  (none)"
echo "  $unshipped unit(s) exist in systemd/ but never reach /usr/lib/systemd/system."
echo "  These are NOT asserted: the ramboot/overlay stack may be driven by the"
echo "  dracut module instead. Review before adding — enabling a unit the image"
echo "  is not set up for is how a boot gets broken."

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
