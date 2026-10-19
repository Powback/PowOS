#!/bin/bash
# Pushes shell files to the phone's override folder (the app's files/shell): the shell there hot-reloads them, no
# APK. A file pushed here wins over the one the APK ships until it's removed (--reset), so a later APK's version of it
# only shows after a reset.
#
# Usage: shell/push.sh <file>...        paths relative to shell/ (e.g. ui/drawer.js theme.css)
#        shell/push.sh --reset [file...] remove overrides (all, or the files named)
# ANDROID_SERIAL picks the phone when several are connected.
set -euo pipefail
cd "$(dirname "$0")"
pkg=com.powos.app
# As the app (run-as), or as root where run-as can't reach it: a privileged system app's data (the PowOS system module)
# is privapp_data_file, out of run-as's reach. Root writes files as the app's user so the app can still change them.
if adb shell "run-as $pkg true" >/dev/null 2>&1; then
  as_app() { adb shell "run-as $pkg sh -c '$1'"; }
else
  uid=$(adb shell "su -c 'stat -c %u /data/data/$pkg'" | tr -d '\r')
  as_app() { adb shell "su $uid -c 'cd /data/data/$pkg && $1'"; }
fi
if [ "${1:-}" = "--reset" ]; then
  shift
  if [ $# -eq 0 ]; then
    # Its contents, not the folder: the shell watches the folder itself, and a new one would go unwatched.
    as_app "rm -rf files/shell/* files/shell/.[!.]*"
  else
    for f in "$@"; do as_app "rm -f files/shell/$f"; done
  fi
  exit 0
fi
[ $# -gt 0 ] || { sed -n '2,9p' "$0"; exit 1; }
for f in "$@"; do
  [ -f "$f" ] || { echo "push.sh: no such shell file: $f" >&2; exit 1; }
  tmp=/data/local/tmp/powos-shell-push
  adb push -q "$f" "$tmp"
  as_app "mkdir -p files/shell/$(dirname "$f") && cat $tmp > files/shell/$f" && adb shell "rm -f $tmp"
  echo "pushed $f"
done
