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
#   - shell, once origin stayed SHIP_QUIET_SHELL_S (10) s on the tip: shell/push.sh --vpn of exactly the shell files
#     that differ from what's live (the last tip it shipped, or the installed build), --reset of the ones the tip
#     deleted - ALSO while an APK ship is out (2026-10-23: shell fixes waited 25-30 min behind one APK's build and idle
#     wait). Never while the verify lock (~/.cache/powos-verify.lock, < 10 min old) is held, never during an install
#     (ship-apk holds <ship lock>/phone for it; the shell push takes the same dir while it pushes);
#   - an APK when Kotlin / APK inputs changed since the installed build (~/.cache/powos-installed-commit), once origin
#     stayed SHIP_QUIET_S (60) s on the tip: ship-apk.sh from the tip in its own checkout ($POWOS_RUN_ROOT/
#     ship-runner-apk), BESIDE the loop, one at a time (it pre-gates, waits for the verify lock and a free phone, resets
#     the overrides and re-pushes newer shell). A request whose commit has Kotlin is done once the APK is installed.
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
QUIET=${SHIP_QUIET_S:-60} QS=${SHIP_QUIET_SHELL_S:-10} POLL=${SHIP_POLL_S:-10}
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
    tools/app-api lib/ai/manager lib/ai/sandbox desktop/plasmoid 2>/dev/null | grep -v '^lib/ai/sandbox/node_modules/'; }
  # The APK ship runs BESIDE the loop, in its own checkout (it builds from it for minutes while ship_tree resets $SR),
  # so a shell change never queues behind an APK's build or idle wait (2026-10-23: shell fixes waited 25-30 min behind
  # one APK). State in $Q/apk/: tip, pid, rc (written when it ends).
  # Under ~/Projects, NOT $POWOS_RUN_ROOT (~/pw): the APK builds in android-app-dev's container, which mounts only
  # ~/Projects as /Projects - from ~/pw every APK ship failed ("Project 'powos' not found", 2026-10-24 06:30-15:30).
  # It is no agent's cwd, so it doesn't add to agents' context (f190: still no .claude/worktrees fallback).
  SA=${POWOS_APK_RUN:-$HOME/Projects/.powos-runners/ship-runner-apk}
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
    ( cd "$SA" && POWOS_SHIP_SERVICE=1 SHIP_DIR=$Q GATE_PRIORITY=ship bash tools/phone/ship-apk.sh "$@" > "$(cat "$Q/apk/log")" 2>&1; echo $? > "$Q/apk/rc" ) &
    echo $! > "$Q/apk/pid"
  }
  # done_req FILE RESULT: a request fully on the phone.
  done_req() { echo "result=$2" >> "$1"; mv "$1" "$Q/done/"; }
  # pending_apk SHA: APK inputs changed up to it and aren't installed yet - its request is done once the APK is in.
  # own_apk SHA: its own commit changed them. A shell-only commit's note goes out with the shell push (it's visible
  # then), even while someone else's Kotlin below it waits for the APK; `noted=1` keeps the APK from repeating it.
  pending_apk() { [ -z "$inst" ] || { ! git merge-base --is-ancestor "$1" "$inst" 2>/dev/null && [ -n "$(apk_inputs "$inst" "$1")" ]; }; }
  own_apk() { [ -n "$(apk_inputs "$1~1" "$1")" ]; }
  # reap_apk: an APK ship that ended (rc exists) is recorded + its requests done. Called every loop turn, at the
  # runner start (a previous runner's finished APK) and before it exits (f252: the runner left while the APK was
  # out, so a finished install was never recorded and phone checks kept waiting for their ship).
  reap_apk() {
    local inst A arc alog n r sha live
    inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
    # An APK ship that ended: its requests are done (installed is installed - its exit is its last check's: a logcat
    # grep with no match was 1, 2026-10-23), or it's tried again (the user stayed active), or it failed.
    if [ -f "$Q/apk/rc" ]; then
      A=$(cat "$Q/apk/tip") arc=$(cat "$Q/apk/rc") alog=$(cat "$Q/apk/log")
      if [ "$arc" = 0 ] || [ "$inst" = "$A" ]; then
        n=0; for r in "$Q"/*.req; do [ -f "$r" ] || continue; sha=; . "$r"
          git merge-base --is-ancestor "$sha" "$A" 2>/dev/null && { done_req "$r" "shipped:${A:0:9}:apk"; n=$((n+1)); }; done
        live=$(cat "$Q/live" 2>/dev/null || true)
        # The install reset the overrides and re-pushed origin's newer shell: live is at least A.
        { [ -n "$live" ] && git merge-base --is-ancestor "$A" "$live" 2>/dev/null; } || echo "$A" > "$Q/live"
        rm -f "$Q/failed-apk"
        echo "$(date '+%F %T') ${A:0:9} apk $n req: $(grep -h '^note=' "$Q/apk/notes" 2>/dev/null | head -1 | cut -c6- || true)" >> "$Q/shipped.log"
        echo "$(date +%T) ${A:0:9}: APK installed ($n request(s) done)"
        e2e_round
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
    while ls "$Q"/*.req >/dev/null 2>&1; do
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
      # The debounce: shell after SHIP_QUIET_SHELL_S (10) s of origin on this tip, an APK after QUIET (60) s.
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
      [ ${#whos[@]} -gt 0 ] || { sleep "$POLL"; continue; }
      who_s=$(printf '%s\n' "${whos[@]}" | sort -u | paste -sd, -)
      joined() { printf '%s\n' "$@" | sed '/^$/d' | paste -sd';' - | sed 's/;/; /g'; }
      # 1. The shell part, now: exactly the shell files that differ from what's live - also while an APK builds or
      #    waits for idle (its install resets the overrides and re-pushes everything origin changed since its build).
      live=$(cat "$Q/live" 2>/dev/null || true)
      base=$inst
      [ -n "$live" ] && [ -n "$inst" ] && git merge-base --is-ancestor "$inst" "$live" 2>/dev/null && base=$live
      d=; [ -n "$base" ] && git cat-file -e "$base^{commit}" 2>/dev/null && d=$(delta "$base" "$T")
      add=$(echo "$d" | sed -n 's/^+//p'); gone=$(echo "$d" | sed -n 's/^-//p')
      if [ -n "$d" ] && [ "$(cat "$Q/failed" 2>/dev/null)" != "$T" ]; then
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
        echo "$(date +%T) ship ${T:0:9} as shell:$(echo $add)$([ -n "$gone" ] && echo " reset:$(echo $gone)") for $who_s$(apk_alive && echo ' (beside the APK ship)')"
        rc=0
        if [ -n "$add" ]; then
          # 60 s like ship-apk's pre-gate: a shell ship runs beside an APK build (Colima ~900% CPU), and at 30 s every
          # page timed out "not ready" with no error (02:03, b56483e).
          (cd shell && POWOS_SHIP_SERVICE=1 GATE_PRIORITY=ship READY_MS=${READY_MS:-60000} ./push.sh --vpn "${na[@]}" $add) > "$log" 2>&1 || rc=$?
        fi
        if [ $rc = 0 ] && [ -n "$gone" ]; then
          (cd shell && POWOS_SHIP_SERVICE=1 GATE_PRIORITY=ship ./push.sh --vpn --reset $gone) >> "$log" 2>&1 || rc=$?
        fi
        rm -rf "$held"; rm -f "$Q/installing"; [ "$(cat "$Q/wants-phone" 2>/dev/null)" = $$ ] && rm -f "$Q/wants-phone"
        if [ $rc = 0 ]; then
          echo "$T" > "$Q/live"; rm -f "$Q/failed"
          echo "$(date '+%F %T') ${T:0:9} shell ${#sreqs[@]} req ($who_s): ${sn:-(silent)}" >> "$Q/shipped.log"
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
      elif [ -z "$d" ] && [ -n "$base" ]; then
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
      alv=$(cat "$Q/apps-live" 2>/dev/null || true)
      abase=$inst
      [ -n "$alv" ] && abase=$alv
      # HACK-fix (2026-10-24): this used to advance abase to the SHELL-live tip, which hid every apps/<app>/ change from
      # the apps ship (shell ships never build apps; app-api's detail page + add-app fix sat unshipped, journey failed).
      # abase moves only when an apps ship records $Q/apps-live (or the APK was installed).
      achg=; [ -n "$abase" ] && git cat-file -e "$abase^{commit}" 2>/dev/null && achg=$(apps_changed "$abase" "$T")
      if [ -n "$achg" ] && ! apk_alive && [ "$age" -ge "$QS" ] && [ "$(cat "$Q/failed-apps" 2>/dev/null)" != "$T" ]; then
        if verify_held; then echo $$ > "$Q/wants-phone"
        elif ship_lock; then
          echo $$ > "$Q/installing"
          an=$(joined ${snotes[@]+"${snotes[@]}"} ${anotes[@]+"${anotes[@]}"}); an=${an:-"app update"}
          alog=$Q/done/$(date +%Y%m%d-%H%M%S)-${T:0:9}-apps.log; arc=0
          echo "$(date +%T) ship ${T:0:9} as apps ($achg) for $who_s" | tee -a "$alog" >/dev/null
          for a in $achg; do
            ( PATH="$here/bin:$PATH" apps/build.sh "$a" && PATH="$here/bin:$PATH" apps/install.sh "$a" install --note "$an" ) >> "$alog" 2>&1 || { arc=$?; break; }
          done
          rm -rf "$SL"; rm -f "$Q/installing"; [ "$(cat "$Q/wants-phone" 2>/dev/null)" = $$ ] && rm -f "$Q/wants-phone"
          if [ $arc = 0 ]; then
            echo "$T" > "$Q/apps-live"; rm -f "$Q/failed-apps"
            echo "$(date '+%F %T') ${T:0:9} apps ($achg) for $who_s: $an" >> "$Q/shipped.log"
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
      rlv=$(cat "$Q/rooted-live" 2>/dev/null || true)
      rbase=$inst
      [ -n "$rlv" ] && rbase=$rlv
      [ -n "$live" ] && [ -n "$rbase" ] && git merge-base --is-ancestor "$rbase" "$live" 2>/dev/null && rbase=$live
      rchg=; [ -n "$rbase" ] && git cat-file -e "$rbase^{commit}" 2>/dev/null && rchg=$(rooted_inputs "$rbase" "$T")
      if [ -n "$rchg" ] && ! apk_alive && [ "$age" -ge "$QS" ] && [ "$(cat "$Q/failed-rooted" 2>/dev/null)" != "$T" ]; then
        if verify_held; then echo $$ > "$Q/wants-phone"
        elif ship_lock; then
          echo $$ > "$Q/installing"
          rn=$(joined ${snotes[@]+"${snotes[@]}"} ${anotes[@]+"${anotes[@]}"}); rn=${rn:-"rooted update"}
          rlog=$Q/done/$(date +%Y%m%d-%H%M%S)-${T:0:9}-rooted.log
          echo "$(date +%T) ship ${T:0:9} as a rooted deploy ($rchg) for $who_s" | tee -a "$rlog" >/dev/null
          rrc=0
          ( PATH="$here/bin:$PATH" POWOS_SHIP_SERVICE=1 targets/android/rooted/rooted.sh deploy --note "$rn" ) >> "$rlog" 2>&1 || rrc=$?
          rm -rf "$SL"; rm -f "$Q/installing"; [ "$(cat "$Q/wants-phone" 2>/dev/null)" = $$ ] && rm -f "$Q/wants-phone"
          if [ $rrc = 0 ]; then
            echo "$T" > "$Q/rooted-live"; rm -f "$Q/failed-rooted"
            echo "$(date '+%F %T') ${T:0:9} rooted ($rchg) for $who_s: $rn" >> "$Q/shipped.log"
            echo "$(date +%T) ${T:0:9}: rooted deploy done ($rchg)"
          else
            echo "$T" > "$Q/failed-rooted"
            echo "$(date +%T) ${T:0:9}: rooted deploy FAILED rc $rrc (log $rlog) - waiting for a new origin commit"
            mail "ship ${T:0:9} (rooted:$rchg) FAILED rc $rrc: $(tail -1 "$rlog" | cut -c1-200) - log $rlog on the Mac; fix it on origin, then ship.sh request again"
          fi
        fi
      fi
      ! ls "$Q"/*.req >/dev/null 2>&1 || sleep "$POLL"
    done
    # An APK ship still out: stay and reap it (the loop above reaps once its rc exists) before the idle exit.
    apk_alive && { sleep "$POLL"; continue; }
    [ -f "$Q/apk/rc" ] && { reap_apk; continue; }
    rm -rf "$L"
    [ -e "$Q/paused" ] && break
    # A request written while this runner was on its way out: take the lock again and serve it.
    ls "$Q"/*.req >/dev/null 2>&1 || break
    mkdir "$L" 2>/dev/null && echo $$ > "$L/pid" || break
  done ;;
*) sed -n 2,14p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
