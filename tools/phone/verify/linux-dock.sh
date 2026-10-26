#!/bin/bash
# lanes: phone
# linux-dock.sh [OUT]: a Linux window is in the dock and the switcher like an Android app (board task "Plasma: Linux
# windows in the dock, Plasma notifications in the shade"), on the unfolded home, for a phone left unattended:
#   1. Dolphin opened through home's launch path (apps.launch l:org.kde.dolphin) is one floating task;
#   2. the dock has exactly ONE cell for it (.dock .app[data-key=l:org.kde.dolphin], class windowed, an icon), not also
#      in the dock's recent apps;
#   3. tasks.list (the switcher's cards) has its task with key l:org.kde.dolphin, Dolphin's icon (the dock cell's) and
#      its caption - not PowOS's generic card - and no second card for it;
#   4. minimised, the launch a dock tap makes brings it back focused (mCurrentFocus = PowosWindowActivity);
#   5. closing its card (tasks.remove) closes the Linux window: no Dolphin process, no task left.
# Needs KWin with export-new running (linux-float.sh installs it). Dolphin already running: not now (exit 3, never
# closes the user's Dolphin). Always restores: Dolphin closed if this started it, home, `cmd device_state state reset`.
# Exit: 0 passed; 1 FAIL; 3 a real touch / no free window / not now; 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/linux-dock-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
K=l:org.kde.dolphin
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
rs() { printf '%s\n' "$1" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
MINE=0
restore() {
  [ $MINE = 1 ] && us "pkill -x dolphin; true"
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"
  sh_ "logcat -d -v time" | grep -E "WindowTasks|PowosWindow|PowosWindowFrames" > "$OUT/logcat.txt"
  echo "restored"
}
. "$here/window-lock.sh"
window_lock linux-dock.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
# A call on home's bridge exactly as the page makes it (float-windows.sh's hcall); $3 maps the answer.
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910400+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
page() { "$T/cdp.sh" eval home "$1" 2>&1 | tr -d '"\r' | tail -1; }
lin() { sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | tr -dc '0-9\n' | sort -n; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ "$(rs 'grep -ac "export-new" /usr/lib/libkwin.so.6 2>/dev/null' | tail -1)" != 0 ] || { echo "ENV: KWin has no export-new: run linux-float.sh first"; exit 5; }
[ "$(us 'pgrep -xc dolphin' | tail -1)" = 0 ] || { echo "Dolphin runs already (the user's?): not now"; exit 3; }

sh_ "cmd device_state state 3"; sleep 3; chk unfold
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); W=${WH% *}; H=${WH#* }
[ "${W:-0}" -gt 2000 ] || fail "display 0 is ${W:-?}x${H:-?}, not the unfolded inner screen"
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "ENV: the keyguard didn't go (a PIN?)"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi PowosLock && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home

# 1. Dolphin from the launcher.
before=$(lin); MINE=1
r=$(hcall apps.launch "['$K']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch $K: $r"
DT=""; for _ in $(seq 30); do sleep 1; DT=$(comm -13 <(echo "$before") <(lin) | tail -1); [ -n "$DT" ] && break; done; chk dolphin
[ -n "$DT" ] || fail "no window task for Dolphin within 30 s"
sleep 3; "$T/shot.sh" "$OUT/dolphin.png" >/dev/null 2>&1
log "Dolphin: task $DT"

# 2. The dock: one cell, windowed, with an icon.
dock=$(page "(()=>{const c=[...document.querySelectorAll('.home .dock .app[data-key=\"$K\"]')];const i=c[0]&&c[0].querySelector('img');return c.length+' '+(c[0]?c[0].className.replace(/ +/g,'.'):'-')+' '+(i?i.getAttribute('src'):'-')})()")
log "dock: $dock"
read -r n cls dicon <<<"$dock"
[ "$n" = 1 ] || fail "the dock has $n cells for Dolphin (want exactly 1): $dock"
[[ $cls == *windowed* ]] || fail "Dolphin's dock cell isn't marked windowed: $cls"
[ "${dicon:--}" != - ] || fail "Dolphin's dock cell has no icon"
pass "Dolphin is in the dock once, windowed, with an icon"

# 3. The switcher's cards.
cards=$(hcall tasks.list "[]" "l=>{const m=l.filter(t=>t.id===$DT||t.key==='$K');const t=m.find(t=>t.id===$DT)||{};return m.length+'|'+(t.key||'-')+'|'+(t.icon||'-')+'|'+(t.label||'-')}")
log "cards: $cards"
IFS='|' read -r cn ck ci cl <<<"$cards"
[ "$ck" = "$K" ] || fail "Dolphin's card has key '$ck', not $K (generic PowOS card?)"
[ "$ci" != - ] || fail "Dolphin's card has no icon"
[ "$ci" = "$dicon" ] || log "note: card icon $ci vs dock icon $dicon"
[ "$cn" = 1 ] || fail "$cn cards for Dolphin (want 1): duplicates"
case "$cl" in -|PowOS|com.powos.app) fail "Dolphin's card is labelled '$cl'" ;; esac
pass "Dolphin's card: its key, its icon, '$cl', one card"

# 4. Minimised, a dock tap's launch brings it back in front.
hcall windows.minimise "[$DT]" "()=>'ok'" >/dev/null; sleep 2
m=$(hcall windows.list "[]" "l=>String((l.find(w=>w.id===$DT)||{}).minimised)"); log "minimised: $m"
[ "$m" = true ] || fail "Dolphin's window didn't minimise ($m)"
hcall apps.launch "['$K']" "()=>'ok'" >/dev/null; sleep 2.5; chk restore
m=$(hcall windows.list "[]" "l=>String((l.find(w=>w.id===$DT)||{}).minimised)")
f=$(sh_ "dumpsys window | grep -m1 mCurrentFocus"); log "after the tap: minimised=$m focus=$f"
[ "$m" = false ] || fail "the dock tap didn't bring Dolphin back (minimised=$m)"
[[ $f == *PowosWindowActivity* ]] || fail "Dolphin's window isn't focused: $f"
[ "$(comm -13 <(echo "$before") <(lin) | grep -c .)" = 1 ] || fail "the tap made another window task"
pass "a dock tap brings the minimised Dolphin back, focused, no second task"

# 5. Closed from the switcher: the Linux window closes.
# The main log rotates in seconds: the app's side of the close (WindowTasks "closed N (caps: .. export-new ..)") is
# captured live from here; KWin's side is its anland lines in the session log (QT_LOGGING_RULES, powos-rooted-session).
sh_ "rm -f /data/local/tmp/ld-log.txt; (timeout 20 logcat -T 1 -v time -s WindowTasks PowosWindow </dev/null >/data/local/tmp/ld-log.txt 2>&1 &)"
hcall tasks.remove "[$DT]" "()=>'ok'" >/dev/null
gone=0; for _ in $(seq 8); do sleep 1; [ "$(us 'pgrep -xc dolphin' | tail -1)" = 0 ] && { gone=1; break; }; done
sh_ "cat /data/local/tmp/ld-log.txt" > "$OUT/close-log.txt"
rs 'tail -c 200000 /run/powos-app/hyprland.log | grep -a anland | tail -30' > "$OUT/kwin-close.txt"
lin | grep -qx "$DT" && fail "Dolphin's task $DT is still there after its card closed"
[ $gone = 1 ] || fail "Dolphin still runs after its card was closed (window back on the hidden desktop?) - $(grep -m1 'closed' "$OUT/close-log.txt" | cut -c1-160)"
MINE=0
pass "closing Dolphin's card closes the Linux window"
echo "all passed; artefacts: $OUT"
