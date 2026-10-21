#!/bin/bash
# Build the PowOS APK from a clean tree and install it on the phone - one at a time across ALL sessions/agents
# (a lock: two builds at once overwrote the shared out/powos.apk), through install-app.sh (privapp allowlist
# guard + app-data backup), then verify the app came back (gesture input, no new crash).
#   tools/phone/ship-apk.sh --note "what changed, plain words" [--now]
# Waits for the user to be idle >= 60 s before installing (an install restarts the PowOS session); --now skips that.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
note="" now=""
while [ $# -gt 0 ]; do case "$1" in --note) note=$2; shift 2;; --now) now=1; shift;; *) echo "unknown: $1" >&2; exit 2;; esac; done
[ -n "${note// }" ] || { echo "ship-apk: --note \"...\" required" >&2; exit 2; }
lock=$HOME/.cache/powos-ship.lock; mkdir -p "$HOME/.cache"
until mkdir "$lock" 2>/dev/null; do
  echo "ship-apk: waiting for $(cat "$lock/who" 2>/dev/null || echo another build)"; sleep 15
done
echo "$(git rev-parse --short HEAD) $(git branch --show-current) pid $$ $(date +%H:%M:%S)" > "$lock/who"
trap 'rm -rf "$lock"' EXIT
targets/android/build-app.sh 2>&1 | grep -E "^e: |BUILD|version code|refus|error:" 
apk=$HOME/Projects/android-app-dev/output/powos.apk
if [ -z "$now" ]; then
  for i in $(seq 1 90); do i2=$(tools/phone/idle.sh); s=${i2#idle=}; s=${s%% *}; [ "$s" -ge 60 ] && break; sleep 10; done
  echo "ship-apk: $i2"
fi
start=$(tools/phone/adb.sh shell 'date +%m-%d\ %H:%M:%S' | tr -d '\r')
docker run --rm --network container:powos-vadb -v "$PWD/targets/android":/ta:ro -v "$apk":/powos.apk:ro --entrypoint bash \
  android-app-dev-android-builder:latest -c 'export PATH=$PATH:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/35.0.0
    adb connect 10.13.13.7:5555 >/dev/null; export ANDROID_SERIAL=10.13.13.7:5555
    cp -r /ta /tmp/ta && cd /tmp/ta && ./install-app.sh /powos.apk --note "'"${note//\"/}"'"' 2>&1 | tail -4
sleep 15
tools/phone/adb.sh shell "dumpsys package com.powos.app | grep -m1 versionCode; logcat -d -v time -T '$start.000' | grep -E 'gesture input on|Fatal signal|FATAL EXCEPTION' | tail -4"
