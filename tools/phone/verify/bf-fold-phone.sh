#!/bin/bash
# bf-fold-phone.sh: (in the PowOS session as powos; bf-fold.sh pushes and runs it) the session side of bf-fold.sh.
#   bf-fold-phone.sh state         one line: reaper=<pid|-> win=<id|-> geom=<WxH+X+Y|-> frozen=<yes|no> root=<WxH>
#   bf-fold-phone.sh start         Broforce up (a cold start unless it runs), its window, past the 2 min sleep grace;
#                                  prints mine=1 when this started it (bf-stop.sh closes it after)
#   bf-fold-phone.sh changes <s>   changes=<n>: distinct frames of the game's window over <s> s (x11grab, 10 fps)
#   bf-fold-phone.sh sleeplog      powos-sleep-gui's Steam lines of the last 2 min
#   bf-fold-phone.sh logout        a fresh session (android-request power logout: the app restarts it)
set -uo pipefail
APP=274190
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app} DISPLAY=${DISPLAY:-:0}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
xw=$(pgrep -x Xwayland | head -1)
[ -n "$xw" ] && { XAUTHORITY=$(tr '\0' '\n' < "/proc/$xw/cmdline" | grep -A1 -x -- -auth | tail -1); export XAUTHORITY; }
reaper() { pgrep -f "SteamLaunch AppId=$APP( |\$)" | head -1; }
gamewin() { xwininfo -root -tree 2>/dev/null | awk '/"Broforce"/ && !/has no name/ {print $1; exit}'; }
case ${1:-state} in
state)
  w=$(gamewin); g=-
  [ -n "$w" ] && g=$(xwininfo -id "$w" 2>/dev/null | awk '/-geometry/{print $2}')
  s=$(cat "/proc/$(cat ~/.steam/steam.pid 2>/dev/null)/cgroup" 2>/dev/null); case $s in *powos/sleep/*) f=yes ;; *) f=no ;; esac
  r=$(xwininfo -root 2>/dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')
  echo "reaper=$(reaper | grep . || echo -) win=${w:--} geom=$g frozen=$f root=$r" ;;
start)
  powos sleep never --remove steam >/dev/null 2>&1  # the real setup: Steam sleepable (games: "pause")
  mine=0
  if [ -z "$(reaper)" ]; then
    mine=1; cd "$HOME" && setsid -f steam steam://rungameid/$APP >/tmp/bf-fold-steam.out 2>&1 </dev/null
  fi
  w=; for _ in $(seq 400); do w=$(gamewin); [ -n "$w" ] && break; sleep 0.5; done
  [ -n "$w" ] || { echo "no Broforce window in 200 s"; echo "mine=$mine"; exit 1; }
  # Past the start grace (2 min from the game's reaper), so the fold meets the automatic sleep as a player would.
  e=$(ps -o etimes= -p "$(reaper)" | tr -d ' '); [ "${e:-0}" -lt 130 ] && sleep $((130 - ${e:-0}))
  sleep 5; echo "mine=$mine" ;;
changes)
  w=$(gamewin); [ -n "$w" ] || { echo "changes=0 (no window)"; exit 0; }
  n=$(ffmpeg -nostdin -loglevel error -f x11grab -framerate 10 -window_id "$w" -i "$DISPLAY" -t "${2:-3}" \
      -f framemd5 - 2>/dev/null | awk '!/^#/ {print $NF}' | sort -u | wc -l)
  echo "changes=$n" ;;
sleeplog)  # what powos-sleep-gui did to Steam in the last 2 minutes
  awk -v t="$(date -d '-2 min' '+%F %T')" '$0 >= t && /steam|Steam/' /run/powos-app/powos-sleep-gui.log | tail -8 ;;
logout)
  android-request power logout && echo "logout requested" ;;
esac
