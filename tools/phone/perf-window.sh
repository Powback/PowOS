#!/bin/bash
# The perf measurements in ONE free window: waits (one held call: AWAKE_ONLY=1 idle.sh --wait 120 MAX) for the screen
# on and nobody touching it, home in front, then:
#   1. idle-sample.sh 30 (per-process CPU, WebView frames, gfxinfo)
#   2. cdp.sh raster 10 (busiest renderer/GPU/viz events)
#   3. __glass.live.counts at rest (10 s)
#   4. drawer drags (injected swipes up and down on the drawer's half), 15 s each run, CPU + counts:
#      A: region sends on; B: sends held (__glass.live.hold) - is sending the blur regions per move a real cost?
# Leaves the drawer closed and the sends on. "perf-window.sh [max_wait_s=3600]". Injected input only inside the
# window; stops at once if a finger comes (touch idle drops).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
AWAKE_ONLY=1 "$here/idle.sh" --wait 120 "${1:-3600}" || { echo "perf-window: no free window"; exit 3; }
fg=$("$here/adb.sh" shell "dumpsys activity activities | grep -m1 topResumedActivity")
[[ "$fg" == *HomeShell* ]] || { echo "perf-window: home isn't in front ($fg)"; exit 3; }
echo "== 1. idle sample"; "$here/idle-sample.sh" 30 | grep -vE '^ *"(beginFrames|timers|layouts|styleRecalcs)'
echo "== 2. raster (10 s)"; "$here/cdp.sh" raster 10 | head -25
"$here/cdp.sh" eval home '__glass.live.counts' >/dev/null
sleep 10
echo "== 3. glass at rest (10 s): $("$here/cdp.sh" eval home 'JSON.stringify(__glass.live.counts)')"
# The drawer's half of home (the right; the left half pulls PowOS AI's panel): device px from the page.
read -r W H < <("$here/cdp.sh" eval home 'Math.round(innerWidth*devicePixelRatio)+" "+Math.round(innerHeight*devicePixelRatio)' | tr -d '"')
x=$((W * 3 / 4)) y0=$((H * 85 / 100)) y1=$((H * 30 / 100))
drags() {
  "$here/adb.sh" shell "t=\$((\$(date +%s)+15)); while [ \$(date +%s) -lt \$t ]; do input swipe $x $y0 $x $y1 700; sleep 0.4; input swipe $x $y1 $x $y0 700; sleep 0.4; done" &
  local d=$!
  "$here/cpu.sh" 15 8 | grep -E "com.powos.app|ocessService|surfaceflinger|system_server|total"
  wait $d
}
runs="on held"
[ "$("$here/cdp.sh" eval home 'typeof __glass.live.hold')" = '"function"' ] || { runs=on; echo "   (no __glass.live.hold on the page yet: run B skipped)"; }
for run in $runs; do
  [ $run = held ] && "$here/cdp.sh" eval home '__glass.live.hold(true)' >/dev/null
  s=$("$here/idle.sh"); i=${s#idle=}; i=${i%% *}
  [ "${i:-0}" -ge 120 ] || { echo "perf-window: a finger came - stopped"; break; }
  "$here/cdp.sh" eval home '__glass.live.counts' >/dev/null
  echo "== 4. drawer drags, region sends $run (15 s)"
  drags
  echo "   glass: $("$here/cdp.sh" eval home 'JSON.stringify(__glass.live.counts)')"
done
"$here/cdp.sh" eval home '__glass.live.hold && __glass.live.hold(false)' >/dev/null
echo "== after: $("$here/idle.sh")"
