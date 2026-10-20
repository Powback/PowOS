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
#
# The gate (shell/dev/gate.sh) runs first: tsc, then every page (home, lock, shade, assist, aod, recents) booted in a
# headless Chromium - the committed shell + the phone's current overrides + these files, as the phone will serve them.
# A page that doesn't load refuses the push, with the error. --force pushes anyway (the gate still runs and says so).
# A push writes a manifest (files/shell-push.json: when, which files, the note) and keeps the overrides it replaced
# (files/shell-prev/): a page that fails to boot within 2 min of it has that push rolled back by the app
# (ShellHost/ShellErrors.kt) and the manager told. Every shell error on the phone reaches the manager's comms inbox and
# files/shell-errors.log:
#        shell/push.sh --errors [N]   the phone's last N (default 40) shell errors (`powos shell errors` on the phone)
set -euo pipefail
cd "$(dirname "$0")"
force=""
for a in "$@"; do [ "$a" = --force ] && force=1; done
if [ "${1:-}" = "--vpn" ]; then
  shift
  addr=${POWOS_PHONE_ADDR:-10.13.13.7:5555}
  # The gate here, on the Mac (docker and git are here, not in the adb container); the phone's overrides aren't
  # reachable from here, so it checks the committed shell + the files pushed.
  if [ -z "${POWOS_GATE_DONE:-}" ] && [[ " $* " != *" --reset "* ]] && [[ " $* " != *" --errors "* ]]; then
    gf=(); for a in "$@"; do case "$a" in --*) ;; *) [ -f "$a" ] && gf+=("$a") ;; esac; done
    if [ ${#gf[@]} -gt 0 ] && ! dev/gate.sh "${gf[@]}"; then
      [ -n "$force" ] || { echo "push.sh: refused - the gate failed (above). Fix it, or --force to push anyway." >&2; exit 1; }
      echo "push.sh: the gate failed - pushing anyway (--force)" >&2
    fi
  fi
  exec docker run --rm -i --network container:wireguard -v "$HOME/.android:/root/.android" -v "$PWD:/shell" \
    -e ANDROID_SERIAL="$addr" -e POWOS_GATE_DONE=1 android-app-dev-android-builder:latest \
    bash -c 'adb connect "$ANDROID_SERIAL" >/dev/null 2>&1; sleep 1; bash /shell/push.sh "$@"' _ "$@"
fi
note=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --note) note=${2:-}; shift 2 || shift ;;
    --note=*) note=${1#--note=}; shift ;;
    --force) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- ${args[@]+"${args[@]}"}
if [ $# -gt 0 ] && [ "$1" != "--reset" ] && [ "$1" != "--errors" ] && [ -z "${note// }" ]; then
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
if [ "${1:-}" = "--errors" ]; then
  as_app "tail -n ${2:-40} files/shell-errors.log 2>/dev/null || echo no shell errors logged"
  exit 0
fi
if [ "${1:-}" = "--reset" ]; then
  shift
  if [ $# -eq 0 ]; then
    # Its contents, not the folder: the shell watches the folder itself, and a new one would go unwatched. No push
    # left to roll back either.
    as_app "rm -rf files/shell/* files/shell/.[!.]*; rm -rf files/shell-push.json files/shell-prev"
  else
    for f in "$@"; do as_app "rm -f files/shell/$f"; done
  fi
  exit 0
fi
[ $# -gt 0 ] || { sed -n '2,23p' "$0"; exit 1; }
for f in "$@"; do
  [ -f "$f" ] || { echo "push.sh: no such shell file: $f" >&2; exit 1; }
  case "$f" in *"'"*|*" "*) echo "push.sh: no quotes or spaces in shell paths: $f" >&2; exit 1 ;; esac
done
# The gate: the shell the phone will run after this push - the committed shell, the phone's overrides (pulled in one
# call), these files - type-checked and every page booted (shell/dev/gate.sh).
if [ -z "${POWOS_GATE_DONE:-}" ]; then
  ov=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate/overrides.XXXXXX" 2>/dev/null || mktemp -d)
  as_app "cd files && tar -cf - shell 2>/dev/null | base64" | tr -d '\r' | base64 -d 2>/dev/null | tar -xf - -C "$ov" 2>/dev/null || true
  set +e
  dev/gate.sh --overrides "$ov/shell" "$@"
  gate=$?
  set -e
  rm -rf "$ov"
  if [ $gate -ne 0 ]; then
    [ -n "$force" ] || { echo "push.sh: refused - the gate failed (above). Fix it, or --force to push anyway." >&2; exit 1; }
    echo "push.sh: the gate failed - pushing anyway (--force)" >&2
  fi
fi
# The push manifest, before the files (a page booting on the first of them already knows it's this push's), and the
# overrides it replaces kept (files/shell-prev/): what the app's rollback restores (ShellErrors.kt).
files_json=$(printf '"%s",' "$@"); files_json="[${files_json%,}]"
json_note=$(printf '%s' "$note" | tr -d '\n\r\t' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-300)
manifest=$(printf '{"at":%s,"files":%s,"note":"%s","from":"%s"}' "$(date +%s)" "$files_json" "$json_note" "$(hostname -s 2>/dev/null || echo mac)" | base64 | tr -d '\n')
as_app "rm -rf files/shell-prev && echo $manifest | base64 -d > files/shell-push.json"
for f in "$@"; do
  tmp=/data/local/tmp/powos-shell-push
  adb push -q "$f" "$tmp"
  as_app "if [ -f files/shell/$f ]; then mkdir -p files/shell-prev/$(dirname "$f") && cp files/shell/$f files/shell-prev/$f; fi; mkdir -p files/shell/$(dirname "$f") && cat $tmp > files/shell/$f" && adb shell "rm -f $tmp"
  echo "pushed $f"
done
# The phone's "update applied" notification (as targets/android/tools/deploy-note.sh, which this folder alone - the
# --vpn container mounts only shell/ - can't reach): one su call, comms batches it with the other deploys.
b=$(printf '%s' "$note" | base64 | tr -d '\n')
adb shell "su -c \"sh /data/powos/powos-run.sh 'echo $b | base64 -d | powos comms notify --from deploy --priority low --batch deploy -'\"" >/dev/null ||
  echo "push.sh: the phone wasn't told (\"$note\")" >&2
