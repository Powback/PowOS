#!/bin/bash
# What a drawer drag costs to DRAW on the phone, in ONE free window: injected swipes up and down on the drawer's half
# (as tools/phone/perf-window.sh's drag section) while cdp.sh raster traces the WebView and cpu.sh samples the
# processes - for the shell as it is, then for each variant: a CSS snippet added to the home page as a <style> for
# that run only (removed at once after it). Leaves the drawer closed.
#   shell/dev/perf/drag-raster.sh [secs=12] ["label=css" ...]
#   PROFILE=1: the home page JS CPU profile (cdp.sh profile: ms/s per function) instead of cdp.sh raster.
#   TRACE=1: trace.ts instead of cdp.sh raster - Paint by DOM node, raster/decode tasks.
#   "label=js:ON|OFF": a page setting instead of CSS (ON evaluated for the run, OFF after), e.g.
#     "measured=js:__glass.live.compute(false)|__glass.live.compute(true)"
#   e.g. drag-raster.sh 12 "cv=.drawer-list .app{content-visibility:auto}" "nohome=.home-content{display:none}"
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
phone=$(cd "$here/../../../tools/phone" && pwd)
secs=${1:-12}
shift || true
# One injected-touch test on the phone at a time (journey.sh's lock; ship-apk.sh won't install over it): agents
# measuring in parallel would swipe into each other's runs. Waited for here on the Mac - nothing reaches the phone.
L=$HOME/.cache/powos-verify.lock; n=0
until mkdir "$L" 2>/dev/null; do
  [ $n -ge 120 ] && { echo "drag-raster: verify lock busy for an hour: $(cat "$L/who" 2>/dev/null)"; exit 4; }
  [ $n = 0 ] && echo "drag-raster: waiting for $(cat "$L/who" 2>/dev/null || echo another phone test)"
  n=$((n + 1)); sleep 30
done
echo "drag-raster $* $(date +%T) (pid $$)" > "$L/who"; trap 'rm -rf "$L"' EXIT
AWAKE_ONLY=1 "$phone/idle.sh" --wait 120 1800 || { echo "drag-raster: no free window"; exit 3; }
fg=$("$phone/adb.sh" shell "dumpsys activity activities | grep -m1 topResumedActivity")
[[ "$fg" == *HomeShell* ]] || { echo "drag-raster: home isn't in front ($fg)"; exit 3; }
# Only on a home the swipes can open the drawer on: not in edit mode, nothing over it, the drawer closed - else the
# numbers are of something else (2026-10-22: two runs on an edit-mode home measured no drag at all).
state=$("$phone/cdp.sh" eval home '(() => { const h = document.querySelector(".home"); return h.classList.contains("editing") ? "home is in edit mode" : h.classList.contains("open") ? "the drawer is open" : document.querySelector(".menu, .sheet:not(.pop)") ? "a menu or sheet is open" : "ok"; })()' | tr -d '"')
[ "$state" = ok ] || { echo "drag-raster: $state - not measured (the user's state; nothing changed)"; exit 3; }
read -r W H < <("$phone/cdp.sh" eval home 'Math.round(innerWidth*devicePixelRatio)+" "+Math.round(innerHeight*devicePixelRatio)' | tr -d '"')
x=$((W * 3 / 4)) y0=$((H * 85 / 100)) y1=$((H * 30 / 100))
run() {
  local label=$1 css=$2
  s=$("$phone/idle.sh"); i=${s#idle=}; i=${i%% *}
  [ "${i:-0}" -ge 120 ] || { echo "drag-raster: a finger came - stopped"; exit 4; }
  # "label=js:ON|OFF": a variant that's a page setting instead of CSS - ON evaluated for the run, OFF right after.
  local off=""
  if [[ "$css" == js:* ]]; then
    local js=${css#js:}
    off=${js#*|}
    "$phone/cdp.sh" eval home "${js%%|*}" >/dev/null
    css=""
  fi
  [ -n "$css" ] && "$phone/cdp.sh" eval home "(() => { const s = document.createElement('style'); s.id = 'drag-raster'; s.textContent = $(printf '%s' "$css" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'); document.head.append(s); return 1; })()" >/dev/null
  echo "== $label${css:+ ($css)}"
  # SWIPES=updown (default, as perf-window.sh): up then down on the drawer; =up: up, then Back closes it (no finger
  # coming down - tells a cost of the down swipe, e.g. the shade's pull, from the drawer's own).
  local close="input swipe $x $y1 $x $y0 700"
  [ "${SWIPES:-updown}" = up ] && close="input keyevent 4"
  "$phone/adb.sh" shell "t=\$((\$(date +%s)+$secs)); while [ \$(date +%s) -lt \$t ]; do input swipe $x $y0 $x $y1 700; sleep 0.4; $close; sleep 0.4; done" &
  local d=$!
  if [ "${PROFILE:-0}" = 1 ]; then
    "$phone/cdp.sh" profile $((secs - 2)) home &
  elif [ "${TRACE:-0}" = 1 ]; then
    docker run --rm -i --network container:powos-vadb -v "$here:/t:ro" oven/bun:1 bun /t/trace.ts $((secs - 2)) &
  else
    "$phone/cdp.sh" raster $((secs - 2)) | head -16 &
  fi
  local r=$!
  "$phone/cpu.sh" $((secs - 2)) 8 | grep -E "com.powos.app|ocessService|surfaceflinger|total"
  wait $r $d
  "$phone/cdp.sh" eval home "document.getElementById('drag-raster')?.remove(), 1" >/dev/null
  [ -n "$off" ] && "$phone/cdp.sh" eval home "$off" >/dev/null
  sleep 1
}
run base ""
for v in "$@"; do run "${v%%=*}" "${v#*=}"; done
echo "== after: $("$phone/idle.sh")"
