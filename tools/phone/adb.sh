#!/bin/bash
# adb to the phone over the VPN (the powos-vadb container's adb server, 10.13.13.7:5555), from the Mac:
#   tools/phone/adb.sh shell 'dumpsys power | head'      tools/phone/adb.sh push FILE /data/local/tmp/
# Paths given to push/pull are on the Mac (under $HOME: Colima only shares the home directory, not /tmp); they're mounted into a throwaway android-builder container sharing
# powos-vadb's network, so any session or agent can use it (no per-session mounts).
set -euo pipefail
# A network change on the phone (wifi <-> mobile) leaves powos-vadb's adb connection stale ("offline", "device not
# found") although the VPN is up: every agent's next call then fails. Not "device"? Drop it and connect afresh, once,
# before the command (a pre-check, not a retry: the command itself never runs twice).
if [ "$(docker exec powos-vadb adb -s 10.13.13.7:5555 get-state 2>/dev/null || true)" != device ]; then
  docker exec powos-vadb sh -c 'adb disconnect 10.13.13.7:5555 >/dev/null 2>&1; timeout 15 adb connect 10.13.13.7:5555 >/dev/null 2>&1' || true
fi
args=() mounts=()
# A path with ".." in it (e.g. verify-runner/../powos-multiplatform/...) can't be walked inside the container, where
# only the file's own directory is mounted: it failed "cannot stat" (kwin 3.23 never reached the phone, 2026-10-23).
# Resolve every existing absolute path to its physical location first.
for a in "$@"; do
  # Relative paths too (`KWIN_PKG=targets/android/out/pkgs/...`): unmounted, the push failed silently and kwin 3.26
  # never installed (21:35, 2026-10-23). A word with a slash that exists here is a local path.
  if [[ -e "$a" && ( "$a" == /* || "$a" == */* ) ]]; then
    d=$(cd "$(dirname "$a")" && pwd -P); a="$d/$(basename "$a")"; mounts+=(-v "$d:$d")
  elif [[ "$a" == "$HOME"/* && -d "$(dirname "$a")" ]]; then
    # A pull's new local file: its directory mounted, else the file stayed in the throwaway container (window-rec's
    # recordings never reached the Mac, 2026-10-23). Only under $HOME: a phone path (/data/..., /tmp/...) is left be.
    d=$(cd "$(dirname "$a")" && pwd -P); a="$d/$(basename "$a")"; mounts+=(-v "$d:$d")
  fi
  args+=("$a")
done
exec docker run --rm -i --network container:powos-vadb ${mounts[@]+"${mounts[@]}"} --entrypoint /opt/android-sdk/platform-tools/adb \
  android-app-dev-android-builder:latest -s 10.13.13.7:5555 "${args[@]}"
