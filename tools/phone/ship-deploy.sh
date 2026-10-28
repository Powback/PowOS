#!/bin/bash
# tools/phone/ship-deploy.sh [install|remove|status] (Mac): the ship service (tools/phone/ship.sh run) as the launchd
# agent com.powos.ship-runner (its plist next to this; unit units/mac/ship-runner-mac.json).
#   install  the plist into ~/Library/LaunchAgents (paths filled in), the agent (re)loaded - it starts at once when
#            ships are requested. Re-run after changing the plist. Refuses while an APK ship holds ~/.cache/powos-ship.lock.
#   remove   the agent unloaded (a ship it was running is killed; its requests stay queued) and its plist deleted.
#            The requests (~/.cache/powos-ship-queue) are kept; `ship.sh request` starts a runner of its own again.
#   status   launchd's view of it.
# Stop it for a while without removing: `launchctl bootout user/$(id -u)/com.powos.ship-runner` (back: install).
# Loaded into user/<uid> (this Mac is headless): after a reboot, the first `ship.sh request` loads it again.
#   gate-install / gate-remove  the ship gate (install runs it too; makes ~/.config/powos/ship-gate.secret if absent) (ship-gate.py, com.powos.ship-gate; unit units/mac/ship-gate-mac.json)
# powos-units: deploy host=mac
set -euo pipefail
L=com.powos.ship-runner
here=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$(dirname "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)")" && pwd -P)
# This checkout is moving to $POWOS_RUN_ROOT/ship-runner (wt-move-rest) - prefer that, fall back to the old
# $REPO/.claude/worktrees/ship-runner while it still has the real checkout (so install still works mid-move).
POWOS_RUN_ROOT=${POWOS_RUN_ROOT:-$HOME/pw}
SR=$POWOS_RUN_ROOT/ship-runner
[ -e "$SR/.git" ] || [ ! -e "$REPO/.claude/worktrees/ship-runner/.git" ] || SR=$REPO/.claude/worktrees/ship-runner
Q=$HOME/.cache/powos-ship-queue
P=$HOME/Library/LaunchAgents/$L.plist
D=user/$(id -u)   # headless Mac: no gui domain; the plist is LimitLoadToSessionType Background
loaded() { launchctl print "$D/$L" >/dev/null 2>&1; }
case "${1:-install}" in
install)
  [ -d "$HOME/.cache/powos-ship.lock" ] && { echo "ship-deploy: an APK ship is running ($(cat "$HOME/.cache/powos-ship.lock/who" 2>/dev/null)) - install after it"; exit 1; }
  [ -e "$SR/.git" ] || git -C "$REPO" worktree add -q --detach "$SR" origin/worktree-powos-multiplatform
  [ -f "$SR/tools/phone/ship.sh" ] || { echo "ship-deploy: $SR has no ship.sh (push it to origin first)"; exit 1; }
  mkdir -p "$Q/done" "$HOME/Library/LaunchAgents"
  sed -e "s#@HOME@#$HOME#g" -e "s#@VR@#$SR#g" "$here/$L.plist" > "$P"
  plutil -lint "$P" >/dev/null
  loaded && launchctl bootout "$D/$L" 2>/dev/null || true
  for _ in $(seq 40); do loaded || break; sleep 1; done
  launchctl bootstrap "$D" "$P"
  echo "loaded $L ($(ls "$Q"/*.req 2>/dev/null | wc -l | tr -d ' ') requests queued)"
  # The gate (powos self push --ship) comes with the runner, so no manual step remains; it never fails the install.
  "$0" gate-install || echo "ship-deploy: gate-install failed (above) - the runner is installed; retry: $0 gate-install" ;;
remove)
  loaded && launchctl bootout "$D/$L" || true
  rm -f "$P"
  echo "removed $L (the requests are kept)" ;;
status)
  loaded && launchctl print "$D/$L" | grep -E '^\s*(state|pid|last exit code|runs) ' || echo "$L: not loaded" ;;
gate-install)
  # The LAN door for `powos self push --ship` (tools/phone/ship-gate.py). Its secret is made here when absent (random,
  # 0600, never printed, never in git); the phone gets the same file from `rooted.sh deploy`. Idempotent.
  # macOS's firewall may ask once to allow python3 on port 7433 - Allow it (this script changes no firewall setting).
  G=com.powos.ship-gate; GP=$HOME/Library/LaunchAgents/$G.plist; GS=$HOME/.config/powos/ship-gate.secret
  if [ ! -s "$GS" ]; then
    ( umask 077; mkdir -p "$(dirname "$GS")"; openssl rand -hex 24 > "$GS.new" && mv "$GS.new" "$GS" )
    echo "ship-deploy: made $GS (0600; the next rooted deploy puts it on the phone)"
  fi
  chmod 600 "$GS"
  [ -f "$SR/tools/phone/ship-gate.py" ] || { echo "ship-deploy: $SR has no ship-gate.py (push it to origin first)"; exit 1; }
  mkdir -p "$Q" "$HOME/Library/LaunchAgents"
  sed -e "s#@HOME@#$HOME#g" -e "s#@VR@#$SR#g" "$here/$G.plist" > "$GP"; plutil -lint "$GP" >/dev/null
  launchctl bootout "$D/$G" 2>/dev/null || true; sleep 1
  launchctl bootstrap "$D" "$GP"; echo "loaded $G (port 7433)" ;;
gate-remove)
  launchctl bootout "$D/com.powos.ship-gate" 2>/dev/null || true; rm -f "$HOME/Library/LaunchAgents/com.powos.ship-gate.plist"
  echo "removed com.powos.ship-gate" ;;
*) sed -n 2,10p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
