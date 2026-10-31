#!/bin/bash
# tools/phone/ship.sh: ONE ship pipeline to the phone. Agents push to origin, then ask; one service ships origin's tip.
#   ship.sh request --note "what changed, for the user"   after your push to origin - and nothing else. Returns at once.
#   ship.sh request --silent                              a change the user can't see (refactor, lint, tooling)
#   ship.sh status                                        queued requests, the service, what's live, the last ships
#   ship.sh pause --why TEXT [--until WHEN]               pause: no new ship starts; a ship in flight that hasn't begun
#        installing is stopped (its ship-apk / build / gate killed, the ship lock freed, its requests kept); an install
#        or shell push in flight finishes, then nothing more. Records who paused (the caller's worktree/agent, or
#        SHIP_REQUESTER), why, and optionally until when - status, request (before it queues) and queue.sh list all
#        show it (friction f114: a paused queue with no reason or owner shown). resume: go on. (2026-10-23:
#        `launchctl bootout` left the runner's ship-apk building, about to install in the middle of a home recovery.)
#   ship.sh run                                           the service: launchd agent com.powos.ship-runner
#        (tools/phone/ship-deploy.sh; unit units/mac/ship-runner-mac.json). `request` kicks it; without the agent,
#        request starts one of its own. ONE runner ever (lock dir <queue>/runner.lock, as the verify runner's).
# Why (2026-10-23): every agent ran ship-apk.sh / push.sh from its own worktree - ~6 APKs and ~15 shell pushes in one
# night, racing; twice an APK built from an older tip landed after newer shell pushes and wiped them on the phone.
# The service, in its own checkout ($POWOS_RUN_ROOT/ship-runner, default ~/pw/ship-runner, only it touches it;
# no .claude/worktrees fallback - wt-move-rest moved it for good, f190), ships origin's TIP in two parts:
#   - shell, at once (SHIP_QUIET_SHELL_S, default 0: commits landing while a ship is out coalesce into the next one): shell/push.sh --vpn of exactly the shell files
#     that differ from what's live (the last tip it shipped, or the installed build), --reset of the ones the tip
#     deleted - ALSO while an APK ship is out (2026-10-23: shell fixes waited 25-30 min behind one APK's build and idle
#     wait). Never while the verify lock (~/.cache/powos-verify.lock, < 10 min old) is held, never during an install
#     (ship-apk holds <ship lock>/phone for it; the shell push takes the same dir while it pushes);
#   - an APK when Kotlin / APK inputs changed since the installed build (~/.cache/powos-installed-commit), once origin
#     stayed SHIP_QUIET_S (60) s on the tip: ship-apk.sh from the tip in its own checkout ($POWOS_RUN_ROOT/
#     ship-runner-apk), BESIDE the loop, one at a time (it pre-gates, waits for the verify lock and a free phone, resets
#     the overrides and re-pushes newer shell). A request whose commit has Kotlin is done once the APK is installed.
#   - HOLD (2026-10-30): a tip whose not-yet-installed APK inputs came in the same commit(s) as shell changes holds its
#     shell part until that APK installs - ship-apk's own post-install push brings the shell, so both land together
#     (10-29 the overlay launcher shell broke the home swipe-up without its APK; 10-30 the web-windows shell left the
#     phone with no floating windows). Shell-only tips, and Kotlin + shell in separate commits, still ship at once.
#     Shown by status and the runner log: "shell held for its APK <sha>".
#   - ~/.config/powos/ship-no-idle-wait (the user's setting; file present = on): APK ships pass --now to ship-apk.sh -
#     install at once instead of waiting for the user to be idle / the screen off. Delete the file to wait again.
#   The notes of the requests a part finishes go into ONE update notification ("a; b"; all --silent = silent). The tip shipped
#   goes to <queue>/live, a line to <queue>/shipped.log, the run's log to <queue>/done/. A failed ship mails the
#   coder inbox and isn't retried until origin moves (a user who stayed active: retried). ship-apk.sh / push.sh
#   refuse to run outside this service (POWOS_SHIP_SERVICE) unless --direct (emergencies; logged to <queue>/direct.log).
set -uo pipefail
here=${SHIP_HERE:-$(cd "$(dirname "$0")" && pwd -P)}; unset SHIP_HERE
BASE=worktree-powos-multiplatform
REPO=$(cd "$here" && cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")" 2>/dev/null && pwd -P || true)
[ "$REPO" = / ] && REPO=
# The service's checkout: only the service touches it. $POWOS_RUN_ROOT/ship-runner, period - the old
# $REPO/.claude/worktrees/ship-runner fallback (wt-move-rest) is gone now that the runners live in ~/pw (f190: a
# lagging agent worktree's stale pre-move copy of THIS script, with no $POWOS_RUN_ROOT concept at all, is what
# used to resurrect the old path - a fallback here can't fix that, and removing it stops this script, once an
# agent rebases onto this tip, from ever choosing that path again).
POWOS_RUN_ROOT=${POWOS_RUN_ROOT:-$HOME/pw}
SR=$POWOS_RUN_ROOT/ship-runner
Q=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}; mkdir -p "$Q/done"
LABEL=${SHIP_AGENT:-com.powos.ship-runner}
QUIET=${SHIP_QUIET_S:-60} QS=${SHIP_QUIET_SHELL_S:-0} POLL=${SHIP_POLL_S:-3}
alive_runner() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null && ps -p "$1" -o command= 2>/dev/null | grep -q ship; }
runner_up() { alive_runner "$(cat "$Q/runner.lock/pid" 2>/dev/null)"; }
killtree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c"; done; kill "$1" 2>/dev/null; }
# installing: an APK install (ship-apk) or a shell push is in flight - $Q/installing holds its pid. Its writer sets it,
# THEN checks the pause flag; pause sets the flag, THEN reads it: one of the two always sees the other.
installing() { local p; p=$(cat "$Q/installing" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
# stop_ships RUNNER: everything the runner has in flight, killed - all of each process tree (a foreground child alone
# kept building). The APK ship's subshell itself lives on to record its rc (the loop then sees it was a pause).
stop_ships() { local c a; a=$(cat "$Q/apk/pid" 2>/dev/null)
  for c in $(pgrep -P "$1"); do
    if [ "$c" = "$a" ]; then for k in $(pgrep -P "$c"); do killtree "$k"; done; else killtree "$c"; fi
  done; }
# The launchd agent: only for the real queue dir, or the test agent SHIP_AGENT names.
agent_on() { [ -z "${SHIP_DIR:-}" ] || [ -n "${SHIP_AGENT:-}" ]; }
agent_loaded() { agent_on && launchctl print "user/$(id -u)/$LABEL" >/dev/null 2>&1; }
agent_kick() { local p=$HOME/Library/LaunchAgents/$LABEL.plist
  agent_on || return 1
  agent_loaded || { [ -f "$p" ] && launchctl bootstrap "user/$(id -u)" "$p" 2>/dev/null; } || return 1
  launchctl kickstart "user/$(id -u)/$LABEL" >/dev/null 2>&1; }
# who_default: the caller's worktree/agent, so pause/request never records an anonymous pause (friction f114).
who_default() { echo "${SHIP_REQUESTER:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)}"; }
# paused_info: "" if not paused, else "by WHO: WHY (until UNTIL)" - shared by status, request and queue.sh's peers.
paused_info() {
  [ -e "$Q/paused" ] || return 0
  local who= why= until=; . "$Q/paused" 2>/dev/null
  printf 'by %s%s%s' "${who:-unknown}" "${why:+: $why}" "${until:+ (until $until)}"
}
case "${1:-}" in
request)
  shift; note= silent= rsha= rwho=
  while [ $# -gt 0 ]; do case "$1" in
    --sha) rsha=${2:-}; shift 2 || shift ;; --who) rwho=${2:-}; shift 2 || shift ;;   # ship-gate.py: a device's pushed sha
    --note) note=${2:-}; shift 2 || shift ;; --note=*) note=${1#--note=}; shift ;; --silent) silent=1; shift ;;
    *) echo "ship.sh request: unknown $1" >&2; exit 2 ;; esac; done
  [ -n "${note// }" ] || [ -n "$silent" ] || { echo "ship.sh request: --note \"what changed, for the user\" (or --silent) required" >&2; exit 2; }
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ship.sh request: run it in your PowOS worktree" >&2; exit 2; }
  git fetch -q origin "$BASE" 2>/dev/null || echo "ship.sh request: fetch failed - checking against the last fetched origin" >&2
  sha=$(git rev-parse --verify -q "${rsha:-HEAD}^{commit}") || { echo "ship.sh request: REFUSED - unknown commit ${rsha}" >&2; exit 3; }
  [ -z "$rwho" ] || SHIP_REQUESTER=$rwho
  git merge-base --is-ancestor "$sha" "origin/$BASE" 2>/dev/null ||
    { echo "ship.sh request: REFUSED - HEAD ${sha:0:9} isn't on origin/$BASE: push it first (git push origin HEAD:$BASE)" >&2; exit 3; }
  # Before queueing: if the service is paused, say who and why now - not only after the request is already on disk
  # (friction f114: nothing at task start said the queue was paused, so the deploy order couldn't be planned).
  pi=$(paused_info); [ -z "$pi" ] || echo "ship.sh request: the ship service is PAUSED $pi - this ships after tools/phone/ship.sh resume"
  r=$Q/$(date +%Y%m%d-%H%M%S)-$$.req
  printf 'sha=%q\nnote=%q\nsilent=%s\nwho=%q\nat=%s\n' "$sha" "$note" "${silent:-0}" "${SHIP_REQUESTER:-$(basename "$top")}" "$(date +%s)" > "$r.tmp" && mv "$r.tmp" "$r"
  # The request is on disk before the runner check: a runner on its way out sees it (run's last look).
  runner_up || agent_kick || { nohup bash "$here/ship.sh" run >> "$Q/runner.log" 2>&1 & }
  echo "ship requested (${sha:0:9}): the ship service ships origin's tip after ${QUIET}s without new commits - nothing else to do (status: tools/phone/ship.sh status) [id $(basename "$r" .req)]" ;;
pause)
  shift; why= until=
  while [ $# -gt 0 ]; do case "$1" in
    --why) why=${2:-}; shift 2 || shift ;; --why=*) why=${1#--why=}; shift ;;
    --until) until=${2:-}; shift 2 || shift ;; --until=*) until=${1#--until=}; shift ;;
    *) echo "ship.sh pause: unknown $1" >&2; exit 2 ;; esac; done
  [ -n "${why// }" ] || { echo "ship.sh pause: --why TEXT required (who's pausing and why, for status/request/queue.sh list - friction f114)" >&2; exit 2; }
  who=$(who_default); who=${who:-unknown}
  printf 'who=%q\nwhy=%q\nuntil=%q\nat=%s\n' "$who" "$why" "$until" "$(date +%s)" > "$Q/paused"
  pi="(by $who: $why${until:+, until $until})"
  if installing; then echo "paused $pi - an install is in flight (pid $(cat "$Q/installing")) - it finishes (install + its push), then nothing new starts"
  elif runner_up; then stop_ships "$(cat "$Q/runner.lock/pid")"
    echo "paused $pi - the ship in flight was stopped (its requests are kept); nothing ships until tools/phone/ship.sh resume"
  else echo "paused $pi - nothing ships until tools/phone/ship.sh resume"; fi ;;
resume)
  rm -f "$Q/paused"
  ls "$Q"/*.req >/dev/null 2>&1 && { runner_up || agent_kick || { nohup bash "$here/ship.sh" run >> "$Q/runner.log" 2>&1 & }; }
  echo "resumed$(ls "$Q"/*.req >/dev/null 2>&1 && echo ": $(ls "$Q"/*.req | wc -l | tr -d ' ') request(s) ship now")" ;;
status)
  pi=$(paused_info)
  [ -z "$pi" ] || echo "PAUSED $pi since $(date -r "$(stat -c %Y "$Q/paused" 2>/dev/null || stat -f %m "$Q/paused")" +%H:%M) - tools/phone/ship.sh resume$(installing && echo " (an install in flight finishes first)")"
  echo "requests:"; for r in "$Q"/*.req; do [ -f "$r" ] || continue; ( . "$r"; echo "  ${sha:0:9} $who: $([ "$silent" = 1 ] && echo '(silent)' || echo "$note")" ); done
  echo "service: $(runner_up && echo "running (pid $(cat "$Q/runner.lock/pid"))" || echo idle)$(agent_loaded && echo " (launchd $LABEL)")"
  echo "live: $(cut -c1-9 "$Q/live" 2>/dev/null || echo -)  installed APK: $(cut -c1-9 "$HOME/.cache/powos-installed-commit" 2>/dev/null || echo -)$([ -s "$Q/failed" ] && echo "  failed at: $(cut -c1-9 "$Q/failed") (waits for a new origin commit)")"
  [ -s "$Q/shell-held" ] && { read -r ht hc < "$Q/shell-held"; echo "shell held for its APK ${ht:0:9} (APK inputs + shell in the same commit: $hc) - they land together at the install"; }
  [ -e "$HOME/.config/powos/ship-no-idle-wait" ] && echo "APK installs: at once, no idle wait (~/.config/powos/ship-no-idle-wait)"
  [ -s "$Q/rooted-pending" ] && { read -r rb rt < "$Q/rooted-pending"; echo "rooted deploy pending since ${rb:0:9} (origin ${rt:0:9}; runs after the APK, under the phone-busy rules)"; }
  [ -s "$Q/window-failed" ] && { read -r wt ww wf < "$Q/window-failed"; if [ "$wf" = render-watch ]; then echo "WINDOWS BROKEN: ${wt:0:9} ($ww) failed the passive window check (render-watch) - log $Q/done/render-watch-${wt:0:9}.log"; else echo "WINDOWS BROKEN: ${wt:0:9} ($ww) failed the device window check (verify/window-render.sh; changed: $wf) - log $Q/done/window-render-${wt:0:9}.log"; fi; }
  [ -s "$Q/window-gate.pid" ] && kill -0 "$(cat "$Q/window-gate.pid")" 2>/dev/null && echo "device window check running (pid $(cat "$Q/window-gate.pid"); waits for a free, unfolded phone)"
  [ -d "$Q/apk" ] && echo "APK ship out: $(cut -c1-9 "$Q/apk/tip" 2>/dev/null) (log $(cat "$Q/apk/log" 2>/dev/null))"
  echo "last ships:"; tail -6 "$Q/shipped.log" 2>/dev/null | sed 's/^/  /' ;;
run)
  [ -n "$REPO" ] || { echo "ship.sh run: not in a PowOS checkout"; exit 2; }
  ls "$Q"/*.req >/dev/null 2>&1 || exit 0   # nothing requested (launchd starts it at load): gone at once
  [ -e "$Q/paused" ] && { echo "$(date +%T) paused - not starting (tools/phone/ship.sh resume)"; exit 0; }
  # ONE runner: the lock dir holds its pid (exec keeps it, so the private copy below holds it already).
  L=$Q/runner.lock
  if [ "$(cat "$L/pid" 2>/dev/null)" != $$ ]; then
    for _ in 1 2; do
      mkdir "$L" 2>/dev/null && { echo $$ > "$L/pid"; break; }
      p=$(cat "$L/pid" 2>/dev/null)
      if alive_runner "$p"; then echo "$(date +%T) ship runner already running (pid $p)"; exit 0; fi
      [ -z "$p" ] && sleep 1 && p=$(cat "$L/pid" 2>/dev/null) && [ -n "$p" ] && continue   # being taken right now
      rm -rf "$L"   # stale: its runner is gone
    done
    [ "$(cat "$L/pid" 2>/dev/null)" = $$ ] || { echo "$(date +%T) ship runner lock busy - exiting"; exit 0; }
  fi
  # ship_tree: the service's checkout at origin's tip (made if missing, shell/node_modules linked).
  ship_tree() {
    git -C "$REPO" fetch -q origin "$BASE" || echo "$(date +%T) fetch failed - on what it has"
    if [ ! -e "$SR/.git" ]; then
      git -C "$REPO" worktree add -q --detach "$SR" "origin/$BASE" || { echo "ship checkout: can't create $SR"; return 1; }
      # Marker land.sh and worktree.sh check (friction f57): only the ship service touches this checkout.
      echo "the ship service (tools/phone/ship.sh)" > "$SR/.powos-runner-checkout"
    else
      git -C "$SR" reset -q --hard "origin/$BASE"   # only the service uses it
    fi
    local nm=$POWOS_RUN_ROOT/powos-multiplatform/shell/node_modules
    [ -d "$nm" ] || nm=$REPO/.claude/worktrees/powos-multiplatform/shell/node_modules
    [ -e "$SR/shell/node_modules" ] || [ ! -d "$nm" ] || ln -s "$nm" "$SR/shell/node_modules"
  }
  if [ -z "${SHIP_COPY:-}" ]; then
    cd "$HOME"; ship_tree || exit 1
    cd "$SR" || exit 1
    # A private copy: bash reads a script as it runs, and the checkout is reset under it.
    c=$(mktemp "${TMPDIR:-/tmp}/powos-ship.XXXXXX") && cp "$SR/tools/phone/ship.sh" "$c" || exit 1
    SHIP_COPY=$c SHIP_HERE=$SR/tools/phone exec bash "$c" run
  fi
  rm -f "$SHIP_COPY"; unset SHIP_COPY
  cd "$SR" || exit 1
  # Stopped (launchctl bootout, a kill): what's in flight goes with it, whole process trees - unless it's installing:
  # that finishes first (ExitTimeOut 300 in the plist).
  trap 'if installing; then echo "$(date +%T) stopping: the install in flight finishes first"; while installing; do sleep 1; done; fi
    stop_ships $$; kill "$(cat "$Q/apk/pid" 2>/dev/null)" 2>/dev/null; rm -rf "$L"; exit 143' TERM
  SL=$HOME/.cache/powos-ship.lock VL=$HOME/.cache/powos-verify.lock
  # After every successful ship (shell or APK): a round of the manager's "use the phone like a user" journeys
  # (verify/e2e-queue.sh: e2e-desktop parts 1-3 + e2e-appapi), unless one is still queued. In the background: queueing
  # is a few quick user.sh calls, never a reason to hold the ship loop. SHIP_E2E=0 turns it off (tests).
  e2e_round() { [ "${SHIP_E2E:-1}" = 1 ] && [ -z "${SHIP_DIR:-}" ] && [ -x "$here/verify/e2e-queue.sh" ] || return 0
    ( "$here/verify/e2e-queue.sh" --if-idle >> "$Q/e2e.log" 2>&1 & ) ; echo "$(date +%T) e2e: a round of user journeys asked for ($Q/e2e.log)"; }
  mail() { local s t ev kind; s=$(mktemp "$Q/mail.XXXX")
    printf 'powos comms send %q %q --from ship-queue >/dev/null 2>&1 || true\n' "${SHIP_MAIL_TO:-coder}" "$1" > "$s"
    # A failed/refused ship is friction too (powos friction: counted, so a recurring refusal shows up as the top item).
    t=${1%% - log *}; ev=${1##* - log }; ev=${ev%% on the Mac*}
    # The kind first: a case inside $( ) inside a case branch is a syntax error in macOS's bash 3.2 (friction f33).
    local kind=broken-tool; case "$1" in *REFUSED*|*refused*) kind=refused ;; esac
    case "$1" in *FAILED*|*REFUSED*|*refused*)
      printf 'powos friction add --area ship --kind %s %q --repro %q --evidence %q --by ship-queue >/dev/null 2>&1 || true\n' \
        "$kind" "$t" \
        "tools/phone/ship.sh request --silent on the same origin tip; the run's log: $ev" "$ev" >> "$s" ;; esac
    "$SR/tools/phone/user.sh" "$s" >/dev/null 2>&1 || echo "$(date +%T) mail failed: $1"; rm -f "$s"; }
  verify_held() { [ -d "$VL" ] && [ $(( $(date +%s) - $(stat -c %Y "$VL" 2>/dev/null || stat -f %m "$VL") )) -lt 600 ]; }
  ship_lock() {   # the cross-agent ship lock (ship-apk's): taken, or a dead holder's taken over
    local p
    mkdir "$SL" 2>/dev/null || {
      p=$(sed -n 's/.* pid \([0-9]*\) .*/\1/p' "$SL/who" 2>/dev/null)
      [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && rm -rf "$SL" && mkdir "$SL" 2>/dev/null; } || return 1
    echo "$(git rev-parse --short HEAD) ship-runner pid $$ $(date +%H:%M:%S)" > "$SL/who"; }
  # delta A B: shell files changed between A and B (no dev/test), relative to shell/; "+f" exists at B, "-f" deleted.
  delta() { git diff --name-only "$1" "$2" -- shell/ 2>/dev/null | grep -vE '^shell/(dev|test)/' |
    while read -r f; do git cat-file -e "$2:$f" 2>/dev/null && echo "+${f#shell/}" || echo "-${f#shell/}"; done; }
  apk_inputs() { git diff --name-only "$1" "$2" -- targets/android/app targets/android/build-app.sh 2>/dev/null | grep -v 'app/version.properties$'; }
  # apps_changed A B: apps/<app>/ dirs (ones with a powos-app.json - never apps/build.sh, apps/registry etc.) that
  # differ between A and B.
  apps_changed() { git diff --name-only "$1" "$2" -- apps 2>/dev/null | sed -n 's#^apps/\([^/]*\)/.*#\1#p' | sort -u |
    while read -r a; do [ -f "apps/$a/powos-app.json" ] && echo "$a"; done; }
  # rooted_inputs A B: what changed between A and B that targets/android/rooted/rooted.sh deploy installs (the
  # rooted-mode part only - its own scripts/session + the small PowOS-side pieces it pushes; the apps-tier pieces
  # it also pushes, lib/apps/bin/powos/the spacetimedb/xwayland/kwin packages, are the "apps" kind above, f105 part
  # 2 - this is part 1). `deploy`, never `install` (which also re-pushes the rootfs tarball - a human step).
  rooted_inputs() { git diff --name-only "$1" "$2" -- targets/android/rooted targets/android/session \
    targets/android/pkgs/fex-emu bin/powos-panel-phone desktop/autostart/powos-panel-phone.desktop \
    lib/powos-tmux-shell lib/self-phone.sh config/etc/profile.d/60-powos-picker-key.sh lib/ai/agents lib/ai/comms/comms-mcp.py \
    tools/app-api lib/ai/manager lib/ai/sandbox desktop/plasmoid units/phone units/phone-android lib/apps/powos-units \
    2>/dev/null | grep -v '^lib/ai/sandbox/node_modules/'; }
  # units_gate: nothing ships to the phone that installs a file no unit claims (DU1: every ship registers what it
  # installs). test-units-registry.py reads every deploy script against units/; a FAIL refuses the rooted deploy.
  units_gate() { python3 test/tier1/test-units-registry.py > "$1" 2>&1 && return 0
    grep -E '^ *FAIL' "$1" | head -3 | cut -c1-200; return 1; }
  # units_publish: the phone's units to the PowOS AI page after a ship to it (in the background, one adb call; the
  # rooted deploy publishes itself). tools/units/publish.sh; a failure is in its log, the page then shows "stale".
  units_publish() { ( tools/units/publish.sh phone > /dev/null 2>&1 & ) ; }
  # rooted_due: rooted_inputs changed since the last rooted deploy ($Q/rooted-live) up to this checkout's HEAD, and
  # the deploy didn't fail on HEAD. Sets rbase/rchg; keeps $Q/rooted-pending ("BASE TIP", for status) in step.
  # It keeps the runner up until the deploy ran (2026-10-30: a tip with APK + rooted inputs installed its APK, which
  # finished every request, and the runner left before step 4 got a pass - powos-app-quit never reached the phone).
  # Measured from rooted-live only, never from the shell-live/installed tip: neither ships rooted pieces (the same
  # bug apps had, 1d3a80ac). No rooted-live yet: the installed APK's commit is the first base, recorded at once so a
  # later APK install can't move it.
  rooted_due() { local h; h=$(git rev-parse HEAD 2>/dev/null) || return 1
    rbase=$(cat "$Q/rooted-live" 2>/dev/null || true)
    [ -n "$rbase" ] || { rbase=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true); [ -z "$rbase" ] || echo "$rbase" > "$Q/rooted-live"; }
    rchg=; [ -n "$rbase" ] && git cat-file -e "$rbase^{commit}" 2>/dev/null && rchg=$(rooted_inputs "$rbase" "$h" | paste -sd' ' -)
    if [ -n "$rchg" ] && [ "$(cat "$Q/failed-rooted" 2>/dev/null)" != "$h" ]; then
      [ "$(cat "$Q/rooted-pending" 2>/dev/null)" = "$rbase $h" ] || echo "$rbase $h" > "$Q/rooted-pending"; return 0; fi
    rm -f "$Q/rooted-pending"; return 1; }
  # The APK ship runs BESIDE the loop, in its own checkout (it builds from it for minutes while ship_tree resets $SR),
  # so a shell change never queues behind an APK's build or idle wait (2026-10-23: shell fixes waited 25-30 min behind
  # one APK). State in $Q/apk/: tip, pid, rc (written when it ends).
  # Under ~/Projects, NOT $POWOS_RUN_ROOT (~/pw): the APK builds in android-app-dev's container, which mounts only
  # ~/Projects as /Projects - from ~/pw every APK ship failed ("Project 'powos' not found", 2026-10-24 06:30-15:30).
  # It is no agent's cwd, so it doesn't add to agents' context (f190: still no .claude/worktrees fallback).
  SA=${POWOS_APK_RUN:-$HOME/Projects/.powos-runners/ship-runner-apk}
  NOIDLE=$HOME/.config/powos/ship-no-idle-wait
  apk_alive() {   # an APK ship out; one whose runner died (killed, restarted) without an rc goes again (rc 4)
    [ -d "$Q/apk" ] && [ ! -f "$Q/apk/rc" ] || return 1
    kill -0 "$(cat "$Q/apk/pid" 2>/dev/null)" 2>/dev/null && return 0
    echo 4 > "$Q/apk/rc"; return 1; }
  apk_launch() {   # $1 tip, rest: --note/--silent
    local a=$1; shift
    if [ ! -e "$SA/.git" ]; then
      git -C "$REPO" worktree add -q --detach "$SA" "$a" || return 1
      echo "the APK ship service (tools/phone/ship.sh)" > "$SA/.powos-runner-checkout"
    else git -C "$SA" reset -q --hard "$a" || return 1; fi
    local nm=$POWOS_RUN_ROOT/powos-multiplatform/shell/node_modules
    [ -d "$nm" ] || nm=$REPO/.claude/worktrees/powos-multiplatform/shell/node_modules
    [ -e "$SA/shell/node_modules" ] || [ ! -d "$nm" ] || ln -s "$nm" "$SA/shell/node_modules"
    rm -rf "$Q/apk"; mkdir -p "$Q/apk"; echo "$a" > "$Q/apk/tip"; echo "$Q/done/$(date +%Y%m%d-%H%M%S)-${a:0:9}-apk.log" > "$Q/apk/log"
    # The user's no-idle-wait setting (file present = on): install at once, don't wait for the user to be idle.
    [ -e "$NOIDLE" ] && set -- "$@" --now
    ( cd "$SA" && POWOS_SHIP_SERVICE=1 SHIP_DIR=$Q GATE_PRIORITY=ship bash tools/phone/ship-apk.sh "$@" > "$(cat "$Q/apk/log")" 2>&1; echo $? > "$Q/apk/rc" ) &
    echo $! > "$Q/apk/pid"
  }
  # post_gate TIP LOG FILE...: the full gate on what was just pushed, in the background, one at a time (a newer tip's
  # gate replaces a running one). A FAIL mails the coder with the failing lines - the push stays (the phone's own
  # rollback handles a page that dies there); SHIP_GATE_FIRST=1 means the push was already gated: nothing to do.
  post_gate() {
    local t=$1 lg=$2; shift 2
    [ -z "${SHIP_GATE_FIRST:-}" ] || return 0
    [ -d shell ] || return 0
    local old; old=$(cat "$Q/postgate.pid" 2>/dev/null) && [ -n "$old" ] && killtree "$old" 2>/dev/null
    ( gl=$Q/done/postgate-${t:0:9}.log
      ( cd shell && GATE_PRIORITY=ship IDLE_MS=0 READY_MS=${READY_MS:-60000} ./push.sh --pre-gate "$@" ) > "$gl" 2>&1; grc=$?
      if [ $grc -ne 0 ] && ! grep '^FAIL' "$gl" | grep -qv 'not ready' ; then ( cd shell && GATE_PRIORITY=ship IDLE_MS=0 READY_MS=90000 ./push.sh --pre-gate "$@" ) > "$gl" 2>&1; grc=$?; fi
      if [ $grc -ne 0 ]; then
        echo "$t" > "$Q/postgate-failed"
        mail "ship ${t:0:9} (shell) went live and its gate FAILED after: $(grep -E '^FAIL|REFUSED|pre-gate failed' "$gl" | head -2 | cut -c1-200 | paste -sd' ' -) - log $gl on the Mac; fix it on origin, then ship.sh request again"
      else rm -f "$Q/postgate-failed"; fi
      rm -f "$Q/postgate.pid" ) &
    echo $! > "$Q/postgate.pid"
  }
  # window_gate BASE TIP WHAT: a ship whose BASE..TIP diff touches web-window files (WINDOW_FILES) is checked ON THE
  # DEVICE after it's live: verify/window-render.sh opens Calculator as a web window, screencaps its body (app content,
  # not the page under it, not a flat fill) and taps it (the app redraws). Why (2026-10-31): web windows shipped as
  # empty frames twice in one night with every headless gate green. In the background, one at a time (a newer ship's
  # check replaces a running one); the check waits for a free, unfolded phone itself and SKIPs (exit 2) while the user
  # is active - tried again up to WINDOW_GATE_TRIES (8) times, ~15 min each. A FAIL marks the ship failed
  # ($Q/window-failed, $Q/failed or $Q/failed-apk, shipped.log, status) and mails the coder + logs friction, as a
  # failed ship does. No rollback (fix forward). SHIP_WINDOW_GATE=0 turns it off; off in tests (SHIP_DIR), as e2e_round.
  WINDOW_FILES='(^|/)(webwindows[^/]*|WebWindows[^/]*\.kt|WebWindowLaunch\.kt|FreeformTasks\.kt|SystemFloat\.kt|home\.tsx|shell\.css)$'
  window_gate() {
    [ "${SHIP_WINDOW_GATE:-1}" = 1 ] && [ -z "${SHIP_DIR:-}" ] && [ -x "$here/verify/window-render.sh" ] || return 0
    local b=$1 t=$2 what=$3 f old wb
    if [ -n "$b" ] && git cat-file -e "$b^{commit}" 2>/dev/null; then
      f=$(git diff --name-only "$b" "$t" 2>/dev/null | grep -E "$WINDOW_FILES" | sed 's|.*/||' | sort -u | paste -sd' ' -)
      [ -n "$f" ] || return 0
    else f="(no base: every window file)"; fi
    old=$(cat "$Q/window-gate.pid" 2>/dev/null) && [ -n "$old" ] && killtree "$old" 2>/dev/null
    # A copy to run: this checkout is reset under a running script (bash reads it as it goes).
    wb=$Q/window-render/bin; mkdir -p "$wb"; cp "$here/verify/window-render.sh" "$here/verify/window-render.py" "$wb/" || return 0
    echo "$(date +%T) ${t:0:9}: window files changed ($f) - device window check queued ($Q/done/window-render-${t:0:9}.log)"
    # The log says what happens from the first second (10-31: every window-render-*.log was 0 bytes - the check waited
    # for an idle phone, said nothing, and the next ship's check killed it): queued, each try's skip, a replacement.
    ( wl=$Q/done/window-render-${t:0:9}.log; n=0; since=$(date +%T)
      echo "$since window-render ${t:0:9} ($what; changed: $f): queued - waits for a free, unfolded phone (up to ${WINDOW_GATE_TRIES:-8} tries)" > "$wl"
      trap 'echo "$(date +%T) stopped: replaced by a newer ship'"'"'s check (try $n; skipped: user active since $since)" >> "$wl"; exit 143' TERM
      while :; do
        n=$((n + 1)); echo "$(date +%T) try $n: started" >> "$wl"
        WR_TOOLS=$here WR_OUT=$Q/window-render bash "$wb/window-render.sh" >> "$wl" 2>&1; wrc=$?
        [ $wrc = 2 ] && echo "$(date +%T) try $n: skipped: $(grep '^SKIP: ' "$wl" | tail -1 | cut -c7-200 | grep . || echo "user active since $since")" >> "$wl"
        [ $wrc = 2 ] && [ $n -lt "${WINDOW_GATE_TRIES:-8}" ] && { sleep 60; continue; }; break
      done
      res=$(grep '^window-render: ' "$wl" | tail -1 | cut -c1-300)
      case $wrc in
        0) rm -f "$Q/window-failed"; echo "$(date '+%F %T') ${t:0:9} $what window-render PASS" >> "$Q/shipped.log" ;;
        2) echo "$(date '+%F %T') ${t:0:9} $what window-render NOT RUN after $n tries: $res" >> "$Q/shipped.log" ;;
        *) echo "$t $what $f" > "$Q/window-failed"
           if [ "$what" = apk ]; then echo "$t" > "$Q/failed-apk"; else echo "$t" > "$Q/failed"; fi
           echo "$(date '+%F %T') ${t:0:9} $what window-render FAILED: $(grep -m1 '^FAIL' "$wl" | cut -c1-200)" >> "$Q/shipped.log"
           echo "$(date +%T) ${t:0:9}: WINDOWS BROKEN on the device after this ship (window-render FAIL, log $wl)"
           mail "ship ${t:0:9} ($what) FAILED the device window check - web windows are BROKEN on the phone (changed: $f): $(grep -m1 '^FAIL' "$wl" | cut -c1-220) - log $wl on the Mac (shots beside it); fix it on origin, then ship.sh request again" ;;
      esac
      rm -f "$Q/window-gate.pid" ) &
    echo $! > "$Q/window-gate.pid"
  }
  # render_watch TIP WHAT: after every shell or APK ship, a PASSIVE 20 s look at the phone's log (read-only, no taps,
  # never waits for an idle phone - unlike window_gate, which the always-active user starved: 10-31's three "windows
  # render empty" P0s all shipped unchecked). Live web windows (`PowosWebWindows: window N: live`, in the last 2 min,
  # by the app's current process) with a `RENDER STALL` (WebWindows' watchdog, RenderWatch.kt) or no applied geometry
  # (`w.f f...` line) since the ship = WINDOWS BROKEN, marked as window_gate marks a FAIL. No geometry while home isn't
  # on screen (an app full screen) is not judged. SHIP_RENDER_WATCH=0 turns it off; off in tests (SHIP_DIR).
  render_watch() {
    [ "${SHIP_RENDER_WATCH:-1}" = 1 ] && [ -z "${SHIP_DIR:-}" ] && [ -x "$here/adb.sh" ] || return 0
    local t=$1 what=$2
    ( rl=$Q/done/render-watch-${t:0:9}.log
      t0=$("$here/adb.sh" shell 'date +%s' 2>/dev/null | tr -d '\r')
      case $t0 in ''|*[!0-9]*) echo "$(date +%T) render-watch ${t:0:9} ($what): not run - the phone's clock unreadable (no phone?)" > "$rl"; exit 0 ;; esac
      echo "$(date +%T) render-watch ${t:0:9} ($what): 20 s passive log check from phone time $t0" > "$rl"
      sleep "${RENDER_WATCH_S:-20}"
      lc=$("$here/adb.sh" shell 'logcat -d -v epoch -s PowosWebWindows:*' 2>/dev/null | tr -d '\r')
      # The app's current process: the newest line's pid (an APK ship restarted it; the old one's windows are gone).
      pid=$(echo "$lc" | awk '/PowosWebWindows:/ {p=$2} END {print p}')
      v=$(echo "$lc" | awk -v t0="$t0" -v pid="$pid" '$2 != pid {next}
        $1 >= t0 - 120 && /PowosWebWindows: window [0-9]+: live/ {live++}
        $1 >= t0 && /RENDER STALL/ {stall++; last=$0}
        $1 >= t0 && /PowosWebWindows: w\.f f/ {wf++}
        END {printf "%d %d %d %s", live, stall, wf, last}')
      read -r live stall wf last <<< "$v"
      echo "live lines $live, RENDER STALL lines $stall, w.f lines $wf (pid ${pid:-?})${last:+; last stall: $last}" >> "$rl"
      bad=""
      if [ "${live:-0}" -gt 0 ] && [ "${stall:-0}" -gt 0 ]; then bad="RENDER STALL after the ship: ${last:0:200}"
      elif [ "${live:-0}" -gt 0 ] && [ "${wf:-0}" = 0 ]; then
        foc=$("$here/adb.sh" shell 'dumpsys window | grep -m1 mCurrentFocus' 2>/dev/null | tr -d '\r')
        home=$("$here/adb.sh" shell "cat /proc/${pid:-0}/cmdline" 2>/dev/null | tr -d '\r\0')
        if [ -n "$home" ] && echo "$foc" | grep -q "$home"; then bad="no w.f geometry applied in ${RENDER_WATCH_S:-20} s with live windows and home on screen ($foc)"
        else echo "not judged: no geometry, but home is not on screen ($foc)" >> "$rl"; fi
      fi
      if [ -z "$bad" ]; then echo "$(date +%T) render-watch: PASS" >> "$rl"; echo "$(date '+%F %T') ${t:0:9} $what render-watch PASS (live $live, w.f $wf)" >> "$Q/shipped.log"; exit 0; fi
      echo "$(date +%T) render-watch: FAIL: $bad" >> "$rl"
      echo "$t $what render-watch" > "$Q/window-failed"
      if [ "$what" = apk ]; then echo "$t" > "$Q/failed-apk"; else echo "$t" > "$Q/failed"; fi
      echo "$(date '+%F %T') ${t:0:9} $what render-watch FAILED: $bad" >> "$Q/shipped.log"
      echo "$(date +%T) ${t:0:9}: WINDOWS BROKEN on the device after this ship (render-watch FAIL, log $rl)"
      mail "ship ${t:0:9} ($what) FAILED the passive window check - web windows are BROKEN on the phone: $bad - log $rl on the Mac; fix it on origin, then ship.sh request again" ) &
  }
  # done_req FILE RESULT: a request fully on the phone.
  done_req() { echo "result=$2" >> "$1"; mv "$1" "$Q/done/"; }
  # pending_apk SHA: APK inputs changed up to it and aren't installed yet - its request is done once the APK is in.
  # own_apk SHA: its own commit changed them. A shell-only commit's note goes out with the shell push (it's visible
  # then), even while someone else's Kotlin below it waits for the APK; `noted=1` keeps the APK from repeating it.
  pending_apk() { [ -z "$inst" ] || { ! git merge-base --is-ancestor "$1" "$inst" 2>/dev/null && [ -n "$(apk_inputs "$inst" "$1")" ]; }; }
  own_apk() { [ -n "$(apk_inputs "$1~1" "$1")" ]; }
  # coupled BASE TIP: the commits in BASE..TIP (not installed yet) that changed APK inputs AND shell files together -
  # a shell that needs its APK (10-29: the overlay launcher shell went live without its APK and broke the home swipe-up;
  # 10-30: the web-windows shell stopped drawing window chrome the APK now draws - "There is no floating windows at all
  # anymore"). Printed as short shas, one per line; empty = nothing coupled.
  coupled() { local c f ak sh
    git rev-list --no-merges "$1..$2" -- targets/android/app targets/android/build-app.sh 2>/dev/null | while read -r c; do
      ak= sh=
      while read -r f; do case "$f" in
        targets/android/app/version.properties) ;; targets/android/app/*|targets/android/build-app.sh) ak=1 ;;
        shell/dev/*|shell/test/*) ;; shell/*) sh=1 ;; esac
      done < <(git diff-tree --no-commit-id --name-only -r "$c" 2>/dev/null)
      [ -n "$ak" ] && [ -n "$sh" ] && git rev-parse --short=9 "$c"
    done; }
  # schema_gate ADD: the checks (a)+(c) of a tip that changes a vendored app's module or pushes a vendored binding.
  # Silent and 0 when neither; else prints what it checked. vmods/T from the loop; SHIP_VENDOR_CHECK and
  # SHIP_BINDINGS_CHECK replace apps/vendor.sh --check / tools/phone/bindings-check.sh (tests).
  vendored_dbs() { sed -n 's|^\([a-z0-9-]*\)\.js  *generated .*|\1|p' shell/vendor/VERSIONS 2>/dev/null; }
  vendor_ok() {   # vendor_ok APP...: committed bindings = what the module builds; remembered per tip
    local a; for a in "$@"; do grep -qx "$T $a" "$Q/vendor-ok" 2>/dev/null && continue
      ${SHIP_VENDOR_CHECK:-apps/vendor.sh --check} "$a" || return 1; echo "$T $a" >> "$Q/vendor-ok"; done; }
  schema_gate() { local f db touch= pub
    for db in $(vendored_dbs); do for f in $1; do [ "$f" = "vendor/$db.js" ] && touch=1; done; done
    [ -n "$vmods" ] || [ -n "$touch" ] || return 0
    pub=$(echo "$vmods" | awk 'NF {print $1}' | paste -sd' ' -)
    [ -z "$pub" ] || vendor_ok $pub || return 1
    ${SHIP_BINDINGS_CHECK:-tools/phone/bindings-check.sh} --no-publish --vendor shell/vendor ${pub:+--publishing "$pub"}; }
  # reap_apk: an APK ship that ended (rc exists) is recorded + its requests done. Called every loop turn, at the
  # runner start (a previous runner's finished APK) and before it exits (f252: the runner left while the APK was
  # out, so a finished install was never recorded and phone checks kept waiting for their ship).
  reap_apk() {
    local inst A arc alog n r sha live ht st
    inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
    # An APK ship that ended: its requests are done (installed is installed - its exit is its last check's: a logcat
    # grep with no match was 1, 2026-10-23), or it's tried again (the user stayed active), or it failed.
    if [ -f "$Q/apk/rc" ]; then
      A=$(cat "$Q/apk/tip") arc=$(cat "$Q/apk/rc") alog=$(cat "$Q/apk/log")
      if [ "$arc" = 0 ] || [ "$inst" = "$A" ]; then
        live=$(cat "$Q/live" 2>/dev/null || true)
        # The install RESET every override, then re-pushed what origin's tip had differently from the APK: the phone's
        # shell is what ship-apk says it left there ($Q/apk/shell-tip: the tip it re-applied, or the APK's own build
        # when that push failed) - never the older "live" record kept as is (2026-10-30: APK f0b895fa installed, the
        # service went on reporting 49afb819 live). Behind the previous live tip: a silent request re-applies the
        # newer shell from here (the loop's delta from this live record).
        st=$(cat "$Q/apk/shell-tip" 2>/dev/null || true)
        git cat-file -e "${st:-x}^{commit}" 2>/dev/null || st=$A
        echo "$st" > "$Q/live"
        if [ -n "$live" ] && [ "$live" != "$st" ] && ! git merge-base --is-ancestor "$live" "$st" 2>/dev/null; then
          echo "$(date +%T) ${A:0:9}: the install left the phone's shell at ${st:0:9}, behind the live ${live:0:9} - re-applying the newer shell"
          r=$Q/$(date +%Y%m%d-%H%M%S)-reapply-$$.req
          printf 'sha=%q\nnote=\nsilent=1\nwho=ship-apk-reapply\nat=%s\n' "$live" "$(date +%s)" > "$r.tmp" && mv "$r.tmp" "$r"
        fi
        rm -f "$Q/failed-apk"
        # A shell held for this APK came with its install (ship-apk pushes origin's tip shell after it).
        { read -r ht _ < "$Q/shell-held" && git merge-base --is-ancestor "$ht" "$A"; } 2>/dev/null && rm -f "$Q/shell-held"
        # The records above first, THEN its requests done: a watcher seeing them done sees the records too.
        n=0; for r in "$Q"/*.req; do [ -f "$r" ] || continue; sha=; . "$r"
          git merge-base --is-ancestor "$sha" "$A" 2>/dev/null && { done_req "$r" "shipped:${A:0:9}:apk"; n=$((n+1)); }; done
        echo "$(date '+%F %T') ${A:0:9} apk $n req: $(grep -h '^note=' "$Q/apk/notes" 2>/dev/null | head -1 | cut -c6- || true)" >> "$Q/shipped.log"
        units_publish
        echo "$(date +%T) ${A:0:9}: APK installed ($n request(s) done)"
        # The build it replaced: ship-apk's snapshot of the previous install (ship-guard.sh snapshot DIR/commit).
        window_gate "$(cat "$HOME/.cache/powos-ship-snapshot/commit" 2>/dev/null)" "$st" apk
        render_watch "$st" apk
        e2e_round
      elif [ "$arc" = 8 ]; then echo "$(date +%T) ${A:0:9}: a newer APK is wanted - the pending one is replaced"
      elif [ "$arc" = 4 ]; then echo "$(date +%T) ${A:0:9}: the user stayed active - the APK goes again"
      elif [ -e "$Q/paused" ]; then echo "$(date +%T) ${A:0:9}: APK ship stopped by pause (rc $arc) - its requests are kept"
      else
        echo "$A" > "$Q/failed-apk"
        echo "$(date +%T) ${A:0:9}: APK ship FAILED rc $arc (log $alog) - waiting for a new origin commit"
        mail "ship ${A:0:9} (apk) FAILED rc $arc: $(grep -E 'REFUSED|refused|FAIL|error' "$alog" | tail -1 | cut -c1-200) - log $alog on the Mac; fix it on origin, then ship.sh request again"
      fi
      rm -rf "$Q/apk"; inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
    fi
  }
  reap_apk   # runner start: a previous runner's finished APK
  while :; do
    while ls "$Q"/*.req >/dev/null 2>&1 || rooted_due; do
      ship_tree >/dev/null || { sleep "$POLL"; continue; }
      T=$(git rev-parse HEAD)
      inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
      reap_apk
      inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
      # Paused: nothing new starts; an APK ship still out (installing) is reaped first.
      if [ -e "$Q/paused" ]; then
        apk_alive && { sleep "$POLL"; continue; }
        echo "$(date +%T) paused - $(ls "$Q"/*.req 2>/dev/null | wc -l | tr -d ' ') request(s) kept"; break
      fi
      # The debounce: shell after SHIP_QUIET_SHELL_S (0) s of origin on this tip, an APK after QUIET (60) s.
      { read -r seen at < "$Q/tip-seen"; } 2>/dev/null || seen=
      [ "$seen" = "$T" ] || { at=$(date +%s); echo "$T $at" > "$Q/tip-seen"; echo "$(date +%T) origin at ${T:0:9}"; }
      age=$(( $(date +%s) - at ))
      [ "$age" -ge "$QS" ] || { sleep "$POLL"; continue; }
      # The requests this tip covers, split into those its shell push finishes and those that wait for an APK.
      sreqs=(); snotes=(); nreqs=(); areqs=(); anotes=(); whos=()
      for r in "$Q"/*.req; do
        [ -f "$r" ] || continue
        sha= note= silent=0 who= noted=; . "$r"
        git merge-base --is-ancestor "$sha" "$T" 2>/dev/null || continue   # newer than this tip (fetched since)
        whos+=("$who")
        if [ "$silent" != 1 ] && [ -z "$noted" ] && ! own_apk "$sha"; then
          nreqs+=("$r"); [[ " ${snotes[*]+${snotes[*]}} " == *"$note"* ]] || snotes+=("$note")
        fi
        if pending_apk "$sha"; then
          areqs+=("$r")
          if [ "$silent" != 1 ] && [ -z "$noted" ] && own_apk "$sha"; then
            [[ " ${anotes[*]+${anotes[*]}} " == *"$note"* ]] || anotes+=("$note"); fi
        else
          sreqs+=("$r")
        fi
      done
      # No request covers this tip: only a pending rooted deploy keeps the loop here (rooted_due above).
      [ ${#whos[@]} -gt 0 ] || rooted_due || { sleep "$POLL"; continue; }
      who_s=$(printf '%s\n' ${whos[@]+"${whos[@]}"} | sed '/^$/d' | sort -u | paste -sd, -); who_s=${who_s:-"$(cut -c6- "$Q/rooted-note" 2>/dev/null | head -1)"}
      joined() { printf '%s\n' "$@" | sed '/^$/d' | paste -sd';' - | sed 's/;/; /g'; }
      # The apps step's changes (step 3), known up front: a vendored app's module change (vmods: "app db" lines) ties
      # the shell's bindings (shell/vendor/<db>.js) to its publish.
      alv=$(cat "$Q/apps-live" 2>/dev/null || true)
      abase=$inst
      [ -n "$alv" ] && abase=$alv
      # HACK-fix (2026-10-24): this used to advance abase to the SHELL-live tip, which hid every apps/<app>/ change from
      # the apps ship (shell ships never build apps; app-api's detail page + add-app fix sat unshipped, journey failed).
      # abase moves only when an apps ship records $Q/apps-live (or the APK was installed).
      achg=; vmods=; [ -n "$abase" ] && git cat-file -e "$abase^{commit}" 2>/dev/null && achg=$(apps_changed "$abase" "$T") &&
        vmods=$(apps/vendor.sh --changed "$abase" "$T" 2>/dev/null | while read -r va vd; do [[ " $(echo $achg) " == *" $va "* ]] && echo "$va $vd"; done)
      # 1. The shell part, now: exactly the shell files that differ from what's live - also while an APK builds or
      #    waits for idle (its install resets the overrides and re-pushes everything origin changed since its build).
      live=$(cat "$Q/live" 2>/dev/null || true)
      base=$inst
      [ -n "$live" ] && [ -n "$inst" ] && git merge-base --is-ancestor "$inst" "$live" 2>/dev/null && base=$live
      d=; [ -n "$base" ] && git cat-file -e "$base^{commit}" 2>/dev/null && d=$(delta "$base" "$T")
      add=$(echo "$d" | sed -n 's/^+//p'); gone=$(echo "$d" | sed -n 's/^-//p')
      # The shell HOLD: this tip has APK inputs not installed yet, and some of them came in the same commits as
      # shell changes (coupled, above) - that shell needs its APK, so it goes WITH it: the APK install (ship-apk.sh)
      # resets the overrides and pushes every shell file origin's tip has differently from the APK's own assets, so
      # holding the shell part here is all it takes. A shell-only tip, or Kotlin and shell in separate commits, ships
      # at once as before (2026-10-23: shell fixes must not queue behind an APK's idle wait). <queue>/shell-held:
      # "TIP COUPLED..." for status; cleared once nothing is held.
      cpl=; [ -n "$d" ] && [ -n "$inst" ] && pending_apk "$T" && cpl=$(coupled "$inst" "$T" | paste -sd' ' -)
      if [ -n "$cpl" ]; then
        [ "$(cat "$Q/shell-held" 2>/dev/null)" = "$T $cpl" ] || { echo "$T $cpl" > "$Q/shell-held"
          echo "$(date +%T) ${T:0:9}: shell held for its APK ${T:0:9} (APK inputs + shell in the same commit: $cpl) - they land together at the install"; }
      else rm -f "$Q/shell-held"; fi
      if [ -n "$d" ] && [ -z "$cpl" ] && [ "$(cat "$Q/failed" 2>/dev/null)" != "$T" ]; then
        # Never inside a verify window. The phone is taken with $SL/phone while our own APK ship holds the ship
        # lock (ship-apk takes it for its install), else with the ship lock itself (a --direct ship).
        # Held: ask the verify queue to yield before its next check (queue.sh reads wants-phone, as for ship-apk) - it
        # touches its lock every heartbeat, so waiting for the lock alone held every ship for a whole window (15:07-15:41,
        # 2026-10-23). Cleared below once the phone is ours and done.
        if verify_held; then echo $$ > "$Q/wants-phone"; echo "$(date +%T) verify lock held ($(cat "$VL/who" 2>/dev/null)) - asked it to yield, waiting"; sleep "$POLL"; continue; fi
        if apk_alive && mkdir "$SL/phone" 2>/dev/null; then held="$SL/phone"
        elif ! apk_alive && ship_lock; then held=$SL
        else echo "$(date +%T) the phone is busy ($(cat "$SL/who" 2>/dev/null)$( [ -d "$SL/phone" ] && echo ', installing')) - waiting"; sleep "$POLL"; continue; fi
        echo $$ > "$Q/installing"
        [ -e "$Q/paused" ] && { rm -f "$Q/installing"; rm -rf "$held"; [ "$(cat "$Q/wants-phone" 2>/dev/null)" = $$ ] && rm -f "$Q/wants-phone"; continue; }
        sn=$(joined ${snotes[@]+"${snotes[@]}"})
        if [ -n "$sn" ]; then na=(--note "$sn"); else na=(--silent); fi
        log=$Q/done/$(date +%Y%m%d-%H%M%S)-${T:0:9}.log
        # f307: this shell goes live before the APK it may need. Bridge methods the installed APK lacks, with no
        # `// detect`: reported to the coder (once per tip) - a bug to fix, so it ships unless SHIP_BRIDGE_STRICT=1.
        if [ -x tools/phone/bridge-detect-check.sh ] && ! bd=$(tools/phone/bridge-detect-check.sh "$T" 2>&1); then
          echo "$bd" | sed 's/^/  /'
          [ "$(cat "$Q/bridge-flagged" 2>/dev/null)" = "$T" ] || { echo "$T" > "$Q/bridge-flagged"
            mail "ship ${T:0:9} (shell) f307: bridge calls the installed APK lacks, no // detect: $(echo "$bd" | sed -n 's/^  \([a-z]*\.[A-Za-z.]*\)$/\1/p' | paste -sd' ' - | cut -c1-200) - log $log on the Mac"; }
          if [ -n "${SHIP_BRIDGE_STRICT:-}" ]; then
            echo "$(date +%T) ${T:0:9}: shell ship held by SHIP_BRIDGE_STRICT (f307)"; rm -rf "$held"; rm -f "$Q/installing"; echo "$T" > "$Q/failed"; continue; fi
        fi
        # Schema changes ship atomically (2026-10-30, powos-agents work.try_line): a vendored app's module change in
        # this tip needs its committed bindings to be exactly what the module builds (apps/vendor.sh --check), and the
        # bindings the phone will run after this push must decode its live modules - ahead only of the modules this
        # ship publishes right after (the apps step: bindings first, then the module). Else the whole tip is refused.
        if ! bok=$(schema_gate "$add" 2>&1); then
          echo "$bok" | sed 's/^/  /'
          rm -rf "$held"; rm -f "$Q/installing"; [ "$(cat "$Q/wants-phone" 2>/dev/null)" = $$ ] && rm -f "$Q/wants-phone"
          echo "$T" > "$Q/failed"; echo "$T" > "$Q/failed-apps"
          echo "$(date +%T) ${T:0:9}: shell ship REFUSED - the bindings and the modules wouldn't match (above)"
          mail "ship ${T:0:9} (shell) REFUSED for $who_s: $(echo "$bok" | grep -E 'REFUSED|bindings:.*(fix|isn)' | head -2 | cut -c1-240 | paste -sd' ' -) - log $Q/runner.log on the Mac; fix it on origin, then ship.sh request again"
          continue
        fi
        [ -z "$bok" ] || echo "$bok" | sed 's/^/  /'
        echo "$(date +%T) ship ${T:0:9} as shell:$(echo $add)$([ -n "$gone" ] && echo " reset:$(echo $gone)") for $who_s$(apk_alive && echo ' (beside the APK ship)')"
        rc=0; sg=POWOS_SKIP_GATE=1; [ -z "${SHIP_GATE_FIRST:-}" ] || sg=
        if [ -n "$add" ]; then
          # 60 s like ship-apk's pre-gate: a shell ship runs beside an APK build (Colima ~900% CPU), and at 30 s every
          # page timed out "not ready" with no error (02:03, b56483e).
          # DEPLOY FIRST, VERIFY AFTER (2026-10-28: the in-ship gate - tsc, lints, every page booted, twice when the Mac
          # is busy - was 2-7 min of the land->live time). The agent's land already gated this tip; the phone's own
          # ShellErrors rollback catches a page that dies on the device; the full gate runs right after, off the
          # critical path (post_gate below), and a FAIL mails the coder. SHIP_GATE_FIRST=1 restores gate-then-push.
          (cd shell && POWOS_SHIP_SERVICE=1 GATE_PRIORITY=ship IDLE_MS=${IDLE_MS:-0} READY_MS=${READY_MS:-60000} env $sg ./push.sh --vpn "${na[@]}" $add) > "$log" 2>&1 || rc=$?
        fi
        if [ $rc = 0 ] && [ -n "$gone" ]; then
          (cd shell && POWOS_SHIP_SERVICE=1 GATE_PRIORITY=ship ./push.sh --vpn --reset $gone) >> "$log" 2>&1 || rc=$?
        fi
        rm -rf "$held"; rm -f "$Q/installing"; [ "$(cat "$Q/wants-phone" 2>/dev/null)" = $$ ] && rm -f "$Q/wants-phone"
        if [ $rc = 0 ]; then
          echo "$T" > "$Q/live"; rm -f "$Q/failed"
          post_gate "$T" "$log" $add
          window_gate "$base" "$T" shell
          render_watch "$T" shell
          echo "$(date '+%F %T') ${T:0:9} shell ${#sreqs[@]} req ($who_s): ${sn:-(silent)}" >> "$Q/shipped.log"
          units_publish
          for r in ${nreqs[@]+"${nreqs[@]}"}; do [ -f "$r" ] && echo "noted=1" >> "$r"; done
          for r in ${sreqs[@]+"${sreqs[@]}"}; do done_req "$r" "shipped:${T:0:9}:shell"; done
          echo "$(date +%T) ${T:0:9}: shipped (shell)"
          e2e_round
        else
          git -C "$REPO" fetch -q origin "$BASE" 2>/dev/null
          if [ "$(git rev-parse "origin/$BASE")" != "$T" ]; then echo "$(date +%T) ${T:0:9}: shell ship ended rc $rc while origin moved on - shipping the new tip"; continue; fi
          echo "$T" > "$Q/failed"
          echo "$(date +%T) ${T:0:9}: shell ship FAILED rc $rc (log $log) - waiting for a new origin commit"
          mail "ship ${T:0:9} (shell) FAILED rc $rc for $who_s: $(grep -E 'REFUSED|refused|FAIL|error' "$log" | tail -1 | cut -c1-200) - log $log on the Mac; fix it on origin, then ship.sh request again"
          continue
        fi
      elif [ -z "$d" ] && [ -n "$base" ] && [ -z "$cpl" ]; then
        for r in ${sreqs[@]+"${sreqs[@]}"}; do done_req "$r" "shipped:${T:0:9}:none"; done
        [ ${#sreqs[@]} -gt 0 ] && echo "$(date +%T) ${T:0:9}: nothing differs from what's live - ${#sreqs[@]} request(s) done"
      fi
      # 2. The APK, beside the loop: once origin stayed QUIET s on the tip, one at a time, not again on a tip that failed.
      if [ ${#areqs[@]} -gt 0 ] && ! apk_alive && [ "$age" -ge "$QUIET" ] && [ "$(cat "$Q/failed-apk" 2>/dev/null)" != "$T" ]; then
        an=$(joined ${anotes[@]+"${anotes[@]}"})
        if [ -n "$an" ]; then na=(--note "$an"); else na=(--silent); fi
        why="no record of the installed build"; [ -n "$inst" ] && why="APK inputs changed: $(apk_inputs "$inst" "$T" | head -3 | paste -sd' ' -)"
        echo "$(date +%T) ship ${T:0:9} as an APK ($why) for $who_s - beside the loop"
        apk_launch "$T" "${na[@]}" && echo "note=${an:-(silent)}" > "$Q/apk/notes" || echo "$(date +%T) ${T:0:9}: couldn't check out $SA for the APK"
      fi
      # 3. Apps: apps/<app>/ changed since the last apps ship, built + installed on the phone - after the APK
      #    (never while one's out, same debounce as the shell ship above so this never waits on an open request
      #    the shell section already closed) and under the shell ship's own phone-busy rules (never inside a
      #    verify window, never during another install).
      # A vendored module waits for its bindings to be live (the shell part held for an APK, or not pushed yet).
      # What the phone's shell is at: the live record, or the installed APK's own when that's newer / there's none.
      vwait=; lv=$(cat "$Q/live" 2>/dev/null || true)
      { [ -n "$lv" ] && { [ -z "$inst" ] || git merge-base --is-ancestor "$inst" "$lv" 2>/dev/null; }; } || lv=$inst
      while read -r va vd; do [ -n "$va" ] || continue
        { [ -n "$lv" ] && git diff --quiet "$lv" "$T" -- "shell/vendor/$vd.js" 2>/dev/null; } || vwait="$vwait $vd"
      done <<< "$vmods"
      if [ -n "$vwait" ] && [ -n "$achg" ]; then
        [ "$(cat "$Q/apps-held" 2>/dev/null)" = "$T" ] || { echo "$T" > "$Q/apps-held"
          echo "$(date +%T) ${T:0:9}: apps held - the shell's bindings for$vwait aren't live yet (they ship first)"; }
      elif [ -n "$achg" ] && ! apk_alive && [ "$age" -ge "$QS" ] && [ "$(cat "$Q/failed-apps" 2>/dev/null)" != "$T" ]; then
        rm -f "$Q/apps-held"
        if verify_held; then echo $$ > "$Q/wants-phone"
        elif ship_lock; then
          echo $$ > "$Q/installing"
          an=$(joined ${snotes[@]+"${snotes[@]}"} ${anotes[@]+"${anotes[@]}"}); an=${an:-"app update"}
          alog=$Q/done/$(date +%Y%m%d-%H%M%S)-${T:0:9}-apps.log; arc=0
          echo "$(date +%T) ship ${T:0:9} as apps ($achg) for $who_s" | tee -a "$alog" >/dev/null
          # A vendored app's module goes out only with its bindings: committed = what it builds (checked before the
          # shell push already, remembered), and LIVE on the phone (the shell part of this tip shipped them first) -
          # never a module ahead of the shell's bindings (2026-10-30 19:31: home's board subscription stopped decoding).
          vpub=$(echo "$vmods" | awk 'NF {print $1}' | paste -sd' ' -)
          if [ -n "$vpub" ] && ! vendor_ok $vpub >> "$alog" 2>&1; then arc=9; echo "apps: REFUSED - committed bindings aren't what the module builds" >> "$alog"; fi
          if [ $arc = 0 ]; then for a in $achg; do
            ( PATH="$here/bin:$PATH" apps/build.sh "$a" && PATH="$here/bin:$PATH" POWOS_SHIP_SERVICE=1 apps/install.sh "$a" install --note "$an" ) >> "$alog" 2>&1 || { arc=$?; break; }
          done; fi
          # And after the publish: the shell's bindings decode the phone's modules (no auto-publish here).
          if [ $arc = 0 ] && [ -n "$vpub" ] && ! ${SHIP_BINDINGS_CHECK:-tools/phone/bindings-check.sh} --no-publish --vendor shell/vendor >> "$alog" 2>&1; then
            arc=10; echo "apps: the phone's modules and the shell's bindings don't match after the publish (above)" >> "$alog"; fi
          rm -rf "$SL"; rm -f "$Q/installing"; [ "$(cat "$Q/wants-phone" 2>/dev/null)" = $$ ] && rm -f "$Q/wants-phone"
          if [ $arc = 0 ]; then
            echo "$T" > "$Q/apps-live"; rm -f "$Q/failed-apps"
            echo "$(date '+%F %T') ${T:0:9} apps ($achg) for $who_s: $an" >> "$Q/shipped.log"
            units_publish
            echo "$(date +%T) ${T:0:9}: apps shipped ($achg)"
          else
            echo "$T" > "$Q/failed-apps"
            echo "$(date +%T) ${T:0:9}: apps ship FAILED rc $arc (log $alog) - waiting for a new origin commit"
            mail "ship ${T:0:9} (apps:$achg) FAILED rc $arc: $(tail -1 "$alog" | cut -c1-200) - log $alog on the Mac; fix it on origin, then ship.sh request again"
          fi
        fi
      fi
      # 4. The rooted-mode deploy (targets/android/rooted/rooted.sh deploy, f105 part 1): rooted_inputs changed
      #    since the last rooted-mode ship, built... nothing to build, just pushed - after the APK, under the
      #    same debounce and phone-busy rules as the apps step above.
      #    Its notes are kept in $Q/rooted-note ("who" line, then the note): the APK's install finishes the requests
      #    before this step gets its turn.
      rn=$(joined ${snotes[@]+"${snotes[@]}"} ${anotes[@]+"${anotes[@]}"})
      if rooted_due; then
        [ -z "$rn" ] || printf 'who: %s\n%s\n' "$who_s" "$rn" > "$Q/rooted-note"
      else rchg=; fi
      if [ -n "$rchg" ] && ! apk_alive && [ "$age" -ge "$QS" ]; then
        if verify_held; then echo $$ > "$Q/wants-phone"
        elif ship_lock; then
          echo $$ > "$Q/installing"
          [ -n "$rn" ] || rn=$(sed -n 2p "$Q/rooted-note" 2>/dev/null); rn=${rn:-"rooted update"}
          rlog=$Q/done/$(date +%Y%m%d-%H%M%S)-${T:0:9}-rooted.log
          echo "$(date +%T) ship ${T:0:9} as a rooted deploy ($rchg) for $who_s" | tee -a "$rlog" >/dev/null
          rrc=0
          if ! ug=$(units_gate "$Q/units-gate.log"); then
            rrc=9; echo "REFUSED: an install no unit claims (units/; test/tier1/test-units-registry.py): $ug" >> "$rlog"
          else
            ( PATH="$here/bin:$PATH" POWOS_SHIP_SERVICE=1 targets/android/rooted/rooted.sh deploy --note "$rn" ) >> "$rlog" 2>&1 || rrc=$?
          fi
          rm -rf "$SL"; rm -f "$Q/installing"; [ "$(cat "$Q/wants-phone" 2>/dev/null)" = $$ ] && rm -f "$Q/wants-phone"
          if [ $rrc = 0 ]; then
            echo "$T" > "$Q/rooted-live"; rm -f "$Q/failed-rooted" "$Q/rooted-pending" "$Q/rooted-note"
            echo "$(date '+%F %T') ${T:0:9} rooted ($rchg) for $who_s: $rn" >> "$Q/shipped.log"
            echo "$(date +%T) ${T:0:9}: rooted deploy done ($rchg)"
          else
            echo "$T" > "$Q/failed-rooted"; rm -f "$Q/rooted-pending" "$Q/rooted-note"
            echo "$(date +%T) ${T:0:9}: rooted deploy FAILED rc $rrc (log $rlog) - waiting for a new origin commit"
            mail "ship ${T:0:9} (rooted:$rchg) FAILED rc $rrc: $(tail -1 "$rlog" | cut -c1-200) - log $rlog on the Mac; fix it on origin, then ship.sh request again"
          fi
        fi
      fi
      ! { ls "$Q"/*.req >/dev/null 2>&1 || rooted_due; } || sleep "$POLL"
    done
    # An APK ship still out: stay and reap it (the loop above reaps once its rc exists) before the idle exit.
    apk_alive && { sleep "$POLL"; continue; }
    [ -f "$Q/apk/rc" ] && { reap_apk; continue; }
    # A rooted deploy still due (its APK just installed, say): one more pass, never while paused.
    [ ! -e "$Q/paused" ] && ship_tree >/dev/null && rooted_due && continue
    rm -rf "$L"
    [ -e "$Q/paused" ] && break
    # A request written while this runner was on its way out: take the lock again and serve it.
    ls "$Q"/*.req >/dev/null 2>&1 || break
    mkdir "$L" 2>/dev/null && echo $$ > "$L/pid" || break
  done ;;
*) sed -n 2,14p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
