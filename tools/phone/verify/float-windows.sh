#!/bin/bash
# float-windows.sh [OUT]: floating app windows on the unfolded home (board task powos-home-as-the-desktop-...), for a
# phone left unattended. Folded, apps open full screen by design, so the check needs the INNER screen: it forces it
# (cmd device_state state 3, as unfolded-checks.sh does), dismisses the keyguard / swipes the lock face (no PIN), home,
# then opens Calculator THROUGH HOME's own launch path - the bridge call a tap makes (state.ts launch ->
# powos.apps.launch -> PowosHost.postMessage [id, "apps.launch", [key]]; `powos` is a module, not a page global) - and
# it must be a freeform task; then PowOS's frame (WindowFrame.kt): bar there, drag moves, grip resizes, minimise hides
# it, its app's launch brings it back, close closes. Always restores: Calculator stopped, home,
# `cmd device_state state reset` (the hinge decides again).
# Exit: 0 all passed; 1 a step failed (FAIL: ...); 3 a real touch / no free window / screen not awake (re-queued);
# 5 can't run (no screen size, keyguard with a PIN). Injected input only. A free window first, the lock only then (5a).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/float-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
PKG=com.oneplus.calculator
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "am force-stop $PKG; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"
window_lock float-windows.sh 120
# Our own trap (window_lock sets none under the queue's LOCK_HELD=1): restore always, the lock only if it's ours.
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
# A call on home's bridge, exactly as the page makes it (bridge.ts native()): its answer through __powosHost.resolve
# under our own id, the page's own pending calls untouched. $1 method, $2 JSON args array, $3 a JS function of the answer.
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910200+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ "$(sh_ "settings get global enable_freeform_support")" = 1 ] || fail "enable_freeform_support isn't 1 (OxygenOS coerces freeform to full screen)"
sh_ "cmd device_state state 3"; sleep 3; chk unfold
sh_ "dumpsys device_state | grep -m1 mCommittedState" | tee -a "$OUT/log.txt" | grep -q OPENED || fail "the inner screen didn't come on (device_state not OPENED)"
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
W=${WH% *}; H=${WH#* }; echo "on: ${W}x${H}"
[ "${W:-0}" -gt 0 ] && [ "${H:-0}" -gt 0 ] || { echo "no screen size (wm size) - stopping before any input"; exit 5; }
[ "$W" -gt 2000 ] || fail "display 0 is ${W}x${H}, not the unfolded inner screen"
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "the keyguard didn't go (a PIN?) - stopping"; exit 5; }
fi
if sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock"; then
  sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5
fi
chk lock
sh_ "am force-stop $PKG; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -q "com.powos.app" || fail "home isn't in front after the home intent"
"$T/shot.sh" "$OUT/home.png"

key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
echo "launch $key" | tee -a "$OUT/log.txt"
case $key in a:$PKG/*) ;; *) fail "Calculator's key from home's apps.list: $key" ;; esac
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 2.5; chk launch
sh_ "dumpsys activity activities | grep -m1 -E \"Task\\{.*$PKG\" | grep -oE \"mode=[a-z-]+\"" | tee "$OUT/mode.txt"
sh_ "am stack list | grep -m1 $PKG | grep -oE \"bounds=\\[[^ ]*\"" | tee -a "$OUT/mode.txt"
"$T/shot.sh" "$OUT/floating.png"
grep -q 'mode=freeform' "$OUT/mode.txt" && pass "a floating window" || fail "not freeform ($(head -1 "$OUT/mode.txt"))"

# PowOS's frame on it (system/WindowFrame.kt): the bar is BAR_DP (40) above the task's top; close is its last button
# (30 dp, 6 dp from the end), minimise the one before it (4 dp gap); the grip disc sits on the lower-right corner.
bounds() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }
D=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1); px() { echo $(( $1 * D / 160 )); }
bars=$(sh_ "dumpsys window windows | grep -c \"PowOS window bar\""); echo "frame bars: $bars" | tee -a "$OUT/mode.txt"
[ "${bars:-0}" -ge 1 ] && pass "a title bar" || fail "no title bar"
read -r XL XT XR XB <<<"$(bounds)"; echo "before: $XL $XT $XR $XB"
[ -n "${XB:-}" ] || fail "no bounds for the task"
BY=$((XT - $(px 20))); sh_ "input swipe $((XL + (XR - XL) / 3)) $BY $((XL + (XR - XL) / 3 + 240)) $((BY + 180)) 700"; sleep 1.5; chk drag
read -r XL2 XT2 XR2 XB2 <<<"$(bounds)"; echo "after drag: $XL2 $XT2 $XR2 $XB2" | tee -a "$OUT/mode.txt"
"$T/shot.sh" "$OUT/framed.png"
[ "$XL2" != "$XL" ] && [ "$XT2" != "$XT" ] && pass "the bar moves it" || fail "the drag didn't move it"
sh_ "input swipe $((XR2 - $(px 6))) $((XB2 - $(px 6))) $((XR2 + $(px 92))) $((XB2 + $(px 72))) 700"; sleep 1.5; chk grip
read -r XL3 XT3 XR3 XB3 <<<"$(bounds)"; echo "after resize: $XL3 $XT3 $XR3 $XB3" | tee -a "$OUT/mode.txt"
[ $((XR3 - XL3)) -gt $((XR2 - XL2)) ] && pass "the grip resizes it" || fail "the grip didn't resize it"
# Minimise: off screen and minimised in home's window list; the app's launch (a dock tap) brings it back.
vis() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'visible=(true|false)'; }
sh_ "input tap $((XR3 - $(px 55))) $((XT3 - $(px 20)))"; sleep 1.5; chk minimise
m=$(hcall windows.list "[]" "l=>l.filter(w=>w.pkg==='$PKG'&&w.minimised).length")
echo "minimised: $(vis) windows.list minimised=$m" | tee -a "$OUT/mode.txt"
"$T/shot.sh" "$OUT/minimised.png"
[ "$m" = 1 ] && [ "$(vis)" = visible=false ] && pass "minimise" || fail "minimise (list: $m, $(vis))"
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch (restore): $r"
sleep 1.5; chk restore
[ "$(vis)" = visible=true ] && pass "the dock brings it back" || fail "not back after its app's launch"
read -r XL3 XT3 XR3 XB3 <<<"$(bounds)"
sh_ "input tap $((XR3 - $(px 6) - $(px 15))) $((XT3 - $(px 20)))"; sleep 1.5; chk close
sh_ "am stack list | grep -c $PKG" | grep -qx 0 && pass "close closes it" || fail "still open after close"
echo "all passed; artefacts: $OUT"
