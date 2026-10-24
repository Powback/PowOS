# lanes: phone
# bf-game.sh state|freeze: (in the PowOS session as powos; bf-pacing.sh / bf-checker.sh push and run it) a Broforce
# (APP=<appid>: that game) that runs before a check is the USER's: they started it and left it (navigated away: unified
# sleep froze it with Steam) or they play it (awake: a controller doesn't move the touch IRQs the idle window counts).
#   state    one line: game=none | game=frozen (Steam's sleep cgroup frozen with it) | game=awake
#   freeze   the user's game back as they left it: out of sight and frozen (`powos game <appid> freeze`), never closed
#   dir      its install dir (Steam's appmanifest installdir under the library that has it)
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
APP=${APP:-274190}
steam_field() {  # steam_field <appid> <name|installdir>: from Steam's appmanifest (any library folder)
  local S=$HOME/.local/share/Steam f
  for f in "$S/steamapps/appmanifest_$1.acf" $(sed -nE 's/^\s*"path"\s*"(.*)"/\1/p' "$S/steamapps/libraryfolders.vdf" 2>/dev/null | sed "s|\$|/steamapps/appmanifest_$1.acf|"); do
    [ -f "$f" ] && { sed -nE "s/^\s*\"$2\"\s*\"(.*)\"/\1/p" "$f" | head -1; return; }; done; }
case ${1:-state} in
state)
  r=; for p in $(pgrep -f "SteamLaunch AppId=$APP( |\$)"); do grep -qa 'Install=1' "/proc/$p/cmdline" 2>/dev/null || r=$p; done
  [ -n "$r" ] || { echo game=none; exit 0; }
  c=$(sed -n 's/^0:://p' "/proc/$(cat ~/.steam/steam.pid 2>/dev/null)/cgroup" 2>/dev/null)  # the v2 line (v1 ones too)
  case $c in */powos/sleep/*) [ "$(cat "/sys/fs/cgroup$c/cgroup.freeze" 2>/dev/null)" = 1 ] && { echo game=frozen; exit 0; } ;; esac
  echo game=awake ;;
freeze)
  timeout 20 powos game "$APP" freeze 2>&1 | tail -1 | sed 's/\x1b\[[0-9;]*m//g' ;;
dir)
  S=$HOME/.local/share/Steam; d=$(steam_field "$APP" installdir)
  for l in "$S" $(sed -nE 's/^\s*"path"\s*"(.*)"/\1/p' "$S/steamapps/libraryfolders.vdf" 2>/dev/null); do
    [ -n "$d" ] && [ -d "$l/steamapps/common/$d" ] && { echo "$l/steamapps/common/$d"; exit 0; }; done; echo "" ;;
esac
