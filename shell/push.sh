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
# Testing the safety net: break test/gate-test.tsx (the test-only page, ?mode=gate-test), never a live page, and push it
# with --test[=ROLE] (the manifest says so: its reports go to ROLE's inbox - default shelltest, a scratch role, never
# the manager or the user - as "[test]", low priority, read again after 2 min).
set -euo pipefail
cd "$(dirname "$0")"
force=""
for a in "$@"; do [ "$a" = --force ] && force=1; done
if [ "${1:-}" = "--vpn" ]; then
  shift
  addr=${POWOS_PHONE_ADDR:-10.13.13.7:5555}
  # The gate here, on the Mac (docker and git are here, not in the adb container): the committed shell + the phone's
  # current overrides (pulled through the adb container, as the local path pulls them) + the files pushed - the shell
  # the phone will run. Without the overrides it checked a shell the phone doesn't have (2026-10-21: a push that passed
  # was followed by a home error). Overrides that can't be pulled: the committed shell + the files, as before.
  if [ -z "${POWOS_GATE_DONE:-}" ] && [[ " $* " != *" --reset "* ]] && [[ " $* " != *" --errors "* ]]; then
    gf=(); for a in "$@"; do case "$a" in --*) ;; *) [ -f "$a" ] && gf+=("$a") ;; esac; done
    if [ ${#gf[@]} -gt 0 ]; then
      # Under $HOME: Colima mounts only the home folder into containers.
      mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate"
      ov=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate/vpn-overrides.XXXXXX")
      ga=()
      if docker run --rm --network container:wireguard -v "$HOME/.android:/root/.android" -v "$ov:/ov" \
        -e ANDROID_SERIAL="$addr" android-app-dev-android-builder:latest bash -c \
        'adb connect "$ANDROID_SERIAL" >/dev/null 2>&1; adb -s "$ANDROID_SERIAL" exec-out "su -c \"cd /data/data/com.powos.app/files && tar -cf - shell\"" | tar -xf - -C /ov' \
        >/dev/null 2>&1 && [ -d "$ov/shell" ]; then
        ga=(--overrides "$ov/shell")
      else
        echo "push.sh: couldn't pull the phone's overrides - gating the committed shell + these files only" >&2
      fi
      set +e
      dev/gate.sh ${ga[@]+"${ga[@]}"} "${gf[@]}"
      gate=$?
      set -e
      rm -rf "$ov"
      if [ $gate -ne 0 ]; then
        [ -n "$force" ] || { echo "push.sh: refused - the gate failed (above). Fix it, or --force to push anyway." >&2; exit 1; }
        echo "push.sh: the gate failed - pushing anyway (--force)" >&2
      fi
    fi
  fi
  exec docker run --rm -i --network container:wireguard -v "$HOME/.android:/root/.android" -v "$PWD:/shell" \
    -e ANDROID_SERIAL="$addr" -e POWOS_GATE_DONE=1 android-app-dev-android-builder:latest \
    bash -c 'adb connect "$ANDROID_SERIAL" >/dev/null 2>&1; sleep 1; bash /shell/push.sh "$@"' _ "$@"
fi
note="" test="" test_to=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --note) note=${2:-}; shift 2 || shift ;;
    --note=*) note=${1#--note=}; shift ;;
    --force) shift ;;
    --test) test=1; test_to=shelltest; shift ;;
    --test=*) test=1; test_to=${1#--test=}; shift ;;
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
manifest=$(printf '{"at":%s,"files":%s,"note":"%s","from":"%s","test":%s,"testTo":"%s"}' "$(date +%s)" "$files_json" "$json_note" "$(hostname -s 2>/dev/null || echo mac)" "$([ -n "$test" ] && echo true || echo false)" "$test_to" | base64 | tr -d '\n')
as_app "rm -rf files/shell-prev && echo $manifest | base64 -d > files/shell-push.json"
# Atomic: every file staged on the phone first (one adb push of a tar, unpacked into files/shell-staging - the same
# filesystem as files/shell), then all of them renamed into files/shell in one call, between files/shell/.pushing
# written (echo, a CLOSE_WRITE - touch only opens it read-only) and removed. A page reloads once, on the whole push:
# ShellHost's HotReload holds every change while .pushing is there and sends them when it goes; an older APK sends
# each, and the renames all land within hot.ts's 300 ms debounce. File by file (each its own adb round trip, ~1 s), a
# page reloaded between an importer and the new module it imports, and the import 404'd (2026-10-20 02:59: gesture.ts
# landed, ui/keyboard.ts a second later).
tmp=/data/local/tmp/powos-shell-push.tar
tarf=$(mktemp "${TMPDIR:-/tmp}/powos-shell-push.XXXXXX")
tflags=(); tar --version 2>/dev/null | grep -q bsdtar && tflags=(--no-xattrs --no-mac-metadata --format ustar)
COPYFILE_DISABLE=1 tar ${tflags[@]+"${tflags[@]}"} -cf "$tarf" "$@"
adb push -q "$tarf" "$tmp"
rm -f "$tarf"
moves=""
for f in "$@"; do
  moves="$moves if [ -f shell/$f ]; then mkdir -p shell-prev/$(dirname "$f") && cp shell/$f shell-prev/$f; fi; mkdir -p shell/$(dirname "$f") && mv -f shell-staging/$f shell/$f || ok=0;"
done
as_app "cd files && rm -rf shell-staging && mkdir -p shell-staging && tar -xf $tmp -C shell-staging && echo > shell/.pushing && ok=1 && {$moves true; }; rm -f shell/.pushing; rm -rf shell-staging; [ \${ok:-0} = 1 ]" || {
  as_app "rm -f files/shell/.pushing; rm -rf files/shell-staging"; adb shell "rm -f $tmp"
  echo "push.sh: staging or moving the files on the phone failed" >&2; exit 1; }
adb shell "rm -f $tmp"
for f in "$@"; do echo "pushed $f"; done
# The phone's "update applied" notification (as targets/android/tools/deploy-note.sh, which this folder alone - the
# --vpn container mounts only shell/ - can't reach): one su call, comms batches it with the other deploys.
b=$(printf '%s' "$note" | base64 | tr -d '\n')
adb shell "su -c \"sh /data/powos/powos-run.sh 'echo $b | base64 -d | powos comms notify --from deploy --priority low --batch deploy -'\"" >/dev/null ||
  echo "push.sh: the phone wasn't told (\"$note\")" >&2
