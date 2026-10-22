#!/bin/bash
# float-desktops.sh [OUT]: floating windows live on home's pages, one desktop per page (shell ui/desktops.ts,
# WindowFrames.desktop; board task floating-windows-live-on-home-pages-one-desktop). Needs the INNER screen (folded,
# apps are full screen by design): forces it (cmd device_state state 3), swipes the lock face, home's first page.
# Then, never touching the home layout (pages are only switched, through home's own host events, never by a swipe over
# widgets): Calculator opened through home's launch call lands on page 1; "windows.edge" (what a drop at the right edge
# sends) takes it and home to page 2; "system.home" (page 1) hides it - away in windows.list, visible=false - and the
# store keeps it on page 2; its app's launch (a dock tap) brings home to page 2 with it shown; a REAL drag of its bar
# to the left edge moves it back to page 1 (shown there after "system.home"). Always restores: Calculator stopped,
# home's first page, `cmd device_state state reset`. Exit: 0 passed; 1 FAIL: ...; 3 a real touch / no free window;
# 5 can't run (no screen size, a PIN, one home page only). Injected input only; a free window first, the lock then.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/desktops-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
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
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
# A host event into home's page, as ShellBridge.emit sends it; the page on screen (0-based, -1 none).
hemit() { "$T/cdp.sh" eval home "(window.__powosHost.emit('$1', $2), 'ok')" >/dev/null 2>&1; sleep 1.2; }
onpage() { "$T/cdp.sh" eval home "[...document.querySelectorAll('.page-track > .page')].findIndex(p=>!p.classList.contains('away'))" 2>&1 | tr -d '"\r' | tail -1; }
npages() { "$T/cdp.sh" eval home "document.querySelectorAll('.page-track > .page').length" 2>&1 | tr -d '"\r' | tail -1; }
vis() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'visible=(true|false)'; }
away() { hcall windows.list "[]" "l=>(l.find(w=>w.pkg==='$PKG')||{away:'none'}).away"; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ "$(sh_ "settings get global enable_freeform_support")" = 1 ] || fail "enable_freeform_support isn't 1"
sh_ "cmd device_state state 3"; sleep 3; chk unfold
sh_ "dumpsys device_state | grep -m1 mCommittedState" | grep -q OPENED || fail "the inner screen didn't come on"
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
W=${WH% *}; H=${WH#* }; echo "on: ${W}x${H}"
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

key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
case $key in a:$PKG/*) ;; *) fail "Calculator's key: $key" ;; esac
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 2.5; chk launch
id=$(hcall windows.list "[]" "l=>(l.find(w=>w.pkg==='$PKG')||{id:'none'}).id"); echo "window $id" | tee -a "$OUT/log.txt"
[ "$id" != none ] && [ "$(vis)" = visible=true ] || fail "no floating Calculator window on page 1 ($id, $(vis))"
"$T/shot.sh" "$OUT/p1-open.png"; pass "opened on page 1"

hemit windows.edge "{id:$id,side:1}"; chk edge
[ "$(onpage)" = 1 ] && [ "$(vis)" = visible=true ] && [ "$(away)" = false ] && pass "an edge drop takes it and home to page 2" \
  || fail "after windows.edge: page $(onpage), $(vis), away=$(away)"
hemit system.home null; sleep 0.8; chk page1
"$T/shot.sh" "$OUT/p1-hidden.png"
[ "$(onpage)" = 0 ] && [ "$(vis)" = visible=false ] && [ "$(away)" = true ] && pass "page 1 hides page 2's window" \
  || fail "on page 1: page $(onpage), $(vis), away=$(away)"
kept=$(hcall store.get "['home.windows']" "m=>m&&m['$id']")
echo "stored page id: $kept" | tee -a "$OUT/log.txt"
[ -n "$kept" ] && [ "$kept" != undefined ] && [ "$kept" != null ] && pass "kept per page in the store" || fail "not in the store's home.windows"

r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch (restore): $r"
sleep 1.8; chk restore
"$T/shot.sh" "$OUT/p2-raised.png"
[ "$(onpage)" = 1 ] && [ "$(vis)" = visible=true ] && pass "its app's launch brings home to its page" || fail "after the launch: page $(onpage), $(vis)"

# A real drag of its bar (BAR_DP 40 above the task's top) to the left edge: back to page 1, home with it.
bounds() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }
D=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1); px() { echo $(( $1 * D / 160 )); }
read -r XL XT XR XB <<<"$(bounds)"; [ -n "${XB:-}" ] || fail "no bounds for the task"
BY=$((XT - $(px 20))); BX=$((XL + (XR - XL) / 3))
sh_ "input swipe $BX $BY 4 $BY 900"; sleep 2; chk drag
"$T/shot.sh" "$OUT/dragged-left.png"
read -r XL2 XT2 XR2 XB2 <<<"$(bounds)"; echo "after the edge drag: $XL2 $XT2 $XR2 $XB2 page $(onpage)" | tee -a "$OUT/log.txt"
[ "$(onpage)" = 0 ] && [ "$(vis)" = visible=true ] && [ "${XL2:-0}" -ge 0 ] && pass "dragged to the left edge: page 1, whole on screen" \
  || fail "after the edge drag: page $(onpage), $(vis), left $XL2"
hemit system.home null; chk end
[ "$(vis)" = visible=true ] && [ "$(away)" = false ] || fail "on page 1 after the drag: $(vis), away=$(away)"
echo "all passed; artefacts: $OUT"
