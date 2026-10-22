#!/bin/bash
# tools/phone/verify/edge.sh [home|edge|shade|corner|all]: one idle window's on-device check of the powos-gestures pieces
# (skill: powos-gestures). Waits once with `AWAKE_ONLY=1 tools/phone/idle.sh --wait 120 7200` (never polls), runs only with the screen
# Awake and nobody touching it, never wakes it; read-only apart from the injected swipes and a screenrecord.
#   home   - a pull down on home opens the shade's WINDOW (dumpsys: "PowOS shade" visible); home's page has no
#            .notif-panel (CDP, read-only); then swiped shut.
#   edge   - right edge, lower half: in and up -> Quick Tools ("PowOS quick tools" window shown, PowosEdge log); a tap
#            outside the card shuts it.
#   shade  - over an app (Settings): a pull down from the status bar opens the shade's window; swiped shut.
#   corner - over the app in front: up from the bottom-right corner -> the pull-up panel window (PowosCornerPull).
# Out: $OUT (default ~/powos-rec/edge-<time>/): <check>.mp4 + logcat excerpts. Restores the app that was in front.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); A=$here/adb.sh
what=${1:-all}
OUT=${OUT:-$HOME/powos-rec/edge-$(date +%H%M%S)}; mkdir -p "$OUT"
# One injected-touch test on the phone at a time (the verify lock, as journey.sh / drag-raster.sh; ship-apk waits for it).
L=$HOME/.cache/powos-verify.lock; n=0
until mkdir "$L" 2>/dev/null; do
  [ $n -ge 120 ] && { echo "edge.sh: verify lock busy for an hour: $(cat "$L/who" 2>/dev/null)"; exit 4; }
  [ $n = 0 ] && echo "edge.sh: waiting for $(cat "$L/who" 2>/dev/null || echo another phone test)"
  n=$((n + 1)); sleep 30
done
echo "edge.sh $* $(date +%T) (pid $$)" > "$L/who"; trap 'rm -rf "$L"' EXIT
# One wait, on the phone (one connection), for the screen on and nobody touching it: up to WAIT_S (default 7200).
s=$(AWAKE_ONLY=1 "$here/idle.sh" --wait 120 "${WAIT_S:-7200}") || { echo "no free window: $s"; exit 3; }
case "$s" in *screen=Awake*) ;; *) echo "free but the screen is off ($s): not waking it"; exit 3 ;; esac
focus=$("$A" shell "dumpsys window | grep -m1 mCurrentFocus" | tr -d '\r'); echo "$s; $focus"
case "$focus" in *Lock*|*Keyguard*|*NotificationShade*|*Bouncer*) echo "locked: skip"; exit 3 ;; esac
comp=$(echo "$focus" | sed -n 's/.* \([A-Za-z0-9_.]*\/[A-Za-z0-9_.$]*\)}.*/\1/p')
size=$("$A" shell wm size | tr -d '\r' | sed -n 's/.*: \([0-9]*\)x\([0-9]*\)$/\1 \2/p' | tail -1); W=${size% *}; H=${size#* }
# Recorded as root (the shell user's screenrecord can't write /data/local/tmp or /sdcard here: "Permission denied").
# The windows' state, printed by a check mid-gesture (after its window should have come, before it's put away).
win='dumpsys window windows | grep -E "Window #.*PowOS (shade|quick tools|pull-up panel)" -A20 | grep -E "Window #|mViewVisibility"'
# A finger drawn with motionevents (DOWN, N moves, the window snapshot, UP): drag <x0> <y0> <dx> <dy> per step.
drag() { echo "input motionevent DOWN $1 $2; for i in 1 2 3 4 5 6 7 8 9 10; do input motionevent MOVE \$(($1 + i*$3)) \$(($2 + i*$4)); done; echo '-- while dragged:'; $win; input motionevent UP \$(($1 + 10*$3)) \$(($2 + 10*$4)); sleep 1.2; echo '-- let go:'; $win"; }
run() { # run <name> <phone shell commands>: recorded, with the log tags around it
  "$A" shell "su -c 'rm -f /data/local/tmp/edge.mp4; screenrecord --time-limit 7 /data/local/tmp/edge.mp4 </dev/null >/dev/null 2>&1 &'; sleep 1; logcat -c; $2; sleep 2.5;
    logcat -d -v time | grep -E 'PowosEdge|PowosCornerPull|PowosOverlay|PowosShade|PowosGestures|FATAL' | tail -12" | tee "$OUT/$1.log"
  sleep 4; "$A" shell "su -c 'chmod 644 /data/local/tmp/edge.mp4'"; "$A" pull /data/local/tmp/edge.mp4 "$OUT/" 2>&1 | tail -1; mv "$OUT/edge.mp4" "$OUT/$1.mp4" 2>/dev/null
  "$A" shell "su -c 'rm -f /data/local/tmp/edge.mp4'"
}
if [ "$what" = home ] || [ "$what" = all ]; then
  # Home first, and make sure it is home in front (home is ShellActivity or the desktop's HomeShell).
  "$A" shell input keyevent KEYCODE_HOME; sleep 1.5
  f=$("$A" shell "dumpsys window | grep -m1 mCurrentFocus" | tr -d '\r')
  case "$f" in *ShellActivity*|*HomeShell*) echo "home in front" ;; *) echo "home isn't in front ($f): the home check is skipped"; skip_home=1 ;; esac
  [ -z "${skip_home:-}" ] && run home "$(drag $((W/2)) $((H*30/100)) 1 $((H*4/100))); sleep 1; input swipe $((W/2)) $((H*80/100)) $((W/2)) $((H*15/100)) 250"
  # A short pull (~3% of the height, ~70 px): the shade's travel is the page's --drop (15vh) at gain 1.5 - it opens.
  [ -z "${skip_home:-}" ] && sleep 1.5 && run home-short "$(drag $((W/2)) $((H*30/100)) 0 $((H*3/1000))); sleep 1; input swipe $((W/2)) $((H*80/100)) $((W/2)) $((H*15/100)) 250"
  echo "home page: $("$here/cdp.sh" eval "" "JSON.stringify({notifPanel: document.querySelectorAll('.notif-panel').length})")"
fi
if [ "$what" = edge ] || [ "$what" = all ]; then
  run edge "$(drag $((W-3)) $((H*75/100)) -$((W*3/100)) -$((H*13/1000))); sleep 1; input tap $((W/5)) $((H*20/100)); sleep 1; echo '-- tapped outside:'; $win"
fi
if [ "$what" = shade ] || [ "$what" = all ]; then
  "$A" shell am start -n com.android.settings/.Settings >/dev/null 2>&1; sleep 2
  run shade "$(drag $((W/4)) 6 0 $((H*2/100))); sleep 1; input swipe $((W/2)) $((H*80/100)) $((W/2)) $((H*15/100)) 250"
fi
if [ "$what" = corner ] || [ "$what" = all ]; then
  # Over an app: the app that was in front, else Android's Settings.
  case "$focus" in *ShellActivity*|*HomeShell*|"") app=com.android.settings/.Settings ;; *) app=$comp ;; esac
  "$A" shell am start -n "$app" >/dev/null 2>&1; sleep 2
  run corner "$(drag $((W*92/100)) $((H-8)) -1 -$((H*5/100))); sleep 1; input keyevent KEYCODE_BACK"
fi
case "$focus" in *ShellActivity*|*HomeShell*) ;; *) [ -n "$comp" ] && "$A" shell am start -n "$comp" >/dev/null 2>&1 ;; esac
echo "out: $OUT (frame-step: ffmpeg -i $OUT/home.mp4 -vf scale=170:-1 -fps_mode passthrough $OUT/f%03d.png)"
