#!/bin/sh
# powos-vadb's main process (compose.yaml): the adb server, kept connected to the phone over the VPN. `adb connect` on
# an already connected device is a no-op, so every 30 s it only reconnects after a drop (phone reboot, VPN blip).
# No su here: connecting is not a root request on the phone.
set -u
: "${ANDROID_SERIAL:?ANDROID_SERIAL (host:port of the phone's adbd) is required}"
mkdir -p /state/xfer /state/status
adb start-server >/dev/null 2>&1
last=
while :; do
  st=$(adb -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)
  if [ "$st" != device ]; then
    adb disconnect "$ANDROID_SERIAL" >/dev/null 2>&1
    adb connect "$ANDROID_SERIAL" >/dev/null 2>&1
    st=$(adb -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)
  fi
  [ "$st" = "$last" ] || echo "$(date '+%F %T') vadb: $ANDROID_SERIAL ${st:-unreachable}"
  last=$st
  sleep 30
done
