#!/bin/bash
# float-windows.sh [OUT]: floating app windows on the unfolded home (board task powos-home-as-the-desktop-...), for a
# phone left unattended: the inner screen forced (cmd device_state state 3), the lock face swiped away (no PIN), home,
# then Calculator opened THROUGH HOME (CDP: powos.apps.launch, the path a tap takes) - it must be a freeform task, not
# full screen - captured with tools/phone/shot.sh; then Calculator stopped, home, `cmd device_state state reset`.
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
