#!/bin/bash
# tools/phone/ship.sh: ONE ship pipeline to the phone. Agents push to origin, then ask; one service ships origin's tip.
#   ship.sh request --note "what changed, for the user"   after your push to origin - and nothing else. Returns at once.
#   ship.sh request --silent                              a change the user can't see (refactor, lint, tooling)
#   ship.sh status                                        queued requests, the service, what's live, the last ships
#   ship.sh run                                           the service: launchd agent com.powos.ship-runner
#        (tools/phone/ship-deploy.sh; unit units/mac/ship-runner-mac.json). `request` kicks it; without the agent,
#        request starts one of its own. ONE runner ever (lock dir <queue>/runner.lock, as the verify runner's).
# Why (2026-10-23): every agent ran ship-apk.sh / push.sh from its own worktree - ~6 APKs and ~15 shell pushes in one
# night, racing; twice an APK built from an older tip landed after newer shell pushes and wiped them on the phone.
# The service, in its own checkout (.claude/worktrees/ship-runner, only it touches it): waits until origin had no new
# commit for SHIP_QUIET_S (60) s, then ships origin's TIP once:
#   - Kotlin / APK inputs changed since the installed build (~/.cache/powos-installed-commit): ship-apk.sh from the
#     tip (it pre-gates, waits for the verify lock and a free phone, re-pushes newer shell);
#   - else: shell/push.sh --vpn of exactly the shell files that differ from what's live (the last tip it shipped,
#     or the installed build), --reset of the ones the tip deleted. Holds the ship lock (~/.cache/powos-ship.lock)
#     and never runs while the verify lock (~/.cache/powos-verify.lock, < 10 min old, as ship-apk) is held.
#   Every covered request's note goes into ONE update notification ("a; b"; all --silent = silent). The tip shipped
#   goes to <queue>/live, a line to <queue>/shipped.log, the run's log to <queue>/done/. A failed ship mails the
#   coder inbox and isn't retried until origin moves (a user who stayed active: retried). ship-apk.sh / push.sh
#   refuse to run outside this service (POWOS_SHIP_SERVICE) unless --direct (emergencies; logged to <queue>/direct.log).
set -uo pipefail
here=${SHIP_HERE:-$(cd "$(dirname "$0")" && pwd -P)}; unset SHIP_HERE
BASE=worktree-powos-multiplatform
REPO=$(cd "$here" && cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")" 2>/dev/null && pwd -P || true)
[ "$REPO" = / ] && REPO=
SR=$REPO/.claude/worktrees/ship-runner   # the service's checkout: only the service touches it
Q=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}; mkdir -p "$Q/done"
LABEL=${SHIP_AGENT:-com.powos.ship-runner}
QUIET=${SHIP_QUIET_S:-60} POLL=${SHIP_POLL_S:-10}
alive_runner() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null && ps -p "$1" -o command= 2>/dev/null | grep -q ship; }
runner_up() { alive_runner "$(cat "$Q/runner.lock/pid" 2>/dev/null)"; }
# The launchd agent: only for the real queue dir, or the test agent SHIP_AGENT names.
agent_on() { [ -z "${SHIP_DIR:-}" ] || [ -n "${SHIP_AGENT:-}" ]; }
agent_loaded() { agent_on && launchctl print "user/$(id -u)/$LABEL" >/dev/null 2>&1; }
agent_kick() { local p=$HOME/Library/LaunchAgents/$LABEL.plist
  agent_on || return 1
  agent_loaded || { [ -f "$p" ] && launchctl bootstrap "user/$(id -u)" "$p" 2>/dev/null; } || return 1
  launchctl kickstart "user/$(id -u)/$LABEL" >/dev/null 2>&1; }
case "${1:-}" in
request)
  shift; note= silent=
  while [ $# -gt 0 ]; do case "$1" in
    --note) note=${2:-}; shift 2 || shift ;; --note=*) note=${1#--note=}; shift ;; --silent) silent=1; shift ;;
    *) echo "ship.sh request: unknown $1" >&2; exit 2 ;; esac; done
  [ -n "${note// }" ] || [ -n "$silent" ] || { echo "ship.sh request: --note \"what changed, for the user\" (or --silent) required" >&2; exit 2; }
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ship.sh request: run it in your PowOS worktree" >&2; exit 2; }
  git fetch -q origin "$BASE" 2>/dev/null || echo "ship.sh request: fetch failed - checking against the last fetched origin" >&2
  sha=$(git rev-parse HEAD)
  git merge-base --is-ancestor "$sha" "origin/$BASE" 2>/dev/null ||
    { echo "ship.sh request: REFUSED - HEAD ${sha:0:9} isn't on origin/$BASE: push it first (git push origin HEAD:$BASE)" >&2; exit 3; }
  r=$Q/$(date +%Y%m%d-%H%M%S)-$$.req
  printf 'sha=%q\nnote=%q\nsilent=%s\nwho=%q\nat=%s\n' "$sha" "$note" "${silent:-0}" "${SHIP_REQUESTER:-$(basename "$top")}" "$(date +%s)" > "$r.tmp" && mv "$r.tmp" "$r"
  # The request is on disk before the runner check: a runner on its way out sees it (run's last look).
  runner_up || agent_kick || { nohup bash "$here/ship.sh" run >> "$Q/runner.log" 2>&1 & }
  echo "ship requested (${sha:0:9}): the ship service ships origin's tip after ${QUIET}s without new commits - nothing else to do (status: tools/phone/ship.sh status)" ;;
status)
  echo "requests:"; for r in "$Q"/*.req; do [ -f "$r" ] || continue; ( . "$r"; echo "  ${sha:0:9} $who: $([ "$silent" = 1 ] && echo '(silent)' || echo "$note")" ); done
  echo "service: $(runner_up && echo "running (pid $(cat "$Q/runner.lock/pid"))" || echo idle)$(agent_loaded && echo " (launchd $LABEL)")"
  echo "live: $(cut -c1-9 "$Q/live" 2>/dev/null || echo -)  installed APK: $(cut -c1-9 "$HOME/.cache/powos-installed-commit" 2>/dev/null || echo -)$([ -s "$Q/failed" ] && echo "  failed at: $(cut -c1-9 "$Q/failed") (waits for a new origin commit)")"
  echo "last ships:"; tail -6 "$Q/shipped.log" 2>/dev/null | sed 's/^/  /' ;;
run)
  [ -n "$REPO" ] || { echo "ship.sh run: not in a PowOS checkout"; exit 2; }
  ls "$Q"/*.req >/dev/null 2>&1 || exit 0   # nothing requested (launchd starts it at load): gone at once
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
    else
      git -C "$SR" reset -q --hard "origin/$BASE"   # only the service uses it
    fi
    local nm=$REPO/.claude/worktrees/powos-multiplatform/shell/node_modules
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
  trap 'for c in $(pgrep -P $$); do kill $c 2>/dev/null; done; rm -rf "$L"; exit 143' TERM
  SL=$HOME/.cache/powos-ship.lock VL=$HOME/.cache/powos-verify.lock
  mail() { local s; s=$(mktemp "$Q/mail.XXXX")
    printf 'powos comms send %q %q --from ship-queue >/dev/null 2>&1 || true\n' "${SHIP_MAIL_TO:-coder}" "$1" > "$s"
    "$SR/tools/phone/user.sh" "$s" >/dev/null 2>&1 || echo "$(date +%T) mail failed: $1"; rm -f "$s"; }
  verify_held() { [ -d "$VL" ] && [ $(( $(date +%s) - $(stat -f %m "$VL" 2>/dev/null || stat -c %Y "$VL") )) -lt 600 ]; }
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
  while :; do
    while ls "$Q"/*.req >/dev/null 2>&1; do
      ship_tree >/dev/null || { sleep "$POLL"; continue; }
      T=$(git rev-parse HEAD)
      # The debounce: a tip is shipped once origin stayed on it QUIET s (since this service first saw it).
      read -r seen at < "$Q/tip-seen" 2>/dev/null || seen=
      [ "$seen" = "$T" ] || { at=$(date +%s); echo "$T $at" > "$Q/tip-seen"; echo "$(date +%T) origin at ${T:0:9} - waiting for ${QUIET}s without a new commit"; }
      [ $(( $(date +%s) - at )) -ge "$QUIET" ] || { sleep "$POLL"; continue; }
      # A tip that failed: not again until origin moves.
      [ "$(cat "$Q/failed" 2>/dev/null)" = "$T" ] && { sleep "$POLL"; continue; }
      reqs=(); notes=(); whos=()
      for r in "$Q"/*.req; do
        [ -f "$r" ] || continue
        sha= note= silent=0 who=; . "$r"
        git merge-base --is-ancestor "$sha" "$T" 2>/dev/null || continue   # newer than this tip (fetched since)
        reqs+=("$r"); whos+=("$who")
        [ "$silent" = 1 ] || [[ " ${notes[*]+${notes[*]}} " == *"$note"* ]] || notes+=("$note")
      done
      [ ${#reqs[@]} -gt 0 ] || { sleep "$POLL"; continue; }
      who_s=$(printf '%s\n' "${whos[@]}" | sort -u | paste -sd, -)
      note_s=$(printf '%s\n' "${notes[@]+"${notes[@]}"}" | sed '/^$/d' | paste -sd';' - | sed 's/;/; /g')
      if [ -n "$note_s" ]; then na=(--note "$note_s"); else na=(--silent); fi
      inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null || true)
      live=$(cat "$Q/live" 2>/dev/null || true)
      # What's live: the last tip shipped here - unless an APK installed since (a --direct one): then that build.
      base=$inst
      [ -n "$live" ] && [ -n "$inst" ] && git merge-base --is-ancestor "$inst" "$live" 2>/dev/null && base=$live
      kind=shell why=
      if [ -z "$inst" ] || ! git cat-file -e "$inst^{commit}" 2>/dev/null; then kind=apk why="no record of the installed build"
      elif [ -n "$(apk_inputs "$inst" "$T")" ]; then kind=apk why="APK inputs changed: $(apk_inputs "$inst" "$T" | head -3 | paste -sd' ' -)"
      fi
      d=$(delta "$base" "$T"); add=$(echo "$d" | sed -n 's/^+//p'); gone=$(echo "$d" | sed -n 's/^-//p')
      n=$(date +%Y%m%d-%H%M%S)-${T:0:9}; log=$Q/done/$n.log
      if [ $kind = shell ] && [ -z "$d" ]; then
        echo "$(date +%T) ${T:0:9}: nothing differs from what's live - ${#reqs[@]} request(s) done"; rc=0
      elif [ $kind = apk ]; then
        echo "$(date +%T) ship ${T:0:9} as an APK ($why) for $who_s"
        POWOS_SHIP_SERVICE=1 bash tools/phone/ship-apk.sh "${na[@]}" > "$log" 2>&1; rc=$?
      else
        # Shell only: never inside a verify window, never beside an APK ship (a --direct one).
        if verify_held; then echo "$(date +%T) verify lock held ($(cat "$VL/who" 2>/dev/null)) - waiting"; sleep "$POLL"; continue; fi
        ship_lock || { echo "$(date +%T) ship lock held ($(cat "$SL/who" 2>/dev/null)) - waiting"; sleep "$POLL"; continue; }
        echo "$(date +%T) ship ${T:0:9} as shell:$(echo $add)$([ -n "$gone" ] && echo " reset:$(echo $gone)") for $who_s"
        rc=0
        if [ -n "$add" ]; then
          (cd shell && POWOS_SHIP_SERVICE=1 READY_MS=${READY_MS:-30000} ./push.sh --vpn "${na[@]}" $add) > "$log" 2>&1 || rc=$?
        fi
        if [ $rc = 0 ] && [ -n "$gone" ]; then
          (cd shell && POWOS_SHIP_SERVICE=1 ./push.sh --vpn --reset $gone) >> "$log" 2>&1 || rc=$?
        fi
        rm -rf "$SL"
      fi
      if [ $rc = 0 ]; then
        echo "$T" > "$Q/live"; rm -f "$Q/failed"
        echo "$(date '+%F %T') ${T:0:9} $kind ${#reqs[@]} req ($who_s): ${note_s:-(silent)}" >> "$Q/shipped.log"
        for r in "${reqs[@]}"; do echo "result=shipped:${T:0:9}:$kind" >> "$r"; mv "$r" "$Q/done/"; done
        echo "$(date +%T) ${T:0:9}: shipped ($kind)"
        continue
      fi
      git -C "$REPO" fetch -q origin "$BASE" 2>/dev/null
      if [ "$(git rev-parse "origin/$BASE")" != "$T" ]; then
        echo "$(date +%T) ${T:0:9}: $kind ship ended rc $rc while origin moved on - shipping the new tip"; continue
      fi
      if [ $rc = 4 ]; then echo "$(date +%T) ${T:0:9}: the user stayed active - again"; continue; fi
      echo "$T" > "$Q/failed"
      echo "$(date +%T) ${T:0:9}: $kind ship FAILED rc $rc (log $log) - waiting for a new origin commit"
      mail "ship ${T:0:9} ($kind) FAILED rc $rc for $who_s: $(grep -E 'REFUSED|refused|FAIL|error' "$log" | tail -1 | cut -c1-200) - log $log on the Mac; fix it on origin, then ship.sh request again"
    done
    rm -rf "$L"
    # A request written while this runner was on its way out: take the lock again and serve it.
    ls "$Q"/*.req >/dev/null 2>&1 || break
    mkdir "$L" 2>/dev/null && echo $$ > "$L/pid" || break
  done ;;
*) sed -n 2,8p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
