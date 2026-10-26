#!/bin/bash
# lanes: phone
# bf-run.sh: Broforce ~10 min check (game takes the screen ~14 min: only when the user is away with the screen on, or
# run it while the user plays - then skip bf-start/bf-stop). Samples memory every 15 s and SurfaceFlinger frame pacing
# every 30 s, collects the new "Xwayland KGSL" stats lines from the session log, closes the game + Steam after, and
# pulls everything to OUT. Stops early on a real touch (touch IRQs move).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/bf-$(date +%F_%H%M)}; mkdir -p "$OUT"; LOG=/data/powos/root/run/powos-app/hyprland.log
BF_ADB=$A . "$here/bf-lib.sh"   # pill <step>: the status pill's sub-step
pill "pushing the samplers"
for f in bf-sample.sh sf-latency.sh bf-start.sh bf-stop.sh; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null; done
asuser() { "$A" shell "su -c 'cp /data/local/tmp/powos-$1 /data/powos/root/var/tmp/powos-$1; chmod 644 /data/powos/root/var/tmp/powos-$1; sh /data/powos/powos-run.sh \"sh /var/tmp/powos-$1\"'"; }
irq() { "$A" shell "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts" | tr -d '\r'; }
k0=$("$A" shell "su -c 'grep -c \"Xwayland KGSL\" $LOG'" | tr -d '\r')
"$A" shell "su -c 'mkdir -p /data/local/tmp/cv; nohup sh /data/local/tmp/powos-bf-sample.sh 900 /data/local/tmp/cv/bf.log >/dev/null 2>&1 &'"
pill "memory baseline (20 s)"; sleep 20; echo "== start $(date +%T)"
[ "${NO_START:-}" ] || { pill "starting Steam + Broforce"; asuser bf-start.sh; }
pill "waiting for the game"
i0=$(irq); gs=""
for m in $(seq 1 26); do
  sleep 30
  [ "${NO_START:-}" ] || { [ "$(irq)" != "$i0" ] && { echo "user input $(date +%T) - stopping"; break; }; }
  g=$("$A" shell "pgrep -f Broforce_beta.exe | head -1" | tr -d '\r')
  echo "$(date +%T) game=${g:-none} $("$A" shell "tail -1 /data/local/tmp/cv/bf.log" | tr -d '\r')"
  [ -n "$g" ] && pill "game up: sampling memory + frames $(( ${gs:-0} ? $(date +%s) - ${gs:-0} : 0 ))/600 s"
  if [ -n "$g" ]; then gs=${gs:-$(date +%s)}; "$A" shell "su -c 'sh /data/local/tmp/powos-sf-latency.sh \"Broforce|steam_app|powos|SurfaceView\"'" | head -4 | tee -a "$OUT/sf.txt"; fi
  [ -n "$gs" ] && [ $(( $(date +%s) - gs )) -ge 600 ] && break
done
echo "== stop $(date +%T)"; [ "${NO_START:-}" ] || { pill "closing the game"; asuser bf-stop.sh; }
pill "memory after the game (60 s)"; sleep 60
pill "collecting the logs"
"$A" shell "su -c 'pkill -f powos-bf-sample.sh; grep \"Xwayland KGSL\" $LOG | tail -n +$((k0 + 1))'" > "$OUT/kgsl.txt"
"$A" pull /data/local/tmp/cv/bf.log "$OUT/bf.log" >/dev/null
"$A" shell "su -c 'rm -rf /data/local/tmp/cv /data/local/tmp/powos-bf-*.sh /data/local/tmp/powos-sf-latency.sh /data/powos/root/var/tmp/powos-bf-*.sh'"
echo "artefacts: $OUT (bf.log memory, sf.txt pacing, kgsl.txt Xwayland stats: healthy = released == commits, held <= 4)"
