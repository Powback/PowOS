#!/bin/bash
# tools/agents/mac-agents-boot-deploy.sh [install|remove|status|dry-run] (Mac, uses sudo): the LaunchDaemon
# com.powos.mac-agents-boot that loads every installed com.powos.* launchd agent at boot and every 10 min
# (tools/agents/mac-agents-boot.sh says why; unit units/mac/mac-agents-boot-mac.json).
#   install  script copied root-owned to /usr/local/libexec/powos/, plist into /Library/LaunchDaemons, (re)loaded -
#            its first pass runs at once and loads whatever agent is missing
#   remove   unloaded, plist and copy deleted (the log ~/Library/Logs/powos-mac-agents-boot.log kept)
#   status   launchd's view of it, which com.powos agents are loaded, and the last log lines
#   dry-run  one pass that loads nothing, prints what it would load
# powos-units: deploy host=mac
set -euo pipefail
L=com.powos.mac-agents-boot
here=$(cd "$(dirname "$0")" && pwd -P)
BIN=/usr/local/libexec/powos
P=/Library/LaunchDaemons/$L.plist
U=$(id -un)
case "${1:-install}" in
install)
  sudo mkdir -p "$BIN"
  sudo install -o root -g wheel -m 755 "$here/mac-agents-boot.sh" "$BIN/mac-agents-boot.sh"
  sed -e "s#@BIN@#$BIN#g" -e "s#@USER@#$U#g" "$here/$L.plist" | sudo tee "$P" >/dev/null
  sudo chown root:wheel "$P"; sudo chmod 644 "$P"
  plutil -lint "$P" >/dev/null
  sudo launchctl bootout "system/$L" 2>/dev/null || true
  sudo launchctl bootstrap system "$P"
  echo "installed $L (boot + every 10 min)" ;;
remove)
  sudo launchctl bootout "system/$L" 2>/dev/null || true
  sudo rm -f "$P" "$BIN/mac-agents-boot.sh"; echo "removed $L" ;;
status)
  sudo launchctl print "system/$L" 2>/dev/null | grep -E "state|last exit|runs" || echo "$L not loaded"
  for p in "$HOME"/Library/LaunchAgents/com.powos.*.plist; do
    l=$(basename "$p" .plist); launchctl print "user/$(id -u)/$l" >/dev/null 2>&1 && echo "loaded      $l" || echo "NOT loaded  $l"
  done
  tail -10 "$HOME/Library/Logs/powos-mac-agents-boot.log" 2>/dev/null || true ;;
dry-run) sudo POWOS_AGENTS_USER="$U" bash "$here/mac-agents-boot.sh" --dry-run ;;
*) echo "usage: $0 [install|remove|status|dry-run]" >&2; exit 2 ;;
esac
