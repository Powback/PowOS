#!/bin/bash
# tools/agents/mac-disk-trim-deploy.sh [install|remove|status|run|dry-run] (Mac): Colima fstrim every 20 min + a weekly
# removal of long-dead loose containers (never build cache, images or volumes) as the launchd agent
# com.powos.mac-disk-trim (its plist next to this; unit units/mac/mac-disk-trim-mac.json).
#   install  mac-disk-trim.sh copied to ~/.local/share/powos/mac-disk-trim/, the plist into ~/Library/LaunchAgents,
#            (re)loaded; then the manager's crontab fstrim line it replaces (tagged "powos manager: return freed VM
#            space to macOS") is removed - only that exact line, every other crontab entry stays
#   remove   unloaded, its plist and copy deleted (~/.cache/powos-mac-disk-trim, the log, kept)
#   status   launchd's view of it and the last log lines
#   run      one pass now;  dry-run  one pass that removes and discards nothing (fstrim -n, lists candidates)
# powos-units: deploy host=mac
set -euo pipefail
L=com.powos.mac-disk-trim
here=$(cd "$(dirname "$0")" && pwd -P)
BIN=$HOME/.local/share/powos/mac-disk-trim
P=$HOME/Library/LaunchAgents/$L.plist
D=user/$(id -u)
CRON_TAG='# powos manager: return freed VM space to macOS'
case "${1:-install}" in
install)
  mkdir -p "$BIN" "$HOME/.cache/powos-mac-disk-trim" "$HOME/Library/LaunchAgents"
  install -m 755 "$here/mac-disk-trim.sh" "$BIN/mac-disk-trim.sh"
  sed -e "s#@HOME@#$HOME#g" -e "s#@BIN@#$BIN#g" "$here/$L.plist" > "$P"
  plutil -lint "$P" >/dev/null
  launchctl bootout "$D/$L" 2>/dev/null || true
  launchctl bootstrap "$D" "$P"
  # The unit now does what the cron line did: drop exactly that line (matched on its tag), nothing else.
  if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
    crontab -l | grep -vF "$CRON_TAG" | crontab -
    echo "removed the crontab fstrim line it replaces"
  fi
  echo "installed $L (every 20 min; weekly container removal)" ;;
remove)
  launchctl bootout "$D/$L" 2>/dev/null || true
  rm -f "$P"; rm -rf "$BIN"; echo "removed $L" ;;
status)
  launchctl print "$D/$L" 2>/dev/null | grep -E "state|last exit|runs" || echo "$L not loaded"
  tail -10 "$HOME/.cache/powos-mac-disk-trim/trim.log" 2>/dev/null || true ;;
run) exec "$here/mac-disk-trim.sh" ;;
dry-run) exec "$here/mac-disk-trim.sh" --dry-run ;;
*) sed -n 2,10p "$0"; exit 2 ;;
esac
