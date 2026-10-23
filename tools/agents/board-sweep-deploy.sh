#!/bin/bash
# tools/agents/board-sweep-deploy.sh [install|remove|status|run] (Mac): the work board's orphan sweeper as the launchd
# agent com.powos.board-sweep (every 30 min; its plist next to this; unit units/mac/board-sweep-mac.json).
#   install  the plist into ~/Library/LaunchAgents (paths filled in), (re)loaded - it sweeps once at load
#   remove   unloaded and its plist deleted (~/.cache/powos-board-sweep, its state and log, kept)
#   status   launchd's view of it and the last sweep's log lines
#   run      one sweep now (board-sweep.sh)
# powos-units: deploy host=mac
set -euo pipefail
L=com.powos.board-sweep
here=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$(dirname "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)")" && pwd -P)
R=$REPO/.claude/worktrees/verify-runner
P=$HOME/Library/LaunchAgents/$L.plist
D=user/$(id -u)
case "${1:-install}" in
install)
  [ -f "$R/tools/agents/board-sweep.sh" ] || { echo "board-sweep-deploy: $R has no tools/agents/board-sweep.sh yet (push it; the verify runner fast-forwards its checkout)"; exit 1; }
  mkdir -p "$HOME/.cache/powos-board-sweep" "$HOME/Library/LaunchAgents"
  # powos-units: ~/Library/LaunchAgents/com.powos.board-sweep.plist
  sed -e "s#@HOME@#$HOME#g" -e "s#@R@#$R#g" "$here/$L.plist" > "$P"
  plutil -lint "$P" >/dev/null
  launchctl bootout "$D/$L" 2>/dev/null || true
  launchctl bootstrap "$D" "$P"
  echo "installed $L (every 30 min, from $R)" ;;
remove)
  launchctl bootout "$D/$L" 2>/dev/null || true
  rm -f "$P"; echo "removed $L" ;;
status)
  launchctl print "$D/$L" 2>/dev/null | grep -E "state|last exit|runs" || echo "$L not loaded"
  tail -20 "$HOME/.cache/powos-board-sweep/sweep.log" 2>/dev/null || true ;;
run) exec "$here/board-sweep.sh" "${@:2}" ;;
*) sed -n 2,7p "$0"; exit 2 ;;
esac
