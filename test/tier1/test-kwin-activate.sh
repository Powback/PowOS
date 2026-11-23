#!/bin/bash
# The KWin activation policy (coordinator decision 2026-11-23, docs/AGENT-HANDBOOK.md "KWin activation"):
# tools/phone/verify/kwin-activate-lib.sh kwact_decide - a game running or a user's Linux app open keeps waiting,
# Steam only is closed + restarted around the session restart, nothing open restarts at once; unknowns wait.
# Plus the ship-status record/line and kwin-pending.sh's wiring into ship.sh. Hermetic: no phone.
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
. "$src/tools/phone/verify/kwin-activate-lib.sh"
fails=0
t() { local want=$1 got; shift; got=$(kwact_decide "$@"); got1=${got%% *}
  if [ "$got1" = "$want" ]; then echo "ok   $want <- $*"; else echo "FAIL want $want, got '$got' <- $*"; fails=$((fails + 1)); fi; }

# kwin_new game apps steam
t active        1 none none down
t active        1 1234 "l:kate" up            # already active: nothing to do, whatever runs
t restart       0 none none down              # nothing open
t restart-steam 0 none l:steam up             # Steam only (its window)
t restart-steam 0 none none up                # Steam only, out of sight (resident)
t wait          0 1234 none down              # a game runs: never closed
t wait          0 1234 l:steam up             # a game under Steam
t wait          0 "" none down                # adb didn't say whether a game runs
t wait          0 none "l:steam l:kate" up    # a user's Linux app besides Steam
t wait          0 none "l:dolphin" down       # a user's Linux app
t wait          0 none "ERR no bridge" down   # home's window list didn't answer
t wait          0 none "" down
t wait          0 none none ""                # Steam state unknown
t wait          "" none none down             # KWin state unknown
t wait          - none none down

# Status record -> ship.sh status line.
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
kwact_status "$d/s" pending 6.7.5-3.90
kwact_status_line "$d/s" | grep -qx 'kwin 6.7.5-3.90 installed, active after next idle window' || { echo "FAIL pending line: $(kwact_status_line "$d/s")"; fails=$((fails + 1)); }
kwact_status "$d/s" waiting 6.7.5-3.90 a game runs
kwact_status_line "$d/s" | grep -q 'active after next idle window (last try .*: a game runs)' || { echo "FAIL waiting line: $(kwact_status_line "$d/s")"; fails=$((fails + 1)); }
kwact_status "$d/s" active 6.7.5-3.90
kwact_status_line "$d/s" | grep -q '^kwin 6.7.5-3.90 active (since ' || { echo "FAIL active line: $(kwact_status_line "$d/s")"; fails=$((fails + 1)); }

# Wiring: ship.sh runs kwin-pending.sh after a rooted deploy and shows the record; the check never injects touch.
grep -q 'tools/phone/kwin-pending.sh' "$src/tools/phone/ship.sh" || { echo "FAIL ship.sh doesn't run kwin-pending.sh"; fails=$((fails + 1)); }
grep -q 'kwact_status_line' "$src/tools/phone/ship.sh" || { echo "FAIL ship.sh status doesn't show the kwin record"; fails=$((fails + 1)); }
! grep -qE 'input (tap|swipe)|sendevent' "$src/tools/phone/verify/kwin-activate.sh" || { echo "FAIL kwin-activate.sh injects input"; fails=$((fails + 1)); }
! grep -qE 'pkill|killall|kill -' "$src/tools/phone/verify/kwin-activate.sh" || { echo "FAIL kwin-activate.sh kills processes itself"; fails=$((fails + 1)); }

[ $fails = 0 ] && echo "PASS: kwin activation policy" || { echo "FAIL: $fails"; exit 1; }
