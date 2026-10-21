#!/bin/bash
# tools/phone/verify/edge.sh [home|edge|corner|all]: one idle window's on-device check of the powos-gestures pieces
# (skill: powos-gestures). Waits with `tools/phone/idle.sh --wait 120 1800` (never polls), runs only with the screen
# Awake and nobody touching it, never wakes it; read-only apart from the injected swipes and a screenrecord.
#   home   - a pull down on home opens the shade's WINDOW (dumpsys: "PowOS shade" visible); home's page has no
#            .notif-panel (CDP, read-only); then swiped shut.
#   edge   - right edge, lower half: in and up -> Quick Tools ("PowOS quick tools" window shown, PowosEdge log); a tap
#            outside the card shuts it.
#   corner - over the app in front: up from the bottom-right corner -> the pull-up panel window (PowosCornerPull).
# Out: $OUT (default ~/powos-rec/edge-<time>/): <check>.mp4 + logcat excerpts. Restores the app that was in front.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); A=$here/adb.sh
what=${1:-all}
OUT=${OUT:-$HOME/powos-rec/edge-$(date +%H%M%S)}; mkdir -p "$OUT"
s=$("$here/idle.sh" --wait 120 1800) || { echo "no free window: $s"; exit 3; }
case "$s" in *screen=Awake*) ;; *) echo "free but the screen is off ($s): not waking it"; exit 3 ;; esac
focus=$("$A" shell "dumpsys window | grep -m1 mCurrentFocus" | tr -d '\r'); echo "$s; $focus"
case "$focus" in *Lock*|*Keyguard*|*NotificationShade*|*Bouncer*) echo "locked: skip"; exit 3 ;; esac
comp=$(echo "$focus" | sed -n 's/.* \([A-Za-z0-9_.]*\/[A-Za-z0-9_.$]*\)}.*/\1/p')
size=$("$A" shell wm size | tr -d '\r' | sed -n 's/.*: \([0-9]*\)x\([0-9]*\)$/\1 \2/p' | tail -1); W=${size% *}; H=${size#* }
run() { # run <name> <phone shell commands>: recorded, with the log tags around it
  "$A" shell "rm -f /data/local/tmp/edge.mp4; (screenrecord --time-limit 7 /data/local/tmp/edge.mp4 &); sleep 1; logcat -c; $2; sleep 2.5;
    dumpsys window windows | grep -E 'Window #.*PowOS (shade|quick tools|pull-up panel)' -A14 | grep -E 'Window #|isOnScreen=|mViewVisibility' ;
    logcat -d -v time | grep -E 'PowosEdge|PowosCornerPull|PowosOverlay|PowosShade|PowosGestures|FATAL' | tail -12" | tee "$OUT/$1.log"
  sleep 4; "$A" pull /data/local/tmp/edge.mp4 "$OUT/$1.mp4" >/dev/null 2>&1; "$A" shell rm -f /data/local/tmp/edge.mp4
}
if [ "$what" = home ] || [ "$what" = all ]; then
  "$A" shell input keyevent KEYCODE_HOME; sleep 1.5
  run home "input swipe $((W/2)) $((H*30/100)) $((W/2+5)) $((H*70/100)) 450; sleep 1.5; input swipe $((W/2)) $((H*80/100)) $((W/2)) $((H*15/100)) 250"
  echo "home page: $("$here/cdp.sh" eval "" "JSON.stringify({notifPanel: document.querySelectorAll('.notif-panel').length})")"
fi
if [ "$what" = edge ] || [ "$what" = all ]; then
  run edge "input swipe $((W-3)) $((H*75/100)) $((W*70/100)) $((H*62/100)) 220; sleep 1.5; input tap $((W/5)) $((H*20/100))"
fi
if [ "$what" = corner ] || [ "$what" = all ]; then
  [ -n "$comp" ] && "$A" shell am start -n "$comp" >/dev/null 2>&1; sleep 1.5
  run corner "input swipe $((W*92/100)) $((H-8)) $((W*90/100)) $((H*45/100)) 400; sleep 1.5; input keyevent KEYCODE_BACK"
fi
case "$focus" in *ShellActivity*) ;; *) [ -n "$comp" ] && "$A" shell am start -n "$comp" >/dev/null 2>&1 ;; esac
echo "out: $OUT (frame-step: ffmpeg -i $OUT/home.mp4 -vf scale=170:-1 -fps_mode passthrough $OUT/f%03d.png)"
