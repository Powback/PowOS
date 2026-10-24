#!/bin/bash
# lanes: emu phone
# launch-paths.sh [OUT] (board desktop-mode-every-android-launch-path-opens-flo; system/AppWindows.options on every
# PowOS launch site, WindowFrames.adopt for the rest): on the unfolded home every way an Android app opens gives a
# floating window. Forces the inner screen, swipes the lock face, home's first page. Then, each time with Calculator
# stopped first: (1) home's launch call (apps.launch over CDP - what a dock, drawer or search tap makes); (2) a plain
# `am start` with no options (what another app, a system notification or a link does); (3) the task brought back from
# recents (tasks.open over CDP) after it was made full screen by the fold (cover screen, state 0, then inner again).
# PASS each = `mode=freeform` in `am stack list` and the window inside the screen, not all of it.
# Restores: Calculator stopped, home, `cmd device_state state reset`. Exit 0 pass, 1 FAIL, 3 touch, 5 can't run.
set -uo pipefail
# (These lines were missing: no here/T/A, so window_lock wasn't found and every run read "the screen is  - not woken"
# and went back on the queue as rc 3, 2026-10-23.)
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/launch-paths-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
PKG=${TEST_APP:-com.oneplus.calculator}
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { release_pkgs; sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"
window_lock launch-paths.sh 120
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
CMP=$(sh_ "cmd package resolve-activity --brief $PKG | tail -1")
case $CMP in */*) ;; *) fail "no launcher activity for $PKG ($CMP)" ;; esac
mode() { sh_ "dumpsys activity activities | grep -m1 -E \"Task\\{.*$PKG\" | grep -oE \"mode=[a-z-]+\""; }
floats() { # <path name>: Calculator is a window now
  local m b; m=$(mode); b=$(sh_ "am stack list | grep -m1 $PKG" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]')
  echo "$1: $m $b" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/$2.png"
  case $m in *freeform*) pass "$1 opens a floating window ($b)" ;; *) fail "$1 opened $m ($b), not a floating window" ;; esac
}
key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
case $key in a:$PKG/*) ;; *) fail "Calculator's key: $key" ;; esac
# (1) home's own launch (dock / drawer / search)
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 2.5; chk launch1; floats "a dock/drawer/search tap" 1-home-launch
# (2) a launch without PowOS's options
release_pkgs $PKG; sleep 1
sh_ "am start -n $CMP >/dev/null"; sleep 3; chk launch2; floats "a plain am start (another app, a notification)" 2-am-start
# (3) recents: full screen while folded, then unfolded and opened from recents
id=$(sh_ "am stack list | grep -m1 $PKG" | sed -nE 's/.*taskId=([0-9]+).*/\1/p')
[ -n "$id" ] || fail "no task id for Calculator"
sh_ "cmd device_state state 0"; sleep 3; chk fold
sh_ "cmd device_state state 3"; sleep 4; chk unfold
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2
r=$(hcall tasks.open "[$id]" "()=>'ok'"); [ "$r" = ok ] || fail "tasks.open $id: $r"
sleep 2.5; chk recents; floats "reopened from recents after a fold" 3-recents
echo "PASS: every launch path opens a floating window (artefacts: $OUT)"
