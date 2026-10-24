#!/bin/bash
# lanes: emu phone
# window-chrome.sh [OUT]: a floating window's chrome (system/WindowFrame.kt; board task floating-windows-live-resize-
# half-height-title-b), for a phone left unattended. Unfolds (cmd device_state state 3), swipes the lock face away, opens
# Calculator through home's own launch path (as float-windows.sh), then:
#   1. the title bar's window is 24-28 dp tall (dumpsys window: its frame), its frost as drawn (logcat PowosWindowFrame:
#      blur 360 dp, the fill/veil/sheen/edge colours) and SurfaceFlinger's blur region on the bar's layer;
#   2. live resize: a slow grip drag (2.4 s); in the middle of it the app's own window (its frame in dumpsys window) is
#      already bigger than before and smaller than after - the content resizes with the finger, not at the lift;
#      PowosWindowResize's line (live bounds calls per drag); a screencap mid-drag and one after.
# Always restores: Calculator stopped, home, `cmd device_state state reset`.
# Exit: 0 all passed; 1 a step failed (FAIL: ...); 3 a real touch / no free window / screen not awake; 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/chrome-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
PKG=com.oneplus.calculator
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "am force-stop $PKG; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"
window_lock window-chrome.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
hcall_once() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
# hcall with retries: an EMPTY answer is a failed adb/CDP hop before the call reached the page (cdp.sh's adb under
# set -e once exited silently: "Calculator's key from home's apps.list: ", 2026-10-23) - the call never ran, so it's
# made again (up to 4 tries, 2 s apart). An answer from the page (ok, ERR ...) is final.
hcall() { local v i; for i in 1 2 3 4; do v=$(hcall_once "$@"); case $v in ""|"cdp: adb"*|*"isn't running"*|"no page"*) echo "hcall $2: try $i: '${v}'" >&2; sleep 2 ;; *) echo "$v"; return ;; esac; done; echo "ERR no answer after 4 tries (${v:-empty})"; }
# A window's frame from dumpsys window: "l t r b" of the first frame=[..][..] in the block of the window whose title
# matches $1.
wframe() { sh_ "dumpsys window windows" | awk -v p="$1" '/^ *Window #/{f=($0 ~ p)} f' | grep -oE ' frame=\[-?[0-9]+,-?[0-9]+\]\[-?[0-9]+,-?[0-9]+\]' | head -1 | tr -c '0-9\n-' ' '; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
sh_ "cmd device_state state 3"; sleep 3; chk unfold
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
W=${WH% *}; H=${WH#* }
[ "${W:-0}" -gt 2000 ] || { echo "display 0 is ${W:-?}x${H:-?}, not the inner screen - stopping before any input"; exit 5; }
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "the keyguard didn't go (a PIN?) - stopping"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock" && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
chk lock
sh_ "am force-stop $PKG; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; logcat -c"; sleep 2; chk home
key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
case $key in a:$PKG/*) ;; *) fail "Calculator's key from home's apps.list: $key" ;; esac
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 3; chk launch

# 1. The bar: its window's height, its frost.
D=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1); px() { echo $(( $1 * D / 160 )); }
read -r BL BT BR BB <<<"$(wframe 'PowOS window bar')"
[ -n "${BB:-}" ] || fail "no title bar window"
BH=$((BB - BT)); BDP=$((BH * 160 / D))
echo "bar window: ${BH} px = ${BDP} dp (density $D)" | tee -a "$OUT/log.txt"
[ "$BDP" -ge 24 ] && [ "$BDP" -le 28 ] && pass "the title bar is ${BH} px (${BDP} dp)" || fail "the title bar is ${BH} px (${BDP} dp), want 24-28 dp"
sh_ "logcat -d -s PowosWindowFrame:I" | grep -m1 "bar .* frost" | tee -a "$OUT/log.txt" > "$OUT/frost.txt"
grep -q "frost blur 360" "$OUT/frost.txt" && pass "frost v2 on the bar: $(grep -oE 'fill=#[0-9a-f]+' "$OUT/frost.txt"), blur 360 dp" || fail "no frost line from the frame (logcat PowosWindowFrame)"
sh_ "dumpsys SurfaceFlinger" | grep -A30 "PowOS window bar" | grep -m3 -E "blurRegions|radius=" | tee -a "$OUT/log.txt" > "$OUT/sf-blur.txt"
grep -qE "radius=[1-9]" "$OUT/sf-blur.txt" && pass "a blur region on the bar's layer" || echo "NOTE: no blur region read on the bar's layer (sf-blur.txt)" | tee -a "$OUT/log.txt"

# 2. Live resize: the app's window mid-drag.
read -r AL AT AR AB <<<"$(wframe "$PKG")"
[ -n "${AB:-}" ] || fail "no window of $PKG"
read -r GL GT GR GB <<<"$(wframe 'PowOS window grip')"
[ -n "${GB:-}" ] || fail "no grip window"
GX=$(((GL + GR) / 2)); GY=$(((GT + GB) / 2))
echo "app window before: $AL $AT $AR $AB; grip at $GX,$GY" | tee -a "$OUT/log.txt"
# One phone shell: the drag in the background, the app's frame read at its middle, then after.
# The drag must stay on the screen: a window cascaded to the right (776..2136 of 2268, 06:58) hit the screen's edge
# after ~130 px of a 442 px drag, so it was already at its last size mid-drag ("not live", the check's fault). With
# less than 200 dp to the right it shrinks the window instead (up and left); mid-drag must lie between either way.
DX=$(px 160); DY=$(px 120); SG=1
[ $((W - GX)) -lt $(px 200) ] || [ $((H - GY)) -lt $(px 200) ] && { SG=-1; }
echo "drag: ${SG}x(${DX},${DY}) px" | tee -a "$OUT/log.txt"
"$A" shell "su -c 'input swipe $GX $GY $((GX + SG * DX)) $((GY + SG * DY)) 2400'" >/dev/null 2>&1 &
SW=$!
sleep 1.3
read -r ML MT MR MB <<<"$(wframe "$PKG")"
"$T/shot.sh" "$OUT/mid-resize.png" >/dev/null 2>&1
wait $SW; sleep 1.5; chk resize
read -r EL ET ER EB <<<"$(wframe "$PKG")"
echo "app window mid-drag: $ML $MT $MR $MB; after: $EL $ET $ER $EB" | tee -a "$OUT/log.txt"
sh_ "logcat -d -s PowosWindowResize:I PowosWindowDrag:I PowosFreeform:W" | tail -6 | tee -a "$OUT/log.txt"
"$T/shot.sh" "$OUT/after-resize.png" >/dev/null 2>&1
W0=$((AR - AL)); WM=$((MR - ML)); W1=$((ER - EL))
[ $(( (W1 - W0) * SG )) -gt 0 ] || fail "the grip didn't resize the window ($W0 -> $W1 px wide)"
[ $(( (WM - W0) * SG )) -gt 0 ] && [ $(( (W1 - WM) * SG )) -gt 0 ] && pass "live resize: the app's window $W0 -> $WM (mid-drag) -> $W1 px wide" ||
  fail "not live: the app's window was $WM px wide mid-drag ($W0 before, $W1 after)"
echo "all passed; artefacts: $OUT"
