#!/bin/bash
# tools/phone/verify/runner-deploy.sh [install|remove|status] (Mac): the verify queue's runner as the launchd agent
# com.powos.verify-runner (its plist next to this; unit units/mac/verify-runner-mac.json).
#   install  the plist into ~/Library/LaunchAgents (paths filled in), the hand-started runner stopped (its TERM trap
#            leaves its job queued; nothing else touches the queue), the agent (re)loaded - it starts at once when
#            jobs are queued. Re-run after changing the plist.
#   remove   the agent unloaded (its TERM trap: the running check stays queued) and its plist deleted. The queue
#            (~/.cache/powos-verify-queue) is kept; `queue.sh add` starts a runner of its own again.
#   status   launchd's view of it.
# Stop it for a while without removing: `launchctl bootout user/$(id -u)/com.powos.verify-runner` (back: install).
# Loaded into user/<uid> (this Mac is headless): after a reboot, the first `queue.sh add` loads it again.
# Test agents: QUEUE_AGENT=<label> with QUEUE_DIR/HOME of their own (never the real queue or a second real runner).
# powos-units: deploy host=mac
set -euo pipefail
L=com.powos.verify-runner
here=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$(dirname "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)")" && pwd -P)
# This checkout is moving to $POWOS_RUN_ROOT/verify-runner (wt-move-rest) - prefer that, fall back to the old
# $REPO/.claude/worktrees/verify-runner while it still has the real checkout (so install still works mid-move).
POWOS_RUN_ROOT=${POWOS_RUN_ROOT:-$HOME/pw}
VR=$POWOS_RUN_ROOT/verify-runner
[ -e "$VR/.git" ] || [ ! -e "$REPO/.claude/worktrees/verify-runner/.git" ] || VR=$REPO/.claude/worktrees/verify-runner
Q=$HOME/.cache/powos-verify-queue
P=$HOME/Library/LaunchAgents/$L.plist
D=user/$(id -u)   # headless Mac: no gui domain; the plist is LimitLoadToSessionType Background
loaded() { launchctl print "$D/$L" >/dev/null 2>&1; }
# The runner of the queue dir's pid file, if it's alive and not launchd's own: a hand-started one.
hand_runner() {
  local p lp; p=$(cat "$Q/runner.lock/pid" 2>/dev/null || cat "$Q/runner.pid" 2>/dev/null) || return 1
  kill -0 "$p" 2>/dev/null || return 1
  lp=$(launchctl print "$D/$L" 2>/dev/null | sed -nE 's/^[[:space:]]*pid = ([0-9]+).*/\1/p')
  [ "$p" != "$lp" ] && echo "$p"
}
case "${1:-install}" in
install)
  [ -e "$VR/.git" ] || git -C "$REPO" worktree add -q --detach "$VR" origin/worktree-powos-multiplatform
  [ -f "$VR/tools/phone/verify/queue.sh" ] || { echo "runner-deploy: $VR has no queue.sh (push it, then queue.sh run once)"; exit 1; }
  mkdir -p "$Q/done" "$HOME/Library/LaunchAgents"
  sed -e "s#@HOME@#$HOME#g" -e "s#@VR@#$VR#g" "$here/$L.plist" > "$P"
  plutil -lint "$P" >/dev/null
  # Migrate: the hand-started runner goes first (TERM: its check stays queued, the lock is freed), so the agent is the
  # only runner - the job files themselves are never moved.
  if p=$(hand_runner); then
    echo "stopping the hand-started runner (pid $p)"; kill "$p"
    for _ in $(seq 40); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
    kill -0 "$p" 2>/dev/null && { echo "runner-deploy: pid $p still up after 40 s - not loading a second runner"; exit 1; }
  fi
  loaded && launchctl bootout "$D/$L" 2>/dev/null || true
  for _ in $(seq 40); do loaded || break; sleep 1; done
  launchctl bootstrap "$D" "$P"
  echo "loaded $L ($(ls "$Q"/*.job 2>/dev/null | wc -l | tr -d ' ') jobs queued)" ;;
remove)
  loaded && launchctl bootout "$D/$L" || true
  rm -f "$P"
  echo "removed $L (the queue is kept)" ;;
status)
  loaded && launchctl print "$D/$L" | grep -E '^\s*(state|pid|last exit code|runs) ' || echo "$L: not loaded" ;;
*) sed -n 2,11p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
