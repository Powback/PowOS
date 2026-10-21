#!/bin/bash
# What a drawer drag costs to DRAW on the phone, in ONE free window: injected swipes up and down on the drawer's half
# (as tools/phone/perf-window.sh's drag section) while cdp.sh raster traces the WebView and cpu.sh samples the
# processes - for the shell as it is, then for each variant: a CSS snippet added to the home page as a <style> for
# that run only (removed at once after it). Leaves the drawer closed.
#   shell/dev/perf/drag-raster.sh [secs=12] ["label=css" ...]
#   TRACE=1: trace.ts instead of cdp.sh raster - Paint by DOM node, raster/decode tasks.
#   e.g. drag-raster.sh 12 "cv=.drawer-list .app{content-visibility:auto}" "nohome=.home-content{display:none}"
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
phone=$(cd "$here/../../../tools/phone" && pwd)
secs=${1:-12}
shift || true
AWAKE_ONLY=1 "$phone/idle.sh" --wait 120 1800 || { echo "drag-raster: no free window"; exit 3; }
fg=$("$phone/adb.sh" shell "dumpsys activity activities | grep -m1 topResumedActivity")
[[ "$fg" == *HomeShell* ]] || { echo "drag-raster: home isn't in front ($fg)"; exit 3; }
read -r W H < <("$phone/cdp.sh" eval home 'Math.round(innerWidth*devicePixelRatio)+" "+Math.round(innerHeight*devicePixelRatio)' | tr -d '"')
x=$((W * 3 / 4)) y0=$((H * 85 / 100)) y1=$((H * 30 / 100))
run() {
  local label=$1 css=$2
  s=$("$phone/idle.sh"); i=${s#idle=}; i=${i%% *}
  [ "${i:-0}" -ge 120 ] || { echo "drag-raster: a finger came - stopped"; exit 4; }
  [ -n "$css" ] && "$phone/cdp.sh" eval home "(() => { const s = document.createElement('style'); s.id = 'drag-raster'; s.textContent = $(printf '%s' "$css" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'); document.head.append(s); return 1; })()" >/dev/null
  echo "== $label${css:+ ($css)}"
  # SWIPES=updown (default, as perf-window.sh): up then down on the drawer; =up: up, then Back closes it (no finger
  # coming down - tells a cost of the down swipe, e.g. the shade's pull, from the drawer's own).
  local close="input swipe $x $y1 $x $y0 700"
  [ "${SWIPES:-updown}" = up ] && close="input keyevent 4"
  "$phone/adb.sh" shell "t=\$((\$(date +%s)+$secs)); while [ \$(date +%s) -lt \$t ]; do input swipe $x $y0 $x $y1 700; sleep 0.4; $close; sleep 0.4; done" &
  local d=$!
  if [ "${TRACE:-0}" = 1 ]; then
    docker run --rm -i --network container:powos-vadb -v "$here:/t:ro" oven/bun:1 bun /t/trace.ts $((secs - 2)) &
  else
    "$phone/cdp.sh" raster $((secs - 2)) | head -16 &
  fi
  local r=$!
  "$phone/cpu.sh" $((secs - 2)) 8 | grep -E "com.powos.app|ocessService|surfaceflinger|total"
  wait $r $d
  "$phone/cdp.sh" eval home "document.getElementById('drag-raster')?.remove(), 1" >/dev/null
  sleep 1
}
run base ""
for v in "$@"; do run "${v%%=*}" "${v#*=}"; done
echo "== after: $("$phone/idle.sh")"
