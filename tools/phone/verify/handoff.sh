#!/bin/bash
# lanes: phone
# handoff.sh (board: continue-a-page-or-app-on-another-device; docs/DEVICES.md "Handoff"): the receiving side of
# "Continue on..." with no touch input. The other signed-in device is drops-peer.py on the Mac (as drops.sh): it hands
# the phone a page (a sealed drop, item type "handoff"); DropInbox (polls every 15 s while the screen is on) must take it
# and post "Continue <title>" with a Continue action - not save it as a file. The notification is left for the owner to
# see (tapping it opens the page in a PowOS web window); the sending side is the switcher card / tile menu (UI, unchecked).
# Exit 0 PASS, 1 FAIL, 2 not judged (SKIP: no phone/root, not joined, no test peer, screen off).
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1
T=tools/phone
PKG=com.powos.app
N=$(date +%s)$RANDOM
peer() { uv run -q --no-project --with cryptography python3 tools/phone/verify/drops-peer.py "$@"; }
adb() { "$T/adb.sh" shell "$@"; }
skip() { echo "SKIP: handoff: $1"; exit 2; }

adb true >/dev/null 2>&1 || skip "phone not reachable"
pid=$(adb "su -c 'cat /data/data/$PKG/files/devices/enrollment.json'" 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["device"]["id"])' 2>/dev/null)
[ -n "$pid" ] || skip "the PowOS app hasn't joined a PowStation here (or no root to read it)"
[ -s "${DROPS_PEER_DIR:-$HOME/.local/state/powos/verify-drops-peer}/enrollment.json" ] ||
    skip "no test peer yet: the owner runs tools/phone/verify/drops-peer.py enroll on the Mac and approves its code"
adb "dumpsys power" 2>/dev/null | awk '/mWakefulness=Awake/{f=1} END{exit !f}' || skip "the phone's screen is off, so DropInbox doesn't poll"

title="Verify handoff $N"
sid=$(peer handoff "$pid" "https://powos.pow/verify-handoff-$N" "$title" 2>&1) || { echo "FAIL handoff: the peer couldn't hand off ($sid)"; exit 1; }
st=waiting; for _ in $(seq 1 12); do sleep 4; st=$(peer state "$sid" 2>&1); [ "$st" = gone ] && break; done
notif=$(adb "dumpsys notification --noredact" 2>/dev/null | grep -c "Continue $title")
saved=$(adb "su -c 'ls /data/data/$PKG/cache/share/drops/$sid 2>/dev/null'" 2>/dev/null)
echo "realm: $st, notification lines: $notif, saved: '${saved}'"
[ "$st" = gone ] || { peer "done" "$sid" >/dev/null 2>&1; echo "FAIL handoff: the phone didn't take the handoff in 48 s"; exit 1; }
[ -z "$saved" ] || { echo "FAIL handoff: the handoff was saved as a file (an older DropInbox?)"; exit 1; }
[ "$notif" -gt 0 ] || { echo "FAIL handoff: no 'Continue $title' notification"; exit 1; }
echo "PASS handoff: the peer's page arrived as 'Continue $title' (from PowOS verify), nothing saved"
