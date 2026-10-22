#!/bin/bash
# float-windows.sh [OUT]: floating app windows on the unfolded home (board task powos-home-as-the-desktop-...), for a
# phone left unattended: the inner screen forced (cmd device_state state 3), the lock face swiped away (no PIN), home,
# then Calculator opened THROUGH HOME (CDP: powos.apps.launch, the path a tap takes) - it must be a freeform task, not
# full screen - captured with tools/phone/shot.sh; then PowOS's frame (WindowFrame.kt): bar there, drag moves, grip
# resizes, minimise hides it, its app's launch brings it back, close closes; then home, `cmd device_state state reset`.
# Injected input only; stops (and restores) on a real touch. A free window first, the verify lock only then (5a).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/float-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
PKG=com.oneplus.calculator
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
WL_TRAP='sh_ "am force-stop '$PKG'; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo restored'
. "$here/window-lock.sh"
window_lock float-windows.sh 120
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
sh_ "cmd device_state state 3"; sleep 3; chk unfold
WH=$(sh_ "dumpsys display | grep -E \"^  DisplayDeviceInfo\" | sed -nE \"s/.*uniqueId=\\\"local:[0-9]+\\\", ([0-9]+) x ([0-9]+),.* state ON,.*/\\1 \\2/p\" | head -1")
W=${WH% *}; H=${WH#* }; echo "on: ${W}x${H}"
if sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qiE "Lock|Keyguard"; then
  sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; chk lock
fi
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
"$T/shot.sh" "$OUT/home.png"
key=$("$T/cdp.sh" eval home "powos.apps.list().then(l => (l.find(a => /^a:$PKG/.test(a.key)) || {}).key || '')" 2>/dev/null | tr -d '"\r' | tail -1)
echo "launch $key"
[ -n "$key" ] || { echo "Calculator isn't in home's app list"; exit 5; }
"$T/cdp.sh" eval home "powos.apps.launch('$key')" >/dev/null 2>&1; sleep 2.5; chk launch
sh_ "dumpsys activity activities | grep -m1 -E \"Task\\{.*$PKG\" | grep -oE \"mode=[a-z-]+\"" | tee "$OUT/mode.txt"
sh_ "am stack list | grep -m1 $PKG | grep -oE \"bounds=\\[[^ ]*\"" | tee -a "$OUT/mode.txt"
"$T/shot.sh" "$OUT/floating.png"
grep -q 'mode=freeform' "$OUT/mode.txt" && echo "PASS: a floating window" || echo "FAIL: not freeform"
# PowOS's frame on it (system/WindowFrame.kt): the bar's window is there, a drag on the bar moves the task, the close
# button closes it. Coordinates from the task's bounds: the bar is BAR_DP above its top, close is its last button.
bounds() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }
D=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1); px() { echo $(( $1 * D / 160 )); }
bars=$(sh_ "dumpsys window windows | grep -c \"PowOS window bar\""); echo "frame bars: $bars" | tee -a "$OUT/mode.txt"
[ "${bars:-0}" -ge 1 ] && echo "PASS: a title bar" || echo "FAIL: no title bar"
read -r XL XT XR XB <<<"$(bounds)"; echo "before: $XL $XT $XR $XB"
BY=$((XT - $(px 20))); sh_ "input swipe $((XL + (XR - XL) / 3)) $BY $((XL + (XR - XL) / 3 + 240)) $((BY + 180)) 700"; sleep 1.5; chk drag
read -r XL2 XT2 XR2 XB2 <<<"$(bounds)"; echo "after drag: $XL2 $XT2 $XR2 $XB2" | tee -a "$OUT/mode.txt"
"$T/shot.sh" "$OUT/framed.png"
[ "$XL2" != "$XL" ] && [ "$XT2" != "$XT" ] && echo "PASS: the bar moves it" || echo "FAIL: the drag didn't move it"
sh_ "input swipe $((XR2 - $(px 6))) $((XB2 - $(px 6))) $((XR2 + $(px 92))) $((XB2 + $(px 72))) 700"; sleep 1.5; chk grip
read -r XL3 XT3 XR3 XB3 <<<"$(bounds)"; echo "after resize: $XL3 $XT3 $XR3 $XB3" | tee -a "$OUT/mode.txt"
[ $((XR3 - XL3)) -gt $((XR2 - XL2)) ] && echo "PASS: the grip resizes it" || echo "FAIL: the grip didn't resize it"
# Minimise (the button left of close): off screen and minimised in home's list; the app's launch (a dock tap) brings it back.
vis() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'visible=(true|false)'; }
sh_ "input tap $((XR3 - $(px 55))) $((XT3 - $(px 20)))"; sleep 1.5; chk minimise
w=$("$T/cdp.sh" eval home "powos.windows.list().then(l => JSON.stringify(l))" 2>/dev/null | tail -1); echo "minimised: $(vis) $w" | tee -a "$OUT/mode.txt"
"$T/shot.sh" "$OUT/minimised.png"
echo "$w" | grep -q 'minimised\\*":true' && [ "$(vis)" = visible=false ] && echo "PASS: minimise" || echo "FAIL: minimise"
"$T/cdp.sh" eval home "powos.apps.launch('$key')" >/dev/null 2>&1; sleep 1.5; chk restore
[ "$(vis)" = visible=true ] && echo "PASS: the dock brings it back" || echo "FAIL: not back after a tap on its app"
read -r XL3 XT3 XR3 XB3 <<<"$(bounds)"
sh_ "input tap $((XR3 - $(px 6) - $(px 15))) $((XT3 - $(px 20)))"; sleep 1.5; chk close
sh_ "am stack list | grep -c $PKG" | grep -qx 0 && echo "PASS: close closes it" || echo "FAIL: still open after close"
