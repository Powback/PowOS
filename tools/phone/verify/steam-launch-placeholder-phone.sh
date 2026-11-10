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
# ask: Steam holds a launch of APP waiting on the user (bf-ask.sh's test: the newest GameAction of APP ended on
# "LaunchApp waiting for user response to <what>" over 5 s ago). Every later -applaunch joins that launch and nothing
# starts until it's answered (11-08 03:20-03:57: "Steam is asking something" since a run before, then a folded FAIL
# "no-launch-task" and game-present-rate's 300 s timeout). Prints "<what>", status 1 when nothing waits.
ask() {
  local line t age; line=$(tail -c 4194304 "$HOME/.local/share/Steam/logs/console_log.txt" 2>/dev/null | grep -a "GameAction \[AppID $APP, ActionID " | tail -1)
  case $line in *"LaunchApp waiting for user response to "*) ;; *) return 1 ;; esac
  t=$(printf '%s\n' "$line" | sed -nE 's/^\[([0-9-]+ [0-9:]+)\].*/\1/p')
  age=$(( $(date +%s) - $(date -d "$t" +%s 2>/dev/null || date +%s) )); [ "$age" -gt 5 ] || return 1
  printf '%s\n' "$line" | sed -E 's/.*waiting for user response to //' | tr -d '\r' | cut -c1-80; }
if [ "${2:-}" = ask ]; then q=$(ask) && echo "ASK $q" || echo "ASK none"; exit 0; fi
q=$(ask) && { echo "SKIP Steam is asking about $APP: $q (from before this run - the user's question, left unanswered)"; exit 3; }
reapers() { local p; for p in $(pgrep -f "SteamLaunch AppId=$APP( |\$)"); do grep -qa 'Install=1' "/proc/$p/cmdline" 2>/dev/null || echo "$p"; done; }
[ -n "$(reapers)" ] && { echo "SKIP game $APP runs already (the user's: left as it is)"; exit 3; }
pgrep -f powos-sleep-gui >/dev/null || { echo "FAIL setup: powos-sleep-gui isn't running (nothing announces launches)"; exit 1; }
t0=$(date +%s%N); s0=$(( $(date +%s) - 1 ))
setsid steam -applaunch "$APP" </dev/null >/dev/null 2>&1 &
# The call's time on the phone's clock (epoch ms): the Mac side times home's placeholder against it, page-side.
echo "CALL $(( t0 / 1000000 ))"
# THIS run's launch: going on and started now ("since" >= the call) - an entry left by the run before (11-08 02:40:
# "ended" at 10 ms, 03:32: "asking" since 03:20) is no announce of this one.
fresh() { python3 -c 'import json,sys;l=json.load(open(sys.argv[1])).get("launches",{}).get(sys.argv[2]) or {};sys.exit(0 if l.get("state") in ("launching","running","asking") and int(l.get("since",0))>=int(sys.argv[3]) else 1)' "$F" "$APP" "$s0" 2>/dev/null; }
for _ in $(seq 1 300); do fresh && break; sleep 0.1; done
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
if fresh; then echo "ANNOUNCE $ms ms: $(head -c 300 "$F")"; else echo "FAIL announce: no new launches.json entry for $APP in $ms ms ($(head -c 300 "$F" 2>/dev/null || echo no file))"; fi
