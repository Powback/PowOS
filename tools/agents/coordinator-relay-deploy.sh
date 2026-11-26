#!/bin/bash
# tools/agents/coordinator-relay-deploy.sh [install|remove|status|run] (Mac): the phone's "coordinator" mail relayed
# to the Mac coordinator as the launchd agent com.powos.coordinator-relay (every 60 s; its plist next to this; unit
# units/mac/coordinator-relay-mac.json). Each pass is one docker exec (WireGuard freshness) while the phone is off.
#   install  the plist into ~/Library/LaunchAgents (paths filled in), (re)loaded - it relays once at load
#   remove   unloaded and its plist deleted (~/.cache/powos-coordinator-inbox.{jsonl,log}, the relayed mail, kept)
#   status   launchd's view of it and the last relayed lines
#   run      one pass now (coordinator-relay.py run)
# powos-units: deploy host=mac
set -euo pipefail
L=com.powos.coordinator-relay
here=$(cd "$(dirname "$0")" && pwd -P)
# Runs from the verify-runner checkout (fast-forwarded by the runner), never a worktree that may be removed.
POWOS_RUN_ROOT=${POWOS_RUN_ROOT:-$HOME/pw}
R=$POWOS_RUN_ROOT/verify-runner
P=$HOME/Library/LaunchAgents/$L.plist
D=user/$(id -u)
case "${1:-install}" in
install)
  [ -f "$R/tools/agents/coordinator-relay.py" ] || { echo "coordinator-relay-deploy: $R has no tools/agents/coordinator-relay.py yet (land it; the verify runner fast-forwards its checkout)"; exit 1; }
  mkdir -p "$HOME/.cache/powos-coordinator-relay" "$HOME/Library/LaunchAgents"
  # powos-units: ~/Library/LaunchAgents/com.powos.coordinator-relay.plist
  sed -e "s#@HOME@#$HOME#g" -e "s#@R@#$R#g" "$here/$L.plist" > "$P"
  plutil -lint "$P" >/dev/null
  launchctl bootout "$D/$L" 2>/dev/null || true
  launchctl bootstrap "$D" "$P"
  echo "installed $L (every 60 s, from $R)" ;;
remove)
  launchctl bootout "$D/$L" 2>/dev/null || true
  rm -f "$P"; echo "removed $L" ;;
status)
  launchctl print "$D/$L" 2>/dev/null | grep -E "state|last exit|runs" || echo "$L not loaded"
  tail -5 "$HOME/.cache/powos-coordinator-relay/launchd.err" 2>/dev/null || true
  tail -10 "$HOME/.cache/powos-coordinator-inbox.log" 2>/dev/null || true ;;
run) exec python3 "$here/coordinator-relay.py" run ;;
*) sed -n 2,9p "$0"; exit 2 ;;
esac
