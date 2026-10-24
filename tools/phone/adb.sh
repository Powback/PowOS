#!/bin/bash
# adb to the phone over the VPN (the powos-vadb container's adb server, 10.13.13.7:5555), from the Mac:
#   tools/phone/adb.sh shell 'dumpsys power | head'      tools/phone/adb.sh push FILE /data/local/tmp/
# Paths given to push/pull/install are on the Mac, anywhere (temp dirs too); they reach a throwaway android-builder container sharing
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
# The handshake-age check and the adb connect-state check below each cost a `docker exec` (~0.2-0.3s apiece,
# measured 2026-10-24 - the dominant cost of every adb.sh call: tools/agents/friction f78, 2.5-4.7s/call vs 0.33s
# for a raw `docker exec powos-vadb adb ...`). A live tunnel only drops its handshake every ~2 min, and the adb
# connection only goes stale after a real network change on the phone, so a GOOD result is cached for
# ADB_STATE_CACHE_S (default 30s); anything else (no cache yet, cache expired, or the last check failed) always
# re-checks live - a failure is never papered over by a stale "ok".
state_file=${POWOS_ADB_STATE_FILE:-/tmp/.powos-adb-state}
now=$(date +%s); cached_ok=
if read -r c_epoch c_status 2>/dev/null < "$state_file"; then
  [ "$c_status" = ok ] && [ $(( now - c_epoch )) -lt "${ADB_STATE_CACHE_S:-30}" ] && cached_ok=1
fi
if [ -z "$cached_ok" ]; then
  age=$(wg_age)
  if [ -n "$age" ] && { [ "$age" = never ] || [ "$age" -gt "${PHONE_WG_STALE_S:-180}" ]; }; then
    echo "adb.sh: phone offline: its WireGuard handshake is $([ "$age" = never ] && echo "missing" || echo "${age}s old") (> ${PHONE_WG_STALE_S:-180}s) - not running adb (docker exec wireguard wg show)" >&2
    exit 69
  fi
  # A network change on the phone (wifi <-> mobile) leaves powos-vadb's adb connection stale ("offline", "device
  # not found") although the VPN is up: every agent's next call then fails. Not "device"? Drop it and connect
  # afresh, once, before the command (a pre-check, not a retry: the command itself never runs twice).
  if [ "$(docker exec powos-vadb adb -s 10.13.13.7:5555 get-state 2>/dev/null || true)" != device ]; then
    docker exec powos-vadb sh -c 'adb disconnect 10.13.13.7:5555 >/dev/null 2>&1; timeout 15 adb connect 10.13.13.7:5555 >/dev/null 2>&1' || true
  fi
  printf '%s ok\n' "$now" > "$state_file.$$" && mv -f "$state_file.$$" "$state_file"
fi
# Local paths: only a file command's own arguments are (push's sources, pull's destination, install's APKs) - a
# `shell cat /etc/hosts` word that happens to exist on the Mac is the phone's path and is left be.
# Under $HOME the file's directory is bind-mounted (Colima shares only the home directory into its VM). Anywhere else
# (mktemp's /var/folders/.../T, /tmp) a mount would be an empty directory in the VM and adb said "cannot stat"
# (user.sh with a /tmp script, apps/install.sh's mktemp stage, 2026-10-24), so the file is copied in with `docker cp`,
# which reads through the Docker client on the Mac, and a pull's result is copied back out the same way.
sub=; for a in "$@"; do [[ "$a" == -* ]] || { sub=$a; break; }; done
shared() { [[ "$1" == "$HOME" || "$1" == "$HOME"/* ]]; }
args=() mounts=() cp_in=() cp_out=() i=0
for a in "$@"; do
  i=$((i + 1)); role=
  case "$sub" in
    push) [ "$i" -lt "$#" ] && [ "$a" != push ] && [[ "$a" != -* ]] && role=in ;;
    pull) [ "$i" = "$#" ] && [ "$i" -gt 2 ] && role=out ;;
    install|install-multiple|install-multi-package|sideload) [ "$a" != "$sub" ] && [[ "$a" != -* ]] && role=in ;;
  esac
  # A path with ".." in it (e.g. verify-runner/../powos-multiplatform/...) can't be walked inside the container:
  # it failed "cannot stat" (kwin 3.23 never reached the phone, 2026-10-23). Relative paths too
  # (`KWIN_PKG=targets/android/out/pkgs/...`): unmounted, the push failed silently (kwin 3.26, 21:35, 2026-10-23).
  # So every local path is resolved to its physical location first.
  if [ "$role" = in ] && [ -e "$a" ]; then
    d=$(cd "$(dirname "$a")" && pwd -P); a="$d/$(basename "$a")"
    if shared "$d"; then mounts+=(-v "$d:$d")
    else cp_in+=("$a" "/stage/in/$i"); a="/stage/in/$i/$(basename "$a")"; fi
  elif [ "$role" = out ] && [ -d "$(dirname "$a")" ]; then
    # A pull's new local file (or an existing directory): its directory mounted, else the file stayed in the
    # throwaway container (window-rec's recordings never reached the Mac, 2026-10-23).
    d=$(cd "$(dirname "$a")" && pwd -P); a="$d/$(basename "$a")"
    if shared "$d"; then mounts+=(-v "$d:$d")
    elif [ -d "$a" ]; then cp_out+=("/stage/out/." "$a"); a=/stage/out/
    else cp_out+=("/stage/out/$(basename "$a")" "$a"); a="/stage/out/$(basename "$a")"; fi
  fi
  args+=("$a")
done
# Argument-only commands (shell, logcat, devices, forward, ...) touch no host path at all: skip the throwaway
# android-builder container and its `docker run` create/teardown entirely - that's the other big chunk of the
# per-call cost in friction f78 - and exec straight into powos-vadb's own, already-running, already-connected adb:
# the same one-`docker exec` path the 0.33s benchmark used.
if [ ${#mounts[@]} -eq 0 ] && [ ${#cp_in[@]} -eq 0 ] && [ ${#cp_out[@]} -eq 0 ]; then
  exec docker exec -i powos-vadb adb -s 10.13.13.7:5555 "${args[@]}"
fi
run=(--network container:powos-vadb ${mounts[@]+"${mounts[@]}"} --entrypoint /opt/android-sdk/platform-tools/adb
  android-app-dev-android-builder:latest -s 10.13.13.7:5555 "${args[@]}")
[ ${#cp_in[@]} -eq 0 ] && [ ${#cp_out[@]} -eq 0 ] && exec docker run --rm -i "${run[@]}"
# docker cp: create the container, copy the files in, run it attached, copy results out, remove it.
c=$(docker create -i "${run[@]}"); sk=$(mktemp -d)
trap 'docker rm -f "$c" >/dev/null 2>&1 || true; rm -rf "$sk"' EXIT
mkdir -p "$sk/stage/out"; for ((j = 1; j < ${#cp_in[@]}; j += 2)); do mkdir -p "$sk${cp_in[j]}"; done
docker cp -q "$sk/stage" "$c:/stage"
for ((j = 0; j < ${#cp_in[@]}; j += 2)); do docker cp -q "${cp_in[j]}" "$c:${cp_in[j + 1]}/"; done
rc=0; docker start -ai "$c" || rc=$?
for ((j = 0; j < ${#cp_out[@]}; j += 2)); do docker cp -q "$c:${cp_out[j]}" "${cp_out[j + 1]}" || { [ "$rc" != 0 ] || rc=1; }; done
exit "$rc"
