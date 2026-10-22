#!/bin/bash
# Build the PowOS APK from a clean tree and install it on the phone - one at a time across ALL sessions/agents
# (a lock: two builds at once overwrote the shared out/powos.apk), through install-app.sh (privapp allowlist
# guard + app-data backup), then verify the app came back (gesture input, no new crash).
#   tools/phone/ship-apk.sh --note "what changed, plain words" [--now]
#   tools/phone/ship-apk.sh --silent [--now]    a change the user can't see (refactor, lint, tooling): no notification
# Waits for the user to be idle >= 60 s (or the screen off) before installing - an install restarts the PowOS session;
# never installs over an active user (exit 4 after SHIP_WAIT_MIN minutes). --now skips the wait (only for urgent fixes).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# Always the shared, current rules: each worktree has its own copy of this script, and an old copy skipped the
# "only the origin tip" check (an unmerged e89fb58 got installed). Re-run as origin's version unless it's this one.
if [ -z "${SHIP_APK_CURRENT:-}" ]; then
  git fetch -q origin worktree-powos-multiplatform 2>/dev/null || true
  cur=$(mktemp); git show origin/worktree-powos-multiplatform:tools/phone/ship-apk.sh > "$cur" 2>/dev/null || true
  if [ -s "$cur" ] && ! cmp -s "$cur" "$0"; then SHIP_APK_CURRENT=1 exec bash "$cur" "$@"; fi
  rm -f "$cur"
fi
note="" now="" silent=""
while [ $# -gt 0 ]; do case "$1" in --note) note=$2; shift 2;; --silent) silent=1; shift;; --now) now=1; shift;; *) echo "unknown: $1" >&2; exit 2;; esac; done
[ -n "${note// }" ] || [ -n "$silent" ] || { echo "ship-apk: --note \"...\" (or --silent for a change the user can't see) required" >&2; exit 2; }
# The note install-app.sh gets: the user's line, or --silent (only comms' quiet log).
if [ -n "$silent" ]; then inote="--silent"; else inote="--note \"${note//\"/}\""; fi
lock=$HOME/.cache/powos-ship.lock; mkdir -p "$HOME/.cache"
# Never ship a build that lacks what's installed: the last shipped commit must be in HEAD (two agents' APKs
# overwrote each other's work). Rebase onto worktree-powos-multiplatform first.
# Ship only what's already on origin/worktree-powos-multiplatform: a build from an unpushed commit (8f2a606) left
# every other agent's next build refused for lacking it.
git fetch -q origin worktree-powos-multiplatform 2>/dev/null || true
if ! git merge-base --is-ancestor HEAD origin/worktree-powos-multiplatform 2>/dev/null; then
  echo "ship-apk: REFUSED - HEAD isn't on origin/worktree-powos-multiplatform yet: fast-forward/rebase and push first" >&2; exit 3
fi
# ...and it must BE that tip: the install resets every shell override, so a build missing a newer shell-only push (a
# revert that brought the blur back, 10:15) silently undid it on the phone at 10:17.
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/worktree-powos-multiplatform)" ]; then
  echo "ship-apk: REFUSED - HEAD is behind origin/worktree-powos-multiplatform: git pull --ff-only (or rebase) first" >&2; exit 3
fi
last=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
if [ -n "$last" ] && ! git merge-base --is-ancestor "$last" HEAD 2>/dev/null; then
  echo "ship-apk: REFUSED - HEAD lacks the installed build's commit $last (git rebase worktree-powos-multiplatform)" >&2; exit 3
fi
until mkdir "$lock" 2>/dev/null; do
  echo "ship-apk: waiting for $(cat "$lock/who" 2>/dev/null || echo another build)"; sleep 15
done
echo "$(git rev-parse --short HEAD) $(git branch --show-current) pid $$ $(date +%H:%M:%S)" > "$lock/who"
trap 'rm -rf "$lock"' EXIT
# Queued ships coalesce: each one builds the origin tip it saw, so a ship whose HEAD is already IN the installed build
# (another ship took the lock first and built a newer tip) has nothing left to install - 3 ships queued behind one idle
# wait each rebuilt and reinstalled the same code (2026-10-22). Skip it instead of an ~8 min build + install.
inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
git fetch -q origin worktree-powos-multiplatform 2>/dev/null || true
if [ -n "$inst" ] && git merge-base --is-ancestor HEAD "$inst" 2>/dev/null; then
  echo "ship-apk: already shipped - the installed build $(git rev-parse --short "$inst") contains $(git rev-parse --short HEAD); nothing to do"
  exit 0
fi
# The commit's own shell must load before it's built in: the APK ships it whole, and an install resets the overrides
# that may have covered for it (17:09: 5130d98's home.tsx imported a gesture.ts export only a later commit added -
# every page failed to boot after the install). The gate on HEAD alone: tsc + every page booted.
if ! READY_MS=${READY_MS:-30000} IDLE_MS=0 bash shell/dev/gate.sh > "${TMPDIR:-/tmp}/ship-apk-gate.log" 2>&1; then
  grep -vE "^ok " "${TMPDIR:-/tmp}/ship-apk-gate.log" | tail -8 >&2
  echo "ship-apk: REFUSED - this commit's shell doesn't load (above); fix it on origin first" >&2
  exit 3
fi
targets/android/build-app.sh 2>&1 | grep -E "^e: |BUILD|version code|refus|error:"
apk=$HOME/Projects/android-app-dev/output/powos.apk
if [ -z "$now" ]; then
  # Never install over an active user (it restarts their session): wait up to SHIP_WAIT_MIN (default 60) minutes for
  # 60 s of idle (or the screen off); if none comes, leave the built APK for the next ship and exit 4 - don't install.
  waited=0; ok=""
  while [ $waited -lt $(( ${SHIP_WAIT_MIN:-60} * 60 )) ]; do
    # A verifier's measurement window has priority (an install restarts the app mid-run and voids it):
    # ~/.cache/powos-verify.lock (mkdir; who/why inside) holds the install until it's gone.
    # A verify lock is for an injected test (minutes). One older than 10 min is held through a wait (a check waiting for
    # idle or for the user to fold - 2026-10-22, twice, blocking every APK for 20+ min): warn and don't wait on it.
    vl="$HOME/.cache/powos-verify.lock"
    if [ -d "$vl" ] && [ $(( $(date +%s) - $(stat -f %m "$vl" 2>/dev/null || stat -c %Y "$vl") )) -lt 600 ]; then
      sleep 15; waited=$((waited + 15)); continue
    fi
    [ -d "$vl" ] && echo "ship-apk: ignoring a stale verify lock (held 10+ min by: $(cat "$vl/who" 2>/dev/null)) - locks are for injected tests, not waits" >&2
    # One held call that returns when the phone is free (the waiting runs on the phone: no poll over the VPN), in
    # 10-min chunks so the verify lock above is seen. Screen off (Asleep/Dozing) = safe at once; Awake = only after 60 s
    # without a touch; anything else (an empty or unreadable state) = NOT safe - it installed over an active user once
    # when the state came back empty.
    chunk=$(( ${SHIP_WAIT_MIN:-60} * 60 - waited )); [ $chunk -gt 600 ] && chunk=600
    # exit 1 = this chunk passed without a free phone: wait the next one (set -e would end the whole ship here).
    i2=$(tools/phone/idle.sh --wait 60 $chunk || true)
    case "$i2" in *screen=Asleep*|*screen=Dozing*|*screen=Awake*) ok=1; break ;; esac
    waited=$((waited + chunk))
  done
  echo "ship-apk: $i2"
  [ -n "$ok" ] || { echo "ship-apk: the user stayed active for ${SHIP_WAIT_MIN:-60} min - NOT installing (APK built, kept)"; exit 4; }
fi
start=$(tools/phone/adb.sh shell 'date +%m-%d\ %H:%M:%S' | tr -d '\r')
docker run --rm --network container:powos-vadb -v "$PWD/targets/android":/ta:ro -v "$apk":/powos.apk:ro --entrypoint bash \
  android-app-dev-android-builder:latest -c 'export PATH=$PATH:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/35.0.0
    adb connect 10.13.13.7:5555 >/dev/null; export ANDROID_SERIAL=10.13.13.7:5555
    cp -r /ta /tmp/ta && cd /tmp/ta && ./install-app.sh /powos.apk '"$inote"'' 2>&1 | tail -4
git rev-parse HEAD > "$HOME/.cache/powos-installed-commit"
# The shell it just installed decodes the phone's live modules only with bindings of their shape (home couldn't read
# local-pet's rows twice on 2026-10-21): checked in one call; bindings ahead of a module that this commit builds are
# published, anything else is reported with its fix (the install stands either way).
tools/phone/bindings-check.sh || echo "ship-apk: the shell's bindings don't match the phone's modules - fix above" >&2
# The APK was built from HEAD, which holds every committed shell push: drop ALL shell overrides so the phone runs
# one consistent shell (a stale override of assistant.ts shadowing the new APK's assist.tsx froze home, the shade
# and assist at 09:47). Uncommitted pushes are lost by design - commit before you push.
shell/push.sh --vpn --reset 2>&1 | tail -2
# ...but a shell push committed WHILE this APK built (or waited to install) isn't in it, and the reset just removed it
# (15:58: a360435 committed 31 s after the build of 366aa8e started; the 15:59 install wiped it). Push again every
# shell file origin changed since the build commit, from origin's tip, through the gate as any push.
git fetch -q origin worktree-powos-multiplatform 2>/dev/null || true
newer=$(git diff --name-only HEAD origin/worktree-powos-multiplatform -- shell/ 2>/dev/null | grep -vE '^shell/(dev|test)/' |
  while read -r f; do git cat-file -e "origin/worktree-powos-multiplatform:$f" 2>/dev/null && echo "${f#shell/}"; done || true)
# (|| true: nothing newer - an APK built from the tip - makes grep exit 1, and set -e + pipefail ended the ship here,
# skipping the checks below; 17:18, APK 29876595.)
if [ -n "$newer" ]; then
  t=$(mktemp -d "$HOME/.cache/powos-reapply.XXXXXX")
  if git worktree add -q --detach "$t/tree" origin/worktree-powos-multiplatform 2>/dev/null; then
    [ -d shell/node_modules ] && ln -s "$PWD/shell/node_modules" "$t/tree/shell/node_modules"
    echo "ship-apk: re-pushing shell changes committed after the build: $(echo $newer)"
    # The phone now runs the APK's (older) shell for these files: re-pushing them is not optional. A loaded Mac timed
    # every page out at 30 s and the re-push was refused, leaving newer fixes off the phone (2026-10-22, 29878209):
    # 60 s, one retry, and a loud line with the exact command if it still fails.
    rp() { (cd "$t/tree/shell" && READY_MS=${READY_MS:-60000} ./push.sh --vpn --silent $newer 2>&1 | tail -3); }
    out=$(rp); echo "$out"
    if ! echo "$out" | grep -q "^pushed "; then
      echo "ship-apk: re-push refused - retrying once" >&2; out=$(READY_MS=90000 rp); echo "$out"
      echo "$out" | grep -q "^pushed " || echo "ship-apk: WARNING - newer shell files are NOT on the phone: (cd <origin-tip tree>/shell && ./push.sh --vpn --silent $newer)" >&2
    fi
    git worktree remove --force "$t/tree" 2>/dev/null
  fi
  rm -rf "$t"
fi
sleep 15
tools/phone/adb.sh shell "dumpsys package com.powos.app | grep -m1 versionCode; logcat -d -v time -T '$start.000' | grep -E 'gesture input on|Fatal signal|FATAL EXCEPTION' | tail -4"
