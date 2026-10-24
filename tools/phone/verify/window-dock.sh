#!/bin/bash
# window-dock.sh [OUT] (board floating-window-never-covers-dock; system/WindowFrame.kt moved): a floating window
# dragged down by its title bar stops above home's bottom bar (the dock), so the dock stays tappable. Unfolds (cmd
# device_state state 3), swipes the lock face, opens Calculator through home's launch call (as window-chrome.sh), then
# drags its bar (left quarter, clear of the buttons) to the bottom of the screen with an injected swipe. PASS when the
# app's window (dumpsys window frame) ends at or above the dock's top (home's page: .home > .dock/.bar, device px) and
# the dock's centre lies in no window of the app. Restores: Calculator stopped, home, `cmd device_state state reset`.
# Exit: 0 pass; 1 FAIL: ...; 3 a real touch / no free window / screen not awake; 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/window-dock-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
PKG=${TEST_APP:-com.oneplus.calculator}
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { [ "${TOUCHED:-0}" = 1 ] || return 0; release_pkgs; sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"
window_lock window-dock.sh 120
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
[ "${W:-0}" -gt 2000 ] || { echo "ENV: display 0 is ${W:-?}x${H:-?}, not the inner screen - stopping before any input"; exit 5; }
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "ENV: the keyguard didn't go (a PIN?) - stopping"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock" && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
chk lock
claim_pkg $PKG
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; logcat -c"; sleep 2; chk home
key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
case $key in a:$PKG/*) ;; *) fail "Calculator's key from home's apps.list: $key" ;; esac
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 3; chk launch

# The dock's top and centre on home's page, device px.
dock=$("$T/cdp.sh" eval home "(()=>{let b=null;for(const e of document.querySelectorAll('.home > .dock, .home > .bar, .home > .bottom-bar')){const r=e.getBoundingClientRect();if(r.height>0&&(!b||r.top<b.top))b=r}return b?[b.top,b.left+b.width/2,b.top+b.height/2].map(v=>Math.round(v*devicePixelRatio)).join(' '):'none'})()" 2>&1 | tr -d '"\r' | tail -1)
read -r DT DX DY <<<"$dock"
[ -n "${DY:-}" ] || fail "no dock on home's page ($dock)"
echo "dock: top $DT px, centre $DX,$DY" | tee -a "$OUT/log.txt"
read -r BL BT BR BB <<<"$(wframe 'PowOS window bar')"
[ -n "${BB:-}" ] || fail "no title bar window"
read -r AL AT AR AB <<<"$(wframe "$PKG")"
[ -n "${AB:-}" ] || fail "no window of $PKG"
echo "before: bar $BL $BT $BR $BB, app $AL $AT $AR $AB" | tee -a "$OUT/log.txt"
SX=$((BL + (BR - BL) / 4)); SY=$(((BT + BB) / 2))
sh_ "input swipe $SX $SY $SX $((H - 4)) 1500"; sleep 2; chk drag
read -r EL ET ER EB <<<"$(wframe "$PKG")"
echo "after the drag down: app $EL $ET $ER $EB" | tee -a "$OUT/log.txt"
"$T/shot.sh" "$OUT/after-drag.png" >/dev/null 2>&1
[ "${ET:-0}" -gt "$AT" ] || fail "the drag didn't move the window down ($AT -> ${ET:-?})"
[ "$EB" -le "$DT" ] && pass "the window stops above the dock: its bottom $EB px <= the dock's top $DT px" ||
  fail "the window covers the dock: its bottom $EB px > the dock's top $DT px"
[ "$DX" -ge "$EL" ] && [ "$DX" -lt "$ER" ] && [ "$DY" -ge "$ET" ] && [ "$DY" -lt "$EB" ] && fail "the dock's centre $DX,$DY is inside the window"
pass "the dock's centre $DX,$DY is in no window of $PKG"
echo "all passed; artefacts: $OUT"
