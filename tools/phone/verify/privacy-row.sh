#!/bin/bash
# lanes: phone
# privacy-row.sh (board control-center-shows-what-is-using-the-mic-and-c; shell ui/privacy.tsx, host RecordingLight.kt,
# gate privacy-row-*): the control center pulled down (the status bar's right half, as owed.sh) - idle: the host's
# privacy.list has nothing in use and no chip says "now"; then PowOS's own dictation started (home's speech.start)
# and the control center pulled again: the host names the mic's holder and a chip names it "Microphone · now"
# (dev/device-checks.js privacyRowNow). Dictation cancelled, the shade closed (Back), home after.
# Not covered here: the status bar's mic glow tap (a native ring; tap it by hand while dictating).
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
case "$idle|$dict" in
  '[]|[]') echo "PASS privacy-row: idle empty, dictating names the mic's holder"; exit 0 ;;
  *'["SKIP:'*'|[]') echo "PASS privacy-row (idle skipped: $idle): dictating names the mic's holder"; exit 0 ;;
  *) echo "FAIL privacy-row: idle $idle; dictating $dict"; exit 1 ;;
esac
