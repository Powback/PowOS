#!/bin/bash
# bf-launchpaths-phone.sh: (in the PowOS session as powos; bf-launchpaths.sh pushes and runs it). Prints "RESULT ..." last.
set -uo pipefail
APP=274190 GLOG=/run/powos-app/powos-sleep-gui.log
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app} DISPLAY=${DISPLAY:-:0}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
XAUTHORITY=$(tr '\0' '\n' < "/proc/$(pgrep -x Xwayland | head -1)/cmdline" | grep -A1 -x -- -auth | tail -1); export XAUTHORITY
now() { date +%s.%N; }
ms() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%d", (b - a) * 1000}'; }
irq() { awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}' /proc/interrupts; }
I0=$(irq)
touched() { [ "$(irq)" != "$I0" ] && { echo "user input $(date +%T) - stopping"; return 0; }; return 1; }
reaper() { pgrep -f "SteamLaunch AppId=$APP( |\$)" | head -1; }
steam_pid() { cat ~/.steam/steam.pid 2>/dev/null; }
frozen() { case $(cat "/proc/$(steam_pid)/cgroup" 2>/dev/null) in *powos/sleep/*) echo yes ;; *) echo no ;; esac; }
gamewin() { xwininfo -root -tree 2>/dev/null | awk '/"Broforce"/ && !/has no name/ {print $1; exit}'; }
powos sleep never --remove steam >/dev/null 2>&1
mine=0
if [ -z "$(reaper)" ]; then
  mine=1; setsid -f steam steam://rungameid/$APP >/dev/null 2>&1 </dev/null
  for _ in $(seq 600); do [ -n "$(gamewin)" ] && break; touched && exit 3; sleep 0.5; done
  [ -n "$(gamewin)" ] || { echo "no Broforce window in 5 min"; bash /var/tmp/powos-bf-stop.sh; exit 1; }
  e=$(ps -o etimes= -p "$(reaper)" | tr -d ' '); [ "${e:-0}" -lt 125 ] && sleep $((125 - ${e:-0}))  # start grace
fi
desk=$(grep -lx "Exec=steam steam://rungameid/$APP" ~/.local/share/applications/*.desktop 2>/dev/null | head -1)
desk=$(basename "${desk:-Broforce.desktop}" .desktop)
res=""
for path in "drawer:$desk" "widget:steam_app_$APP"; do
  touched && exit 3
  powos game $APP freeze >/dev/null; for _ in $(seq 20); do [ "$(frozen)" = yes ] && break; sleep 0.5; done
  fz=$(frozen); r0=$(reaper); t0=$(now)
  st=$(timeout 40 powos-open-task --app-id "${path#*:}" -- steam steam://rungameid/$APP | head -1)
  t=$(ms "$t0" "$(now)")
  ok=FAIL; [ "$fz" = yes ] && [ "$st" = "powos-open-task: task" ] && [ "$(frozen)" = no ] && [ "$(reaper)" = "$r0" ] && ok=ok
  echo "${path%%:*} (--app-id ${path#*:}): frozen before $fz, '$st' in $t ms, frozen after $(frozen), same game $([ "$(reaper)" = "$r0" ] && echo yes || echo no) -> $ok"
  grep "app $APP resumed" "$GLOG" | tail -1
  res="$res ${path%%:*} $ok ${t}ms;"
  sleep 5
done
[ $mine = 1 ] && { echo "== closing what this check started"; bash /var/tmp/powos-bf-stop.sh | tail -2; }
echo "RESULT bf-launchpaths:$res"
