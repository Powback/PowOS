#!/bin/bash
# steam-tap.sh [OUT] (board tapping-steam-shows-its-window-resident-steam-ru; Mac side, queue it with --budget 900):
# a tap on Steam's own launcher entry SHOWS Steam's main window, from cold and from a resident (-silent) Steam, and
# taps inside the floating Steam window reach it. On the unfolded home, recorded (screenrecord per phase, OUT/*.mp4):
#   cold:     no Steam running (closed first; a game under Steam = not now) -> a real tap on the dock's Steam cell (else
#             home's launch call, as a tap) -> X window "Steam" (steamwebhelper/steam) viewable, a PowosWindowActivity
#             task in focus, the task's part of the screen not black. "TIME cold <ms>" = tap -> all of that.
#   resident: Steam closed, started exactly as powos-steam-resident does (`steam -silent`), up 30 s, no Steam window
#             viewable -> the same tap -> the same assertions. "TIME resident <ms>".
#   touch:    a real tap on Steam's LIBRARY tab (X window point 427,103 - its tab row, Steam's UI at scale 1): the
#             window's URL row (store.steampowered.com on the Store) changes. Else the same point as an X click
#             (xdotool, the app's own input) tells KWin's touch path from the app; then the tap again with
#             `settings put global powos_live_leash 0` (the TaskLeash bisect; put back after).
#   kate:     Kate through home's launch call, a real tap in its window's middle, `input text` -> its part of the
#             screen changed (the tap focused it, the keys went in).
# Steam is left running (shown) when this started it; Kate is closed; home; `cmd device_state state reset`.
# Exit: 0 pass; 1 FAIL; 3 a real touch / not now; 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/steam-tap-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
rs() { printf '%s\n' "$1" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
X='export DISPLAY=:0 XAUTHORITY=$(pgrep -a Xwayland | grep -o -- "-auth [^ ]*" | head -1 | cut -d" " -f2)'
LEASH0=""; REC=""; KATE=0; RC=0
recstop() { [ -n "$REC" ] || return 0; sh_ "pkill -INT screenrecord"; sleep 2
  sh_ "chmod 644 /data/local/tmp/steam-tap-$REC.mp4"; touch "$OUT/$REC.mp4"
  "$A" pull "/data/local/tmp/steam-tap-$REC.mp4" "$OUT/$REC.mp4" >/dev/null 2>&1; sh_ "rm -f /data/local/tmp/steam-tap-$REC.mp4"; REC=""; }
rec() { recstop; REC=$1; "$A" shell "su -c 'screenrecord --time-limit 170 --bit-rate 6000000 /data/local/tmp/steam-tap-$1.mp4 >/dev/null 2>&1 &'" >/dev/null 2>&1; sleep 1; }
restore() {
  recstop
  [ -n "$LEASH0" ] && sh_ "settings put global powos_live_leash $LEASH0"
  [ $KATE = 1 ] && us "pkill -x kate; true"
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"
  sh_ "logcat -d -v time" | grep -E "WindowTasks|PowosWindow|PowosTaskLeash" | tail -300 > "$OUT/logcat.txt"
  echo "restored; recordings: $(ls "$OUT"/*.mp4 2>/dev/null | tr '\n' ' ')"
}
. "$here/window-lock.sh"
window_lock steam-tap.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail-$(date +%H%M%S).png" >/dev/null 2>&1; RC=1; }
pass() { echo "PASS $*" | tee -a "$OUT/log.txt"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
page() { "$T/cdp.sh" eval home "$1" 2>&1 | tr -d '"\r' | tail -1; }
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910700+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',$2]))}).then(v=>($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
tasks() { sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | tr -dc '0-9\n' | sort -n; }
tbounds() { sh_ "am stack list | grep -E \"taskId=$1[^0-9]\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }
focus() { sh_ "dumpsys window | grep -m1 mCurrentFocus"; }
# The Steam main window, viewable and full-sized: "<id> <w> <h>" or nothing.
steamwin() { us "$X; xwininfo -root -tree 2>/dev/null | awk '/\"Steam\": \\(\"steamwebhelper\" \"steam\"\\)/{print \$1}' | while read -r w; do xwininfo -id \$w 2>/dev/null | awk -v w=\$w '/Map State/{m=\$3} /Width:/{x=\$2} /Height:/{y=\$2} END{if(m==\"IsViewable\"&&x>=400&&y>=300)print w, x, y}'; done | head -1" | tail -1; }
steam_up() { us 'case $(readlink /proc/$(cat ~/.steam/steam.pid 2>/dev/null || echo 0)/exe 2>/dev/null) in */steamrtarm64/steam) echo up ;; *) echo down ;; esac' | tail -1; }
steam_close() {
  us 'timeout 10 steam -shutdown >/dev/null 2>&1; for i in $(seq 24); do pgrep -f "steamrtarm64/steam( |$)" >/dev/null || break; sleep 0.5; done
      pkill -KILL -f "steamrtarm64/steam( |$)"; pkill -KILL -f steamrtarm64/steamwebhelper; sleep 1; true' >/dev/null
}
# Mean brightness of the screen inside "L T R B" (screencap of the display that is ON, sampled every 8th pixel).
bright() {
  sh_ "screencap -d ${DID:-0} /data/powos/root/var/tmp/steam-tap.raw" >/dev/null
  rs "python3 - /var/tmp/steam-tap.raw $1 $2 $3 $4 <<'PY' 2>/dev/null || echo 0
import struct, sys
f = sys.argv[1]; l, t, r, b = map(int, sys.argv[2:6]); d = open(f, 'rb').read(); w, h = struct.unpack('<II', d[:8])
off = len(d) - w * h * 4; s = n = 0
for y in range(max(t, 0), min(b, h), 8):
    row = off + y * w * 4
    for x in range(max(l, 0), min(r, w), 8):
        p = row + x * 4; s += d[p] + d[p + 1] + d[p + 2]; n += 3
print(s // max(n, 1))
PY
rm -f /var/tmp/steam-tap.raw" | tail -1
}
# A tap on Steam's launcher entry the way home's own is tapped: the dock's cell, else home's launch call.
steam_tap() {
  local xy
  xy=$(page "(()=>{const e=document.querySelector('.home .dock .app[data-key=\"l:steam\"]');if(!e)return 'none';const r=e.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.left+r.width/2)*d)+' '+Math.round((r.top+r.height/2)*d)})()")
  if [[ $xy =~ ^[0-9]+\ [0-9]+$ ]]; then log "tap: the dock's Steam cell at $xy"; sh_ "input tap $xy"
  else log "tap: no Steam cell in the dock ($xy) - home's launch call"; hcall apps.launch "['l:steam']" "()=>'ok'" >/dev/null; fi
}
# After a tap at $1 (ms): Steam's window viewable + a new PowosWindowActivity task in focus + not black, in 240 s.
expect_window() {
  local phase=$1 t0=$2 before=$3 w="" tk="" f="" b="" br=0 end=$((SECONDS + 240))
  while [ $SECONDS -lt $end ]; do
    w=$(steamwin); [ -n "$w" ] && tk=$(tasks | tail -1) && f=$(focus)
    if [ -n "$w" ] && [ -n "$tk" ] && [[ $f == *PowosWindowActivity* ]]; then break; fi
    sleep 2
  done
  local t=$(( $(ms) - t0 ))
  chk "$phase"
  log "$phase: window '${w:-none}' task ${tk:-none} focus ${f:-?}"
  [ -n "$w" ] || { fail "$phase: no viewable Steam window $((t / 1000)) s after the tap"; return 1; }
  [[ $f == *PowosWindowActivity* ]] || { fail "$phase: Steam's window isn't a task in front: $f"; return 1; }
  b=$(tbounds "$tk"); br=$(bright $b)
  "$T/shot.sh" "$OUT/$phase.png" >/dev/null 2>&1
  log "$phase: task $tk bounds $b, brightness $br, X window ${w#* }"
  [ "${br:-0}" -gt 12 ] || { fail "$phase: Steam's task is black (brightness $br)"; return 1; }
  echo "TIME $phase $t ms" | tee -a "$OUT/log.txt"
  pass "$phase: a tap on Steam shows its window in $((t / 1000)) s"
  STEAMTASK=$tk; STEAMWIN=${w%% *}
}

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ "$(us "pgrep -fc 'SteamLaunch AppId='" | tail -1)" = 0 ] || { echo "a game runs under Steam (the user's): not now"; exit 3; }
sh_ "cmd device_state state 3"; sleep 3; chk unfold
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); W=${WH% *}; H=${WH#* }
[ "${W:-0}" -gt 2000 ] || { echo "display is ${W:-?}x${H:-?}, not the unfolded inner screen"; exit 5; }
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "the keyguard didn't go (a PIN?)"; exit 5; }
fi
home() { sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; }
home; chk home
DID=$(sh_ "dumpsys display" | sed -nE 's/.*uniqueId="local:([0-9]+)".* state ON,.*/\1/p' | head -1)
log "steam: $(us 'pacman -Q steam' | tail -1), open-task: $(us 'grep -c WAIT_STEAM_S "$(command -v powos-open-task)"' | tail -1)"

# cold
steam_close; [ "$(steam_up)" = down ] || { fail "cold: Steam didn't close"; exit 1; }
home; rec cold; before=$(tasks); t0=$(ms); steam_tap; chk "cold tap"
expect_window cold "$t0" "$before"
recstop

# resident
steam_close; home
us 'cd ~ && setsid -f steam -silent </dev/null >/dev/null 2>&1' >/dev/null
for _ in $(seq 60); do us 'pgrep -c -f steamrtarm64/steamwebhelper' | tail -1 | grep -qv '^0$' && break; sleep 2; done
sleep 30; chk resident
w=$(steamwin); log "resident: Steam $(steam_up), window before the tap: '${w:-none}'"
[ -z "$w" ] || log "note: the resident Steam already has a viewable window ($w)"
home; rec resident; before=$(tasks); t0=$(ms); steam_tap; chk "resident tap"
expect_window resident "$t0" "$before"
sleep 3; us "tail -5 \${XDG_RUNTIME_DIR:-/run/powos-app}/powos-open-task.log 2>/dev/null; grep -a 'steam:' /run/powos-app/hyprland.log | tail -3" > "$OUT/handoff.txt"

# touch: LIBRARY tab
urlrow() { us "$X; ffmpeg -loglevel error -f x11grab -window_id $STEAMWIN -i :0 -frames:v 1 -vf crop=900:50:100:140,format=gray -f rawvideo - 2>/dev/null | md5sum | cut -c1-12" | tail -1; }
tap_library() {
  local b l t; b=$(tbounds "$STEAMTASK"); read -r l t _ _ <<<"$b"
  log "touch ($1): task bounds $b -> tap $((l + 427)),$((t + 103))"
  sh_ "input tap $((l + 427)) $((t + 103))"; sleep 3; chk "library tap"
}
if [ -n "${STEAMTASK:-}" ] && [ -n "${STEAMWIN:-}" ]; then
  rec touch
  u0=$(urlrow); sleep 2; u1=$(urlrow); log "touch: URL row $u0 / $u1 (still)"
  tap_library leash-on; u2=$(urlrow)
  if [ "$u2" != "$u1" ]; then pass "touch: a tap on LIBRARY reached Steam (URL row changed)"
  else
    fail "touch: a tap on LIBRARY changed nothing in Steam's window"
    us "$X; xdotool mousemove --window $STEAMWIN 427 103 click 1" >/dev/null; sleep 3; u3=$(urlrow)
    [ "$u3" != "$u2" ] && log "control: an X click at the same point switched it - the touch path (Android -> KWin -> Xwayland) loses the tap" \
                       || log "control: an X click didn't switch it either - the point or Steam itself"
    LEASH0=$(sh_ "settings get global powos_live_leash" | tr -dc '0-9'); LEASH0=${LEASH0:-1}
    sh_ "settings put global powos_live_leash 0"; sleep 1
    us "$X; xdotool mousemove --window $STEAMWIN 160 103 click 1" >/dev/null; sleep 3   # back to STORE
    u4=$(urlrow); tap_library leash-off; u5=$(urlrow)
    [ "$u5" != "$u4" ] && log "bisect: with powos_live_leash 0 the tap reaches Steam - TaskLeash" || log "bisect: powos_live_leash 0 changes nothing - not TaskLeash"
    sh_ "settings put global powos_live_leash $LEASH0"; LEASH0=""
  fi
  recstop
fi

# kate
home; rec kate; before=$(tasks); KATE=1
hcall apps.launch "['l:org.kde.kate']" "()=>'ok'" >/dev/null
KT=""; for _ in $(seq 30); do sleep 1; KT=$(comm -13 <(echo "$before") <(tasks) | tail -1); [ -n "$KT" ] && break; done; chk kate
if [ -z "$KT" ]; then fail "kate: no window task in 30 s"
else
  sleep 4; read -r kl kt kr kb <<<"$(tbounds "$KT")"
  k0=$(bright "$kl" "$kt" "$kr" "$kb")
  sh_ "input tap $(( (kl + kr) / 2 )) $(( (kt + kb) / 2 ))"; sleep 1.5
  sh_ "input text powostaptest"; sleep 2; chk "kate tap"
  k1=$(bright "$kl" "$kt" "$kr" "$kb"); "$T/shot.sh" "$OUT/kate.png" >/dev/null 2>&1
  cap=$(hcall windows.list "[]" "l=>String((l.find(w=>w.id===$KT)||{}).title||(l.find(w=>w.id===$KT)||{}).label||'-')")
  log "kate: task $KT bounds $kl $kt $kr $kb, brightness $k0 -> $k1, title '$cap'"
  [[ $cap == *"*"* || $cap == *odified* || $k0 != "$k1" ]] && pass "kate: a tap + keys reached Kate" || fail "kate: the tap + keys changed nothing in Kate"
fi
recstop
exit $RC
