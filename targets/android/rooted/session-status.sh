#!/bin/bash
# What the rooted desktop session is doing, from the Mac: the root session log, the app's run dir (logs of each
# service, sockets, desktop-ready) and which session processes run.   rooted/session-status.sh [lines]
set -uo pipefail
n=${1:-15}
SU=$(adb shell 'command -v su || echo /debug_ramdisk/su' | tr -d '\r')
RUN=/data/data/com.powos.app/files/run
adb shell "$SU -c 'tail -n $n /data/powos/session.log 2>&1'"
echo "--- run dir"
adb shell "$SU -c 'ls -la $RUN $RUN/andromarchy 2>&1'"
for l in hyprland powos-root-session andromarchy dbus pipewire; do
  echo "--- $l.log"
  adb shell "$SU -c 'tail -n $n $RUN/$l.log 2>/dev/null'"
done
echo "--- processes"
adb shell "$SU -c 'ps -A -o PID,NAME'" | grep -E "kwin|plasmashell|startplasma|pipewire|dbus-daemon|andromarchy|powos" || echo "(none)"
