#!/bin/bash
# lanes: phone
# launch-window.sh [OUT] (board launch-window-instant-placeholder-splash-until-t): a tap on an app shows its window at
# once, at its final size and place, which then becomes the app's real window with no jump - on the unfolded home:
#   1. Steam (a cold start: 25-40 s to its first window): tapped (its dock cell, else home's launch call), a new window
#      task is on the screen within LAUNCH_S (LaunchWindows' launch window: Steam's icon and name), and once Steam's
#      window comes (WindowTasks "open N (steam): in its launch window") it is in THAT task, at the same bounds;
#   2. an Android app (Calculator) the same way: its task within LAUNCH_S (the system's starting window), the same
#      task and bounds 5 s later.
# Phone-side samples of `am stack list` every ~0.2 s give the times. Screencaps OUT/launch.png (the launch window),
# OUT/steam.png. Restores: what it opened closed, home, `cmd device_state state reset`. Steam with a window already
# (the user's): not now. Exit: 0 passed; 1 FAIL; 3 a real touch / no free window / not now; 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/launch-window-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
LAUNCH_S=${LAUNCH_S:-1.5}
. "$here/linux-win-lib.sh"
. "$here/window-lock.sh"
window_lock launch-window.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
unfolded_home
[ "$(steam_window)" = none ] || { echo "Steam has a window already (the user's?): not now"; exit 3; }
LIN0=$(lin)
livelog launch-window 240

# sample <name> <pattern>: `am stack list` lines matching <pattern> (no spaces), stamped with the phone's uptime, ~5/s for 25 s.
sample() { sh_ "rm -f /data/local/tmp/lw-$1.txt; (i=0; while [ \$i -lt 120 ]; do read -r u _ < /proc/uptime; am stack list | grep -E $2 | while read -r l; do echo \$u \$l; done; i=\$((i+1)); sleep 0.05; done > /data/local/tmp/lw-$1.txt 2>&1 &)"; }
# tap_app <key>: its dock cell tapped (the tap and the phone's uptime in one call), else home's launch call; echoes the uptime.
tap_app() {
  local xy; xy=$(hcall_page "(()=>{const e=document.querySelector('.home .dock .app[data-key=\"$1\"]');if(!e)return 'none';const r=e.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.left+r.width/2)*d)+' '+Math.round((r.top+r.height/2)*d)})()")
  if [[ $xy =~ ^[0-9]+\ [0-9]+$ ]]; then sh_ "read -r u _ < /proc/uptime; echo \$u; input tap $xy" | head -1; log "tapped $1's dock cell at $xy" >&2
  else sh_ "read -r u _ < /proc/uptime; echo \$u" | head -1; hcall apps.launch "['$1']" "()=>'ok'" >/dev/null; log "no dock cell for $1: home's launch call" >&2; fi
}
hcall_page() { "$T/cdp.sh" eval home "$1" 2>&1 | tr -d '"\r' | tail -1; }
# first <name>: "<uptime> <task> <l t r b>" of the first sampled task that wasn't there at the start.
first() {
  sh_ "cat /data/local/tmp/lw-$1.txt" | python3 -c '
import re, sys
old = set(sys.argv[1].split())
for line in sys.stdin:
    m = re.match(r"(\S+) .*taskId=(\d+):.*bounds=\[(\d+),(\d+)\]\[(\d+),(\d+)\]", line)
    if m and m.group(2) not in old:
        print(m.group(1), m.group(2), *m.group(3, 4, 5, 6)); break' "$LIN0"
}

# 1. Steam.
sample steam "PowosWindowActivity"; sleep 0.4
t0=$(tap_app l:steam); MINE="$MINE steam"; chk "steam tap"
sleep 1.2; "$T/shot.sh" "$OUT/launch.png" >/dev/null 2>&1
sleep 2; read -r ts tk l t r b <<<"$(first steam)"
[ -n "${tk:-}" ] || fail "no window task on the screen within 3 s of the tap on Steam (no launch window)"
dt=$(python3 -c "print(round($ts - $t0, 2))"); log "Steam: task $tk at $l $t $r $b, $dt s after the tap"
python3 -c "import sys; sys.exit(0 if $dt <= $LAUNCH_S else 1)" || fail "Steam's launch window took $dt s (want <= $LAUNCH_S s)"
pass "a tap on Steam shows its launch window at once ($dt s, task $tk)"
got=""; end=$((SECONDS + 150))
while [ $SECONDS -lt $end ]; do sleep 3; live; got=$(grep -aoE "open [0-9]+ \(steam\): [a-z ]+" "$OUT/live.txt" | head -1); [ -n "$got" ] && break; done
chk steam
[ -n "$got" ] || fail "no Steam window within 150 s (launch window task $tk: $(tbounds "$tk"))"
sleep 4; "$T/shot.sh" "$OUT/steam.png" >/dev/null 2>&1
log "KWin: $got"
[[ $got == *"in its launch window"* ]] || fail "Steam's window opened in a task of its own, not its launch window: $got"
w=$(steam_window); read -r l2 t2 r2 b2 <<<"$(tbounds "$tk")"
log "Steam's window: task ${w:-?}, bounds ${l2:-?} ${t2:-?} ${r2:-?} ${b2:-?}"
[ "$w" = "$tk" ] || fail "Steam's window is task $w, its launch window was task $tk"
[ "$l $t $r $b" = "${l2:-} ${t2:-} ${r2:-} ${b2:-}" ] || fail "Steam's window jumped: launch window at $l $t $r $b, its window at $l2 $t2 $r2 $b2"
pass "the launch window became Steam's window: the same task $tk, the same place ($l $t $r $b)"

# 2. An Android app: the system's starting window is its launch window.
key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:com\\.(oneplus|google\\.android|android)\\.calculator/.test(a.key))||{}).key||'none'")
if [ "$key" = none ] || [ -n "$(sh_ "am stack list" | grep -i calculator)" ]; then
  log "Calculator: not in the app list or open already (the user's): skipped"
else
  sample calc "calculator"; sleep 0.4
  t0=$(tap_app "$key"); chk calc
  sleep 3; read -r ts ck l t r b <<<"$(first calc)"
  [ -n "${ck:-}" ] || fail "no Calculator task within 3 s of the tap"
  dt=$(python3 -c "print(round($ts - $t0, 2))"); log "Calculator: task $ck at $l $t $r $b, $dt s after the tap"
  python3 -c "import sys; sys.exit(0 if $dt <= $LAUNCH_S else 1)" || fail "Calculator's window took $dt s (want <= $LAUNCH_S s)"
  sleep 5; read -r l2 t2 r2 b2 <<<"$(tbounds "$ck")"
  [ "$l $t $r $b" = "${l2:-} ${t2:-} ${r2:-} ${b2:-}" ] || fail "Calculator's window jumped: $l $t $r $b -> $l2 $t2 $r2 $b2"
  pass "a tap on Calculator shows its window at once ($dt s) where it stays (task $ck)"
  sh_ "am stack remove $ck"
fi
echo "all passed; artefacts: $OUT"
