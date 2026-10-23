#!/bin/bash
# linux-touch.sh [OUT] (board linux-windows-take-no-taps-kate-dolphin-steam-kd; Mac side, queue it): where a real tap
# inside a Linux window goes, for Kate and Dolphin (never Steam), each opened through home's launch call (apps.launch):
#   tap:   `input motionevent DOWN` in the window's content, then `dumpsys input` TouchStatesByDisplay (which windows
#          the finger went to, pilferingPointerIds), UP.
#   kate:  + `input text` -> the window's pixels or its caption change (a typed character).
#   dolphin: a tap in its places panel -> the window's pixels change.
#   logs:  logcat PowosWindowActivity/WindowTasks/PowosTaskLeash/PowosWindowFrames + KWin's new anland lines, per round.
# LEASH=both (default) runs every round with powos_live_leash as it is AND with 0 (restored after); LEASH=asis only.
# Kate/Dolphin must not be running already (the user's: exit 3). Ours are closed (pkill), home at the end.
# Exit: 0 pass; 1 FAIL; 3 a real touch / not now; 5 can't run. Files: OUT/<round>-<app>-{before,after}.png, OUT/*.txt
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/linux-touch-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
RC=0; KL0=0; LEASH0=""; MINE=""; REC=""
recstop() { [ -n "$REC" ] || return 0; sh_ "pkill -INT screenrecord"; sleep 2
  sh_ "chmod 644 /data/local/tmp/linux-touch-$REC.mp4"
  "$A" pull "/data/local/tmp/linux-touch-$REC.mp4" "$OUT/$REC.mp4" >/dev/null 2>&1; sh_ "rm -f /data/local/tmp/linux-touch-$REC.mp4"; REC=""; }
rec() { recstop; REC=$1; "$A" shell "su -c 'screenrecord --time-limit 120 --bit-rate 6000000 /data/local/tmp/linux-touch-$1.mp4 >/dev/null 2>&1 &'" >/dev/null 2>&1; sleep 1; }
restore() {
  recstop
  [ -n "$MINE" ] && us "pkill -x kate; pkill -x dolphin; true"
  [ -n "$LEASH0" ] && { [ "$LEASH0" = null ] && sh_ "settings delete global powos_live_leash" || sh_ "settings put global powos_live_leash $LEASH0"; }
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  echo "restored (leash ${LEASH0:-unchanged}); files in $OUT"
}
. "$here/window-lock.sh"
window_lock linux-touch.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL $*" | tee -a "$OUT/log.txt"; RC=1; }
pass() { echo "PASS $*" | tee -a "$OUT/log.txt"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910900+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',$2]))}).then(v=>($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
tasks() { sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | tr -dc '0-9\n' | sort -n; }
tbounds() { sh_ "am stack list | grep -E \"taskId=$1[^0-9]\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }
# md5 of the region "L T R B" of the ON display's screencap (every 4th pixel).
rhash() {
  sh_ "screencap -d ${DID:-0} /data/powos/root/var/tmp/linux-touch.raw" >/dev/null
  printf '%s\n' "python3 - /var/tmp/linux-touch.raw $1 $2 $3 $4 <<'PY' 2>/dev/null || echo none
import hashlib, struct, sys
f = sys.argv[1]; l, t, r, b = map(int, sys.argv[2:6]); d = open(f, 'rb').read(); w, h = struct.unpack('<II', d[:8])
off = len(d) - w * h * 4; m = hashlib.md5()
for y in range(max(t, 0), min(b, h), 4):
    row = off + y * w * 4
    m.update(d[row + max(l, 0) * 4: row + min(r, w) * 4: 16])
print(m.hexdigest()[:12])
PY
rm -f /var/tmp/linux-touch.raw" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r' | tail -1
}
touched() {  # DOWN at $1 $2, the touch state while it is down, UP
  sh_ "input motionevent DOWN $1 $2"; sleep 0.4
  sh_ "dumpsys input" | awk '/TouchStatesByDisplay/{p=1} p&&/Display: /{if(n++)exit} p' | grep -E "Windows|name=|pilfering|deviceId|Display" | sed 's/^ *//' | cut -c1-200 | head -12
  sh_ "input motionevent UP $1 $2"
}

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
run=$(us "pgrep -x kate; pgrep -x dolphin" | tail -2)
[ -z "$run" ] || { echo "kate or dolphin already runs (the user's: never closed): not now"; exit 3; }
[ "$(us "pgrep -fc 'SteamLaunch AppId='" | tail -1)" = 0 ] || { echo "a game runs under Steam (the user's): not now"; exit 3; }
sh_ "cmd device_state state 3"; sleep 3; chk unfold
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); W=${WH% *}
[ "${W:-0}" -gt 2000 ] || { echo "display is ${WH:-?}, not the unfolded inner screen"; exit 5; }
if sh_ "dumpsys window policy | grep -m1 mIsShowing=" | grep -q true; then sh_ "wm dismiss-keyguard"; sleep 1.5; fi
DID=$(sh_ "dumpsys display" | sed -nE 's/.*uniqueId="local:([0-9]+)".* state ON,.*/\1/p' | head -1)
LEASH0=$(sh_ "settings get global powos_live_leash"); LEASH0=${LEASH0:-null}
log "apk $(sh_ "dumpsys package com.powos.app | grep -m1 versionName" | sed 's/ *//'), kwin $(us 'pacman -Q kwin' | tail -1), powos_live_leash=$LEASH0"

round() {  # $1 = round name, $2 = app key, $3 = process name
  local R=$1 key=$2 proc=$3 before KT l t r b h0 h1 h2 x y t0
  sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk "$R home"
  KL0=$(us "grep -a -c . /run/powos-app/hyprland.log" | tail -1); KL0=${KL0:-0}
  t0=$(sh_ "date +\"%m-%d %H:%M:%S.000\"")
  rec "$R-$proc"; before=$(tasks); MINE=1
  log "[$R/$proc] launch: $(hcall apps.launch "['$key']" "v=>'ok '+JSON.stringify(v)")"
  KT=""; for _ in $(seq 30); do sleep 1; KT=$(comm -13 <(echo "$before") <(tasks) | tail -1); [ -n "$KT" ] && break; done; chk "$R launch"
  if [ -z "$KT" ]; then fail "[$R/$proc] no window task in 30 s"; us "pkill -x $proc; true"; recstop; return; fi
  sleep 5; read -r l t r b <<<"$(tbounds "$KT")"
  log "[$R/$proc] task $KT bounds $l $t $r $b, focus: $(sh_ "dumpsys window | grep -m1 mCurrentFocus" | sed 's/^ *//')"
  "$T/shot.sh" "$OUT/$R-$proc-before.png" >/dev/null 2>&1
  h0=$(rhash "$l" "$((t + 80))" "$r" "$b")
  if [ "$proc" = kate ]; then x=$(( (l + r) / 2 )); y=$(( (t + b) / 2 )); else x=$(( l + (r - l) / 10 )); y=$(( t + (b - t) * 45 / 100 )); fi
  log "[$R/$proc] DOWN at $x,$y; touch state:"; touched "$x" "$y" | sed 's/^/    /' | tee -a "$OUT/log.txt"
  sleep 1.5; h1=$(rhash "$l" "$((t + 80))" "$r" "$b")
  if [ "$proc" = kate ]; then sh_ "input text powostaptest"; sleep 2; fi
  chk "$R tap"; h2=$(rhash "$l" "$((t + 80))" "$r" "$b")
  "$T/shot.sh" "$OUT/$R-$proc-after.png" >/dev/null 2>&1
  log "[$R/$proc] window pixels: $h0 -> tap $h1 -> ${proc/dolphin/(no keys)} $h2"
  sh_ "logcat -d -T \"$t0\" -s PowosWindowActivity WindowTasks PowosTaskLeash PowosWindowFrames PowosWindowFrame InputDispatcher" > "$OUT/$R-$proc-logcat.txt"
  us "tail -n +$((KL0 + 1)) /run/powos-app/hyprland.log | grep -a kwin_backend_anland" > "$OUT/$R-$proc-kwin.txt"
  log "[$R/$proc] logcat (last 8):"; grep -v "^-" "$OUT/$R-$proc-logcat.txt" | tail -8 | cut -c1-220 | sed 's/^/    /' | tee -a "$OUT/log.txt"
  log "[$R/$proc] kwin (last 8):"; tail -8 "$OUT/$R-$proc-kwin.txt" | cut -c1-220 | sed 's/^/    /' | tee -a "$OUT/log.txt"
  if [ "$proc" = kate ]; then
    [ "$h2" != "$h1" ] && [ "$h2" != none ] && pass "[$R/kate] a tap + keys changed Kate's window" || fail "[$R/kate] a tap + keys changed nothing in Kate's window"
  else
    [ "$h1" != "$h0" ] && [ "$h1" != none ] && pass "[$R/dolphin] a tap in the places panel changed Dolphin's window" || fail "[$R/dolphin] a tap changed nothing in Dolphin's window"
  fi
  us "pkill -x $proc; true"; sleep 2; recstop
}

round asis org.kde.kate kate
round asis org.kde.dolphin dolphin
if [ "${LEASH:-both}" = both ]; then
  sh_ "settings put global powos_live_leash 0"; log "powos_live_leash -> 0"
  round leash0 org.kde.kate kate
  round leash0 org.kde.dolphin dolphin
fi
exit $RC
