#!/bin/bash
# lanes: phone
# privacy-row.sh (board control-center-shows-what-is-using-the-mic-and-c; shell ui/privacy.tsx, host RecordingLight.kt,
# gate privacy-row-*): the control center pulled down (the status bar's right half, as owed.sh) - idle: the host's
# privacy.list has nothing in use and no chip says "now"; then PowOS's own dictation started (home's speech.start)
# and the control center pulled again: the host names the mic's holder and a chip names it "Microphone · now"
# (dev/device-checks.js privacyRowNow). Dictation cancelled, the shade closed (Back), home after.
# Then, still dictating, the shade closed: the status bar's recording ring (the mic glow, chrome.tsx RecordingRing) tapped
# where it's drawn -> the control center opens with the "Microphone · now" chip (ringtap).
# Exit 0 PASS, 1 FAIL, 3 no free window, 5 SKIP.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
SHELL_CHECK_LIB=1 . "$here/shell-check.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/privacy-row-$(date +%m%d-%H%M%S)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
. "$here/window-lock.sh"
window_lock privacy-row.sh 120
sh_() { "$T/adb.sh" shell "$*" 2>/dev/null | tr -d '\r'; }
DICT=
restore() {
  [ -z "$DICT" ] || "$T/cdp.sh" eval home 'importShim("./bridge.ts").then(b=>b.powos.speech.cancel()).then(()=>"ok")' >/dev/null 2>&1
  sh_ "input keyevent KEYCODE_BACK; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
}
trap restore EXIT
read -r W H < <(sh_ "wm size" | sed -nE 's/.*: ([0-9]+)x([0-9]+).*/\1 \2/p' | tail -1)
W=${W:-1116}; H=${H:-2484}
pull() { sh_ "cmd statusbar collapse"; sleep 0.4; sh_ "input swipe $((W * 8 / 10)) 8 $((W * 8 / 10)) $((H * 6 / 10)) 350"; sleep 1.8; }
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1
pull
idle=$(shell_check shade device-checks.js privacyRowNow idle)
"$T/shot.sh" "$OUT/idle.png" >/dev/null 2>&1 || true
echo "privacy-row idle: $idle"
sh_ "input keyevent KEYCODE_BACK"; sleep 1
DICT=1
"$T/cdp.sh" eval home 'importShim("./bridge.ts").then(b=>b.powos.speech.start(false)).then(()=>"ok",e=>"ERR "+e)' 2>&1 | tail -1
sleep 2
pull
dict=$(shell_check shade device-checks.js privacyRowNow dictating)
"$T/shot.sh" "$OUT/dictating.png" >/dev/null 2>&1 || true
echo "privacy-row dictating: $dict (shots $OUT)"
# The ring's tap: its centre in display px (the status strip spans the screen's top from 0,0), then the shade's chips.
sh_ "input keyevent KEYCODE_BACK"; sleep 1
at=$("$T/cdp.sh" eval statusbar '(()=>{const r=document.querySelector(".status-rec-ring");if(!r)return "none";const b=r.getBoundingClientRect(),d=devicePixelRatio;return Math.round((b.left+b.width/2)*d)+" "+Math.round((b.top+b.height/2)*d)})()' 2>&1 | tail -1 | tr -d '"')
case $at in
  [0-9]*\ [0-9]*)
    sh_ "input tap $at"; sleep 1.5
    ring=$("$T/cdp.sh" eval shade 'new Promise(res=>{const end=Date.now()+4000,g=()=>{const c=[...document.querySelectorAll(".notif-panel.shown .privacy-chip")].map(e=>e.textContent.trim());if(c.some(t=>/Microphone/.test(t)&&/now/.test(t)))res("ok");else if(Date.now()>end)res(document.querySelector(".notif-panel.shown")?"chips "+JSON.stringify(c):"shade not open");else setTimeout(g,200)};g()})' 2>&1 | tail -1 | tr -d '"')
    "$T/shot.sh" "$OUT/ring-tap.png" >/dev/null 2>&1 || true ;;
  *) ring="no ring to tap while dictating ($at)" ;;
esac
echo "privacy-row ring tap: $ring"
[ "$ring" = ok ] && rt="[]" || rt="[\"ring tap: $ring\"]"
case "$idle|$dict|$rt" in
  '[]|[]|[]') echo "PASS privacy-row: idle empty, dictating names the mic's holder, the ring's tap opens it"; exit 0 ;;
  *'["SKIP:'*'|[]|[]') echo "PASS privacy-row (idle skipped: $idle): dictating names the mic's holder, the ring's tap opens it"; exit 0 ;;
  *) echo "FAIL privacy-row: idle $idle; dictating $dict; ring tap $rt"; exit 1 ;;
esac
