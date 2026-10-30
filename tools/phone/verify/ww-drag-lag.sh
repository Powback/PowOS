#!/bin/bash
# Web windows: how far a window's content trails its title bar during a move (docs/WEB_WINDOWS.md "Native frame and
# move"). Needs one web window open on the page on screen (powos_web_windows=1, unfolded).
#
#   tools/phone/verify/ww-drag-lag.sh            read-only: the layer tree + the last moves' log lines (run after the
#                                                user dragged a window, or after --drag)
#   tools/phone/verify/ww-drag-lag.sh --drag     waits until the phone is idle 2+ min (idle.sh --wait), then injects one
#                                                title-bar drag of the top window (input swipe, 600 ms) and reports
#
# What it reports:
#   structure  the window's bar ("powos-ww-<id>-bar") and its content (the display's mirror) are children of ONE
#              container layer "powos-ww-<id>": a move is that container's setPosition, so bar and content land in the
#              same SurfaceFlinger transaction - lag 0 frames by construction. FAIL if the bar is anything else.
#   cadence    "native move wN: M layer moves in T ms": M / (T / frame) ~ 1 = one transaction per input frame (as
#              Android's freeform drag). The page-driven path's "w.f ... behind=K" lines (page swipes) give K: how many
#              page frames newer the DOM was when that geometry was bound - the old drag's lag.
here=$(cd "$(dirname "$0")/.." && pwd)
adb="$here/adb.sh"

if [ "$1" = --drag ]; then
  "$here/idle.sh" --wait 120 1800 >/dev/null || { echo "phone busy (not idle 2 min within 30 min): not injecting"; exit 1; }
  read -r screen < <("$here/idle.sh")
  case "$screen" in *screen=Awake*) ;; *) echo "screen not on ($screen): not injecting"; exit 1 ;; esac
  # The top window's body from the last placing log line ("w.f fN behind=K (...) <id>@[l,t][r,b] zZ shown, ...").
  line=$("$adb" shell 'logcat -d -s PowosWebWindows:I' | grep ' w.f f' | tail -1)
  rect=$(echo "$line" | grep -oE '[0-9]+@\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\] z[0-9]+ shown' | sort -t z -k2 -n | tail -1)
  [ -n "$rect" ] || { echo "no shown web window in the log: open one first"; exit 1; }
  read -r l t r < <(echo "$rect" | sed -E 's/.*@\[([0-9]+),([0-9]+)\]\[([0-9]+),.*/\1 \2 \3/')
  dpi=$("$adb" shell wm density | grep -oE '[0-9]+' | tail -1)
  bar=$(( t - 18 * dpi / 160 ))   # the bar's middle: 18 dp above the body's top
  x=$(( l + (r - l) / 3 ))
  echo "drag: bar at $x,$bar -> $((x + 300)),$((bar + 200)) (600 ms)"
  "$adb" shell "input swipe $x $bar $((x + 300)) $((bar + 200)) 600"
  sleep 1
fi

echo "== structure (SurfaceFlinger layer tree) =="
"$adb" shell 'dumpsys SurfaceFlinger' | grep -E "powos-webwindows|powos-ww-|mirror" | head -20
echo "== cadence (last moves) =="
"$adb" shell 'logcat -d -s PowosWebWindows:I' | grep -E 'native (move|resize)|behind=' | tail -8
refresh=$("$adb" shell 'dumpsys SurfaceFlinger' | grep -oE 'refresh-rate *: *[0-9.]+' | head -1 | grep -oE '[0-9.]+$')
"$adb" shell 'logcat -d -s PowosWebWindows:I' | grep -E 'native (move|resize)' | tail -1 |
  awk -v hz="${refresh:-120}" '{ for (i = 1; i <= NF; i++) { if ($i == "layer") m = $(i - 1); if ($i == "ms") t = $(i - 1) }
    if (t > 0) printf "moves per frame at %s Hz: %.2f (1.0 = every input frame)\n", hz, m / (t * hz / 1000) }'
