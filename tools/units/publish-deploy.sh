#!/bin/bash
# tools/units/publish-deploy.sh [install|remove|status|run] (Mac, uses sudo): every host's units published to the PowOS
# AI page every 15 min, as the LaunchDaemon com.powos.units-publish run as you (its plist next to this says why a daemon;
# unit units/mac/units-publish-mac.json).
#   install  publish.sh copied to ~/.local/share/powos/units-publish/ (it fetches origin's powos-units each pass, so
#            the copy only changes with publish.sh itself), the plist into /Library/LaunchDaemons, (re)loaded - it
#            publishes once at load and at every boot; the old LaunchAgent (pre-11-26) unloaded and deleted
#   remove   unloaded, its plist and copy deleted (~/.cache/powos-units-publish, the snapshots and log, kept)
#   status   launchd's view of it and the last log lines
#   run      one pass now (publish.sh all)
# powos-units: deploy host=mac
set -euo pipefail
L=com.powos.units-publish
here=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$(dirname "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)")" && pwd -P)
BIN=$HOME/.local/share/powos/units-publish
P=/Library/LaunchDaemons/$L.plist
OLD=$HOME/Library/LaunchAgents/$L.plist
D=system
case "${1:-install}" in
install)
  mkdir -p "$BIN" "$HOME/.cache/powos-units-publish" "$HOME/Library/LaunchAgents"
  # powos-units: ~/.local/share/powos/units-publish/publish.sh
  install -m 755 "$here/publish.sh" "$BIN/publish.sh"
  echo "$REPO" > "$HOME/.cache/powos-units-publish/repo"
  # The LaunchAgent it was until 11-26 (never loaded again after a reboot on this headless Mac).
  launchctl bootout "user/$(id -u)/$L" 2>/dev/null || true; rm -f "$OLD"
  # powos-units: /Library/LaunchDaemons/com.powos.units-publish.plist
  sed -e "s#@USER@#$(id -un)#g" -e "s#@HOME@#$HOME#g" -e "s#@BIN@#$BIN#g" -e "s#@R@#$REPO#g" "$here/$L.plist" |
    sudo tee "$P" >/dev/null
  sudo chown root:wheel "$P"; sudo chmod 644 "$P"
  plutil -lint "$P" >/dev/null
  sudo launchctl bootout "$D/$L" 2>/dev/null || true
  sudo launchctl bootstrap "$D" "$P"
  echo "installed $L (boot + every 15 min, as $(id -un); fetches from $REPO)" ;;
remove)
  sudo launchctl bootout "$D/$L" 2>/dev/null || true
  launchctl bootout "user/$(id -u)/$L" 2>/dev/null || true
  sudo rm -f "$P"; rm -f "$OLD"; rm -rf "$BIN"; echo "removed $L" ;;
status)
  launchctl print "$D/$L" 2>/dev/null | grep -E "state|last exit|runs" || echo "$L not loaded"
  tail -10 "$HOME/.cache/powos-units-publish/publish.log" 2>/dev/null || true ;;
run) exec "$here/publish.sh" all ;;
*) sed -n 2,9p "$0"; exit 2 ;;
esac
