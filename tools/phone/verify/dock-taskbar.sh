#!/bin/bash
# lanes: emu phone
# dock-taskbar.sh [OUT] (board dock-as-taskbar-tap-focused-app-minimises-tap-ag; shell ui/desktops.ts dockTap, home.tsx
# DockWindows): on the unfolded home the dock is a taskbar. Forces the inner screen (cmd device_state state 3), swipes
# the lock face, home's first page; opens Calculator, then Settings, through home's launch call (apps.launch over CDP,
# as a tap) - both float, Settings in front. Then REAL injected taps on Calculator's dock icon (its spot read over CDP):
# (1) it comes in front of Settings (focus); (2) again: it goes into the dock (minimised, hidden); (3) again: it's back
# in front. Each step reads windows.list (the host's order: front first) and `am stack list`. Screencaps per step.
# Restores: both stopped, home, `cmd device_state state reset`. Never touches the layout (no drag, no edit mode).
# Exit: 0 pass; 1 FAIL: ...; 3 a real touch / no free window; 5 can't run (no unfolded size, a PIN).
set -uo pipefail
# (These lines were missing: no here/T/A, so window_lock wasn't found and every run read "the screen is  - not woken"
# and went back on the queue as rc 3, 2026-10-23.)
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/dock-taskbar-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
PKG=${TEST_APP:-com.oneplus.calculator}
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { [ "${TOUCHED:-0}" = 1 ] || return 0; release_pkgs; sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"
window_lock dock-taskbar.sh 120
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
[ "${W:-0}" -gt 2000 ] || { echo "ENV: no unfolded screen size ($WH) - stopping before any input"; exit 5; }
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "ENV: the keyguard didn't go (a PIN?) - stopping"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock" && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
chk lock
claim_pkg $PKG
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
hemit system.home null
PKG2=com.android.settings
claim_pkg $PKG2
vis2() { sh_ "am stack list | grep -m1 $PKG2" | grep -oE 'visible=(true|false)'; }
# The window in front (windows.list: the host's order, top first) and Calculator's state there.
front() { hcall windows.list "[]" "l=>(l.find(w=>!w.minimised&&!w.away)||{pkg:'none'}).pkg"; }
calc() { hcall windows.list "[]" "l=>{const w=l.find(w=>w.pkg==='$PKG');return w?(w.minimised?'minimised':'shown'):'none'}"; }
# Calculator's dock icon centre, device px (read only): a pinned cell or DockWindows' cell after the pinned ones.
icon() { "$T/cdp.sh" eval home "(()=>{const e=[...document.querySelectorAll('.home .dock .app[data-key]')].find(a=>a.dataset.key.startsWith('a:$PKG/'));if(!e)return 'none';const r=e.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.x+r.width/2)*d)+' '+Math.round((r.y+r.height/2)*d)})()" 2>&1 | tr -d '"\r' | tail -1; }
tap_icon() { local p; p=$(icon); [ "$p" != none ] && [ -n "$p" ] || fail "no dock icon for Calculator ($p) at step $1"; echo "tap $1 at $p" >>"$OUT/log.txt"; sh_ "input tap $p"; sleep 1.8; chk "$1"; }

key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
case $key in a:$PKG/*) ;; *) fail "Calculator's key: $key" ;; esac
key2=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG2\\//.test(a.key))||{}).key||'ERR not in the list'")
case $key2 in a:$PKG2/*) ;; *) fail "Settings' key: $key2" ;; esac
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch Calculator: $r"
sleep 2.5; chk launch1
r=$(hcall apps.launch "['$key2']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch Settings: $r"
sleep 2.5; chk launch2
[ "$(vis)" = visible=true ] && [ "$(vis2)" = visible=true ] || fail "two windows should show: Calculator $(vis), Settings $(vis2)"
f=$(front); echo "front after opening both: $f" | tee -a "$OUT/log.txt"
[ "$f" = "$PKG2" ] || fail "Settings, opened last, isn't in front ($f)"
"$T/shot.sh" "$OUT/0-two-windows.png"

tap_icon focus
f=$(front); "$T/shot.sh" "$OUT/1-focus.png"
[ "$f" = "$PKG" ] && [ "$(vis)" = visible=true ] && pass "a dock tap on Calculator (behind Settings) brought it in front" \
  || fail "a dock tap on Calculator behind Settings: front $f, $(vis)"
tap_icon minimise
c=$(calc); "$T/shot.sh" "$OUT/2-minimised.png"
[ "$c" = minimised ] && [ "$(vis)" = visible=false ] && pass "a dock tap on the focused Calculator minimised it" \
  || fail "a dock tap on the focused Calculator: $c, $(vis)"
tap_icon restore
c=$(calc); f=$(front); "$T/shot.sh" "$OUT/3-restored.png"
[ "$c" = shown ] && [ "$(vis)" = visible=true ] && [ "$f" = "$PKG" ] && pass "a dock tap on the minimised Calculator brought it back in front" \
  || fail "a dock tap on the minimised Calculator: $c, $(vis), front $f"
release_pkgs $PKG2
echo "PASS: the dock works as a taskbar - focus, minimise, restore (artefacts: $OUT)"
