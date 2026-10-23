#!/bin/bash
# linux-session.sh [OUT] (board linux-stale-window-tasks; Mac side, queue it): Linux apps open again after a session
# restart. KWin's window ids restart at 1 with each KWin while Android kept the old window tasks, so a launcher tap on
# Kate "restored" the old session's dead Kate task and nothing opened (2026-10-23: tasks 2678, 2679; "no window task in
# 30 s"). kwin 0023 (3.27) sends "session <uuid> <ids>", the app finishes every other window task.
#   1. KWin 3.27+ installed (the newest built kwin pkg, as linux-float.sh) and Kate opened through home's launch call
#      (apps.launch l:org.kde.kate) on the running session: its task is the OLD one;
#   2. a fresh session (`android-request power logout`, as linux-float.sh) - the restart that left the stale tasks;
#   3. the app heard the new session (logcat WindowTasks "KWin session") and the old Kate task is gone (am stack list,
#      recents);
#   4. Kate from the launcher again: a NEW window task within 30 s, windows.list names it, and a tap + keys change its
#      window (linux-touch.sh's test).
# Kate must not be running before (the user's: exit 3). Ours is closed at the end, home in front.
# Exit: 0 passed; 1 FAIL; 3 a real touch / no free window / not now (re-queued); 5 can't run.
#   KWIN_PKG=<pkg.tar.xz> (default: the newest targets/android/out/pkgs/kwin-*.pkg.tar.xz here or in a sibling worktree)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; ROOT=$(cd "$T/../.." && pwd)
OUT=${1:-$HOME/.cache/powos-verify/linux-session-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
PKG=${KWIN_PKG:-$(ls -t "$ROOT"/targets/android/out/pkgs/kwin-*.pkg.tar.xz "$ROOT"/../*/targets/android/out/pkgs/kwin-*.pkg.tar.xz 2>/dev/null | head -1)}
WANT=$(basename "${PKG:-none}" | sed -E 's/^kwin-([^-]+-[^-]+)-.*/\1/')
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
rs() { printf '%s\n' "$1" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
MINE=0
restore() {
  [ $MINE = 1 ] && us "pkill -x kate; true"
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  sh_ "logcat -d -v time" | grep -E "WindowTasks|PowosWindow" > "$OUT/logcat.txt"
  echo "restored; files in $OUT"
}
. "$here/window-lock.sh"
window_lock linux-session.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
hcall() {  # home's bridge call exactly as the page makes it (linux-float.sh's)
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=911300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
lin() { sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | tr -dc '0-9\n' | sort -n; }
tbounds() { sh_ "am stack list | grep -E \"taskId=$1[^0-9]\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }
app_of() { hcall windows.list "[]" "l=>(l.find(w=>w.id===$1)||{app:'none'}).app||'none'"; }
new_task() { local n="" i; for i in $(seq 1 "$1"); do sleep 1; n=$(comm -13 <(echo "$2") <(lin) | tail -1); [ -n "$n" ] && break; done; echo "$n"; }
# Recents' window tasks: "<taskId> <data>" (dumpsys activity recents: a "* Recent #n: Task{.. #<id>" block's unredacted
# "intent={dat=powos-window://<id>?session=.." line; the "Visible recent tasks" part redacts it to "/...").
recents() { sh_ "dumpsys activity recents" | awk '/\* Recent #/{t=$0; sub(/.*#[0-9]+: Task\{[^ ]* #/,"",t); sub(/ .*/,"",t)} / intent=\{dat=powos-window:/ {d=$0; sub(/.*intent=\{dat=/,"",d); sub(/ .*/,"",d); print t, d}' | sort -u; }
kw() { rs 'k=$(pgrep -x kwin_wayland | head -1); n=0; [ -n "$k" ] && ! grep -q "libkwin.*(deleted)" /proc/$k/maps && n=1; echo "kwin=${k:--} kwin_new=$n"' | tail -1; }
# md5 of the region "L T R B" of the ON display's screencap (linux-touch.sh's rhash).
rhash() {
  sh_ "screencap -d ${DID:-0} /data/powos/root/var/tmp/linux-session.raw" >/dev/null
  printf '%s\n' "python3 - /var/tmp/linux-session.raw $1 $2 $3 $4 <<'PY' 2>/dev/null || echo none
import hashlib, struct, sys
f = sys.argv[1]; l, t, r, b = map(int, sys.argv[2:6]); d = open(f, 'rb').read(); w, h = struct.unpack('<II', d[:8])
off = len(d) - w * h * 4; m = hashlib.md5()
for y in range(max(t, 0), min(b, h), 4):
    row = off + y * w * 4
    m.update(d[row + max(l, 0) * 4: row + min(r, w) * 4: 16])
print(m.hexdigest()[:12])
PY
rm -f /var/tmp/linux-session.raw" > "$OUT/h.sh"; "$T/root.sh" "$OUT/h.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r' | tail -1
}
home() {
  sh_ "cmd device_state state 3"; sleep 2
  if sh_ "dumpsys window policy | grep -m1 mIsShowing=" | grep -q true; then sh_ "wm dismiss-keyguard"; sleep 1.5; fi
  sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk "$1"
}

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ -z "$(us 'pgrep -x kate' | tail -1)" ] || { echo "kate already runs (maybe the user's): not now"; exit 3; }
[ "$(us "pgrep -fc 'SteamLaunch AppId='" | tail -1)" = 0 ] || { echo "a game runs under Steam (the user's): not now"; exit 3; }
log "apk $(sh_ "dumpsys package com.powos.app | grep -m1 versionCode" | sed 's/^ *//')"

# 1. KWin 3.27+ installed (rollback tar of the old files, as linux-float.sh).
have=$(rs 'pacman -Q kwin | cut -d" " -f2' | tail -1)
log "kwin installed $have, package $WANT (${PKG:-none})"
if [ -n "${PKG:-}" ] && [ "$have" != "$WANT" ] && [ "$(printf '%s\n%s\n' "$have" "$WANT" | sort -V | tail -1)" = "$WANT" ]; then
  "$A" push "$PKG" /data/local/tmp/powos-kwin.pkg.tar.xz >/dev/null
  sh_ "mv /data/local/tmp/powos-kwin.pkg.tar.xz /data/powos/root/var/tmp/"
  rs "set -e; mkdir -p /var/cache/powos
pacman -Qlq kwin | while read -r f; do [ -f \"\$f\" ] && echo \"\$f\"; done | tar -cf /var/cache/powos/kwin-$have-files.tar -T -
pacman -U --noconfirm /var/tmp/powos-kwin.pkg.tar.xz >/dev/null && rm -f /var/tmp/powos-kwin.pkg.tar.xz
pacman -Q kwin" | tail -1 | tee -a "$OUT/log.txt"
fi
[ "$(rs 'grep -ac "export-new fullscreen session" /usr/lib/libkwin.so.6 2>/dev/null' | tail -1)" != 0 ] ||
  fail "the installed KWin has no \"session\" (pkgs/kwin 0023, 3.27)"
DID=$(sh_ "dumpsys display" | sed -nE 's/.*uniqueId="local:([0-9]+)".* state ON,.*/\1/p' | head -1)

# An old-session Kate task: Kate through the launcher on the running KWin (when it's up; an old KWin's task is the
# bug's case exactly).
home "before"
st=$(kw); log "running before the restart: $st"
before=$(lin); MINE=1
log "launch Kate on the old session: $(hcall apps.launch "['l:org.kde.kate']" "()=>'ok'")"
OLD=$(new_task 30 "$before"); chk "old kate"
log "old session's Kate task: ${OLD:-none} (window tasks before: $(echo $before))"
log "recents' window tasks before: $(recents | tr '\n' ';')"

# 2. A fresh session.
sh_ "logcat -c"
log "fresh session (android-request power logout)"
us "android-request power logout"; sleep 20
k0=${st#kwin=}; k0=${k0%% *}
for _ in $(seq 30); do st=$(kw); k=${st#kwin=}; k=${k%% *}; [[ $st == *kwin_new=1* ]] && [ "$k" != "$k0" ] && [ "$k" != - ] && break; sleep 5; done
log "after the restart: $st (was kwin=$k0)"
[[ $st == *kwin_new=1* ]] && [ "$k" != "$k0" ] || fail "KWin didn't come back as a new process on the new package (rollback: tar -xf /var/cache/powos/kwin-$have-files.tar -C /)"
MINE=0
SES=""; for _ in $(seq 30); do SES=$(sh_ "logcat -d -s WindowTasks" | sed -nE 's/.*KWin session ([0-9a-f-]+),.*/\1/p' | tail -1); [ -n "$SES" ] && break; sleep 2; done
caps=$(sh_ "logcat -d -s WindowTasks" | grep "KWin caps:" | tail -1)
log "app: ${caps:-no caps line}; session ${SES:-none}"
if [ -z "$SES" ]; then
  [[ $caps == *session* ]] && { echo "the installed APK doesn't know KWin sessions yet (no \"KWin session\" line): not now"; exit 3; }
  fail "the app heard no KWin session (caps: ${caps:-none})"
fi
pass "the app heard the new KWin session $SES"

# 3. The old session's tasks are gone.
sleep 3
left=$(lin); rec=$(recents)
log "window tasks now: $(echo $left); recents: $(echo "$rec" | tr '\n' ';')"
log "finished: $(sh_ "logcat -d -s WindowTasks PowosWindow" | grep -E "not this KWin|not the running KWin|earlier KWin" | tr '\n' '|' | cut -c1-600)"
[ -z "$OLD" ] || ! grep -qx "$OLD" <<<"$left" || fail "the old session's Kate task $OLD is still there"
stale=$(awk -v s="$SES" '$2 !~ ("session=" s)' <<<"$rec" | grep . || true)
[ -z "$stale" ] || fail "window tasks of an earlier session are still in recents: $(echo "$stale" | tr '\n' ';')"
pass "no window task of an earlier session is left (old Kate task ${OLD:-none})"

# 4. Kate from the launcher: a new, live window task that takes a tap.
home "after"
before=$(lin); MINE=1
r=$(hcall apps.launch "['l:org.kde.kate']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch l:org.kde.kate: $r"
KT=$(new_task 30 "$before"); chk "new kate"
[ -n "$KT" ] || fail "no window task for Kate within 30 s (logcat: $(sh_ "logcat -d -v time" | grep -E "WindowTasks| runtime" | tail -3 | tr '\n' ' '))"
[ "$KT" != "${OLD:-x}" ] || fail "Kate came back in the old task $KT"
sleep 5
[ "$(app_of "$KT")" = l:org.kde.kate ] || fail "Kate's task $KT is '$(app_of "$KT")' in windows.list"
grep -q "$KT" <<<"$(awk -v s="$SES" '$2 ~ ("session=" s) {print $1}' <<<"$(recents)")" || log "note: task $KT's data not seen with session=$SES in recents"
pass "Kate from the launcher opened a new window task $KT, windows.list names it"
read -r l t r b <<<"$(tbounds "$KT")"
"$T/shot.sh" "$OUT/kate-before.png" >/dev/null 2>&1
x=$(( (l + r) / 2 )); y=$(( (t + b) / 2 ))
h1=$(rhash "$l" "$((t + 80))" "$r" "$b")
sh_ "input tap $x $y"; sleep 1.5; sh_ "input text powossessiontest"; sleep 2; chk "kate tap"
h2=$(rhash "$l" "$((t + 80))" "$r" "$b")
"$T/shot.sh" "$OUT/kate-after.png" >/dev/null 2>&1
log "Kate's window (task $KT, $l,$t $r,$b): $h1 -> tap + keys $h2"
[ "$h2" != "$h1" ] && [ "$h2" != none ] || fail "a tap + keys changed nothing in Kate's new window"
pass "Kate's new window takes a tap and keys"
