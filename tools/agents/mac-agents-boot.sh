#!/bin/bash
# tools/agents/mac-agents-boot.sh [--dry-run] (Mac, as root): (re)load every installed PowOS launchd agent
# (~<user>/Library/LaunchAgents/com.powos.*.plist) that is not loaded in the user's launchd domain. Run at boot and
# every 10 min by the LaunchDaemon com.powos.mac-agents-boot (tools/agents/mac-agents-boot-deploy.sh; unit
# units/mac/mac-agents-boot-mac.json).
#
# Why (2026-11-09, board task mac-disk-keeps-hitting-the-fleet-death-cliff-dur): the Mac went from 14 to 0 GB free in
# 7 h. Its PowOS agents are bootstrapped into user/<uid> by their deploy scripts from an SSH session - and this Mac is
# headless, so after a reboot nothing loads ~/Library/LaunchAgents (no GUI login). The 11-02 reboot silently killed
# com.powos.board-sweep (its worktree gc: 74 merged, idle worktrees piled up in ~/pw) and the 11-07 reboot killed
# com.powos.mac-disk-trim (Colima fstrim: freed VM blocks - image rebuilds, removed layers - stayed allocated on the
# Mac; it had been returning up to 19 GiB per pass). Only the agents someone re-installed by hand came back.
#
# HACK: a root daemon that bootstraps user agents, because macOS loads LaunchAgents only for a GUI login and this Mac
# never has one. Real fix: each deploy script installs its job as its own LaunchDaemon with UserName=<user> (what
# PowStation does for colima/vm-route), so launchd itself starts it at boot.
#
# Loads only plists already installed by a deploy script (`<x>-deploy.sh remove` deletes the plist, so a removed
# agent stays removed; rename one to *.plist.disabled to keep it off). Never edits, unloads or restarts a loaded one.
# Log: ~<user>/Library/Logs/powos-mac-agents-boot.log (only when it loads something, or fails to).
set -u
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
U=${POWOS_AGENTS_USER:-macback}
uid=$(id -u "$U") || { echo "no user $U" >&2; exit 1; }
H=$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}'); [ -n "$H" ] || H=/Users/$U
LOG=$H/Library/Logs/powos-mac-agents-boot.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; chown "$U" "$LOG" 2>/dev/null; [ $DRY = 1 ] && echo "$*"; return 0; }
for p in "$H"/Library/LaunchAgents/com.powos.*.plist; do
  [ -f "$p" ] || continue
  # Only the user's own files: a plist anyone else could write would run as the user.
  [ "$(stat -f %u "$p")" = "$uid" ] || { log "skip $p: not owned by $U"; continue; }
  l=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$p" 2>/dev/null) || { log "skip $p: no Label"; continue; }
  launchctl print "user/$uid/$l" >/dev/null 2>&1 && continue
  if [ $DRY = 1 ]; then log "dry-run: would load $l"; continue; fi
  if out=$(launchctl bootstrap "user/$uid" "$p" 2>&1); then log "loaded $l (was not loaded)"; else log "FAILED to load $l: $out"; fi
done
exit 0
