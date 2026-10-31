#!/bin/bash
# tools/units/publish-deploy.sh [install|remove|status|run] (Mac): every host's units published to the PowOS AI page
# every 15 min, as the launchd agent com.powos.units-publish (its plist next to this; unit units/mac/units-publish-mac.json).
#   install  publish.sh copied to ~/.local/share/powos/units-publish/ (it fetches origin's powos-units each pass, so
#            the copy only changes with publish.sh itself), the plist into ~/Library/LaunchAgents, (re)loaded - it
#            publishes once at load
#   remove   unloaded, its plist and copy deleted (~/.cache/powos-units-publish, the snapshots and log, kept)
#   status   launchd's view of it and the last log lines
#   run      one pass now (publish.sh all)
# powos-units: deploy host=mac
set -euo pipefail
L=com.powos.units-publish
here=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$(dirname "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)")" && pwd -P)
BIN=$HOME/.local/share/powos/units-publish
P=$HOME/Library/LaunchAgents/$L.plist
D=user/$(id -u)
case "${1:-install}" in
install)
  mkdir -p "$BIN" "$HOME/.cache/powos-units-publish" "$HOME/Library/LaunchAgents"
  # powos-units: ~/.local/share/powos/units-publish/publish.sh
  install -m 755 "$here/publish.sh" "$BIN/publish.sh"
  echo "$REPO" > "$HOME/.cache/powos-units-publish/repo"
  # powos-units: ~/Library/LaunchAgents/com.powos.units-publish.plist
  sed -e "s#@HOME@#$HOME#g" -e "s#@BIN@#$BIN#g" -e "s#@R@#$REPO#g" "$here/$L.plist" > "$P"
  plutil -lint "$P" >/dev/null
  launchctl bootout "$D/$L" 2>/dev/null || true
  launchctl bootstrap "$D" "$P"
  echo "installed $L (every 15 min; fetches from $REPO)" ;;
remove)
  launchctl bootout "$D/$L" 2>/dev/null || true
  rm -f "$P"; rm -rf "$BIN"; echo "removed $L" ;;
status)
  launchctl print "$D/$L" 2>/dev/null | grep -E "state|last exit|runs" || echo "$L not loaded"
  tail -10 "$HOME/.cache/powos-units-publish/publish.log" 2>/dev/null || true ;;
run) exec "$here/publish.sh" all ;;
*) sed -n 2,9p "$0"; exit 2 ;;
esac
