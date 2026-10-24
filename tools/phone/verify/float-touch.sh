#!/bin/bash
# lanes: emu phone
# float-touch.sh [OUT] (board floating-window-blocks-swiping-home-pages-touch; shell ui/desktops.ts inWindow, gesture.ts
# startGesture): with a floating window open on the unfolded home, touches inside it are the app's and never home's
# swipes; beside it, home's swipes work. Forces the inner screen (cmd device_state state 3), swipes the lock face, home's
# first page, Calculator through home's launch call (apps.launch over CDP, as a tap), its bounds from windows.list. Then
# real injected swipes: (1) sideways INSIDE the window: home stays on its page; (2) up INSIDE it: the launcher stays shut;
# (3) sideways BESIDE it (an empty spot read over CDP): the next page shows, and back; (4) up from empty space beside
# it: the launcher opens (Back closes it). Restores: Calculator stopped, home, `cmd device_state state reset`.
# Exit: 0 pass; 1 FAIL: ...; 3 a real touch / no free window; 5 can't run (no unfolded size, a PIN, one home page).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/float-touch-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
PKG=com.oneplus.calculator
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "am force-stop $PKG; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"
window_lock float-desktops.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
# A call on home's bridge as the page makes it (float-windows.sh hcall): $1 method, $2 JSON args, $3 JS fn of the answer.
hcall_once() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
# hcall with retries: an EMPTY answer is a failed adb/CDP hop before the call reached the page (cdp.sh's adb under
# set -e once exited silently: "Calculator's key from home's apps.list: ", 2026-10-23) - the call never ran, so it's
# made again (up to 4 tries, 2 s apart). An answer from the page (ok, ERR ...) is final.
hcall() { local v i; for i in 1 2 3 4; do v=$(hcall_once "$@"); case $v in ""|"cdp: adb"*|*"isn't running"*|"no page"*) echo "hcall $2: try $i: '${v}'" >&2; sleep 2 ;; *) echo "$v"; return ;; esac; done; echo "ERR no answer after 4 tries (${v:-empty})"; }
# A host event into home's page, as ShellBridge.emit sends it; the page on screen (0-based, -1 none).
hemit() { "$T/cdp.sh" eval home "(window.__powosHost.emit('$1', $2), 'ok')" >/dev/null 2>&1; sleep 1.2; }
onpage() { "$T/cdp.sh" eval home "[...document.querySelectorAll('.page-track > .page')].findIndex(p=>!p.classList.contains('away'))" 2>&1 | tr -d '"\r' | tail -1; }
npages() { "$T/cdp.sh" eval home "document.querySelectorAll('.page-track > .page').length" 2>&1 | tr -d '"\r' | tail -1; }
vis() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'visible=(true|false)'; }
away() { hcall windows.list "[]" "l=>(l.find(w=>w.pkg==='$PKG')||{away:'none'}).away"; }

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
hemit system.home null
n=$(npages); echo "home pages: $n, on $(onpage)" | tee -a "$OUT/log.txt"
[ "${n:-0}" -ge 2 ] || { echo "home has one page - nothing to switch between; stopping"; exit 5; }
[ "$(onpage)" = 0 ] || fail "system.home didn't show page 1 ($(onpage))"

bounds() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' ' | xargs; }
# $2 a sideways swipe's way (-1 leftwards), $3 its length: a spot with room for the whole swipe first (the leftmost
# spot, left of the window, once clamped a leftward swipe to 207 px - too short to turn a page; float-desktops 2026-10-23).
freept() {
  "$T/cdp.sh" eval home "(()=>{const b='$1'.split(' ').map(Number),r=devicePixelRatio,d=${2:-0},len=${3:-0},W=innerWidth*r;let best=null,room=-1;for(let y=.2;y<=.9;y+=.05)for(let x=.06;x<=.94;x+=.04){const cx=innerWidth*x,cy=innerHeight*y,px=cx*r,py=cy*r;if(b.length===4&&px>=b[0]-60&&px<=b[2]+60&&py>=b[1]-120&&py<=b[3]+60)continue;const e=document.elementFromPoint(cx,cy);if(!e||!e.closest('.page-track'))continue;if(e.closest('.tile,.app,.panel,.widget,.island,.owl,button,a,input,.bar,.bottom-bar,.dock,[data-key]'))continue;const m=d<0?px-20:d>0?W-20-px:len;if(m>=len)return Math.round(px)+' '+Math.round(py);if(m>room){room=m;best=Math.round(px)+' '+Math.round(py)}}return best||'none'})()" 2>&1 | tr -d '"\r' | tail -1
}
isopen() { "$T/cdp.sh" eval home "!!document.querySelector('.home.open')" 2>&1 | tr -d '"\r' | tail -1; }

key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
case $key in a:$PKG/*) ;; *) fail "Calculator's key: $key" ;; esac
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 2.5; chk launch
[ "$(vis)" = visible=true ] || fail "Calculator's window isn't showing ($(vis))"
WB=$(hcall windows.list "[]" "l=>{const w=l.find(w=>w.pkg==='$PKG');return w&&w.bounds?w.bounds.join(' '):'ERR no bounds'}")
echo "window bounds (windows.list): $WB" | tee -a "$OUT/log.txt"
case $WB in ERR*) fail "windows.list has no bounds for Calculator: $WB (APK without 907927a?)" ;; esac
set -- $WB; L0=$1; T0=$2; R0=$3; B0=$4; WW=$((R0 - L0)); WHt=$((B0 - T0))
[ "$WW" -gt 300 ] && [ "$WHt" -gt 300 ] || fail "window bounds too small: $WB"
[ "$WW" -lt $((W - 100)) ] || fail "the window fills the screen ($WB) - not floating"
"$T/shot.sh" "$OUT/0-window.png"

# (1) sideways inside the window (its lower half: the keypad, below the title bar)
y=$((T0 + WHt * 70 / 100))
sh_ "input swipe $((L0 + WW * 85 / 100)) $y $((L0 + WW * 15 / 100)) $y 250"; sleep 1.5; chk inside-side
p=$(onpage); [ "$p" = 0 ] && [ "$(vis)" = visible=true ] && pass "a sideways swipe inside the window left home on page 1" \
  || fail "a sideways swipe inside the window moved home: page $p, $(vis)"
# (2) up inside the window
x=$((L0 + WW / 2))
sh_ "input swipe $x $((T0 + WHt * 85 / 100)) $x $((T0 + WHt * 35 / 100)) 250"; sleep 1.2; chk inside-up
o=$(isopen); [ "$o" = false ] && pass "a swipe up inside the window didn't open the launcher" || { sh_ "input keyevent 4"; fail "a swipe up inside the window opened the launcher ($o)"; }
"$T/shot.sh" "$OUT/1-after-inside.png"

# (3) sideways beside the window: the next page, then back
d=$((W * 35 / 100)); pt=$(freept "$WB" -1 "$d"); [ "$pt" != none ] && [ -n "$pt" ] || { echo "no empty spot beside the window - stopping"; exit 5; }
x=${pt% *}; y=${pt#* }; to=$((x - d)); [ $to -lt 20 ] && to=20
[ $((x - to)) -ge $((W / 4 + 40)) ] || { echo "only a $((x - to)) px swipe fits beside the window - stopping (not a product FAIL)"; exit 5; }
echo "beside: $x,$y -> $to,$y" >>"$OUT/log.txt"
sh_ "input swipe $x $y $to $y 250"; sleep 1.5; chk beside
p=$(onpage); [ "$p" = 1 ] && pass "a swipe beside the window showed page 2" || fail "a swipe beside the window: page $p (want 2)"
"$T/shot.sh" "$OUT/2-page2.png"
hemit system.home null; chk home1
[ "$(onpage)" = 0 ] || fail "home didn't come back to page 1"
# (4) up from empty space beside the window
pt=$(freept "$(bounds)"); [ "$pt" != none ] && [ -n "$pt" ] || { echo "no empty spot on page 1 - stopping"; exit 5; }
x=${pt% *}; y=${pt#* }; y1=$((y - H * 30 / 100)); [ $y1 -lt 60 ] && y1=60
sh_ "input swipe $x $y $x $y1 250"; sleep 1.2; chk empty-up
o=$(isopen); "$T/shot.sh" "$OUT/3-launcher.png"
sh_ "input keyevent 4"; sleep 0.8
[ "$o" = true ] && pass "a swipe up beside the window opened the launcher" || fail "a swipe up from empty space didn't open the launcher ($o)"
echo "PASS: touches inside the floating window stay the app's; beside it home's swipes work (artefacts: $OUT)"
