#!/bin/bash
# lanes: phone
# steam-launch-placeholder-phone.sh <appid>: (in the PowOS session as powos; steam-launch-placeholder.sh runs it) start
# the game the way Steam's own UI does - `steam -applaunch`, no PowOS launch path (no powos-open-task, no placeholder
# made by a tap) - and time powos-sleep-gui's announce (SL1: running/launches.json naming it). Exit 3 when the game
# runs already (the user's: never touched).
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
APP=${1:?appid}
F=$XDG_RUNTIME_DIR/running/launches.json
reapers() { local p; for p in $(pgrep -f "SteamLaunch AppId=$APP( |\$)"); do grep -qa 'Install=1' "/proc/$p/cmdline" 2>/dev/null || echo "$p"; done; }
[ -n "$(reapers)" ] && { echo "SKIP game $APP runs already (the user's: left as it is)"; exit 3; }
pgrep -f powos-sleep-gui >/dev/null || { echo "FAIL setup: powos-sleep-gui isn't running (nothing announces launches)"; exit 1; }
t0=$(date +%s%N)
setsid steam -applaunch "$APP" </dev/null >/dev/null 2>&1 &
for _ in $(seq 1 300); do grep -q "\"$APP\"" "$F" 2>/dev/null && break; sleep 0.1; done
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
if grep -q "\"$APP\"" "$F" 2>/dev/null; then echo "ANNOUNCE $ms ms: $(head -c 300 "$F")"; else echo "FAIL announce: no launches.json entry for $APP in $ms ms ($(head -c 200 "$F" 2>/dev/null || echo no file))"; fi
