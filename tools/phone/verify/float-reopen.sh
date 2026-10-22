#!/bin/bash
# float-reopen.sh [OUT]: reopening a resized floating window from the switcher leaves no full-screen ghost (board task
# reopening-a-floating-window-from-switcher-leaves). Unfolded (cmd device_state state 3), lock swiped, home: Calculator
# opened through home's launch call floats; its grip resized (a real injected drag); the switcher shown (the overview
# key); its card tapped (pointer events into home's page). Then: the card grown over the layer (.recents-expand) and
# the layer (.recents.open) must be gone, the window still where it was resized to, visible. Screencaps of each step.
# Always restores: Calculator stopped, home, `cmd device_state state reset`. Exit: 0 passed; 1 FAIL: ...; 3 a real
# touch / no free window; 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/reopen-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
PKG=com.oneplus.calculator
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "am force-stop $PKG; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"
window_lock float-reopen.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
# A call on home's bridge as the page makes it (float-windows.sh hcall): $1 method, $2 JSON args, $3 JS fn of the answer.
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
# A host event into home's page, as ShellBridge.emit sends it; the page on screen (0-based, -1 none).
hemit() { "$T/cdp.sh" eval home "(window.__powosHost.emit('$1', $2), 'ok')" >/dev/null 2>&1; sleep 1.2; }
onpage() { "$T/cdp.sh" eval home "[...document.querySelectorAll('.page-track > .page')].findIndex(p=>!p.classList.contains('away'))" 2>&1 | tr -d '"\r' | tail -1; }
vis() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'visible=(true|false)'; }
npages() { "$T/cdp.sh" eval home "document.querySelectorAll('.page-track > .page').length" 2>&1 | tr -d '"\r' | tail -1; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ "$(sh_ "settings get global enable_freeform_support")" = 1 ] || fail "enable_freeform_support isn't 1"
# The committed state flips to OPENED before display 0 is the inner screen: 3 s once wasn't enough (right after
# sketch-rotate, folded: OPENED, wm size still the cover's 1116x2484) - wait for the inner size, up to 15 s.
sh_ "cmd device_state state 3"; sleep 2; chk unfold
sh_ "dumpsys device_state | grep -m1 mCommittedState" | grep -q OPENED || fail "the inner screen didn't come on"
wsize() { sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1; }
t=0; WH=$(wsize)
while [ "${WH%% *}" -le 2000 ] 2>/dev/null && [ $t -lt 13 ]; do sleep 1; t=$((t + 1)); WH=$(wsize); done
chk unfold
W=${WH% *}; H=${WH#* }; echo "on: ${W}x${H} ($((t + 2)) s after state 3)"
[ "${W:-0}" -gt 2000 ] || { echo "no unfolded screen size ($WH) - stopping before any input"; exit 5; }
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "the keyguard didn't go (a PIN?) - stopping"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock" && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
chk lock
sh_ "am force-stop $PKG; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
# The fix's APK not installed yet (its tasks carry "floats" unfolded): no verdict, again next window (rc 3).
fl=$(hcall tasks.list "[]" "l=>l.some(t=>t.floats)?'yes':'no'")
[ "$fl" = yes ] || { echo "the installed APK has no floating-task data in tasks.list ($fl) - not shipped yet, again next window"; exit 3; }
key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
case $key in a:$PKG/*) ;; *) fail "Calculator's key: $key" ;; esac
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 2.5; chk launch
id=$(hcall windows.list "[]" "l=>(l.find(w=>w.pkg==='$PKG')||{id:'none'}).id"); echo "window $id" | tee -a "$OUT/log.txt"
[ "$id" != none ] && [ "$(vis)" = visible=true ] || fail "no floating Calculator window ($id, $(vis))"
bounds() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }
D=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1); px() { echo $(( $1 * D / 160 )); }
read -r XL XT XR XB <<<"$(bounds)"; [ -n "${XB:-}" ] || fail "no bounds for the task"
# The grip (lower right corner disc) dragged out: the window resized as the user does.
sh_ "input swipe $((XR - $(px 6))) $((XB - $(px 6))) $((XR + $(px 92))) $((XB + $(px 72))) 700"; sleep 1.5; chk grip
read -r L1 T1 R1 B1 <<<"$(bounds)"; echo "resized: $XL $XT $XR $XB -> $L1 $T1 $R1 $B1" | tee -a "$OUT/log.txt"
[ $((R1 - L1)) -gt $((XR - XL)) ] && pass "the grip resized it" || fail "the grip didn't resize it"
"$T/shot.sh" "$OUT/1-resized.png"
# The switcher, as the overview button shows it.
sh_ "input keyevent KEYCODE_APP_SWITCH"; sleep 2; chk switcher
up=$("$T/cdp.sh" eval home "!!document.querySelector('.recents.open .task[data-task=\"$id\"] .task-shot')" 2>&1 | tr -d '"\r' | tail -1)
"$T/shot.sh" "$OUT/2-switcher.png"
[ "$up" = true ] || fail "the switcher didn't show Calculator's card ($up)"
pass "the switcher shows its card"
# Its card tapped: a pointer down + up on its picture, as a finger's tap reaches the page.
"$T/cdp.sh" eval home "(()=>{const s=document.querySelector('.task[data-task=\"$id\"] .task-shot');const r=s.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2,o={bubbles:true,clientX:x,clientY:y,pointerId:7,isPrimary:true,pointerType:'touch'};s.dispatchEvent(new PointerEvent('pointerdown',o));s.dispatchEvent(new PointerEvent('pointerup',o));return 'ok'})()" >/dev/null 2>&1
sleep 0.4; "$T/shot.sh" "$OUT/3-opening.png"; sleep 1.6; chk reopen
"$T/shot.sh" "$OUT/4-reopened.png"
st=$("$T/cdp.sh" eval home "JSON.stringify({expand:!!document.querySelector('.recents-expand'),layer:!!document.querySelector('.recents.open')})" 2>&1 | tr -d '\r' | tail -1)
echo "page after reopen: $st" | tee -a "$OUT/log.txt"
read -r L2 T2 R2 B2 <<<"$(bounds)"; echo "window after reopen: $L2 $T2 $R2 $B2, $(vis)" | tee -a "$OUT/log.txt"
case $st in *'expand\":false'*'layer\":false'*|*'expand":false'*'layer":false'*) pass "no ghost: the grown card and the layer are gone" ;; *) fail "a ghost stays behind the window: $st" ;; esac
[ "$(vis)" = visible=true ] && [ "$L2 $T2 $R2 $B2" = "$L1 $T1 $R1 $B1" ] && pass "it came back where it was resized to" \
  || fail "the window after reopen: $L2 $T2 $R2 $B2 ($(vis)), was $L1 $T1 $R1 $B1"
echo "PASS float-reopen ($OUT)"
