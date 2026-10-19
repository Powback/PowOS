#!/bin/bash
# Pushes shell files to the phone's override folder (the app's files/shell): the shell there hot-reloads them, no
# APK. A file pushed here wins over the one the APK ships until it's removed (--reset), so a later APK's version of it
# only shows after a reset.
#
# Usage: shell/push.sh --note "what changed, for the user" <file>...   paths relative to shell/ (e.g. ui/drawer.js)
#        shell/push.sh --reset [file...] remove overrides (all, or the files named)
#        --vpn first: through the VPN instead of a local adb (the wireguard container's network, as the Mac reaches
#        the phone: adb at 10.13.13.7:5555, or $POWOS_PHONE_ADDR).
# The note is the phone's quiet "update applied" notification (shade only, batched over 2 min with other deploys:
# targets/android/tools/deploy-note.sh): plain words - "Switcher now follows your finger" - never a file or a hash.
# ANDROID_SERIAL picks the phone when several are connected.
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1:-}" = "--vpn" ]; then
  shift
  addr=${POWOS_PHONE_ADDR:-10.13.13.7:5555}
  exec docker run --rm -i --network container:wireguard -v "$HOME/.android:/root/.android" -v "$PWD:/shell" \
    -e ANDROID_SERIAL="$addr" android-app-dev-android-builder:latest \
    bash -c 'adb connect "$ANDROID_SERIAL" >/dev/null 2>&1; sleep 1; bash /shell/push.sh "$@"' _ "$@"
fi
note=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --note) note=${2:-}; shift 2 || shift ;;
    --note=*) note=${1#--note=}; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- ${args[@]+"${args[@]}"}
if [ $# -gt 0 ] && [ "$1" != "--reset" ] && [ -z "${note// }" ]; then
  echo "push.sh: --note \"what changed, for the user\" is required (the phone's update notification)" >&2
  exit 2
fi
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
[ $# -gt 0 ] || { sed -n '2,15p' "$0"; exit 1; }
for f in "$@"; do
  [ -f "$f" ] || { echo "push.sh: no such shell file: $f" >&2; exit 1; }
  tmp=/data/local/tmp/powos-shell-push
  adb push -q "$f" "$tmp"
  as_app "mkdir -p files/shell/$(dirname "$f") && cat $tmp > files/shell/$f" && adb shell "rm -f $tmp"
  echo "pushed $f"
done
# The phone's "update applied" notification (as targets/android/tools/deploy-note.sh, which this folder alone - the
# --vpn container mounts only shell/ - can't reach): one su call, comms batches it with the other deploys.
b=$(printf '%s' "$note" | base64 | tr -d '\n')
adb shell "su -c \"sh /data/powos/powos-run.sh 'echo $b | base64 -d | powos comms notify --from deploy --priority low --batch deploy -'\"" >/dev/null ||
  echo "push.sh: the phone wasn't told (\"$note\")" >&2
