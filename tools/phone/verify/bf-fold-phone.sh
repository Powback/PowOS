#!/bin/bash
# bf-fold-phone.sh: (in the PowOS session as powos; bf-fold.sh pushes and runs it) the session side of bf-fold.sh.
#   bf-fold-phone.sh state         one line: reaper=<pid|-> win=<id|-> geom=<WxH+X+Y|-> frozen=<yes|no> root=<WxH>
#   bf-fold-phone.sh start         Broforce up the way the user starts it (bf-lib step_launch: powos-open-task, its
#                                  window as its own task in front; one the user left frozen is resumed), past the
#                                  2 min sleep grace; prints mine=1 when this started it (bf-stop.sh closes it after),
#                                  mine=0 for the user's (refreeze puts it back); "FAIL launch: ..." when it didn't come
#   bf-fold-phone.sh changes <s>   changes=<n>: distinct samples of the game's window over <s> s (bf-lib xframes count,
#                                  10 a second; ffmpeg's x11grab gets no frame on Android: no MIT-SHM)
#   bf-fold-phone.sh refreeze      the user's Broforce back out of sight and frozen (`powos game 274190 freeze`)
#   bf-fold-phone.sh sleeplog      powos-sleep-gui's Steam lines of the last 2 min
#   bf-fold-phone.sh logout        a fresh session (android-request power logout: the app restarts it)
set -uo pipefail
APP=${APP:-274190} WIN_NAME=${WIN_NAME:-Broforce}  # any Steam game: APP + its window's name (bf-fold.sh passes them)
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app} DISPLAY=${DISPLAY:-:0}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
xw=$(pgrep -x Xwayland | head -1)
[ -n "$xw" ] && { XAUTHORITY=$(tr '\0' '\n' < "/proc/$xw/cmdline" | grep -A1 -x -- -auth | tail -1); export XAUTHORITY; }
reaper() { local p; for p in $(pgrep -f "SteamLaunch AppId=$APP( |\$)"); do  # not the install script evaluator's
  grep -qa 'Install=1' "/proc/$p/cmdline" 2>/dev/null || { echo "$p"; return; }; done; }
gamewin() { xwininfo -root -tree 2>/dev/null | awk -v n="\"$WIN_NAME\"" 'index($0, n) && !/has no name/ {print $1; exit}'; }
case ${1:-state} in
state)
  w=$(gamewin); g=-
  [ -n "$w" ] && g=$(xwininfo -id "$w" 2>/dev/null | awk '/-geometry/{print $2}')
  s=$(sed -n 's/^0:://p' "/proc/$(cat ~/.steam/steam.pid 2>/dev/null)/cgroup" 2>/dev/null); case $s in */powos/sleep/*) f=yes ;; *) f=no ;; esac
  r=$(xwininfo -root 2>/dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')
  echo "reaper=$(reaper | grep . || echo -) win=${w:--} geom=$g frozen=$f root=$r" ;;
start)
  powos sleep never --remove steam >/dev/null 2>&1  # the real setup: Steam sleepable (games: "pause")
  cd "$HOME"; LAUNCH_S=200 . /var/tmp/powos-bf-lib.sh; trap - HUP TERM INT
  step_launch || { echo "mine=$mine"; exit 1; }
  # Past the start grace (2 min from the game's reaper), so the fold meets the automatic sleep as a player would.
  e=$(ps -o etimes= -p "$(reaper)" | tr -d ' '); [ "${e:-0}" -lt 130 ] && sleep $((130 - ${e:-0}))
  sleep 5; rm -rf "$T"; echo "mine=$mine" ;;
changes)
  w=$(gamewin); [ -n "$w" ] || { echo "changes=0 (no window)"; exit 0; }
  . /var/tmp/powos-bf-lib.sh; trap - HUP TERM INT
  echo "changes=$(xframes count "$w" "${2:-3}" 10)"; rm -rf "$T" ;;
refreeze)
  powos game $APP freeze 2>&1 | tail -1 | sed 's/\x1b\[[0-9;]*m//g' ;;
sleeplog)  # what powos-sleep-gui did to Steam in the last 2 minutes
  awk -v t="$(date -d '-2 min' '+%F %T')" '$0 >= t && /steam|Steam/' /run/powos-app/powos-sleep-gui.log | tail -8 ;;
logout)
  android-request power logout && echo "logout requested" ;;
esac
