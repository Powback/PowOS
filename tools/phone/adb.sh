#!/bin/bash
# adb to the phone over the VPN (the powos-vadb container's adb server, 10.13.13.7:5555), from the Mac:
#   tools/phone/adb.sh shell 'dumpsys power | head'      tools/phone/adb.sh push FILE /data/local/tmp/
# Paths given to push/pull are on the Mac (under $HOME: Colima only shares the home directory, not /tmp); they're mounted into a throwaway android-builder container sharing
# powos-vadb's network, so any session or agent can use it (no per-session mounts).
set -euo pipefail
# The device: POWOS_DEVICE=phone (default) or emu - the emulator lane (tools/emu/emu.sh: the AVD shaped like the Open's
# inner screen), through the SDK's own adb on the Mac. Every check that goes through adb.sh (and cdp.sh, idle.sh,
# root.sh, user.sh, shot.sh) runs unchanged against it.
case "${POWOS_DEVICE:-phone}" in
  phone) ;;
  emu)
    [ "${1:-}" = --vpn-state ] && { echo "vpn=emu (the emulator, no VPN)"; exit 0; }
    exec "${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}/platform-tools/adb" -s "emulator-${EMU_PORT:-5584}" "$@" ;;
  *) echo "adb.sh: POWOS_DEVICE=${POWOS_DEVICE} - phone or emu" >&2; exit 2 ;;
esac
# Fail fast when the phone is off the VPN. adb keeps listing the device after the tunnel died, and every call then
# HANGS (2026-10-23/24: drops at ~13:40, 16:0x, 19:5x, 02:56 held the ship service, the check queue and the board).
# Both ends send a keepalive every 25 s, so a live tunnel re-handshakes about every 2 min; a handshake older than
# PHONE_WG_STALE_S (default 180 s, WireGuard's own reject-after time) means no packet can reach the phone. Exit 69
# (EX_UNAVAILABLE) with "phone offline" on stderr, without touching adb. Unreadable (wireguard container down or not
# ours): carry on as before - the command then fails on its own.
wg_age() {
  docker exec wireguard wg show wg0 dump 2>/dev/null | awk -F'\t' -v now="$(date +%s)" \
    'NR > 1 && $4 ~ /(^|,)10\.13\.13\.7\/32(,|$)/ { print ($5 == 0 ? "never" : now - $5); exit }'
}
if [ "${1:-}" = --vpn-state ]; then
  a=$(wg_age); [ -n "$a" ] || { echo "vpn=unknown"; exit 0; }
  [ "$a" != never ] && [ "$a" -le "${PHONE_WG_STALE_S:-180}" ] && { echo "vpn=up handshake=${a}s"; exit 0; }
  echo "vpn=offline handshake=$a$([ "$a" = never ] || echo s)"; exit 69
fi
age=$(wg_age)
if [ -n "$age" ] && { [ "$age" = never ] || [ "$age" -gt "${PHONE_WG_STALE_S:-180}" ]; }; then
  echo "adb.sh: phone offline: its WireGuard handshake is $([ "$age" = never ] && echo "missing" || echo "${age}s old") (> ${PHONE_WG_STALE_S:-180}s) - not running adb (docker exec wireguard wg show)" >&2
  exit 69
fi
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
