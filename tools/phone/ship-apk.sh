#!/bin/bash
# Build the PowOS APK from a clean tree and install it on the phone - one at a time across ALL sessions/agents
# (a lock: two builds at once overwrote the shared out/powos.apk), through install-app.sh (privapp allowlist
# guard + app-data backup), then verify the app came back (gesture input, no new crash).
#   tools/phone/ship-apk.sh --note "what changed, plain words" [--now]
#   tools/phone/ship-apk.sh --silent [--now]    a change the user can't see (refactor, lint, tooling): no notification
# Before the install: a snapshot of the installed APK + the exact overrides (ship-guard.sh). After it and the one push
# of every shell file origin's tip has differently from the APK's own assets: every page must boot within 2 min, else
# the whole snapshot is restored and the coder inbox told (exit 6).
# Run by the ship service only (tools/phone/ship.sh: agents push, then `ship.sh request`); by hand only with --direct
# (an emergency; logged to ~/.cache/powos-ship-queue/direct.log).
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
note="" now="" silent="" direct=""
while [ $# -gt 0 ]; do case "$1" in --note) note=$2; shift 2;; --silent) silent=1; shift;; --now) now=1; shift;; --direct) direct=1; shift;; *) echo "unknown: $1" >&2; exit 2;; esac; done
[ -n "${note// }" ] || [ -n "$silent" ] || { echo "ship-apk: --note \"...\" (or --silent for a change the user can't see) required" >&2; exit 2; }
# One shipper: agents each shipping from their own worktree raced (2026-10-23: ~6 APKs and ~15 shell pushes in a night;
# twice an APK from an older tip wiped newer shell pushes). Only the ship service (tools/phone/ship.sh) runs this.
if [ -z "${POWOS_SHIP_SERVICE:-}" ]; then
  [ -n "$direct" ] || { echo "ship-apk: REFUSED - agents don't ship: push to origin, then tools/phone/ship.sh request --note \"...\" (the ship service ships origin's tip; --direct only for an emergency, logged)" >&2; exit 3; }
  dl=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}; mkdir -p "$dl"
  echo "$(date '+%F %T') ship-apk --direct $(git rev-parse --short HEAD) $(basename "$PWD") pid $$: ${note:-(silent)}" >> "$dl/direct.log"
  echo "ship-apk: --direct - outside the ship service (logged to $dl/direct.log)" >&2
  export POWOS_SHIP_SERVICE=direct   # its own push.sh calls (the reset, the re-pushes) are part of this ship
fi
# The note install-app.sh gets: the user's line, or --silent (only comms' quiet log).
if [ -n "$silent" ]; then inote="--silent"; else inote="--note \"${note//\"/}\""; fi
lock=$HOME/.cache/powos-ship.lock; mkdir -p "$HOME/.cache"
sq=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}   # the ship service's dir: its pause flag, the installing mark
# Never ship a build that lacks what's installed: the last shipped commit must be in HEAD (two agents' APKs
# overwrote each other's work). Rebase onto worktree-powos-multiplatform first.
# Ship only what's already on origin/worktree-powos-multiplatform: a build from an unpushed commit (8f2a606) left
# every other agent's next build refused for lacking it.
git fetch -q origin worktree-powos-multiplatform 2>/dev/null || true
# Only refuse a request whose own commit isn't on origin at all (force-pushed away, or never pushed). A commit that
# IS on origin but origin has since moved past is NOT refused here (friction f36: "HEAD is behind origin" refused
# ships from the service's own checkout lagging origin by the time the build started - the service's whole job is
# to ship origin's TIP, never its own stale snapshot).
if ! git merge-base --is-ancestor HEAD origin/worktree-powos-multiplatform 2>/dev/null; then
  echo "ship-apk: REFUSED - HEAD isn't on origin/worktree-powos-multiplatform yet: fast-forward/rebase and push first" >&2; exit 3
fi
# ...and the BUILD must be at that tip: the install resets every shell override, so a build missing a newer
# shell-only push (a revert that brought the blur back, 10:15) silently undid it on the phone at 10:17. The service
# (POWOS_SHIP_SERVICE=1) catches itself up to origin's tip instead of refusing - it just confirmed above that HEAD's
# own commit is still in origin's history, so this only ever fast-forwards. A human's --direct ship still refuses
# and asks them to pull/rebase by hand (an emergency ship from an old snapshot should be deliberate).
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/worktree-powos-multiplatform)" ]; then
  if [ "${POWOS_SHIP_SERVICE:-}" = 1 ]; then
    echo "ship-apk: HEAD was behind origin/worktree-powos-multiplatform - catching up to its tip before building"
    git reset -q --hard origin/worktree-powos-multiplatform
  else
    echo "ship-apk: REFUSED - HEAD is behind origin/worktree-powos-multiplatform: git pull --ff-only (or rebase) first" >&2; exit 3
  fi
fi
last=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
if [ -n "$last" ] && ! git merge-base --is-ancestor "$last" HEAD 2>/dev/null; then
  echo "ship-apk: REFUSED - HEAD lacks the installed build's commit $last (git rebase worktree-powos-multiplatform)" >&2; exit 3
fi
until mkdir "$lock" 2>/dev/null; do
  echo "ship-apk: waiting for $(cat "$lock/who" 2>/dev/null || echo another build)"; sleep 15
done
echo "$(git rev-parse --short HEAD) $(git branch --show-current) pid $$ $(date +%H:%M:%S)" > "$lock/who"
t=""   # the origin-tip tree the newer shell files are gated and pushed from (below)
trap 'rm -rf "$lock"; rm -f "$sq/wants-phone"; [ "$(cat "$sq/installing" 2>/dev/null)" = $$ ] && rm -f "$sq/installing"; [ -n "$t" ] && { git worktree remove --force "$t/tree" 2>/dev/null; rm -rf "$t"; }' EXIT
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
# Only "not ready" timeouts and no error: the Mac was busy (training runs + a kernel build, load ~20: refused 3cecf58d
# and 5b23de9b, 2026-10-23, whose shell loaded) - once more with a longer wait, as shell/push.sh does. The log keeps
# the FAIL lines themselves (a tail of the console warnings hid them).
glog=${TMPDIR:-/tmp}/ship-apk-gate.log
gate_head() { GATE_PRIORITY=ship READY_MS=$1 IDLE_MS=0 bash shell/dev/gate.sh > "$glog" 2>&1; }
grc=0; gate_head "${READY_MS:-30000}" || grc=$?
if [ $grc -ne 0 ] && grep -q '^FAIL' "$glog" && ! grep '^FAIL' "$glog" | grep -qv 'not ready'; then
  echo "ship-apk: only boot timeouts - the Mac is busy? gating once more with READY_MS=90000" >&2
  grc=0; gate_head 90000 || grc=$?
fi
if [ $grc -ne 0 ]; then
  { grep -E '^FAIL|^gate:' "$glog" | head -12; grep -E '^(error|src/).*TS[0-9]' "$glog" | head -5; } >&2
  echo "ship-apk: REFUSED - this commit's shell doesn't load (above); fix it on origin first" >&2
  exit 3
fi
blog=${TMPDIR:-/tmp}/ship-apk-build.log
# The build's output to a log, filtered after: piping it straight into grep under pipefail ended the script SILENTLY
# when the build failed with no matching line (e.g. a tree outside ~/Projects, 2026-10-22).
if ! targets/android/build-app.sh > "$blog" 2>&1; then
  tail -15 "$blog" >&2
  echo "ship-apk: REFUSED - build-app.sh failed (above; whole log $blog)" >&2
  exit 5
fi
grep -E "^e: |BUILD|version code|refus|error:" "$blog" || true
apk=$HOME/Projects/android-app-dev/output/powos.apk
# The install resets every shell override to this APK's shell, so right after it the phone must get every shell file
# origin's tip has differently - computed from the APK's OWN assets (assets/shell), never from a commit diff, and pushed
# as ONE set: a partial re-push left home without an export it imported (APK 29878476, desktopPages, 2026-10-23).
# Gated BEFORE the install, at origin's tip: gated after it, under a loaded Mac (load ~17, 23:09, APK 29878377) the
# phone showed the old AI page for minutes. A set that doesn't load refuses the install.
apk_delta() {   # shell files at commit $1 the APK's bundled shell lacks or has differently (relative to shell/)
  local d f; d=$(mktemp -d "${TMPDIR:-/tmp}/ship-apk-delta.XXXXXX"); mkdir -p "$d/apk" "$d/tip"
  unzip -q -o "$apk" 'assets/shell/*' -d "$d/apk" 2>/dev/null
  git archive "$1" shell | tar -x -C "$d/tip"
  # What build.gradle.kts's copyShell leaves out of the APK, and dev/test (no live page).
  (cd "$d/tip/shell" && find . -type f | sed 's|^\./||' | sort |
    grep -vE '^(DESIGN\.md|push\.sh|package(-lock)?\.json|tsconfig\.json|\.gitignore)$|^(dev|test|node_modules)/' |
    while read -r f; do cmp -s "$f" "$d/apk/assets/shell/$f" || echo "$f"; done)
  rm -rf "$d"
}
git fetch -q origin worktree-powos-multiplatform 2>/dev/null || true
tip=$(git rev-parse origin/worktree-powos-multiplatform)
newer=$(apk_delta "$tip") stamp=""
if [ -n "$newer" ]; then
  t=$(mktemp -d "$HOME/.cache/powos-reapply.XXXXXX")
  git worktree add -q --detach "$t/tree" "$tip" 2>/dev/null || { echo "ship-apk: REFUSED - couldn't check out origin's tip to gate the newer shell files" >&2; exit 3; }
  [ -d shell/node_modules ] && ln -s "$PWD/shell/node_modules" "$t/tree/shell/node_modules"
  echo "ship-apk: gating the shell files the APK has differently from origin's tip $(git rev-parse --short "$tip"): $(echo $newer)"
  pg=$(cd "$t/tree/shell" && GATE_PRIORITY=ship READY_MS=${READY_MS:-60000} ./push.sh --pre-gate $newer 2>&1 || true)
  stamp=$(echo "$pg" | sed -n 's/^pre-gated //p' | tail -1)
  if [ -z "$stamp" ]; then
    # Every FAIL line, not the last 8 lines: the pages' console noise (WebSocket retries) pushed the FAILs out (01:39).
    gl=$sq/done/pregate-$(git rev-parse --short "$tip").log; mkdir -p "$sq/done"; echo "$pg" > "$gl"
    { echo "$pg" | grep -E "^(FAIL|gate:)" | head -20; echo "  (whole gate output: $gl)"; } >&2
    echo "ship-apk: REFUSED - not installing: the shell files origin changed since the build don't load at its tip (above)," >&2
    echo "  and the install would leave the phone on this APK's older copies of them. Fix them on origin, ship again (APK built, kept)." >&2
    exit 3
  fi
fi
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
      # Ask the verify queue to yield: it ends its window before its next check (queue.sh, wants-phone), so the install
      # waits one check, not the 10 min until the lock goes stale (01:56, 2026-10-23).
      echo $$ > "$sq/wants-phone"
      sleep 15; waited=$((waited + 15)); continue
    fi
    [ -d "$vl" ] && echo "ship-apk: ignoring a stale verify lock (held 10+ min by: $(cat "$vl/who" 2>/dev/null)) - locks are for injected tests, not waits" >&2
    # One held call that returns when the phone is free (the waiting runs on the phone: no poll over the VPN), in
    # 4-min chunks (AGENT-HANDBOOK.md, Caps: no repo wait helper blocks past ~4 min in one call) so the verify lock
    # above is seen. Screen off (Asleep/Dozing) = safe at once; Awake = only after 60 s without a touch; anything else
    # (an empty or unreadable state) = NOT safe - it installed over an active user once when the state came back empty.
    chunk=$(( ${SHIP_WAIT_MIN:-60} * 60 - waited )); [ $chunk -gt 240 ] && chunk=240
    # exit 1 = this chunk passed without a free phone: wait the next one (set -e would end the whole ship here).
    i2=$(tools/phone/idle.sh --wait 60 $chunk || true)
    case "$i2" in *screen=Asleep*|*screen=Dozing*|*screen=Awake*) ok=1; break ;; esac
    waited=$((waited + chunk))
    echo "ship-apk: waiting for a free phone ($waited/$(( ${SHIP_WAIT_MIN:-60} * 60 ))s): $i2"
  done
  echo "ship-apk: $i2"
  [ "$i2" = offline ] && [ -z "$ok" ] && { echo "ship-apk: the phone is offline (stale VPN handshake, tools/phone/adb.sh --vpn-state) - NOT installing (APK built, kept)"; exit 4; }
  [ -n "$ok" ] || { echo "ship-apk: the user stayed active for ${SHIP_WAIT_MIN:-60} min - NOT installing (APK built, kept)"; exit 4; }
fi
# The install and its re-pushes own the phone. The ship service pushes shell BESIDE this ship (during the build and the
# idle wait) and holds $lock/phone while one push runs: wait for it, then hold it to the end (the trap removes $lock).
# One left over 10 min (a killed push) is taken over.
until mkdir "$lock/phone" 2>/dev/null; do
  [ $(( $(date +%s) - $(stat -f %m "$lock/phone" 2>/dev/null || stat -c %Y "$lock/phone" 2>/dev/null || date +%s) )) -gt 600 ] && rm -rf "$lock/phone"
  sleep 2
done
# The known-good state, for a rollback if a page doesn't boot after this install (tools/phone/ship-guard.sh): no
# snapshot, no install.
# Paused (tools/phone/ship.sh pause - a recovery on the phone): no install starts. The mark first, then the flag
# (ship.sh pause: the flag, then the mark), so one always sees the other; past this point a pause lets it finish.
mkdir -p "$sq"; echo $$ > "$sq/installing"
[ -e "$sq/paused" ] && { rm -f "$sq/installing"; echo "ship-apk: the ship service is paused (ship.sh resume) - NOT installing (APK built, kept)"; exit 7; }
snap=$HOME/.cache/powos-ship-snapshot; rm -rf "$snap"
tools/phone/ship-guard.sh snapshot "$snap" || { echo "ship-apk: REFUSED - couldn't snapshot the phone's current APK + overrides (above): not installing without a way back (APK built, kept)" >&2; exit 3; }
# ALL shell overrides off BEFORE the install, never after: the new APK's pages boot within a second of it, and on the
# old overrides they die (APK 29878476, 00:59:48: home, assist and petover loaded its new desktops.ts against the old
# state.ts) - a dead page's hot.ts never runs, so no later reset or push reloaded them. Now they boot on the APK's own,
# consistent shell; the old APK runs its own shell for the seconds until the install. Uncommitted pushes are lost by
# design - commit before you push. The snapshot above has the overrides for a rollback.
if ! out=$(shell/push.sh --vpn --reset 2>&1); then
  echo "$out" | tail -3 >&2
  echo "ship-apk: REFUSED - couldn't reset the phone's shell overrides before the install (above): not installing (APK built, kept)" >&2
  tools/phone/ship-guard.sh restore-overrides "$snap" >&2 || true
  exit 3
fi
start=$(tools/phone/adb.sh shell 'date +%m-%d\ %H:%M:%S' | tr -d '\r')
if ! docker run --rm --network container:powos-vadb -v "$PWD/targets/android":/ta:ro -v "$apk":/powos.apk:ro --entrypoint bash \
  android-app-dev-android-builder:latest -c 'export PATH=$PATH:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/35.0.0
    adb connect 10.13.13.7:5555 >/dev/null; export ANDROID_SERIAL=10.13.13.7:5555
    cp -r /ta /tmp/ta && cd /tmp/ta && ./install-app.sh /powos.apk '"$inote"'' 2>&1 | tail -4; then
  # Not installed: the old APK again gets the overrides it ran with.
  echo "ship-apk: the install failed (above) - putting the old overrides back" >&2
  tools/phone/ship-guard.sh restore-overrides "$snap" >&2 || true
  exit 5
fi
git rev-parse HEAD > "$HOME/.cache/powos-installed-commit"
# The shell it just installed decodes the phone's live modules only with bindings of their shape (home couldn't read
# local-pet's rows twice on 2026-10-21): checked in one call; bindings ahead of a module that this commit builds are
# published, anything else is reported with its fix (the install stands either way).
tools/phone/bindings-check.sh || echo "ship-apk: the shell's bindings don't match the phone's modules - fix above" >&2
# Then, in ONE push, every shell file origin's tip (now: it may have moved during the wait) has differently from the
# APK's own shell. The set gated before the install goes on without a second gate (the stamp is for exactly it at that
# tree); a different set (origin moved) is gated as any push, from the new tip.
git fetch -q origin worktree-powos-multiplatform 2>/dev/null || true
tip2=$(git rev-parse origin/worktree-powos-multiplatform)
full=$(apk_delta "$tip2")
pushok=1
if [ -n "$full" ]; then
  if [ -z "$t" ]; then
    t=$(mktemp -d "$HOME/.cache/powos-reapply.XXXXXX"); git worktree add -q --detach "$t/tree" "$tip2" 2>/dev/null || true
    [ -d shell/node_modules ] && [ -d "$t/tree/shell" ] && ln -s "$PWD/shell/node_modules" "$t/tree/shell/node_modules"
  elif [ "$tip2" != "$tip" ]; then
    git -C "$t/tree" checkout -q --detach "$tip2" 2>/dev/null || true
  fi
  if [ -n "$stamp" ] && [ "$tip2" = "$tip" ] && [ "$full" = "$newer" ]; then
    echo "ship-apk: pushing the shell files the APK has differently from origin's tip (pre-gated): $(echo $full)"
    rp() { (cd "$t/tree/shell" && ./push.sh --vpn --pre-gated="$stamp" --silent $full 2>&1 | tail -3); }
  else
    echo "ship-apk: pushing the shell files the APK has differently from origin's tip $(git rev-parse --short "$tip2"): $(echo $full)"
    # A loaded Mac timed every page out at 30 s and the re-push was refused (2026-10-22, 29878209): 60 s, one retry.
    rp() { (cd "$t/tree/shell" && READY_MS=${READY_MS:-60000} ./push.sh --vpn --silent $full 2>&1 | tail -3); }
  fi
  out=$(rp); echo "$out"
  if ! echo "$out" | grep -q "^pushed "; then
    echo "ship-apk: the push was refused - retrying once" >&2; out=$(READY_MS=90000 stamp= rp); echo "$out"
    echo "$out" | grep -q "^pushed " || { pushok=""; echo "ship-apk: WARNING - the phone runs the APK's own shell, without origin's newer files: $(echo $full)" >&2; }
  fi
  rm -f "$stamp"
fi
gone=$(unzip -Z1 "$apk" 'assets/shell/*' 2>/dev/null | sed 's|^assets/shell/||' | grep -v '/$' |
  while read -r f; do git cat-file -e "$tip2:shell/$f" 2>/dev/null || echo "$f"; done)
[ -z "$gone" ] || echo "ship-apk: note - the APK carries shell files origin's tip deleted (an override can't remove them): $(echo $gone)"
# Every page must boot on what the phone now runs; if one doesn't within 2 min, the WHOLE snapshot goes back.
if ! g=$(tools/phone/ship-guard.sh check "${GUARD_WAIT_S:-120}"); then
  echo "$g" >&2
  echo "ship-apk: ROLLING BACK - restoring the previous APK and its overrides" >&2
  r=$(tools/phone/ship-guard.sh restore "$snap" 2>&1) || r="$r - the RESTORE FAILED: the phone needs a hand"; echo "$r" >&2
  m=$(mktemp); printf 'powos comms send %q %q --from ship-apk >/dev/null 2>&1 || true\n' "${SHIP_MAIL_TO:-coder}" \
    "APK $(git rev-parse --short HEAD) rolled back: ${g#ship-guard: } after the install$([ -z "$pushok" ] && echo " (its shell push was refused)"). $(echo "$r" | tail -1)" > "$m"
  tools/phone/user.sh "$m" >/dev/null 2>&1 || true; rm -f "$m"
  exit 6
fi
echo "$g"
sleep 15
tools/phone/adb.sh shell "dumpsys package com.powos.app | grep -m1 versionCode; logcat -d -v time -T '$start.000' | grep -E 'gesture input on|Fatal signal|FATAL EXCEPTION' | tail -4" || true   # a report: no match is no failure (it made the ship's exit 1)
