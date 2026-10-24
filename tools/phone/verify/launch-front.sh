#!/bin/bash
# lanes: phone
# launch-front.sh [OUT]: a PowOS (Linux) app launched from home comes up IN FRONT on the launch that started it - its
# task (PowosWindowActivity) is the top resumed activity, home is not - on the unfolded home (windows float), also when
# its window maps late (a game's cold start: Broforce's window came 75 s after the tap and stayed behind home until a
# second tap, bf-return "launch-front", 2026-10-23: open-task had shown a short-lived window of the launch, which closed,
# and exited) and when it goes full screen right after mapping (Unity maps a small window, then full screen). Launches
# glxgears (an X11 app, Xwayland) through this tree's powos-open-task (installed, as bf-return does), three ways:
#   win    maps at once, stays a window
#   fs     maps at once, full screen 1 s later (wmctrl), like Unity
#   late   a throwaway window first (closed after 3 s, like Steam's), the app's own LATE_S (12) s after the launch
# Each case waits for open-task to exit (its window settled), then reads the top resumed activity.
# Each: logcat (ActivityTaskManager START/BAL, WindowTasks, PowosWindowFrames) goes into OUT; glxgears closed after.
# Exit: 0 passed; 1 FAIL; 3 a real touch / no free window / not now; 5 can't run. Always restores home + device state.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/launch-front-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
LATE_S=${LATE_S:-12}
CASES=${CASES:-win fs late}
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
top() { sh_ "dumpsys activity activities | grep -m1 topResumedActivity" | sed -nE 's#.* ([a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+) .*#\1#p'; }
restore() {
  us "pkill -x glxgears; true" >/dev/null
  sh_ "pkill -f \"logcat -T 1 -v time -s ActivityTaskManager\"; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"
  echo "restored"
}
. "$here/window-lock.sh"
window_lock launch-front.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ "$(us 'pgrep -xc glxgears' | tail -1)" = 0 ] || { echo "glxgears runs already: not now"; exit 3; }
ot=$(cd "$here/../../../targets/android/session" && pwd)/powos-open-task
"$A" push "$ot" /data/local/tmp/powos-open-task >/dev/null || { echo "FAIL setup: can't push $ot"; exit 5; }
sh_ "install -m 755 /data/local/tmp/powos-open-task /data/powos/root/usr/local/bin/powos-open-task && rm -f /data/local/tmp/powos-open-task"
sh_ "cmd device_state state 3"; sleep 3; chk unfold
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); W=${WH% *}; H=${WH#* }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "the keyguard didn't go (a PIN?)"; exit 5; }
fi

fails=0
run_case() {  # run_case <name> <delay s> <fullscreen 0|1>
  local name=$1 d=$2 fs=$3 st t
  sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk "home ($name)"
  log "-- $name: launch (window after ${d} s, full screen $fs); front before: $(top)"
  "$A" shell "su -c 'nohup timeout $((d + 60)) logcat -T 1 -v time -s ActivityTaskManager:I ActivityStarter:V WindowTasks:V PowosWindowFrames:I PowosWindowActivity:V >/data/local/tmp/lf-$name.txt 2>&1 </dev/null &'" </dev/null
  local cmd="sleep $d; exec glxgears"
  [ "$name" = late ] && cmd="glxgears & p=\\\$!; sleep 3; kill \\\$p; sleep $((d - 3)); exec glxgears"
  st=$(us "out=/tmp/lf-open-\$\$.out
( POWOS_NO_LAUNCH_RECORD=1 timeout $((d + 45)) powos-open-task --app-id glxgears -- \"sh -c '$cmd'\" >\$out 2>&1 </dev/null & )
if [ $fs = 1 ]; then ( w=\$(timeout $((d + 30)) xdotool search --sync --onlyvisible --class glxgears 2>/dev/null | head -1)
  [ -n \"\$w\" ] && sleep 1 && wmctrl -i -r \"\$w\" -b add,fullscreen && echo \"full screen \$w \$(date +%T)\" >>\$out ) </dev/null >/dev/null 2>&1 & fi
sleep 1
for i in \$(seq $((2 * (d + 45)))); do pgrep -f 'powos-open-task --app-id glxgears' >/dev/null || break; sleep 0.5; done
sleep 2; cat \$out; rm -f \$out")
  chk "launch ($name)"
  t=$(top)
  log "$name: $(grep '^powos-open-task' <<<"$st" | tr '\n' ' ') $(grep '^full screen' <<<"$st")"
  log "$name: in front: $t"
  case $t in *PowosWindowActivity*) log "PASS $name: the new window's task is in front" ;;
  *) log "FAIL $name: the new window's task isn't in front ($t)"; "$T/shot.sh" "$OUT/fail-$name.png" >/dev/null 2>&1; fails=$((fails + 1)) ;; esac
  us "pkill -x glxgears; true" >/dev/null; sleep 2
  sh_ "pkill -f \"logcat -T 1 -v time -s ActivityTaskManager\"; cat /data/local/tmp/lf-$name.txt; rm -f /data/local/tmp/lf-$name.txt" > "$OUT/logcat-$name.txt"
  grep -E 'START u0.*PowosWindow|WindowTasks|Background|BAL_BLOCK|abort' "$OUT/logcat-$name.txt" | cut -c1-260 | tee -a "$OUT/log.txt"
}
for c in $CASES; do
  case $c in win) run_case win 0 0 ;; fs) run_case fs 0 1 ;; late) run_case late "$LATE_S" 0 ;; esac
done
[ $fails = 0 ] && { echo "RESULT launch-front: PASS ($CASES); artefacts $OUT"; exit 0; }
echo "RESULT launch-front: FAIL $fails of ($CASES); artefacts $OUT"; exit 1
