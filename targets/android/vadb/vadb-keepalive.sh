#!/bin/sh
# powos-vadb's main process (compose.yaml): the adb server, kept connected to the phone over the VPN. `adb connect` on
# an already connected device is a no-op, so every 30 s it only reconnects after a drop (phone reboot, VPN blip).
# No su here: connecting is not a root request on the phone.
# UNAUTHORIZED (the phone's "Allow USB debugging?" pending or denied): never disconnect/reconnect every 30 s - each
# reconnect is a new auth request, a new dialog on the user's screen (11-08: the dialog storm). While the phone
# reports unauthorized the pending connection is kept as it is and at most one reconnect is tried per
# VADB_UNAUTH_BACKOFF_S (default 600 s); reading the state never prompts, so an Allow is picked up within 30 s.
# tools/phone/adb.sh backs off the same way on the Mac's side (docs/REMOTE-POWOS.md, "adb authorization").
set -u
: "${ANDROID_SERIAL:?ANDROID_SERIAL (host:port of the phone's adbd) is required}"
mkdir -p /state/xfer /state/status
adb start-server >/dev/null 2>&1
last= unauth_at=0
state() { o=$(adb -s "$ANDROID_SERIAL" get-state 2>&1 || true)
  case "$o" in device) echo device ;; *unauthorized*) echo unauthorized ;; *) echo "" ;; esac; }
while :; do
  st=$(state)
  [ "$st" = unauthorized ] && [ "$unauth_at" = 0 ] && unauth_at=$(date +%s)
  if [ "$st" = device ]; then unauth_at=0
  elif [ "$unauth_at" != 0 ] && [ $(( $(date +%s) - unauth_at )) -lt "${VADB_UNAUTH_BACKOFF_S:-600}" ]; then
    :   # backing off: no connect while the phone asks the user
  else
    [ "$unauth_at" != 0 ] && unauth_at=$(date +%s)   # the window's one attempt
    adb disconnect "$ANDROID_SERIAL" >/dev/null 2>&1
    adb connect "$ANDROID_SERIAL" >/dev/null 2>&1
    st=$(state)
    [ "$st" = unauthorized ] && [ "$unauth_at" = 0 ] && unauth_at=$(date +%s)
  fi
  [ "$st" = "$last" ] || echo "$(date '+%F %T') vadb: $ANDROID_SERIAL ${st:-unreachable}$([ "$st" = unauthorized ] && echo " - backing off reconnects ${VADB_UNAUTH_BACKOFF_S:-600}s")"
  last=$st
  sleep "${VADB_POLL_S:-30}"
done
