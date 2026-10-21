#!/bin/bash
# Build the PowOS APK from a clean tree and install it on the phone - one at a time across ALL sessions/agents
# (a lock: two builds at once overwrote the shared out/powos.apk), through install-app.sh (privapp allowlist
# guard + app-data backup), then verify the app came back (gesture input, no new crash).
#   tools/phone/ship-apk.sh --note "what changed, plain words" [--now]
# Waits for the user to be idle >= 60 s (or the screen off) before installing - an install restarts the PowOS session;
# never installs over an active user (exit 4 after SHIP_WAIT_MIN minutes). --now skips the wait (only for urgent fixes).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
note="" now=""
while [ $# -gt 0 ]; do case "$1" in --note) note=$2; shift 2;; --now) now=1; shift;; *) echo "unknown: $1" >&2; exit 2;; esac; done
[ -n "${note// }" ] || { echo "ship-apk: --note \"...\" required" >&2; exit 2; }
lock=$HOME/.cache/powos-ship.lock; mkdir -p "$HOME/.cache"
# Never ship a build that lacks what's installed: the last shipped commit must be in HEAD (two agents' APKs
# overwrote each other's work). Rebase onto worktree-powos-multiplatform first.
last=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
if [ -n "$last" ] && ! git merge-base --is-ancestor "$last" HEAD 2>/dev/null; then
  echo "ship-apk: REFUSED - HEAD lacks the installed build's commit $last (git rebase worktree-powos-multiplatform)" >&2; exit 3
fi
until mkdir "$lock" 2>/dev/null; do
  echo "ship-apk: waiting for $(cat "$lock/who" 2>/dev/null || echo another build)"; sleep 15
done
echo "$(git rev-parse --short HEAD) $(git branch --show-current) pid $$ $(date +%H:%M:%S)" > "$lock/who"
trap 'rm -rf "$lock"' EXIT
targets/android/build-app.sh 2>&1 | grep -E "^e: |BUILD|version code|refus|error:" 
apk=$HOME/Projects/android-app-dev/output/powos.apk
if [ -z "$now" ]; then
  # Never install over an active user (it restarts their session): wait up to SHIP_WAIT_MIN (default 60) minutes for
  # 60 s of idle (or the screen off); if none comes, leave the built APK for the next ship and exit 4 - don't install.
  waited=0; ok=""
  while [ $waited -lt $(( ${SHIP_WAIT_MIN:-60} * 60 )) ]; do
    i2=$(tools/phone/idle.sh); s=${i2#idle=}; s=${s%% *}
    # Screen off (Asleep/Dozing) = safe at once; Awake = only after 60 s without a touch; anything else (an empty or
    # unreadable state) = NOT safe - it installed over an active user once when the state came back empty.
    case "$i2" in *screen=Asleep*|*screen=Dozing*) ok=1; break ;; *screen=Awake*) [ "$s" -ge 60 ] && { ok=1; break; } ;; esac
    sleep 15; waited=$((waited + 15))
  done
  echo "ship-apk: $i2"
  [ -n "$ok" ] || { echo "ship-apk: the user stayed active for ${SHIP_WAIT_MIN:-60} min - NOT installing (APK built, kept)"; exit 4; }
fi
start=$(tools/phone/adb.sh shell 'date +%m-%d\ %H:%M:%S' | tr -d '\r')
docker run --rm --network container:powos-vadb -v "$PWD/targets/android":/ta:ro -v "$apk":/powos.apk:ro --entrypoint bash \
  android-app-dev-android-builder:latest -c 'export PATH=$PATH:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/35.0.0
    adb connect 10.13.13.7:5555 >/dev/null; export ANDROID_SERIAL=10.13.13.7:5555
    cp -r /ta /tmp/ta && cd /tmp/ta && ./install-app.sh /powos.apk --note "'"${note//\"/}"'"' 2>&1 | tail -4
git rev-parse HEAD > "$HOME/.cache/powos-installed-commit"
# The APK was built from HEAD, which holds every committed shell push: drop ALL shell overrides so the phone runs
# one consistent shell (a stale override of assistant.ts shadowing the new APK's assist.tsx froze home, the shade
# and assist at 09:47). Uncommitted pushes are lost by design - commit before you push.
shell/push.sh --vpn --reset 2>&1 | tail -2
sleep 15
tools/phone/adb.sh shell "dumpsys package com.powos.app | grep -m1 versionCode; logcat -d -v time -T '$start.000' | grep -E 'gesture input on|Fatal signal|FATAL EXCEPTION' | tail -4"
