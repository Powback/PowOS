#!/bin/bash
# lanes: phone
# tools/phone/verify/fold.sh: the powos-gestures pieces on the other screen of the foldable (skill: powos-gestures) -
# the device state forced (cmd device_state: 3 OPENED = the inner screen, 0 CLOSED = the cover) for one run of
# verify/edge.sh there (home pull, edge -> Quick Tools, shade over an app, corner pull), plus where the edge handles'
# windows sit after the switch. In one free window, the verify lock taken only then; the forced state is always reset at the end
# (cmd device_state state reset) - the phone follows its real hinge again.
#   tools/phone/verify/fold.sh [opened|closed]   (default: the state it isn't in)
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); A=$here/adb.sh
OUT=${OUT:-$HOME/powos-rec/fold-$(date +%H%M%S)}; mkdir -p "$OUT"
# A free window first, the verify lock only then (handbook 5a); the device state reset runs before the lock goes.
WL_TRAP='"$A" shell cmd device_state state reset >/dev/null 2>&1; echo "device state reset: $("$A" shell cmd device_state print-state | tr -d "\r")"'
. "$(dirname "$0")/window-lock.sh"
window_lock fold.sh 120
now=$("$A" shell cmd device_state print-state | tr -d '\r')
case "${1:-}" in opened) to=3 ;; closed) to=0 ;; *) [ "$now" = 3 ] && to=0 || to=3 ;; esac
echo "device state $now -> $to"
"$A" shell cmd device_state state $to; sleep 4
"$A" shell "dumpsys window displays | grep -m1 -o 'cur=[0-9]*x[0-9]*'; dumpsys window windows | grep -E 'Window #.*PowOS edge handle' -A30 | grep -E 'Window #|mFrame=|mViewVisibility'" | tee "$OUT/handles.txt"
"$A" shell "screencap -p /data/local/tmp/fold-home.png"; "$A" pull /data/local/tmp/fold-home.png "$OUT/" >/dev/null 2>&1; "$A" shell rm -f /data/local/tmp/fold-home.png
LOCK_HELD=1 WAIT_S=600 OUT="$OUT" "$(dirname "$0")/edge.sh" all
