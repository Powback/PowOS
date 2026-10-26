#!/bin/bash
# lanes: phone
# bf-return.sh: (Mac side; queue it: queue.sh add <board-task> [env APP=<appid>] bf-return.sh) a game the user started,
# left and taps again comes back at once - any Steam game (APP, default 274190 Broforce, the test case): started through powos-open-task (the drawer's path) -> its frame -> HOME (Android's
# HOME intent, as the user's home gesture) -> frozen in the background by unified sleep, not closed -> its icon tapped
# again (powos-open-task) -> tap -> first changed frame, which must be under 10 s (goal: under 3 s, RESUME_MS), with the
# game's task in front, its window focused and its audio back. Phases: bf-return-phone.sh; ~3-4 min (the 2 min start
# grace). What it started is closed after; a game the user had left frozen is frozen again; the front activity is
# put back. Exit 3 on a real touch (re-queued). Artefacts ~/.cache/powos-verify/bf-return-<date>/run.txt.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"; APP=${APP:-274190}
case $APP in *[!0-9]*|"") echo "FAIL setup: APP must be a Steam app id ($APP)"; exit 2 ;; esac
OUT=${OUT:-$HOME/.cache/powos-verify/bf-return-$(date +%F_%H%M)}; mkdir -p "$OUT"
BF_ADB=$A . "$here/bf-lib.sh"   # pill <step>: the status pill's sub-step
irq() { "$A" shell "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts" | tr -d '\r'; }
top() { "$A" shell "dumpsys activity activities | grep -m1 topResumedActivity" | tr -d '\r' | sed -nE 's#.* ([a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+) .*#\1#p'; }
# adb.sh mounts each pushed file's directory into its container: the path must be resolved (no "..").
ot=$(cd "$here/../../../targets/android/session" && pwd)/powos-open-task
"$A" push "$ot" /data/local/tmp/powos-open-task >/dev/null || { echo "FAIL setup: can't push $ot"; exit 1; }
for f in bf-return-phone.sh bf-lib.sh bf-stop.sh; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "FAIL setup: can't push $f"; exit 1; }; done
"$A" shell "su -c 'install -m 755 /data/local/tmp/powos-open-task /data/powos/root/usr/local/bin/powos-open-task && cp /data/local/tmp/powos-bf-return-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-bf-*.sh'"
ph() { "$A" shell "su -c 'sh /data/powos/powos-run.sh \"APP=$APP bash /var/tmp/powos-bf-return-phone.sh $1\"'" 2>&1 | grep -v sysvipc | sed -l $'s/\r$//' | tee -a "$OUT/run.txt"; }
front=$(top); echo "front before: ${front:-?}" | tee -a "$OUT/run.txt"
closed=0
finish() {  # once: the game closed (or the user's frozen again), the front activity back, the pushed files gone
  [ $closed = 1 ] && return; closed=1
  ph close >/dev/null
  [ -n "$front" ] && [ "$(top)" != "$front" ] && "$A" shell "am start -n $front >/dev/null 2>&1"
  "$A" shell "su -c 'rm -f /data/local/tmp/powos-open-task /data/local/tmp/powos-bf-return-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/powos-bf-return-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-bf-stop.sh /data/powos/root/tmp/bf-return.env'" >/dev/null 2>&1
}
trap 'echo "stopped from outside $(date +%T)" | tee -a "$OUT/run.txt"; finish; exit 3' HUP TERM INT
i0=$(irq); touched() { [ "$(irq)" != "$i0" ] && { echo "user input $(date +%T) - stopping" | tee -a "$OUT/run.txt"; finish; exit 3; }; }
result() { local t; t=$(grep -m1 '^TIMES' "$OUT/run.txt" | sed 's/^TIMES //')
  echo "RESULT bf-return: $(grep -q '^FAIL' "$OUT/run.txt" && echo "FAIL$(grep '^FAIL' "$OUT/run.txt" | sed -E 's/^FAIL ([^:]*):.*/ \1/' | tr -d '\n') - " )tap -> first changed frame: ${t:-none}; artefacts $OUT/run.txt" | tee -a "$OUT/run.txt"; }

ph launch; rc=${PIPESTATUS[0]}
grep -q '^SKIP\|^user input' "$OUT/run.txt" && { finish; exit 3; }
grep -q '^FAIL launch' "$OUT/run.txt" && { finish; result; exit 1; }
touched
t=$(top); echo "in front with the game up: $t" | tee -a "$OUT/run.txt"
case $t in *PowosWindowActivity*) ;; *) echo "FAIL launch-front: the game's task isn't in front ($t)" | tee -a "$OUT/run.txt" ;; esac
pill "going home (HOME intent)"
"$A" shell "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1"; sleep 1
echo "home: $(top)" | tee -a "$OUT/run.txt"
ph away
grep -q '^user input' "$OUT/run.txt" && exit 3
touched
ph back
grep -q '^user input' "$OUT/run.txt" && exit 3
t=$(top); echo "in front after the tap: $t" | tee -a "$OUT/run.txt"
case $t in *PowosWindowActivity*) ;; *) echo "FAIL resume-front: the game's task isn't in front after the tap ($t): touches go elsewhere" | tee -a "$OUT/run.txt" ;; esac
finish
result
grep -q '^FAIL' "$OUT/run.txt" && exit 1
exit 0
