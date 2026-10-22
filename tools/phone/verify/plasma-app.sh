#!/bin/bash
# plasma-app.sh [OUT]: Plasma as a drawer app + the Linux app list from KSycoca's change signal (board task "Plasma as
# app + backend for the web launcher", slice 1; docs/DESKTOP-WEB-SHELL.md). Steps:
#   1. the session runs powos-apps-watch (inotify on ~/.cache's ksycoca6_*), idle at rest;
#   2. apps.tsv lists org.powos.plasma;
#   3. a KSycoca rebuild (kbuildsycoca6, as kded6 runs it on an app dir change, as the session user) reruns the export
#      (.icon-names renamed anew) - no file is created or changed by hand, only KService's own cache;
#   4. home's bridge apps.list has "l:org.powos.plasma" (the app re-read the list itself);
#   5. apps.launch of it (the drawer tap's call), from the web home (HomeShell), brings the Plasma desktop in front:
#      the engine's MainActivity, by its class or by its HOME alias HomeDesktop (same activity, the unfolded "auto"
#      home: MainActivity.show() resumes that instance) - and in it Plasma's own shell: plasmashell + KWin running,
#      the paused powos-shell host not.
# Always restores: home. Exit: 0 passed; 1 FAIL; 3 a real touch / not awake (re-queued); 5 keyguard with a PIN.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/plasma-app-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
KEY=l:org.powos.plasma
RUN=/data/data/com.powos.app/files/run/powos-apps
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
# As the session user (its bus): powos-run.sh. Never sudo through it.
us_() { "$A" shell "su -c \"sh /data/powos/powos-run.sh '$*'\"" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; echo "restored"; }
. "$here/window-lock.sh"
window_lock plasma-app.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}

# 1. The watcher, and that it sleeps (ticks of its processes over 5 s).
pids=$(sh_ "pgrep -f -d, \"^python3 /usr/local/bin/powos-apps-watch\"")
[ -n "$pids" ] || fail "powos-apps-watch isn't running (rooted.sh deploy, then a new session start)"
t() { sh_ "for p in ${pids//,/ }; do awk '{s+=\$14+\$15} END{print s}' /proc/\$p/stat; done" | awk '{s+=$1} END{print s}'; }
t0=$(t); sleep 5; t1=$(t)
[ $((t1 - t0)) -le 1 ] || fail "powos-apps-watch used $((t1 - t0)) ticks in 5 s at rest"
pass "watcher running ($pids), $((t1 - t0)) ticks in 5 s"

# 2. The entry.
sh_ "grep -c ^org.powos.plasma $RUN/apps.tsv" | grep -q '^1$' || fail "apps.tsv has no org.powos.plasma"
pass "apps.tsv lists Plasma"

# 3. A KSycoca rebuild -> a fresh export.
first=$(sh_ "stat -c %y $RUN/icons/.icon-names")
[ -n "$first" ] || fail "no icons/.icon-names (the export never ran)"
us_ "kbuildsycoca6 --noincremental >/dev/null 2>&1" >/dev/null
sleep 4
second=$(sh_ "stat -c %y $RUN/icons/.icon-names")
[ "$first" != "$second" ] || fail "a KSycoca rebuild didn't rerun the export (.icon-names $first)"
pass "the rebuild reran the export ($second)"

# 4. The app's list (it re-read on that rename).
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); steps 4-5 not run"; exit 3; }
r=$(hcall apps.list "[]" "l=>(l.find(a=>a.key==='$KEY')||{}).label||'ERR not in the list'")
[ "$r" = Plasma ] || fail "home's apps.list: $r"
pass "the drawer's list has Plasma"

# 5. Its launch opens the Plasma desktop.
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); W=${WH% *}; H=${WH#* }
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
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
DESK='andro\.marchy\.(MainActivity|HomeDesktop)'
# Unfolded, Home may be the desktop itself (HomeDesktop): start from the web home, or the launch proves nothing.
if sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qE "$DESK"; then
  sh_ "am start -W -n com.powos.app/andro.marchy.HomeShell >/dev/null"; sleep 2; chk webhome
fi
f=$(sh_ "dumpsys window | grep -m1 mCurrentFocus")
grep -qE "$DESK" <<<"$f" && fail "the desktop was already in front before the launch: $f"
r=$(hcall apps.launch "['$KEY']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 3; chk launch
f=$(sh_ "dumpsys window | grep -m1 mCurrentFocus")
"$T/shot.sh" "$OUT/plasma.png" >/dev/null 2>&1
grep -qE "$DESK" <<<"$f" || fail "Plasma's desktop isn't in front: $f"
sh_ "pgrep -x plasmashell" | grep -q . || fail "the desktop is in front but plasmashell isn't running"
sh_ "pgrep -x kwin_wayland" | grep -q . || fail "the desktop is in front but KWin isn't running"
sh_ "pgrep -x powos-shell" | grep -q . && fail "the paused powos-shell host is running (not Plasma's own shell)"
pass "Plasma opened from the drawer's launch: ${f##*/} with plasmashell + KWin ($OUT/plasma.png)"
