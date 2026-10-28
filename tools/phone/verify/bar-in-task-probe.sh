#!/bin/bash
# lanes: phone emu
# bar-in-task-probe.sh [OUT]: feasibility of title bars IN the task's own layer (system/TaskBarProbe.kt; board task
# floating-window-title-bars-z-ordered-with-their). Same setup as window-chrome.sh (unfold, lock face, Calculator
# floating through home's launch path), with `settings put global powos_bar_in_task 1`, then:
#   1. a slow drag of the (overlay) title bar starts a TaskLeash session; logcat PowosTaskBar "bar attached";
#   2. SurfaceFlinger's layer tree: a layer of the PowOS app's uid DIRECTLY under Task=N (sibling of SystemUI's
#      "Decor container of Task=N"), i.e. in the task's own layer, after the transition ended;
#   3. a tap at the probe strip (inside the task's top 18 dp) reaches it: logcat "touch at".
# Always restores: the flag back to 0, Calculator stopped, home, `cmd device_state state reset`.
# Exit: 0 all passed; 1 a step failed; 3 a real touch / screen not awake; 5 can't run.
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/barprobe-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
PKG=${TEST_APP:-com.oneplus.calculator}
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ 'settings put global powos_bar_in_task 0'; [ "${TOUCHED:-0}" = 1 ] || return 0; release_pkgs; sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"
window_lock bar-in-task-probe.sh 120
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
claim_pkg $PKG
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
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; logcat -c"; sleep 2; chk home
key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
case $key in a:$PKG/*) ;; *) fail "Calculator's key from home's apps.list: $key" ;; esac
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 3; chk launch

# 1. The bar: its window's height, its frost.
D=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1); px() { echo $(( $1 * D / 160 )); }

sh_ "settings put global powos_bar_in_task 1; logcat -c"
D=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1); px() { echo $(( $1 * D / 160 )); }
read -r BL BT BR BB <<<"$(wframe 'PowOS window bar')"
[ -n "${BB:-}" ] || fail "no title bar window"
BID=$(sh_ "dumpsys window windows" | grep -m1 -oE "PowOS window bar [0-9]+" | grep -oE "[0-9]+$")
[ -n "$BID" ] || fail "no task id from the bar's window title"
# 1. A slow bar drag: a TaskLeash session (the probe attaches when its leashes come).
X=$(((BL + BR) / 2)); Y=$(((BT + BB) / 2))
sh_ "input swipe $X $Y $((X + $(px 60))) $((Y + $(px 40))) 1500"; sleep 2.5; chk drag
sh_ "logcat -d -s PowosTaskBar:I PowosTaskLeash:I" | tee -a "$OUT/log.txt" > "$OUT/logcat.txt"
grep -q "task $BID: bar attached" "$OUT/logcat.txt" && pass "probe attached under task $BID's leash" || fail "no 'bar attached' for task $BID (logcat.txt; did a TaskLeash session start?)"
# 2. The layer tree: a direct child of Task=N owned by PowOS's uid.
PUID=$(sh_ "dumpsys package com.powos.app" | grep -m1 -oE "userId=[0-9]+" | grep -oE "[0-9]+")
# Box-drawing characters to ASCII first: the tree depth is counted in columns (BSD awk counts bytes).
sh_ "dumpsys SurfaceFlinger" | sed -e "s/│/|/g; s/├/+/g; s/└/+/g; s/─/-/g" > "$OUT/sf.txt"
awk -v t="Task=$BID#" 'index($0,t)&&/- Task=/{p=index($0,"Task=");on=1;print;next} on{q=match($0,/[^ |+-]/); if(q<=p)exit; print}' "$OUT/sf.txt" > "$OUT/task-tree.txt"
cat "$OUT/task-tree.txt" | tee -a "$OUT/log.txt"
TD=$(head -1 "$OUT/task-tree.txt" | awk '{print index($0,"Task=")}')
CH=$(awk -v d="$TD" -v u="uid=$PUID" 'NR>1{q=match($0,/[^ |+-]/); if(q==d+3 && index($0,u)) print}' "$OUT/task-tree.txt")
[ -n "$CH" ] && pass "a PowOS-owned layer is a direct child of Task=$BID: $CH" || fail "no direct child of Task=$BID with uid $PUID (task-tree.txt)"
# 3. Input: a tap in the strip (task top + 9 dp).
read -r AL AT AR AB <<<"$(wframe "$PKG")"
sh_ "input tap $(((AL + AR) / 2)) $((AT + $(px 9)))"; sleep 1; chk tap
sh_ "logcat -d -s PowosTaskBar:I" | grep -m1 "task $BID: touch at" | tee -a "$OUT/log.txt" | grep -q . && pass "the strip in the task's layer gets touches" || fail "no touch reached the probe strip"
"$T/shot.sh" "$OUT/probe.png" >/dev/null 2>&1
echo "ALL PASS" | tee -a "$OUT/log.txt"
