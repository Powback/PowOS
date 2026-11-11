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
#   - packages (11-10): targets/android/pkgs/<name>/ changed since the last packages build ($Q/pkgs-live): build-pkgs.sh
#     <names> under the heavy build slot + publish-repo.sh ([powos] on android.pow, the non-root phones' updates), BESIDE
#     the loop in its own checkout ($POWOS_RUN_ROOT/ship-runner-pkgs); the rooted deploy (which installs kwin etc. from
#     out/pkgs) waits for it. Before, a PKGBUILD bump shipped as code only and no package was ever built (kwin 3.76).
#   - ~/.config/powos/ship-no-idle-wait (the user's setting; file present = on): APK ships pass --now to ship-apk.sh -
#     install at once instead of waiting for the user to be idle / the screen off. Delete the file to wait again.
#   The notes of the requests a part finishes go into ONE update notification ("a; b"; all --silent = silent). The tip shipped
#   goes to <queue>/live, a line to <queue>/shipped.log, the run's log to <queue>/done/. A failed ship mails the
#   coder inbox and isn't retried until origin moves (a user who stayed active: retried). No gate verdict (gate.sh exit 75,
#   its job machine .58 gone; push.sh / apps/install.sh / ship-apk.sh exit 75) is no failure: that step is DEFERRED
#   (gate_deferred: requests kept, no mail, one status line) and gated again once the machine answers. ship-apk.sh / push.sh
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
killtree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c" "${2:-TERM}"; done; kill -"${2:-TERM}" "$1" 2>/dev/null; }
# gate_deadline SECS PID: PID's hard wall-clock deadline (backgrounded; $! is the watchdog): its whole tree TERMed after
# SECS s, then - still there WINDOW_GATE_GRACE_S (30) s later - KILLed, tree re-read (a TERM trap's cleanup starts new
# children after the first sweep). 11-11 14:50: window-render's cleanup wrote to a fifo with no reader after the TERM;
# the single sweep had already run and `wait` held the ship service 2.5 h. test/tier1/test-window-render-fifo.sh.
gate_deadline() { ( sleep "$1"; killtree "$2"; for _ in $(seq 1 "${WINDOW_GATE_GRACE_S:-30}"); do kill -0 "$2" 2>/dev/null || exit 0; sleep 1; done; killtree "$2" KILL ) & }
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
  [ -s "$Q/window-gate.pid" ] && kill -0 "$(cat "$Q/window-gate.pid")" 2>/dev/null && echo "device window check running (pid $(cat "$Q/window-gate.pid"); hidden display, no wait)"
  gd=$(for f in "$Q"/gate-deferred/*; do [ -s "$f" ] || continue; read -r gt ga _ < "$f"; echo "$(basename "$f") ${gt:0:9} since $(date -r "$ga" +%H:%M)"; done | paste -sd, - | sed 's/,/, /g')
  [ -z "$gd" ] || echo "GATE DEFERRED (no verdict: the gate machine ${POW_JOB_CONTEXT:-pow58} didn't answer): $gd - nothing failed, requests kept; gated again once it answers"
  [ -d "$Q/apk" ] && echo "APK ship out: $(cut -c1-9 "$Q/apk/tip" 2>/dev/null) (log $(cat "$Q/apk/log" 2>/dev/null))"
  echo "last ships:"; tail -6 "$Q/shipped.log" 2>/dev/null | sed 's/^/  /' ;;
run)
  [ -n "$REPO" ] || { echo "ship.sh run: not in a PowOS checkout"; exit 2; }
  # Nothing requested (launchd starts it at load): gone at once - unless a post-deploy gate waits for its machine.
  ls "$Q"/*.req >/dev/null 2>&1 || [ -s "$Q/gate-deferred/postgate" ] || exit 0
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
    [ -d "$Q/apk" ] && [ ! -f "$Q/apk/rc" ] && touch "$Q/apk/stopped"
    stop_ships $$; kill "$(cat "$Q/apk/pid" 2>/dev/null)" 2>/dev/null; rm -rf "$L"; exit 143' TERM
  SL=$HOME/.cache/powos-ship.lock VL=$HOME/.cache/powos-verify.lock
  # After every successful ship (shell or APK): a round of the manager's "use the phone like a user" journeys
  # (verify/e2e-queue.sh: e2e-desktop parts 1-3 + e2e-appapi), unless one is still queued. In the background: queueing
  # is a few quick user.sh calls, never a reason to hold the ship loop. SHIP_E2E=0 turns it off (tests).
  e2e_round() { [ "${SHIP_E2E:-1}" = 1 ] && [ -z "${SHIP_DIR:-}" ] && [ -x "$here/verify/e2e-queue.sh" ] || return 0
    ( "$here/verify/e2e-queue.sh" --if-idle >> "$Q/e2e.log" 2>&1 || echo "$(date '+%F %T') e2e: round NOT queued (queue.sh refused) - $Q/e2e.log" >> "$Q/shipped.log" & ) ; echo "$(date +%T) e2e: a round of user journeys asked for ($Q/e2e.log)"; }
  # nonroot_kick: the non-root phones (tools/phone/devices.conf) brought to what's live here - the last installed APK and
  # the live shell (tools/phone/nonroot-sync.sh, in the background, from a private copy: this checkout is reset under
  # it). At most once a minute unless the live tip moved (--now: the runner's idle exit, a last pass); never in a test queue (SHIP_DIR) unless SHIP_NONROOT=1.
  # (2026-11-09: the razr fold kept its last manual APK's UI - "the launcher seems way outdated".)
  nonroot_kick() { { [ -z "${SHIP_DIR:-}" ] || [ "${SHIP_NONROOT:-}" = 1 ]; } && [ -s "$SR/tools/phone/devices.conf" ] && [ -f "$SR/tools/phone/nonroot-sync.sh" ] || return 0
    local d; d=$(mktemp -d "${TMPDIR:-/tmp}/powos-nonroot-kick.XXXXXX") || return 0
    cp "$SR/tools/phone/nonroot-sync.sh" "$SR/tools/phone/devices.conf" "$d/" || { rm -rf "$d"; return 0; }
    ( NONROOT_REPO=$SR NONROOT_CONF=$d/devices.conf bash "$d/nonroot-sync.sh" ${1:---if-due} >/dev/null 2>&1; rm -rf "$d" ) & }
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
  # it also pushes, lib/apps/bin/powos, are the "apps" kind above, f105 part 2 - this is part 1; the spacetimedb/
  # xwayland/kwin packages are BUILT by the "pkgs" step (pkgs_due, 11-10) and installed by this deploy). `deploy`, never `install` (which also re-pushes the rootfs tarball - a human step).
  # lib/apps/powos-terms + powos-transcribe: powos-deploy.sh installs them (e4bc7be0); a change to them alone must deploy
  # (11-01: the terminals view-only rewrite ec367873 changed only powos-terms and would never have reached the phone).
  # targets/android/pkgs (all of it, 11-10): the deploy installs our packages (kwin, xwayland-kgsl, spacetimedb ...)
  # from out/pkgs, which the "pkgs" step below builds first - a PKGBUILD change alone must deploy too.
  rooted_inputs() { git diff --name-only "$1" "$2" -- targets/android/rooted targets/android/session \
    targets/android/pkgs bin/powos-panel-phone desktop/autostart/powos-panel-phone.desktop \
    lib/powos-tmux-shell lib/self-phone.sh config/etc/profile.d/60-powos-picker-key.sh lib/ai/agents lib/ai/comms/comms-mcp.py \
    tools/app-api lib/ai/manager lib/ai/sandbox desktop/plasmoid units/phone units/phone-android lib/apps/powos-units lib/apps/powos-terms lib/apps/powos-transcribe \
    targets/android/steam/unity-screen \
    2>/dev/null | grep -v -e '^lib/ai/sandbox/node_modules/' -e '^targets/android/pkgs/[^/]*/test/'; }
  # units_gate: nothing ships to the phone that installs a file no unit claims (DU1: every ship registers what it
  # installs). test-units-registry.py reads every deploy script against units/; a FAIL refuses the rooted deploy.
  # test-powos-dispatch.py: every `powos <subcommand>`'s file is installed by the deploy (powos terms wasn't, 11-01).
  units_gate() { { python3 test/tier1/test-units-registry.py && python3 test/tier1/test-powos-dispatch.py; } > "$1" 2>&1 && return 0
    grep -E '^ *FAIL' "$1" | head -3 | cut -c1-200; return 1; }
  # units_publish: the phone's units to the PowOS AI page after a ship to it (in the background, one adb call; the
  # rooted deploy publishes itself). tools/units/publish.sh; a failure is in its log, the page then shows "stale".
  units_publish() { ( tools/units/publish.sh phone > /dev/null 2>&1 & ) ; }
  # pull_publish WHAT LOG: what just went live on the rooted phone, published for the phones no adb reaches (the S25,
  # the razr: docs/PHONE-UPDATES.md) - the shell bundle (shell) or powos-core, PowOS's own code (rooted). Both skip
  # what the store has already and never fail the ship (the phone's ship stands).
  pull_publish() {
    case "$1" in
      shell) targets/android/publish-shell.sh >> "$2" 2>&1 || echo "$(date +%T) pull update: publish-shell failed (log $2)" ;;
      rooted) targets/android/build-powos-core.sh --publish >> "$2" 2>&1 || echo "$(date +%T) pull update: powos-core failed (log $2)" ;;
    esac
  }
  # phone_offline: the phone is off the VPN (adb.sh --vpn-state rc 69: its WireGuard handshake is stale). That is NOT a
  # fault of the tip: a step that needs the phone (shell push, module first, APK, rooted deploy) keeps its request
  # pending and runs again once the phone is back, never "held until a new origin commit" (11-06: two APK fixes and a
  # rooted deploy sat 2 h after the phone came back, 14:39 / 15:02 "module first ((unreadable)) failed rc 11" and
  # "rooted deploy FAILED rc 69 ... handshake is 1913s old"). Once offline it is re-checked only every
  # SHIP_OFFLINE_POLL_S (60) s ($Q/phone-offline: the epoch of the last check); back online is logged once.
  # SHIP_PHONE_STATE replaces the check (tests). Unknown (no wireguard container) = online, as adb.sh treats it.
  phone_offline() { local at now src=0
    now=$(date +%s)
    if { read -r at < "$Q/phone-offline"; } 2>/dev/null && [ -n "$at" ] && [ $(( now - at )) -lt "${SHIP_OFFLINE_POLL_S:-60}" ]; then return 0; fi
    ${SHIP_PHONE_STATE:-tools/phone/adb.sh --vpn-state} >/dev/null 2>&1 || src=$?
    if [ $src = 69 ]; then
      [ -e "$Q/phone-offline" ] || echo "$(date +%T) the phone is offline (no WireGuard link) - what needs it waits, checked every ${SHIP_OFFLINE_POLL_S:-60} s"
      echo "$now" > "$Q/phone-offline"; return 0; fi
    [ -e "$Q/phone-offline" ] && { rm -f "$Q/phone-offline" "$Q/offline-wait"; echo "$(date +%T) the phone is back online - what waited for it runs now"; }
    return 1; }
  # link_down FILE: FILE (a step's stderr/log) says adb.sh found the phone off the VPN ("phone offline", rc 69) - the
  # same as phone_offline, remembered so the next try waits SHIP_OFFLINE_POLL_S. Not "phone unavailable after
  # reconnect" (VPN up, adb flaked): that stays a link fault with its capped retries (apk_link_fault).
  link_down() { grep -q 'adb\.sh: phone offline' "$1" 2>/dev/null || return 1
    [ -e "$Q/phone-offline" ] || echo "$(date +%T) the phone is offline (adb.sh) - what needs it waits, checked every ${SHIP_OFFLINE_POLL_S:-60} s"
    date +%s > "$Q/phone-offline"; }
  # offline_wait WHAT: logged once per tip and step - the step's requests stay pending, nothing is marked failed.
  offline_wait() { ! grep -qxF "$T $1" "$Q/offline-wait" 2>/dev/null || return 0; echo "$T $1" >> "$Q/offline-wait"
    echo "$(date +%T) ${T:0:9}: $1 waits for the phone (offline) - kept pending, it goes once the phone is back"; }
  # NO GATE VERDICT (11-10): shell/dev/gate.sh exits 75 (only) when its job machine (POW_JOB_CONTEXT, default pow58 = .58)
  # didn't answer within GATE_JOB_WAIT_S - the hub can't pass the full gate, so there is no verdict (its exit 2, a
  # usage/environment error, stays a refusal: never deferred here); push.sh,
  # apps/install.sh and ship-apk.sh pass it on as exit 75 (GATE_NV). Not the commit's fault: no failed mark, no mail, no
  # REFUSED/FAILED wording, and nothing goes out ungated - the step's requests stay queued. $Q/gate-deferred/<step>
  # ("TIP EPOCH [files]") holds that step (ship.sh status says so) until the machine answers again (gate_up: probed at
  # most every SHIP_GATE_PROBE_S, 60 s) or SHIP_GATE_RETRY_S (1800) s passed; then it gates again.
  GATE_NV=75 gate_probe_at=0 gate_probe_rc=1
  gate_deferred() {   # STEP TIP [FILES...]
    local st=$1 tp=$2; shift 2; mkdir -p "$Q/gate-deferred"
    [ "$(cut -d' ' -f1 "$Q/gate-deferred/$st" 2>/dev/null)" = "$tp" ] ||
      echo "$(date +%T) ${tp:0:9}: $st DEFERRED - no gate verdict (the gate machine ${POW_JOB_CONTEXT:-pow58} didn't answer): nothing failed, requests kept - gated again once it answers"
    echo "$tp $(date +%s) $*" > "$Q/gate-deferred/$st"; }
  gate_probe() { [ "${POW_JOB_CONTEXT:-pow58}" = hub ] && return 0
    perl -e 'alarm 5; exec @ARGV' docker --context "${POW_JOB_CONTEXT:-pow58}" version --format '{{.Server.Version}}' >/dev/null 2>&1; }
  gate_up() { local now; now=$(date +%s)
    [ $((now - gate_probe_at)) -lt "${SHIP_GATE_PROBE_S:-60}" ] && return $gate_probe_rc
    gate_probe_at=$now; ${SHIP_GATE_PROBE:-gate_probe}; gate_probe_rc=$?; return $gate_probe_rc; }
  gate_clear() { rm -f "$Q/gate-deferred/$1"; }
  gate_ready() {   # STEP: 0 = it may gate now (nothing deferred, or the machine is back / the retry is due)
    local f=$Q/gate-deferred/$1 tp at; [ -s "$f" ] || return 0
    read -r tp at _ < "$f"
    if gate_up; then echo "$(date +%T) ${tp:0:9}: the gate machine answers again - $1 gates now"
    elif [ $(( $(date +%s) - at )) -ge "${SHIP_GATE_RETRY_S:-1800}" ]; then echo "$(date +%T) ${tp:0:9}: $1 deferred ${SHIP_GATE_RETRY_S:-1800}+ s - gating again"
    else return 1; fi
    rm -f "$f"; }
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
  # rooted_after_apk: HEAD has APK inputs the installed build lacks (and its APK didn't fail): the rooted deploy waits
  # for that install (11-01: a pass that saw the tip before its request - a runner on its way out fetched it, rooted_due
  # alone kept it in the loop - had no APK to launch, so it could run the rooted deploy FIRST). rooted_go = due and not
  # waiting: what keeps the runner up and what lets step 4 run. An APK nobody requested
  # doesn't keep the runner up: the request that brings it restarts the runner, which then runs both in order.
  rooted_after_apk() { local h i; h=$(git rev-parse HEAD 2>/dev/null) || return 1
    i=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true); [ -n "$i" ] || return 1
    git merge-base --is-ancestor "$h" "$i" 2>/dev/null && return 1
    [ -n "$(apk_inputs "$i" "$h")" ] && [ "$(cat "$Q/failed-apk" 2>/dev/null)" != "$h" ]; }
  rooted_go() { rooted_due && ! rooted_after_apk && ! pkgs_pending; }
  # bg_go: work the runner stays up for without a request - a rooted deploy due, or a packages build due / out.
  # A post-deploy gate deferred for no verdict (post_gate_retry) keeps the runner up too, until it gates again.
  bg_go() { rooted_go || pkgs_out || pkgs_due || [ -s "$Q/gate-deferred/postgate" ]; }
  # THE PACKAGES (11-10): kwin 3.76's PKGBUILD (patches 0067/0068) landed and shipped as "code", but no step ever built
  # or published a package - only an agent's hand-run build-pkgs.sh did, so the phone stayed on 3.74 and the game-audio
  # check failed on the missing KWin half. pkg_names A B: targets/android/pkgs/<name>/ dirs with a PKGBUILD at B whose
  # files (not their test/) changed between A and B.
  pkg_names() { git diff --name-only "$1" "$2" -- targets/android/pkgs 2>/dev/null | grep -v '^targets/android/pkgs/[^/]*/test/' |
    sed -n 's#^targets/android/pkgs/\([^/]*\)/.*#\1#p' | sort -u |
    while read -r n; do git cat-file -e "$2:targets/android/pkgs/$n/PKGBUILD" 2>/dev/null && echo "$n"; done; }
  # pkgs_due: packages changed since the last tip the pkgs step built ($Q/pkgs-live; none yet: the rooted deploy's or
  # the installed APK's base, recorded at once) up to HEAD, and the build didn't fail on HEAD. Sets pbase/pchg.
  pkgs_due() { local h; h=$(git rev-parse HEAD 2>/dev/null) || return 1
    pbase=$(cat "$Q/pkgs-live" 2>/dev/null || true)
    [ -n "$pbase" ] || { pbase=$(cat "$Q/rooted-live" 2>/dev/null || cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
      [ -z "$pbase" ] || echo "$pbase" > "$Q/pkgs-live"; }
    pchg=; [ -n "$pbase" ] && git cat-file -e "$pbase^{commit}" 2>/dev/null && pchg=$(pkg_names "$pbase" "$h" | paste -sd' ' -)
    [ -n "$pchg" ] && [ "$(cat "$Q/failed-pkgs" 2>/dev/null)" != "$h" ]; }
  # The build runs BESIDE the loop (a KWin build is 20+ min; shell ships must not queue behind it), in its own checkout
  # ($PK, as the APK's $SA); build-pkgs.sh queues on the Mac's one heavy build slot. State in $Q/pkgs/: tip, names, pid, log, rc.
  PK=${POWOS_PKGS_RUN:-$POWOS_RUN_ROOT/ship-runner-pkgs}
  pkgs_alive() { [ -d "$Q/pkgs" ] && [ ! -f "$Q/pkgs/rc" ] || return 1
    kill -0 "$(cat "$Q/pkgs/pid" 2>/dev/null)" 2>/dev/null && return 0
    # Gone without an rc: died with its runner (rc 4, it goes again). noclobber: a build that wrote its rc and exited
    # between the two checks above keeps its own rc (a finished build was reaped as "stopped" and built twice).
    (set -C; echo 4 > "$Q/pkgs/rc") 2>/dev/null; return 1; }
  pkgs_out() { pkgs_alive || [ -f "$Q/pkgs/rc" ]; }
  # pkgs_pending: a build out, or one due - the rooted deploy waits for it (it installs from out/pkgs).
  pkgs_pending() { pkgs_out || pkgs_due; }
  # pkgs_build NAME...: in $PK - build-pkgs.sh (takes the heavy build slot itself), publish-repo.sh ([powos] on android.pow: the non-root
  # phones' phone-update.sh), then the new builds into the ship checkout's out/pkgs, where the rooted deploy finds them.
  # SHIP_PKGS_BUILD replaces the build + publish (tests).
  pkgs_build() {
    if [ -n "${SHIP_PKGS_BUILD:-}" ]; then $SHIP_PKGS_BUILD "$@" || return
    # build-pkgs.sh takes the heavy build slot itself, per package: wrapping it in build-slot.sh too deadlocks (the outer
    # holder waits on its own inner request forever, 11-10).
    else targets/android/build-pkgs.sh "$@" && targets/android/publish-repo.sh || return; fi
    local n f; mkdir -p "$SR/targets/android/out/pkgs"
    for n in "$@"; do f=$(sh targets/android/tools/newest-pkgs.sh targets/android/out/pkgs "$n")
      [ -n "$f" ] && cp -p "$f" "$SR/targets/android/out/pkgs/" && echo "pkgs: ${f##*/} -> the ship checkout"; done; }
  pkgs_launch() {   # $1 tip, rest: names
    local a=$1; shift
    if [ ! -e "$PK/.git" ]; then
      git -C "$REPO" worktree add -q --detach "$PK" "$a" || return 1
      echo "the packages ship service (tools/phone/ship.sh)" > "$PK/.powos-runner-checkout"
    else git -C "$PK" reset -q --hard "$a" || return 1; fi
    rm -rf "$Q/pkgs"; mkdir -p "$Q/pkgs"; echo "$a" > "$Q/pkgs/tip"; echo "$*" > "$Q/pkgs/names"
    echo "$Q/done/$(date +%Y%m%d-%H%M%S)-${a:0:9}-pkgs.log" > "$Q/pkgs/log"
    ( cd "$PK" && pkgs_build "$@" > "$(cat "$Q/pkgs/log")" 2>&1; echo $? > "$Q/pkgs/rc" ) &
    echo $! > "$Q/pkgs/pid"; }
  # reap_pkgs: a build that ended - built + published (pkgs-live; the rooted deploy goes next), or failed (mailed, not
  # retried on that tip). rc 4: its runner died / was paused mid-build - it goes again.
  reap_pkgs() { local A arc plog pn
    [ -f "$Q/pkgs/rc" ] || return 0
    A=$(cat "$Q/pkgs/tip") arc=$(cat "$Q/pkgs/rc") plog=$(cat "$Q/pkgs/log") pn=$(cat "$Q/pkgs/names")
    if [ "$arc" = 0 ]; then
      echo "$A" > "$Q/pkgs-live"; rm -f "$Q/failed-pkgs"
      echo "$(date '+%F %T') ${A:0:9} pkgs ($pn) built + published" >> "$Q/shipped.log"
      echo "$(date +%T) ${A:0:9}: packages built + published ($pn)"
    elif [ "$arc" = 4 ] || [ -e "$Q/paused" ]; then echo "$(date +%T) ${A:0:9}: packages build stopped (rc $arc) - it goes again"
    else
      echo "$A" > "$Q/failed-pkgs"
      echo "$(date +%T) ${A:0:9}: packages build FAILED rc $arc (log $plog) - waiting for a new origin commit"
      mail "ship ${A:0:9} (pkgs:$pn) FAILED rc $arc: $(tail -1 "$plog" | cut -c1-200) - log $plog on the Mac; fix it on origin, then ship.sh request again"
    fi
    rm -rf "$Q/pkgs"; }
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
  # apk_out: an APK ship out, or ended and not reaped yet. 11-01 (CI "APK then rooted", ~1 in 4): an APK that ended
  # after this pass's reap_apk read !apk_alive in step 2, which relaunched it - apk_launch's rm -rf $Q/apk threw away
  # the unreaped rc, so the same tip installed twice (APK,APK,ROOTED). Steps 2-4 start nothing until the loop top reaps.
  apk_out() { apk_alive || [ -f "$Q/apk/rc" ]; }
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
      if [ $grc = 1 ] && ! grep '^FAIL' "$gl" | grep -qv 'not ready' ; then ( cd shell && GATE_PRIORITY=ship IDLE_MS=0 READY_MS=90000 ./push.sh --pre-gate "$@" ) > "$gl" 2>&1; grc=$?; fi
      # No verdict (the gate machine gone): not a FAIL - kept as deferred, gated again from the loop (post_gate_retry).
      # The runner may have left meanwhile (the gate waited GATE_JOB_WAIT_S): started again, it retries (bg_go).
      if [ $grc = $GATE_NV ]; then gate_deferred postgate "$t" "$@"
        runner_up || agent_kick || { nohup bash "$here/ship.sh" run >> "$Q/runner.log" 2>&1 & }
      elif [ $grc -ne 0 ]; then
        echo "$t" > "$Q/postgate-failed"
        mail "ship ${t:0:9} (shell) went live and its gate FAILED after: $(grep -E '^FAIL|REFUSED|pre-gate failed' "$gl" | head -2 | cut -c1-200 | paste -sd' ' -) - log $gl on the Mac; fix it on origin, then ship.sh request again"
      else rm -f "$Q/postgate-failed"; fi
      rm -f "$Q/postgate.pid" ) &
    echo $! > "$Q/postgate.pid"
  }
  # post_gate_retry: a post-deploy gate deferred for no verdict runs again once gate_ready says so, while that tip is
  # still the live shell (a newer shell ship ran its own post_gate: dropped), on this checkout (origin's tip).
  post_gate_retry() {
    local f=$Q/gate-deferred/postgate tp at files
    [ -s "$f" ] || return 0
    [ -s "$Q/postgate.pid" ] && kill -0 "$(cat "$Q/postgate.pid")" 2>/dev/null && return 0
    read -r tp at files < "$f"
    [ "$(cat "$Q/live" 2>/dev/null)" = "$tp" ] || { rm -f "$f"; return 0; }
    gate_ready postgate || return 0
    post_gate "$tp" "" $files
  }
  # window_gate BASE TIP WHAT: a ship whose BASE..TIP diff touches web-window files (WINDOW_FILES) is checked ON THE
  # DEVICE once it's live, synchronously: verify/window-render.sh --hidden starts the APK's own window host
  # (WebWindowsHost) on a display nobody sees, launches Calculator there, screencaps THAT display (app content, not a
  # flat fill) and taps it with `input -d` (the app redraws) - nothing on the user's screen, so it never waits for an
  # idle phone and has no skip: exit 0 PASS, 2 NOT JUDGED (phone asleep and the user active in the last 10 min - the check wakes an idle phone itself: requests kept, retried ~60 s, window_wait), anything else (FAIL, timeout, no phone) is a FAIL. Why (2026-10-31): web
  # windows shipped as empty frames twice in one night with every headless gate green, and the old idle-waiting check
  # never ran once (the user is always active; manager rule G-1). Returns 1 on a FAIL: WINDOWS BROKEN ($Q/window-failed,
  # status, shipped.log, a mail) and the caller keeps the ship's requests and marks it failed, so nothing later ships as
  # done while windows are broken: as long as $Q/window-failed is there EVERY ship runs the check, window files or not,
  # and only a PASS clears it. No rollback (fix forward). The log ($Q/done/window-render-<tip>.log) is always written.
  # SHIP_WINDOW_GATE=0 turns it off; off in tests (SHIP_DIR), as e2e_round. WINDOW_GATE_TIMEOUT_S (240) bounds it.
  # It runs with --hold RENDER_WATCH_S: once its log shows the content+tap PASS line, render_watch runs WHILE the hidden
  # display stays up (a live window across the watch; manager: "a watch with no window open is not a pass"), then the
  # gate waits for window-render's exit (its hold re-measures the display: going flat there is a FAIL too). RW_DONE=TIP
  # tells the caller's own render_watch call that this tip was watched already.
  WINDOW_FILES='(^|/)(webwindows[^/]*|WebWindows[^/]*\.kt|WebWindowLaunch\.kt|FreeformTasks\.kt|SystemFloat\.kt|home\.tsx|shell\.css)$'
  window_gate() {
    [ "${SHIP_WINDOW_GATE:-1}" = 1 ] && [ -z "${SHIP_DIR:-}" ] || return 0
    local b=$1 t=$2 what=$3 f= wb wl wrc gp wdg
    RW_DONE=
    # A shell window check superseded while NOT JUDGED (window_wait) left its base here: this check covers that base's
    # window changes too, so a newer tip shipping past an unjudged one never skips its device check.
    [ -s "$Q/window-unjudged" ] && b=$(cat "$Q/window-unjudged")
    if [ -n "$b" ] && git cat-file -e "$b^{commit}" 2>/dev/null; then
      f=$(git diff --name-only "$b" "$t" 2>/dev/null | grep -E "$WINDOW_FILES" | sed 's|.*/||' | sort -u | paste -sd' ' -)
    else f="(no base: every window file)"; fi
    [ -s "$Q/window-failed" ] && f="${f:+$f; }(windows broken since $(cut -c1-9 "$Q/window-failed"): every ship is checked)"
    [ -n "$f" ] || return 0
    wl=$Q/done/window-render-${t:0:9}.log
    echo "$(date '+%F %T') ${t:0:9} $what: window files changed ($f) - device window check (--hidden)" > "$wl"
    # A copy to run: this checkout is reset under a running script (bash reads it as it goes).
    wb=$Q/window-render/bin; mkdir -p "$wb"
    if [ -x "$here/verify/window-render.sh" ] && cp "$here/verify/window-render.sh" "$here/verify/window-render.py" "$wb/"; then
      echo "$(date +%T) ${t:0:9}: window files changed ($f) - device window check running ($wl)"
      WR_TOOLS=$here WR_OUT=$Q/window-render bash "$wb/window-render.sh" --hidden --hold "${RENDER_WATCH_S:-20}" >> "$wl" 2>&1 & gp=$!
      echo "$gp" > "$Q/window-gate.pid"
      gate_deadline "${WINDOW_GATE_TIMEOUT_S:-240}" "$gp"; wdg=$!
      while kill -0 "$gp" 2>/dev/null && ! grep -q '^window-render: PASS' "$wl"; do sleep 1; done
      if grep -q '^window-render: PASS' "$wl"; then render_watch "$t" "$what"; RW_DONE=$t; fi
      wait "$gp"; wrc=$?
      kill "$wdg" 2>/dev/null; rm -f "$Q/window-gate.pid"
      [ $wrc -ge 128 ] && echo "window-render: FAIL (killed after ${WINDOW_GATE_TIMEOUT_S:-240} s, rc $wrc)" >> "$wl"
    else wrc=1; echo "window-render: FAIL (verify/window-render.sh missing or not copied)" >> "$wl"; fi
    grep -q '^window-render: ' "$wl" || echo "window-render: FAIL (no verdict, rc $wrc)" >> "$wl"
    # rc 2 = NOT JUDGED (the phone isn't Awake: the hidden display goes dark with the screen; or the user acted -
    # touched it during the Linux step, opened/closed a window). Neither a pass nor a skip
    # that lets the ship through: the caller keeps its requests and retries every WINDOW_WAIT_S (60) s, no cap.
    if [ $wrc = 2 ]; then
      echo "$(date '+%F %T') ${t:0:9} $what window check waiting for an awake, idle phone ($(grep -m1 '^window-render: NOT JUDGED' "$wl" | cut -c17-80))" >> "$Q/shipped.log"
      echo "$(date +%T) ${t:0:9}: window check waiting for an awake phone - its requests are kept, retried in ${WINDOW_WAIT_S:-60} s (log $wl)"
      return 2
    fi
    rm -f "$Q/window-unjudged"   # judged (PASS or FAIL; a FAIL keeps window-failed, which checks every ship)
    if [ $wrc = 0 ]; then
      rm -f "$Q/window-failed"; echo "$(date '+%F %T') ${t:0:9} $what window-render PASS" >> "$Q/shipped.log"
      echo "$(date +%T) ${t:0:9}: device window check PASS"; return 0
    fi
    echo "$t $what $f" > "$Q/window-failed"
    echo "$(date '+%F %T') ${t:0:9} $what WINDOWS BROKEN - window-render FAILED rc $wrc: $(grep -m1 '^FAIL' "$wl" | cut -c1-200)" >> "$Q/shipped.log"
    echo "$(date +%T) ${t:0:9}: WINDOWS BROKEN on the device after this ship (window-render rc $wrc, log $wl) - its requests are kept, later ships stay checked"
    mail "ship ${t:0:9} ($what) FAILED the device window check - web windows are BROKEN on the phone (changed: $f): $(grep -m1 '^FAIL' "$wl" | cut -c1-220) - log $wl on the Mac (shots beside it); fix it on origin, then ship.sh request again"
    return 1
  }
  # render_watch TIP WHAT: after every shell or APK ship, a PASSIVE 20 s look at the phone's log (read-only, no taps,
  # never waits for an idle phone - unlike window_gate, which the always-active user starved: 10-31's three "windows
  # render empty" P0s all shipped unchecked). Live web windows (`PowosWebWindows: window N: live`, in the last 2 min,
  # by the app's current process) with a `RENDER STALL` (WebWindows' watchdog, RenderWatch.kt) or no applied geometry
  # (`w.f f...` line) since the ship = WINDOWS BROKEN, marked as window_gate marks a FAIL. No geometry while home isn't
  # on screen (an app full screen) is not judged. No live window = NOT JUDGED, never a pass (manager: "a watch with no
  # window open is not a pass"): logged + shipped.log, the ship not failed, nothing opened on the user's screen. The
  # window that covers it is window_gate's hidden display, held across this watch (window-render.sh --hold, its
  # `PowosWrHidden: hold display ...` lines): that display is the adb-started helper's, not in WebWindows.kt's list, so
  # it has no `live`/`w.f` lines and the app's watchdog doesn't count it - judged by WebWindows' watchdog only (no
  # `RENDER STALL` from the app's process). The user's minimised/PiP web windows aren't counted by it either
  # (RenderWatch.owesGeometry: 9b16c2ce7's false stall was a minimised Linux window probed during a slow page). SHIP_RENDER_WATCH=0 turns it off; off in tests (SHIP_DIR).
  # Synchronous (20 s): the service is a launchd job that exits when idle, and launchd kills what it leaves running -
  # a backgrounded check died mid-sleep (10-31 14:46, 38fdae87: only its first log line).
  render_watch() {
    [ "${SHIP_RENDER_WATCH:-1}" = 1 ] && [ -z "${SHIP_DIR:-}" ] && [ -x "$here/adb.sh" ] || return 0
    local t=$1 what=$2
    [ "${RW_DONE:-}" = "$t" ] && return 0
    ( rl=$Q/done/render-watch-${t:0:9}.log
      t0=$("$here/adb.sh" shell 'date +%s' 2>/dev/null | tr -d '\r')
      case $t0 in ''|*[!0-9]*) echo "$(date +%T) render-watch ${t:0:9} ($what): not run - the phone's clock unreadable (no phone?)" > "$rl"; exit 0 ;; esac
      echo "$(date +%T) render-watch ${t:0:9} ($what): 20 s passive log check from phone time $t0" > "$rl"
      sleep "${RENDER_WATCH_S:-20}"
      lc=$("$here/adb.sh" shell 'logcat -d -v epoch -s PowosWebWindows:* PowosWrHidden:*' 2>/dev/null | tr -d '\r')
      # The app's current process: the newest line's pid (an APK ship restarted it; the old one's windows are gone).
      pid=$(echo "$lc" | awk '/PowosWebWindows:/ {p=$2} END {print p}')
      v=$(echo "$lc" | awk -v t0="$t0" -v pid="$pid" '$1 >= t0 && /PowosWrHidden: hold display [0-9]+ live/ {hid++}
        $2 != pid {next}
        $1 >= t0 - 120 && /PowosWebWindows: window [0-9]+: live/ {live++}
        $1 >= t0 && /RENDER STALL/ {stall++; last=$0}
        $1 >= t0 && /PowosWebWindows: w\.f f/ {wf++}
        END {printf "%d %d %d %d %s", live, stall, wf, hid, last}')
      read -r live stall wf hid last <<< "$v"
      echo "live lines $live, RENDER STALL lines $stall, w.f lines $wf, hidden hold lines $hid (pid ${pid:-?})${last:+; last stall: $last}" >> "$rl"
      if [ "${live:-0}" = 0 ] && [ "${hid:-0}" = 0 ]; then
        echo "$(date +%T) render-watch: NO WINDOW - not judged" >> "$rl"
        echo "$(date '+%F %T') ${t:0:9} $what render-watch NOT JUDGED (no live window)" >> "$Q/shipped.log"; exit 0
      fi
      bad=""
      # Only the hidden hold display: no w.f to expect (never mirrored) - the watchdog's stall line alone judges.
      if [ "${live:-0}" = 0 ] && [ "${stall:-0}" -gt 0 ]; then bad="RENDER STALL during the hidden window's hold: ${last:0:200}"; fi
      if [ "${live:-0}" -gt 0 ] && [ "${stall:-0}" -gt 0 ]; then bad="RENDER STALL after the ship: ${last:0:200}"
      elif [ "${live:-0}" -gt 0 ] && [ "${wf:-0}" = 0 ]; then
        foc=$("$here/adb.sh" shell 'dumpsys window | grep -m1 mCurrentFocus' 2>/dev/null | tr -d '\r')
        home=$("$here/adb.sh" shell "cat /proc/${pid:-0}/cmdline" 2>/dev/null | tr -d '\r\0')
        if [ -n "$home" ] && echo "$foc" | grep -q "$home"; then bad="no w.f geometry applied in ${RENDER_WATCH_S:-20} s with live windows and home on screen ($foc)"
        else echo "not judged: no geometry, but home is not on screen ($foc)" >> "$rl"; fi
      fi
      if [ -z "$bad" ]; then echo "$(date +%T) render-watch: PASS" >> "$rl"; echo "$(date '+%F %T') ${t:0:9} $what render-watch PASS (live $live, w.f $wf, hidden hold $hid)" >> "$Q/shipped.log"; exit 0; fi
      echo "$(date +%T) render-watch: FAIL: $bad" >> "$rl"
      echo "$t $what render-watch" > "$Q/window-failed"
      if [ "$what" = apk ]; then echo "$t" > "$Q/failed-apk"; else echo "$t" > "$Q/failed"; fi
      echo "$(date '+%F %T') ${t:0:9} $what render-watch FAILED: $bad" >> "$Q/shipped.log"
      echo "$(date +%T) ${t:0:9}: WINDOWS BROKEN on the device after this ship (render-watch FAIL, log $rl)"
      mail "ship ${t:0:9} ($what) FAILED the passive window check - web windows are BROKEN on the phone: $bad - log $rl on the Mac; fix it on origin, then ship.sh request again" )
  }
  # done_req FILE RESULT: a request fully on the phone.
  done_req() { echo "result=$2" >> "$1"; mv "$1" "$Q/done/"; }
  # The known hacks to the Progress app (apps/powos-progress, its Hacks widget): the HACK registry of what just
  # shipped, pushed whole after each ship - no polling. In the background and never fatal: a ship doesn't wait on it.
  sync_hacks() { [ -x lib/apps/powos-progress-cli ] || return 0
    ( python3 lib/apps/powos-progress-cli hacks sync > "$Q/hacks-sync.log" 2>&1 || echo "hacks sync failed (rc $?)" >> "$Q/hacks-sync.log" ) & }
  # pending_apk SHA: APK inputs changed up to it and aren't installed yet - its request is done once the APK is in.
  # own_apk SHA: its own commit changed them. A shell-only commit's note goes out with the shell push (it's visible
  # then), even while someone else's Kotlin below it waits for the APK; `noted=1` keeps the APK from repeating it.
  # served_shell: the commit the phone's home page is actually served from (ShellHost.kt ShellSource ->
  # window.__powosShellCommit: the APK's own shell or the shipped layer, whichever is newer), full sha; empty when it
  # can't be read (no phone, an APK from before the stamps) - then the records are all there is. Why (2026-10-31
  # 15:50): the service believed its "live" record while the phone showed an older shell (the search bar "reverted").
  # Off in tests (SHIP_DIR) unless SHIP_SERVED_CMD stands in for the read.
  served_shell() { local o c
    if [ -n "${SHIP_SERVED_CMD:-}" ]; then o=$($SHIP_SERVED_CMD 2>/dev/null) || true
    else [ -z "${SHIP_DIR:-}" ] || return 0
      o=$(CDP_TIMEOUT_S=15 "$SR/tools/phone/cdp.sh" eval home 'window.__powosShellCommit || ""' 2>/dev/null) || true; fi
    c=$(echo "$o" | grep -oE '[0-9a-f]{40}' | head -1)
    [ -n "$c" ] && git cat-file -e "$c^{commit}" 2>/dev/null && echo "$c"; }
  # shell_check WHAT TIP: after an install, the shell the phone renders must contain the latest shipped shell (the
  # "live" record before the install, $1 here: LIVE). Older = SHELL BEHIND, marked as window_gate marks a FAIL (the
  # APK failed, shipped.log, a mail) and the newer shell re-applied at once by a silent request. Returns 1 on a FAIL.
  shell_check() { local want=$1 a=$2 s r
    [ -n "$want" ] || return 0
    s=$(served_shell); [ -n "$s" ] || { echo "$(date +%T) ${a:0:9}: the phone's served shell commit couldn't be read - not judged"; return 0; }
    git merge-base --is-ancestor "$want" "$s" 2>/dev/null && { echo "$(date '+%F %T') ${a:0:9} apk shell-check PASS (serves ${s:0:9}, live ${want:0:9})" >> "$Q/shipped.log"; return 0; }
    echo "$(date '+%F %T') ${a:0:9} apk SHELL BEHIND - the phone serves ${s:0:9}, older than the shipped ${want:0:9}" >> "$Q/shipped.log"
    echo "$(date +%T) ${a:0:9}: SHELL BEHIND after the install (serves ${s:0:9}, shipped ${want:0:9}) - re-applying the newer shell"
    echo "$s" > "$Q/live"
    r=$Q/$(date +%Y%m%d-%H%M%S)-reapply-shell-$$.req
    printf 'sha=%q\nnote=\nsilent=1\nwho=ship-apk-reapply\nat=%s\n' "$want" "$(date +%s)" > "$r.tmp" && mv "$r.tmp" "$r"
    mail "ship ${a:0:9} (apk) FAILED the shell check: the phone renders shell ${s:0:9}, older than the shipped ${want:0:9} - re-applying it now; log $Q/runner.log on the Mac"
    return 1; }
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
    # No --publishing: modules_first (below) published every module these bindings need already - they must match now.
    ${SHIP_BINDINGS_CHECK:-tools/phone/bindings-check.sh} --no-publish --vendor shell/vendor; }
  # MODULE FIRST (11-01 c615e0f6, f391; 10-30 try_line): a shell - pushed, or carried by an APK install - whose vendored
  # bindings (shell/vendor/<db>.js) need columns/reducers the phone's module doesn't have can't subscribe ("bindings
  # stale"). So the module goes out BEFORE the bindings, in the same pass, and the shell/APK waits for that publish:
  #   (1) history: a vendored app whose module changed (vmods) and whose bindings differ between the phone's shell
  #       (phone_shell) and the tip;
  #   (2) the device, trusting no record: bindings-check.sh --needs, the tip's bindings against the phone's LIVE module
  #       schemas (tables, columns, reducers) - anything the phone lacks names its app.
  # Either one = the apps step for that app runs now (build + install), then the device is checked again. A failure
  # holds the shell (and the APK), logged and mailed like any failed ship. $Q/apps-first "TIP APP": published first for
  # that tip (the apps step below doesn't publish it again).
  phone_shell() { local l; l=$(cat "$Q/live" 2>/dev/null || true)
    { [ -n "$l" ] && { [ -z "$inst" ] || git merge-base --is-ancestor "$inst" "$l" 2>/dev/null; }; } || l=$inst; echo "$l"; }
  device_needs() {   # the vendored apps whose live module on the phone lacks what this tip's bindings need; rc 1 = can't vouch
    local o; o=$(${SHIP_BINDINGS_CHECK:-tools/phone/bindings-check.sh} --needs --vendor shell/vendor 2>&1) || { echo "$o" | sed 's/^/  /' >&2; return 1; }
    echo "$o" | sed -n 's/^needs \([a-z0-9-]*\) .*/\1/p'; }
  modules_needed() { local va vd ps h dv
    ps=$(phone_shell)
    h=$(while read -r va vd; do [ -n "$va" ] || continue
      { [ -n "$ps" ] && git diff --quiet "$ps" "$T" -- "shell/vendor/$vd.js" 2>/dev/null; } || echo "$va"; done <<< "$vmods")
    dv=$(device_needs) || return 1
    printf '%s\n' $h $dv | sed '/^$/d' | sort -u; }
  first_done() { grep -qx "$T $1" "$Q/apps-first" 2>/dev/null; }
  # modules_first WHAT ("shell"/"APK") [lock]: 0 = nothing needed or all published; 1 = held (logged + mailed); 2 = the
  # phone is busy or offline (phone_offline), try again (lock: take the ship lock for the publish - the shell step holds the phone already).
  modules_first() {
    local need a mlog mrc=0 left mn lk= mm
    if phone_offline; then offline_wait "$1"; return 2; fi
    if ! need=$(modules_needed 2>"$Q/modules-first.err"); then
      # The schemas couldn't be read because the phone dropped off (not a bindings fault): try again, never held.
      if link_down "$Q/modules-first.err" || phone_offline; then offline_wait "$1"; return 2; fi
      mrc=11; need="(unreadable)"
    else need=$(for a in $need; do first_done "$a" || echo "$a"; done | paste -sd' ' -); [ -n "$need" ] || return 0; fi
    # A module publish deferred for no gate verdict (apps/install.sh exit 75): held, never published ungated.
    [ $mrc != 0 ] || gate_ready modules || return 2
    if [ $mrc = 0 ] && [ "${2:-}" = lock ]; then
      if verify_held; then echo $$ > "$Q/wants-phone"; return 2; fi
      ship_lock || return 2; lk=1; echo $$ > "$Q/installing"
    fi
    mlog=$Q/done/$(date +%Y%m%d-%H%M%S)-${T:0:9}-modules-first.log; mkdir -p "$Q/done"; cat "$Q/modules-first.err" > "$mlog" 2>/dev/null
    if [ $mrc = 0 ]; then
      echo "$(date +%T) ${T:0:9}: module first - publishing $need before the $1 carries its bindings (log $mlog)"
      mn=$(joined ${snotes[@]+"${snotes[@]}"} ${anotes[@]+"${anotes[@]}"}); mn=${mn:-"app update"}
      vendor_ok $need >> "$mlog" 2>&1 || { mrc=9; echo "modules-first: REFUSED - committed bindings aren't what the module builds" >> "$mlog"; }
      [ $mrc = 0 ] && for a in $need; do
        ( PATH="$here/bin:$PATH" apps/build.sh "$a" && PATH="$here/bin:$PATH" POWOS_SHIP_SERVICE=1 apps/install.sh "$a" install --note "$mn" --no-build ) >> "$mlog" 2>&1 || { mrc=$?; [ $mrc != 0 ] || mrc=1; break; }
        echo "$T $a" >> "$Q/apps-first"
      done
      # The device again: nothing these bindings need may be missing now.
      if [ $mrc = 0 ]; then
        if ! left=$(device_needs 2>>"$mlog"); then mrc=11; link_down "$mlog" && mrc=12
        else left=$(echo "$left" | paste -sd' ' -); [ -z "$left" ] || { mrc=10; echo "modules-first: the phone still lacks what the bindings need for $left" >> "$mlog"; }; fi
      fi
    fi
    [ -z "$lk" ] || { rm -rf "$SL"; rm -f "$Q/installing"; [ "$(cat "$Q/wants-phone" 2>/dev/null)" = $$ ] && rm -f "$Q/wants-phone"; }
    if [ $mrc = 0 ]; then echo "$(date '+%F %T') ${T:0:9} apps-first ($need) for $who_s: before the $1" >> "$Q/shipped.log"; return 0; fi
    if [ $mrc = $GATE_NV ]; then gate_deferred modules "$T"; return 2; fi
    # Published, then the phone dropped off before the re-check: what went out is recorded (apps-first), the rest waits.
    if [ $mrc = 12 ]; then offline_wait "$1"; return 2; fi
    # The phone WAS read and the bindings wouldn't decode its modules in a way no publish fixes (another shape, or bindings
    # ahead of a module this commit doesn't build): not "can't be checked" - the tip is REFUSED, as schema_gate refuses it.
    mm=$( [ $mrc = 11 ] && grep -E '^ *bindings:.*(fix|isn)' "$Q/modules-first.err" 2>/dev/null | sed 's/^ *//' | head -2 | cut -c1-240 | paste -sd' ' - || true)
    if [ -n "$mm" ]; then
      echo "$T" > "$Q/failed-apps"; sed 's/^/  /' "$Q/modules-first.err"
      echo "$(date +%T) ${T:0:9}: $1 ship REFUSED - the bindings and the modules wouldn't match (above; log $mlog)"
      [ "$(cat "$Q/modules-first-mailed" 2>/dev/null)" = "$T" ] || { echo "$T" > "$Q/modules-first-mailed"
        mail "ship ${T:0:9} ($1) REFUSED for $who_s: $mm - log $mlog on the Mac; fix it on origin, then ship.sh request again"; }
      return 1
    fi
    [ $mrc = 11 ] && echo "modules-first: the phone's module schemas can't be checked against these bindings (above)" >> "$mlog"
    echo "$T" > "$Q/failed-apps"
    echo "$(date +%T) ${T:0:9}: $1 HELD - module first ($need) failed rc $mrc (log $mlog) - waiting for a new origin commit"
    [ "$(cat "$Q/modules-first-mailed" 2>/dev/null)" = "$T" ] || { echo "$T" > "$Q/modules-first-mailed"
      mail "ship ${T:0:9} ($1) HELD for $who_s: its bindings need a module publish first ($need), which failed rc $mrc: $(tail -1 "$mlog" | cut -c1-200) - log $mlog on the Mac; fix it on origin, then ship.sh request again"; }
    return 1; }
  # reap_apk_installed A: reap_apk's installed case (rc 0, or the phone reports A installed): the live record,
  # the window/shell checks, then its requests done. rc 2 = the window check was NOT JUDGED ($Q/apk stays).
  reap_apk_installed() {
    local A=$1 live st wg r n sha ht
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
    # The device window check BEFORE its requests are done (the build it replaced: ship-apk's snapshot of the
    # previous install, ship-guard.sh snapshot DIR/commit): WINDOWS BROKEN keeps them and marks the APK failed.
    wg=0; window_gate "$(cat "$HOME/.cache/powos-ship-snapshot/commit" 2>/dev/null)" "$st" apk || wg=$?
    # NOT JUDGED (phone asleep): nothing recorded, its requests kept; the next reap tries again in ~60 s.
    if [ $wg = 2 ]; then date +%s > "$Q/apk/window-wait"; return 2; fi
    rm -f "$Q/apk/window-wait"
    # What the phone RENDERS, not the record: older than the shipped shell = the APK failed, the shell re-applied.
    [ -n "$live" ] && ! shell_check "$live" "$A" && wg=1
    if [ $wg = 0 ]; then rm -f "$Q/failed-apk"
    else echo "$A" > "$Q/failed-apk"; echo "$(date +%T) ${A:0:9}: APK installed but WINDOWS BROKEN - its requests kept, waiting for a new origin commit"; fi
    # A shell held for this APK came with its install (ship-apk pushes origin's tip shell after it).
    { read -r ht _ < "$Q/shell-held" && git merge-base --is-ancestor "$ht" "$A"; } 2>/dev/null && rm -f "$Q/shell-held"
    # The records above first, THEN its requests done: a watcher seeing them done sees the records too.
    n=0; [ $wg = 0 ] && for r in "$Q"/*.req; do [ -f "$r" ] || continue; sha=; . "$r"
      git merge-base --is-ancestor "$sha" "$A" 2>/dev/null && { done_req "$r" "shipped:${A:0:9}:apk"; n=$((n+1)); }; done
    echo "$(date '+%F %T') ${A:0:9} apk $n req: $(grep -h '^note=' "$Q/apk/notes" 2>/dev/null | head -1 | cut -c6- || true)" >> "$Q/shipped.log"
    units_publish
    echo "$(date +%T) ${A:0:9}: APK installed ($n request(s) done)"
    render_watch "$st" apk
    e2e_round
    return 0   # its rc is 2 only for NOT JUDGED above, never a trailing command's
  }
  # reap_apk: an APK ship that ended (rc exists) is recorded + its requests done. Called every loop turn, at the
  # runner start (a previous runner's finished APK) and before it exits (f252: the runner left while the APK was
  # out, so a finished install was never recorded and phone checks kept waiting for their ship).
  reap_apk() {
    local inst A arc alog
    inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
    # An APK ship that ended: its requests are done (installed is installed - its exit is its last check's: a logcat
    # grep with no match was 1, 2026-10-23), or it's tried again (the user stayed active), or it failed.
    if [ -f "$Q/apk/rc" ]; then
      # A window check NOT JUDGED (phone asleep) is retried here, ~60 s after the last try; $Q/apk stays till judged.
      [ -f "$Q/apk/window-wait" ] && [ $(( $(date +%s) - $(cat "$Q/apk/window-wait") )) -lt "${WINDOW_WAIT_S:-60}" ] && return 0
      A=$(cat "$Q/apk/tip") arc=$(cat "$Q/apk/rc") alog=$(cat "$Q/apk/log")
      if [ "$arc" = 0 ] || [ "$inst" = "$A" ]; then
        gate_clear apk
        reap_apk_installed "$A" || [ $? != 2 ] || return 0
      elif [ "$arc" = 8 ]; then echo "$(date +%T) ${A:0:9}: a newer APK is wanted - the pending one is replaced"
      elif [ "$arc" = 4 ]; then echo "$(date +%T) ${A:0:9}: the user stayed active - the APK goes again"
      # No gate verdict (ship-apk exit 75: the gate machine didn't answer): nothing installed, nothing failed - its
      # requests stay and the APK step goes again once gate_ready says so.
      elif [ "$arc" = "$GATE_NV" ]; then gate_deferred apk "$A"
      elif [ -e "$Q/paused" ]; then echo "$(date +%T) ${A:0:9}: APK ship stopped by pause (rc $arc) - its requests are kept"
      # Stopped WITH its runner (the TERM trap marked it before killing ship-apk, whose subshell still writes 143): not
      # a failure of this tip - it goes again, as one whose runner died without an rc does (apk_alive's rc 4).
      elif [ -e "$Q/apk/stopped" ]; then echo "$(date +%T) ${A:0:9}: APK ship stopped with the runner (rc $arc) - it goes again"
      # The PHONE LINK dropped, not this tip (11-01 measure: 12 of 36 APK FAILs were "couldn't snapshot" / "phone
      # unavailable" / "error: closed" / an empty adb install failure; each held every request until an unrelated push,
      # 293 min in 2 days). Nothing new is on the phone (ship-apk restored the overrides), so the same tip goes again, up
      # to SHIP_APK_LINK_RETRIES (default 2) times; a code fault (build, shell doesn't load, guard) still fails at once.
      # The phone went OFFLINE (no VPN link): not this tip either, and no retry is spent - the APK step waits for the
      # phone (phone_offline) and launches it again once it's back.
      elif link_down "$alog" || phone_offline; then echo "$(date +%T) ${A:0:9}: APK ship rc $arc while the phone is offline (log $alog) - it goes again once it's back"
      elif apk_link_fault "$alog" && lr=$(apk_link_retry "$A") && [ "$lr" -le "${SHIP_APK_LINK_RETRIES:-2}" ]; then
        echo "$(date +%T) ${A:0:9}: APK ship rc $arc: the phone link dropped (log $alog) - it goes again ($lr/${SHIP_APK_LINK_RETRIES:-2})"
      else
        echo "$A" > "$Q/failed-apk"
        echo "$(date +%T) ${A:0:9}: APK ship FAILED rc $arc (log $alog) - waiting for a new origin commit"
        mail "ship ${A:0:9} (apk) FAILED rc $arc: $(grep -E 'REFUSED|refused|FAIL|error' "$alog" | tail -1 | cut -c1-200) - log $alog on the Mac; fix it on origin, then ship.sh request again"
      fi
      rm -rf "$Q/apk"; inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
    fi
  }
  # apk_link_fault LOG: the APK ship failed on the adb link to the phone (before or at the install), not on the tip.
  apk_link_fault() {
    [ -f "$1" ] || return 1
    grep -q 'REFUSED - this commit\|build-app.sh failed\|INSTALL_FAILED' "$1" && return 1
    grep -q "phone unavailable after reconnect\|^error: closed\|couldn't snapshot the phone\|couldn't reset the phone's shell overrides\|failed to install /powos.apk: *\$" "$1"
  }
  # apk_link_retry TIP: prints how many link retries TIP has had, this one counted ($Q/apk-link-retry: "tip n").
  apk_link_retry() {
    local t="" n=0; [ -s "$Q/apk-link-retry" ] && read -r t n < "$Q/apk-link-retry"; case $n in ''|*[!0-9]*) n=0 ;; esac
    [ "$t" = "$1" ] || n=0; n=$((n+1)); echo "$1 $n" > "$Q/apk-link-retry"; echo "$n"
  }
  # shell_done: a live shell ship of T whose window check passed (or wasn't needed): its records, then its requests done.
  shell_done() {
    render_watch "$T" shell
    echo "$(date '+%F %T') ${T:0:9} shell ${#sreqs[@]} req ($who_s): ${sn:-(silent)}" >> "$Q/shipped.log"
    units_publish
    for r in ${nreqs[@]+"${nreqs[@]}"}; do [ -f "$r" ] && echo "noted=1" >> "$r"; done
    for r in ${sreqs[@]+"${sreqs[@]}"}; do done_req "$r" "shipped:${T:0:9}:shell"; done
    echo "$(date +%T) ${T:0:9}: shipped (shell)"
    sync_hacks
    e2e_round
  }
  # window_wait: a window check NOT JUDGED (the phone asleep) blocks the loop - nothing else ships, no request is done -
  # until it's judged: retried every WINDOW_WAIT_S (60) s, each try logged (window_gate), no cap. Returns 0 while it
  # still waits (the caller sleeps and loops), 1 once judged (PASS: the ship's requests done; FAIL: as a FAIL).
  window_wait() {
    local ww_at ww_base ww_tip wgr
    [ -s "$Q/window-wait" ] || { [ -f "$Q/apk/window-wait" ] && return 0; return 1; }
    . "$Q/window-wait"
    # Superseded (ask-latency 11-01: one dozing-phone wait blocked every later ship for 94 min, 5 requests stuck): the
    # phone is asleep (nobody looking) and origin has a newer tip that changes the shell again and needs no APK - the
    # loop ships that tip now. Its own window check covers this tip's base too ($Q/window-unjudged, window_gate), and
    # this tip's requests are ancestors of the new one, so none is done before a check of its window changes passes.
    local nt; nt=$(git rev-parse HEAD)
    if [ "$nt" != "$ww_tip" ] && git merge-base --is-ancestor "$ww_tip" "$nt" 2>/dev/null &&
       ! pending_apk "$nt" && [ -n "$(delta "$ww_tip" "$nt")" ]; then
      [ -s "$Q/window-unjudged" ] || echo "$ww_base" > "$Q/window-unjudged"
      rm -f "$Q/window-wait"
      echo "$(date +%T) ${ww_tip:0:9}: window check still waiting for an awake phone - superseded by ${nt:0:9} (its check covers both)"
      return 1
    fi
    [ $(( $(date +%s) - ww_at )) -ge "${WINDOW_WAIT_S:-60}" ] || return 0
    T=$ww_tip; window_gate "$ww_base" "$T" shell; wgr=$?
    if [ $wgr = 2 ]; then sed -i '' "s/^ww_at=.*/ww_at=$(date +%s)/" "$Q/window-wait"; return 0; fi
    rm -f "$Q/window-wait"
    if [ $wgr = 0 ]; then shell_done
    else echo "$T" > "$Q/failed"; echo "$(date +%T) ${T:0:9}: shell ship live but WINDOWS BROKEN - requests kept, waiting for a new origin commit"; fi
    return 1
  }
  reap_apk   # runner start: a previous runner's finished APK
  reap_pkgs  # ... and packages build
  while :; do
    while ls "$Q"/*.req >/dev/null 2>&1 || bg_go; do
      ship_tree >/dev/null || { sleep "$POLL"; continue; }
      T=$(git rev-parse HEAD)
      inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
      reap_apk; reap_pkgs
      nonroot_kick
      inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
      # Paused: nothing new starts; an APK ship still out (installing) is reaped first.
      if [ -e "$Q/paused" ]; then
        apk_alive && { sleep "$POLL"; continue; }
        echo "$(date +%T) paused - $(ls "$Q"/*.req 2>/dev/null | wc -l | tr -d ' ') request(s) kept"; break
      fi
      # A window check waiting for an awake phone (window-render rc 2): only its retry runs until it's judged.
      if window_wait; then sleep "$POLL"; continue; fi
      T=$(git rev-parse HEAD)
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
      # No request covers this tip: only a pending rooted deploy or packages build keeps the loop here (bg_go above).
      [ ${#whos[@]} -gt 0 ] || bg_go || { sleep "$POLL"; continue; }
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
      # "Nothing differs" only against what the phone SERVES (served_shell), never the record alone: a record ahead of
      # the rendered shell (an install left an older one) diffs from the rendered commit instead.
      if [ -z "$d" ] && [ -n "$base" ]; then
        sv=$(served_shell)
        if [ -n "$sv" ] && [ "$sv" != "$base" ] && ! git merge-base --is-ancestor "$T" "$sv" 2>/dev/null; then
          echo "$(date +%T) ${T:0:9}: the phone serves ${sv:0:9}, not the recorded ${base:0:9} - shipping the difference from what it serves"
          base=$sv; d=$(delta "$base" "$T")
        fi
      fi
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
      post_gate_retry
      if [ -n "$d" ] && [ -z "$cpl" ] && [ "$(cat "$Q/failed" 2>/dev/null)" != "$T" ] && gate_ready shell; then
        # Never inside a verify window. The phone is taken with $SL/phone while our own APK ship holds the ship
        # lock (ship-apk takes it for its install), else with the ship lock itself (a --direct ship).
        # Held: ask the verify queue to yield before its next check (queue.sh reads wants-phone, as for ship-apk) - it
        # touches its lock every heartbeat, so waiting for the lock alone held every ship for a whole window (15:07-15:41,
        # 2026-10-23). Cleared below once the phone is ours and done.
        if phone_offline; then offline_wait shell; sleep "$POLL"; continue; fi
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
        # MODULE FIRST (modules_first above, 11-01 f391): every module these bindings need is published on the phone
        # before this push; a failed publish holds the shell (logged + mailed there).
        mfs=0; modules_first shell || mfs=$?
        if [ $mfs != 0 ]; then
          rm -rf "$held"; rm -f "$Q/installing"; [ "$(cat "$Q/wants-phone" 2>/dev/null)" = $$ ] && rm -f "$Q/wants-phone"
          [ $mfs = 2 ] && { sleep "$POLL"; continue; }   # offline: kept pending, tried again (phone_offline)
          echo "$T" > "$Q/failed"; continue
        fi
        # Schema changes ship atomically (2026-10-30, powos-agents work.try_line): a vendored app's module change in
        # this tip needs its committed bindings to be exactly what the module builds (apps/vendor.sh --check), and the
        # bindings the phone will run after this push must decode its live modules (published first, above). Else the
        # whole tip is refused.
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
          echo "$T" > "$Q/live"; echo "$T" > "$Q/processed"; rm -f "$Q/failed"; gate_clear shell
          pull_publish shell "$log"
          post_gate "$T" "$log" $add
          # A shell whose tip also has APK inputs not yet installed is checked by that APK's ship, on the build it needs:
          # checked here it ran on the OLD APK, failed, marked the ship broken, and the APK carrying the fix never
          # went out (11-01 03:47, 6339815a: f356 deadlock).
          inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
          if pending_apk "$T"; then
            echo "$(date +%T) ${T:0:9}: window check deferred to its APK ship (APK inputs not installed yet)"; wgr=0
          else window_gate "$base" "$T" shell; wgr=$?; fi
          if [ $wgr = 2 ]; then
            # NOT JUDGED (phone asleep): live, but its requests stay NOT done; the loop top retries the check (~60 s).
            { printf 'ww_at=%s\nww_base=%q\nww_tip=%q\nwho_s=%q\nsn=%q\n' "$(date +%s)" "$base" "$T" "$who_s" "$sn"
              declare -p sreqs nreqs; } > "$Q/window-wait.tmp" && mv "$Q/window-wait.tmp" "$Q/window-wait"
            continue
          fi
          if [ $wgr != 0 ]; then
            echo "$T" > "$Q/failed"; echo "$(date +%T) ${T:0:9}: shell ship live but WINDOWS BROKEN - requests kept, waiting for a new origin commit"
            continue
          fi
          shell_done
        else
          git -C "$REPO" fetch -q origin "$BASE" 2>/dev/null
          if [ "$(git rev-parse "origin/$BASE")" != "$T" ]; then echo "$(date +%T) ${T:0:9}: shell ship ended rc $rc while origin moved on - shipping the new tip"; continue; fi
          if link_down "$log" || phone_offline; then offline_wait shell; continue; fi
          # No gate verdict (SHIP_GATE_FIRST's gated push; push.sh exit 75): deferred, not failed - requests kept.
          if [ $rc = $GATE_NV ]; then gate_deferred shell "$T"; continue; fi
          echo "$T" > "$Q/failed"
          echo "$(date +%T) ${T:0:9}: shell ship FAILED rc $rc (log $log) - waiting for a new origin commit"
          mail "ship ${T:0:9} (shell) FAILED rc $rc for $who_s: $(grep -E 'REFUSED|refused|FAIL|error' "$log" | tail -1 | cut -c1-200) - log $log on the Mac; fix it on origin, then ship.sh request again"
          continue
        fi
      elif [ -z "$d" ] && [ -n "$base" ] && [ -z "$cpl" ]; then
        # processed: the newest tip whose shell part is on the phone (nothing to push) - verify/queue.sh's shipped()
        # counts a commit it contains as shipped (11-05: a docs commit's checks waited for a ship that never comes).
        [ "$(cat "$Q/processed" 2>/dev/null)" = "$T" ] || echo "$T" > "$Q/processed"
        for r in ${sreqs[@]+"${sreqs[@]}"}; do done_req "$r" "shipped:${T:0:9}:none"; done
        [ ${#sreqs[@]} -gt 0 ] && echo "$(date +%T) ${T:0:9}: nothing differs from what's live - ${#sreqs[@]} request(s) done"
      fi
      # 2. The APK, beside the loop: once origin stayed QUIET s on the tip, one at a time, not again on a tip that failed.
      if [ ${#areqs[@]} -gt 0 ] && ! apk_out && [ "$age" -ge "$QUIET" ] && [ "$(cat "$Q/failed-apk" 2>/dev/null)" != "$T" ] && gate_ready apk; then
        an=$(joined ${anotes[@]+"${anotes[@]}"})
        if [ -n "$an" ]; then na=(--note "$an"); else na=(--silent); fi
        why="no record of the installed build"; [ -n "$inst" ] && why="APK inputs changed: $(apk_inputs "$inst" "$T" | head -3 | paste -sd' ' -)"
        # MODULE FIRST for the shell this APK's install brings (11-01 c615e0f6: the shell held for its APK went live
        # with the install while the agents module waited for the apps step, which never ran): under the ship lock.
        mfa=0; modules_first APK lock || mfa=$?   # rc 2 (busy / offline): the APK stays pending, tried next pass
        if [ $mfa = 1 ]; then echo "$T" > "$Q/failed-apk"
        elif [ $mfa = 0 ]; then
        echo "$(date +%T) ship ${T:0:9} as an APK ($why) for $who_s - beside the loop"
        apk_launch "$T" "${na[@]}" && echo "note=${an:-(silent)}" > "$Q/apk/notes" || echo "$(date +%T) ${T:0:9}: couldn't check out $SA for the APK"
        fi
      fi
      # 3. Apps: apps/<app>/ changed since the last apps ship, built + installed on the phone - after the APK
      #    (never while one's out, same debounce as the shell ship above so this never waits on an open request
      #    the shell section already closed) and under the shell ship's own phone-busy rules (never inside a
      #    verify window, never during another install).
      # A vendored module waits for its bindings to be live (the shell part held for an APK, or not pushed yet).
      # What the phone's shell is at: the live record, or the installed APK's own when that's newer / there's none.
      # A module published first for this tip (modules_first) isn't published again; all of them = the apps are live.
      vwait=; lv=$(phone_shell)
      aleft=$(for a in $achg; do first_done "$a" || echo "$a"; done | paste -sd' ' -)
      if [ -n "$achg" ] && [ -z "$aleft" ]; then
        echo "$T" > "$Q/apps-live"; rm -f "$Q/failed-apps" "$Q/apps-held"; echo "$(date +%T) ${T:0:9}: apps live (published first: $achg)"; fi
      achg=$aleft
      while read -r va vd; do [ -n "$va" ] || continue
        first_done "$va" && continue
        { [ -n "$lv" ] && git diff --quiet "$lv" "$T" -- "shell/vendor/$vd.js" 2>/dev/null; } || vwait="$vwait $vd"
      done <<< "$vmods"
      if [ -n "$vwait" ] && [ -n "$achg" ]; then
        [ "$(cat "$Q/apps-held" 2>/dev/null)" = "$T" ] || { echo "$T" > "$Q/apps-held"
          echo "$(date +%T) ${T:0:9}: apps held - the shell's bindings for$vwait aren't live yet (the module goes first, with the shell's ship)"; }
      elif [ -n "$achg" ] && ! apk_out && [ "$age" -ge "$QS" ] && [ "$(cat "$Q/failed-apps" 2>/dev/null)" != "$T" ] && gate_ready apps; then
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
            ( PATH="$here/bin:$PATH" apps/build.sh "$a" && PATH="$here/bin:$PATH" POWOS_SHIP_SERVICE=1 apps/install.sh "$a" install --note "$an" --no-build ) >> "$alog" 2>&1 || { arc=$?; break; }
          done; fi
          # And after the publish: the shell's bindings decode the phone's modules (no auto-publish here).
          if [ $arc = 0 ] && [ -n "$vpub" ] && ! ${SHIP_BINDINGS_CHECK:-tools/phone/bindings-check.sh} --no-publish --vendor shell/vendor >> "$alog" 2>&1; then
            arc=10; echo "apps: the phone's modules and the shell's bindings don't match after the publish (above)" >> "$alog"; fi
          rm -rf "$SL"; rm -f "$Q/installing"; [ "$(cat "$Q/wants-phone" 2>/dev/null)" = $$ ] && rm -f "$Q/wants-phone"
          if [ $arc = $GATE_NV ]; then gate_deferred apps "$T"   # no gate verdict: not failed, gated again (gate_ready)
          elif [ $arc = 0 ]; then
            echo "$T" > "$Q/apps-live"; rm -f "$Q/failed-apps"; gate_clear apps
            echo "$(date '+%F %T') ${T:0:9} apps ($achg) for $who_s: $an" >> "$Q/shipped.log"
            units_publish
            echo "$(date +%T) ${T:0:9}: apps shipped ($achg)"
            sync_hacks
          else
            echo "$T" > "$Q/failed-apps"
            echo "$(date +%T) ${T:0:9}: apps ship FAILED rc $arc (log $alog) - waiting for a new origin commit"
            mail "ship ${T:0:9} (apps:$achg) FAILED rc $arc: $(tail -1 "$alog" | cut -c1-200) - log $alog on the Mac; fix it on origin, then ship.sh request again"
          fi
        fi
      fi
      # 3b. Packages (pkgs_due above): targets/android/pkgs/<name>/ changed since the last packages build - built and
      #     published beside the loop, once origin stayed QUIET s on the tip; the rooted deploy below waits for it.
      if ! pkgs_out && [ "$age" -ge "$QUIET" ] && pkgs_due; then
        echo "$(date +%T) ship ${T:0:9} as packages ($pchg) - built beside the loop"
        pkgs_launch "$T" $pchg || echo "$(date +%T) ${T:0:9}: couldn't check out $PK for the packages"
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
      if [ -n "$rchg" ] && ! apk_out && ! rooted_after_apk && ! pkgs_pending && [ "$age" -ge "$QS" ]; then
        if phone_offline; then offline_wait "rooted deploy"
        elif verify_held; then echo $$ > "$Q/wants-phone"
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
            pull_publish rooted "$rlog"
            echo "$(date '+%F %T') ${T:0:9} rooted ($rchg) for $who_s: $rn" >> "$Q/shipped.log"
            echo "$(date +%T) ${T:0:9}: rooted deploy done ($rchg)"
          elif link_down "$rlog" || phone_offline || { [ $rrc = 69 ] && date +%s > "$Q/phone-offline"; }; then
            # The phone dropped off (adb.sh rc 69, EX_UNAVAILABLE): its note and pending record stay, the deploy goes
            # again once phone_offline says it's back (>= SHIP_OFFLINE_POLL_S later).
            offline_wait "rooted deploy"
          else
            echo "$T" > "$Q/failed-rooted"; rm -f "$Q/rooted-pending" "$Q/rooted-note"
            echo "$(date +%T) ${T:0:9}: rooted deploy FAILED rc $rrc (log $rlog) - waiting for a new origin commit"
            mail "ship ${T:0:9} (rooted:$rchg) FAILED rc $rrc: $(tail -1 "$rlog" | cut -c1-200) - log $rlog on the Mac; fix it on origin, then ship.sh request again"
          fi
        fi
      fi
      ! { ls "$Q"/*.req >/dev/null 2>&1 || bg_go; } || sleep "$POLL"
    done
    # An APK ship still out: stay and reap it (the loop above reaps once its rc exists) before the idle exit.
    apk_alive && { sleep "$POLL"; continue; }
    [ -f "$Q/apk/rc" ] && { reap_apk; continue; }
    # A rooted deploy still due (its APK just installed, say): one more pass, never while paused.
    [ ! -e "$Q/paused" ] && ship_tree >/dev/null && bg_go && continue
    [ -e "$Q/paused" ] || nonroot_kick --now
    rm -rf "$L"
    [ -e "$Q/paused" ] && break
    # A request written while this runner was on its way out: take the lock again and serve it.
    ls "$Q"/*.req >/dev/null 2>&1 || break
    mkdir "$L" 2>/dev/null && echo $$ > "$L/pid" || break
  done ;;
*) sed -n 2,14p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
