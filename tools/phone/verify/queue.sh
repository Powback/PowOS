#!/bin/bash
# tools/phone/verify/queue.sh: ONE queue for every on-device check, so no agent waits on the phone itself.
#   queue.sh add [--close] [--dev phone|emu|auto] [--name TEXT] [--screen inner|cover] [--budget S] <board-task> <cmd> [args...]
#        queue a Mac-side check (a tools/phone/verify/*.sh or any command that drives the phone) and return at once;
#        starts the runner if none runs, and marks the board task's step "phone check queued" (the AI page's "test now")
#        env vars: queue them through env, e.g. `queue.sh add t env PROFILE=1 shell/dev/perf/drag-raster.sh 12`
#        --close: a PASS also marks the board task done (use when this check is the task's last proof) - only that task, and only
#             when nothing else is open on it: a planned step or an open sub-task keeps it open (the done rule, may_close)
#        --name: what the phone's status pill says is being tested (default: the script's name)
#        --screen: the screen it needs (the pill asks to fold / unfold); default either
#        --budget: seconds it may run (default 300); past it the runner kills it: "FAIL timeout" on the board and pill
#        --dev emu: the EMULATOR lane (tools/emu/emu.sh, the AVD shaped like the Open's inner screen): runs at once, no
#             free phone window waited for, with POWOS_DEVICE=emu (adb.sh & co. reach the emulator); the emulator is
#             started from its snapshot and runs the APK of origin's tip (its build is the ship wait). One emu runner,
#             jobs in turn, own checkout ($POWOS_RUN_ROOT/emu-runner). Hardware checks stay phone-only (refused here:
#             games, Steam, fps, fold, kernel). Results: the board as for phone checks (step "emulator PASS: ..."),
#             kept and sent again later when the board (on the phone) can't be reached.
#        --dev auto: never errors either way; reads the check's own `# lanes:` header line (its first ~6 lines) and
#             picks emu when it says "emu" (every check's does, or "phone" - what the emulator's AVD can ever stand
#             in for: no Linux session, no hardware), or when it says "emu?" (conditionally capable) AND the run was
#             TOLD, not guessed, to be Android-only: a literal --android-only in the command, OR (window-max.sh) its
#             first argument is calc or video - and no argument names a Linux app/stage either way (kate, dolphin,
#             gwenview, ffplay, steam, kwin). Else phone. Handbook "The emulator lane" has the table, per check.
#   queue.sh summary [--since HH:MM | YYYY-MM-DD[ HH:MM]]  one line per finished job: time, id, PASS/FAIL/SKIP, first FAIL line
#        --since: HH:MM means today; a bare date means from its midnight; compared on the job id's date and time (f291)
#        last line: the idle windows' utilization over that span - seconds of jobs that gave a verdict vs wasted ones
#        (rc 3 tries: touched / precond / early, SKIPs, the gaps between jobs); the runner logs it hourly too
#   queue.sh util [--since EPOCH] [--windows]  that utilization line alone (--windows: one line per idle window)
#   queue.sh wait <job-id> [max_s]              block until that job's result; prints its PASS/FAIL/SKIP lines only
#   queue.sh list                               queued, running, paused (who/why/until, if given) and the last results
#   queue.sh pause --why TEXT [--until WHEN]    pause the runner (what the pill's tap does, with its own reason) / resume
#        it (go=all). Records who paused (the caller's worktree/agent, or QUEUE_REQUESTER), why, and optionally until
#        when - `list` and ship.sh's own status/request show it too (friction f114: a paused queue with no reason or
#        owner shown left an agent unable to plan the deploy order).
#   queue.sh resume
#   queue.sh run                                the runner: launchd's agent com.powos.verify-runner (runner-deploy.sh)
#   queue.sh run-emu                            the emulator lane's runner (add --dev emu starts it; ends when nothing waits)
#        starts it when add kicks it (launchctl kickstart) and again if it dies; without the agent, add starts one. Stays while anything is queued.
# The runner waits for ONE free window (window-lock.sh: screen on, no touch for 120 s, then the verify lock), runs every
# queued check in it with LOCK_HELD=1, then releases the lock. "Test now" on the AI page (VerifyRun.kt) writes the phone's
# go flag (/tmp/powos-verify-go in PowOS: a task id or "all"): the wait returns at once and only that task's checks run.
# While a check runs, the phone shows a status pill (VerifyRun.kt, fed /run/powos-app/verify/status.json): a heartbeat
# every HB_S (4) s carries the check, k/N, elapsed time and the SUB-STEP with its own time ("waiting for the game window
# · 45 s": the check's /tmp/powos-verify-step - bf-lib.sh pill - else its log's last line); no beat for 30 s and the pill hides itself. Its x writes
# /tmp/powos-verify-stop, which the next beat sees: the check is killed and stays queued. While runnable checks wait for
# the user (a touch in the last QUEUE_IDLE_S, a game running) the pill says "Tests wait · phone in use" (wait_pill). A check that exits 3 goes back on the queue for the
# next window when the phone's input source says a finger came while it ran (rc3_kind touched) or it gave up at once
# (early) - never dropped: from its 5th try it backs off a few minutes per try (rc3_requeue; each try's log appended to
# done/<job>.log.tries). One that burnt the phone's time with nobody on it (precond: its own setup failed, e.g. the game
# never on screen) gets a verdict at its QUEUE_PRECOND_MAX (3)rd such try: FAIL precondition + its reason line.
# Same-game jobs run back to back (order_jobs) and may hand the running game on (QUEUE_NEXT_APP, warm_stop). A check that exits 0
# but printed a line starting with FAIL is a FAIL. Exit codes -> verdict: 0 PASS; 1 (any other non-zero) FAIL; past its
# --budget FAIL timeout (rc 124); 3 stays queued (no verdict); 5 SKIP (ENV:/test error: preflight, a recorder that
# left no file); 137/143 SKIP killed (a signal not the budget's); a first verdict line "SKIP:" SKIP. SKIPs count as no
# FAIL - a board FAIL must mean a real product bug. Each result goes onto the check's board task (`--step`, the log's
# last line; a FAIL also gets a screenshot as its review image), a mail to the coder inbox (QUEUE_MAIL_TO) and the log
# stays in ~/.cache/powos-verify-queue/done/. Queue a check and END YOUR TURN: the result shows on the board (handbook,
# Efficiency). Paused (the pill's tap, `queue.sh pause`: ~/.cache/powos-verify-queue/paused): the runner stays up but
# runs nothing until the phone's go flag (the AI page's "resume", "test all", "test now"); its state goes to the phone's
# /data/local/tmp/powos-verify-runner (waiting | paused | running | idle), the waits touch it every 5 s (the heartbeat
# the AI page reads: paused or stale -> "checks paused · resume"). Paths: a job queued from inside any PowOS worktree is stored repo-relative and runs in the runner's own
# checkout ($POWOS_RUN_ROOT/verify-runner, fast-forwarded to origin before each window), so removing the worktree it
# came from is fine - push before you queue. The runner runs a private copy of that checkout's queue.sh.
set -uo pipefail
here=${QUEUE_HERE:-$(cd "$(dirname "$0")" && pwd -P)}; unset QUEUE_HERE; phone=${QUEUE_PHONE:-$(cd "$here/.." && pwd -P)}
BASE=worktree-powos-multiplatform
REPO=$(cd "$here" && cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")" 2>/dev/null && pwd -P || true)
[ "$REPO" = / ] && REPO=
WTR=${POWOS_WT_ROOT:-$HOME/pw}   # where tools/agents/worktree.sh new puts agent worktrees (outside the repo)
# The runner's checkout: only the runner touches it. $POWOS_RUN_ROOT/verify-runner, period - the old
# $REPO/.claude/worktrees/verify-runner fallback (wt-move-rest) is gone now that the runners live in ~/pw (f190:
# a lagging agent worktree's stale pre-move copy of THIS script, with no $POWOS_RUN_ROOT concept at all, is what
# used to resurrect the old path - a fallback here can't fix that, and removing it stops this script, once an
# agent rebases onto this tip, from ever choosing that path again).
POWOS_RUN_ROOT=${POWOS_RUN_ROOT:-$HOME/pw}
VR=$POWOS_RUN_ROOT/verify-runner
Q=${QUEUE_DIR:-$HOME/.cache/powos-verify-queue}; mkdir -p "$Q/done"
QUEUED_STEP="phone check queued"   # shell/ui/powai.tsx matches this text
# user_sh <script text>: run it inside PowOS as the session user (its `powos ...`), quietly.
# drop_job <job> <reason>: a queued job leaves the queue without a verdict - never silently: the reason goes into the
# job (dropped=, dropped_at=), it moves to cancelled/, and runner.log and the caller get a line. 11-08 the coordinator
# found two install jobs "vanished with no verdict and no done/cancelled file" (they were still queued, behind a game
# group order_jobs pulled ahead of them) - nothing could tell a dropped job from a waiting one.
drop_job() { local j=$1 n; n=$(basename "$j" .job); [ -f "$j" ] || return 0; mkdir -p "$Q/cancelled"
  printf 'dropped=%q\ndropped_at=%s\n' "$2" "$(date +%s)" >> "$j"
  mv -f "$j" "$Q/cancelled/$n.job" || return 1
  echo "$(date +%T) $n: dropped without a verdict - $2 (cancelled/$n.job)" >> "$Q/runner.log"
  echo "dropped queued $n: $2 (cancelled/$n.job)"; }
user_sh() { local s; s=$(mktemp "$Q/user.XXXX"); printf '%s\n' "$1" > "$s"; "$phone/user.sh" "$s" >/dev/null 2>&1; local rc=$?; rm -f "$s"; return $rc; }
# rc3_requeue <job> <log> <tries> [now]: a check that exited 3 (touched, no window, "skip", bf-pacing's INVALID game
# not on the screen) STAYS QUEUED - always, however many tries. Before, the 5th rc 3 moved the job to done/ as
# "SKIP phone in use" and the measurement never ran (11-05: 194920, 215351, 221526, 221528 - all four burnt their 5
# tries in ~10 min of back-to-back windows while the phone sat idle). Its tries count goes up; from the 5th on it
# backs off (after=<epoch>: QUEUE_RC3_BACKOFF_S (300) s per try past 4, at most 30 min) so a check that keeps exiting
# 3 can't hold every idle window. This attempt's log is appended to <log>.tries (not overwritten by the next try;
# not a .log, so summary/wait/status never read an attempt as a verdict). Prints the backoff epoch (0 = none).
rc3_requeue() { local j=$1 log=$2 t=$(($3 + 1)) now=${4:-$(date +%s)} after=0 tmp
  [ $t -lt 5 ] || { after=$(( (t - 4) * ${QUEUE_RC3_BACKOFF_S:-300} )); [ $after -le 1800 ] || after=1800; after=$((now + after)); }
  [ -f "$log" ] && { printf '=== try %s ended rc 3 at %s ===\n' "$t" "$(date -r "$now" +%T 2>/dev/null || date -d "@$now" +%T)"; cat "$log"; } >> "$log.tries"
  tmp=$(mktemp "$j.XXXX") || return 1
  { grep -vE '^(tries|after)=' "$j"; printf 'tries=%s\nafter=%s\n' "$t" "$after"; } > "$tmp" && mv -f "$tmp" "$j"
  echo "$after"; }
# rc3_kind <elapsed s> <idle s>: what an exit 3 really was, from the input source (idle.sh: the touch IRQs + every
# input device), never from the check's own word. touched = a finger/pad came while it ran (idle < its run time, or
# idle unknown: the old meaning, safe). early = nobody touched it and it gave up within QUEUE_EARLY_S (20) s: not ready
# yet (perf-scenarios' "need 600 s idle"), cheap - kept queued, backing off as before. precond = nobody touched it, it
# spent the phone's time and still had no result: its own setup failed. 11-07 03:32-03:37: six ABZU bf-pacing runs of
# ~85 s each ended "INVALID ... wasn't on the screen" + rc 3, logged "no window / touched" while idle=507 - retried
# forever while the phone sat in the switcher. Those are capped (rc3_precond).
rc3_kind() { local el=$1 idl=${2:-}
  case $idl in ''|*[!0-9]*) echo touched; return ;; esac
  [ "$idl" -lt "$el" ] && { echo touched; return; }
  [ "$el" -lt "${QUEUE_EARLY_S:-20}" ] && { echo early; return; }
  echo precond; }
# rc3_precond <job>: one more precond rc 3 for it (ptries= in the job); prints the new count. At QUEUE_PRECOND_MAX (3)
# the runner turns it into a verdict - "FAIL precondition: <its INVALID/SKIP/FAIL line>" - instead of another retry.
rc3_precond() { local j=$1 p=0 tmp; p=$(sed -n 's/^ptries=//p' "$j" | tail -1); p=$(( ${p:-0} + 1 ))
  tmp=$(mktemp "$j.XXXX") || return 1
  { grep -v '^ptries=' "$j"; printf 'ptries=%s\n' "$p"; } > "$tmp" && mv -f "$tmp" "$j"; echo "$p"; }
# util_rec J <start> <end> <class> <job> | W <open> <close>: the utilization ledger ($Q/util.log, queue-util.py reads
# it): every job's seconds by outcome and every idle window's span - `queue.sh summary` / `util` and the hourly line.
util_rec() { echo "$*" >> "$Q/util.log" 2>/dev/null; }
util_line() { python3 -I "$here/queue-util.py" "$@" "$Q/util.log" 2>/dev/null; }
# util_hourly: once an hour (the stamp $Q/util.stamp), the last hour's utilization into runner.log.
util_hourly() { local now; now=$(date +%s)
  [ $(( now - $(cat "$Q/util.stamp" 2>/dev/null || echo 0) )) -ge "${UTIL_EVERY_S:-3600}" ] || return 0
  echo "$now" > "$Q/util.stamp"; echo "$(date +%T) last hour's $(util_line --since $((now - 3600)))"; }
# warm_stop: close the game a job left warm ($Q/warm: its app id; bf-pacing's "WARM:" line) when the job after it
# isn't for that game after all (a dropped job, the window ended) - the same close bf-stop.sh does, and its marker.
warm_stop() { local a; a=$(cat "$Q/warm" 2>/dev/null); rm -f "$Q/warm"; case $a in ''|*[!0-9]*) return 0 ;; esac
  echo "$(date +%T) closing app $a: ${1:-left warm for a next job of it that never came}"
  user_sh "export XDG_RUNTIME_DIR=/run/powos-app DBUS_SESSION_BUS_ADDRESS=unix:path=/run/powos-app/bus; timeout 35 powos game $a stop; timeout 5 powos sleep never --remove steam"
  phone_sh "rm -f /var/tmp/powos-warm-$a" >/dev/null; }
# warm_takes <dir> <cmd...>: the check reuses a game the job before left warm - a bf-pacing.sh (relative paths from the
# job's dir) that reads the warm marker. 11-07 12:08: ABZU jobs queued with frozen copies of bf-pacing
# (~/.cache/abzu-tools, rsu-tools: no hand-over) were handed the running game, read it as "the user's AbzuGame is up"
# (rc 3) and the game stayed up - window-bench, ww-glue and ww-popups after it all SKIPped on "a game runs".
warm_takes() { local d=$1 a f; shift; for a in "$@"; do [ "$(basename -- "$a" 2>/dev/null)" = bf-pacing.sh ] || continue; case $a in /*) f=$a ;; *) f=$d/$a ;; esac; grep -q 'powos-warm-' "$f" 2>/dev/null && return 0; done; return 1; }
# warm_after <log> <game key>: after a job. Its "WARM:" line hands the game on ($Q/warm = its app); anything else and a
# game that was left warm for it is closed now - the job closed it itself (a no-op then) or never took it (an rc 3
# before its setup, an old check): never a queue game left running into the next, unrelated job.
warm_after() { if grep -q '^WARM: ' "$1" 2>/dev/null && [ -n "$2" ]; then echo "$2" > "$Q/warm"; else warm_stop "the job it was left warm for didn't hand it on"; fi; }
# game_key <cmd...>: the Steam app a games check drives ("" for any other check): APP=<id> in its env, else a games
# script's first numeric argument (game-resize.sh 384190), else Broforce (274190, bf-*.sh's default).
game_key() { local a g=0 app=
  for a in "$@"; do
    case $a in APP=[0-9]*) app=${a#APP=} ;; esac
    basename -- "$a" 2>/dev/null | grep -qiE '^(bf-|games?-)' && g=1 && continue
    [ $g = 1 ] && [ -z "$app" ] && case $a in [0-9]*) [ -z "${a//[0-9]/}" ] && app=$a ;; esac
  done
  [ $g = 1 ] && echo "${app:-274190}"; :; }
# order_jobs: sel[] regrouped so every game's jobs run back to back (each group where its first job was; the others
# keep their order) - ABZU's fps jobs one after another, the game kept warm between them (QUEUE_NEXT_APP), instead of
# ABZU, window-bench ("a game runs: not now"), ABZU again. Sources each job: call it in the window's subshell.
# A job is never pulled ahead of an earlier queued job of its own TASK: a task's jobs run in the order they were
# queued (its installs first). 11-08 00:57-02:04 "Broforce fps after the KWin + Xwayland installs" ran twice, grouped
# behind a games job, before the task's pkg-install/kwin-install jobs queued ahead of it - it measured the old builds
# and the installs looked "vanished".
order_jobs() { local j k i m b out=() keys=() tasks=() placed=()
  for j in ${sel[@]+"${sel[@]}"}; do task=; cmd=(); . "$j"; keys+=("$(game_key ${cmd[@]+"${cmd[@]}"})"); tasks+=("$task"); placed+=(0); done
  for i in ${sel[@]+"${!sel[@]}"}; do
    [ "${placed[$i]}" = 1 ] && continue
    out+=("${sel[$i]}"); placed[$i]=1; k=${keys[$i]}
    [ -n "$k" ] || continue
    for j in "${!sel[@]}"; do
      [ "$j" -gt "$i" ] && [ "${placed[$j]}" = 0 ] && [ "${keys[$j]}" = "$k" ] || continue
      b=0; for ((m = i + 1; m < j; m++)); do [ "${placed[$m]}" = 0 ] && [ "${tasks[$m]}" = "${tasks[$j]}" ] && { b=1; break; }; done
      [ $b = 1 ] || { out+=("${sel[$j]}"); placed[$j]=1; }
    done
  done
  sel=(${out[@]+"${out[@]}"}); }
# rc3_waits <after> [now]: the job backs off (rc3_requeue) until then - not selected for a window yet.
# runner_sum <queue.sh copy>: what the runner runs - that queue.sh and the verify checkout's window-lock.sh it sources.
runner_sum() { echo "$(cksum < "$1" 2>/dev/null) $(cksum < "$VR/tools/phone/verify/window-lock.sh" 2>/dev/null)"; }
rc3_waits() { [ "${1:-0}" -gt "${2:-$(date +%s)}" ] 2>/dev/null; }
# alive_runner <pid>: that pid runs a queue runner (not a recycled pid).
alive_runner() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null && ps -p "$1" -o command= 2>/dev/null | grep -q queue; }
runner_up() { alive_runner "$(cat "$Q/runner.lock/pid" 2>/dev/null || cat "$Q/runner.pid" 2>/dev/null)"; }
# The launchd agent (runner-deploy.sh): only for the real queue dir, or the test agent QUEUE_AGENT names.
LABEL=${QUEUE_AGENT:-com.powos.verify-runner}
agent_on() { [ -z "${QUEUE_DIR:-}" ] || [ -n "${QUEUE_AGENT:-}" ]; }
agent_loaded() { agent_on && launchctl print "user/$(id -u)/$LABEL" >/dev/null 2>&1; }
# agent_kick: start the agent's runner now (a no-op while it runs). Installed but not loaded (a reboot: this headless
# Mac has no login session to load it): loaded here, which starts it. Fails without the agent.
agent_kick() { local p=$HOME/Library/LaunchAgents/$LABEL.plist
  agent_on || return 1
  agent_loaded || { [ -f "$p" ] && launchctl bootstrap "user/$(id -u)" "$p" 2>/dev/null; } || return 1
  launchctl kickstart "user/$(id -u)/$LABEL" >/dev/null 2>&1; }
# who_default: the caller's worktree/agent, so a CLI pause never records an anonymous owner (friction f114).
who_default() { echo "${QUEUE_REQUESTER:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)}"; }
# paused_info: "" if not paused, else "by WHO: WHY (until UNTIL)" - shared by list and whatever else checks $Q/paused.
# Tolerates a bare `touch` (no who=/why=/until= lines) too, same as before this file carried any content.
paused_info() {
  [ -e "$Q/paused" ] || return 0
  local who= why= until=; . "$Q/paused" 2>/dev/null
  printf 'by %s%s%s' "${who:-unknown}" "${why:+: $why}" "${until:+ (until $until)}"
}
# phone_sh <script>: run it in PowOS as root; killed after 15 s (a hung adb never holds the runner). RSTATE set: the
# runner's state word for the AI page goes to the phone's /data/local/tmp/powos-verify-runner first (its heartbeat).
phone_sh() { local b; b=$(printf '%s\n' "$1" | base64 | tr -d '\n')
  perl -e 'alarm shift; exec @ARGV' 15 "$phone/adb.sh" shell "${RSTATE:+printf $RSTATE > /data/local/tmp/powos-verify-runner; }su -c 'sh /data/powos/powos-run.sh \"echo $b | base64 -d | bash\"'" 2>/dev/null; }
killtree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c" "${2:-TERM}"; done; kill -"${2:-TERM}" "$1" 2>/dev/null; }
# endjob <pid>: TERM its tree, KILL what's left after 10 s (f44: 5 s cut off a check's restore
# trap - EXIT/TERM traps that undo a setting change need real wall time to run their adb calls).
endjob() { killtree "$1"; for _ in $(seq 10); do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done; killtree "$1" KILL; }
# The emulator lane: its jobs, its runner's checkout. HW_ONLY: what only the phone's hardware can answer. "fold" is
# word-bounded (grep -E, no \b for portability): "folder-clip.sh" (an app-drawer folder, nothing to do with the
# hinge) and "unfolded-checks.sh" (device_state-simulated, same as every e2e_setup inner check) matched the old
# unbounded "fold" and were wrongly refused --dev emu (2026-10-24).
E=$Q/emu
# emu-runner's checkout: $POWOS_RUN_ROOT/emu-runner, period (f190: no .claude/worktrees fallback - see VR above).
ET=$POWOS_RUN_ROOT/emu-runner
HW_ONLY='^(bf-|steam-|td-launch|mc-launch|games?-)|fps|(^|[^a-z])fold([^a-z]|$)|kernel'
# LINUX_ONLY: an argument naming a Linux app or stage the emulator has no session for - --dev auto never picks emu
# when one of these appears literally in the command (window-max.sh's STAGE, --apps "... kate ...", etc).
LINUX_ONLY='^(kate|dolphin|gwenview|ffplay|steam|kwin)$'
# lanes_marker <script>: its "# lanes:" header line (first 6 lines), "" if it has none. "emu" = runs on the
# emulator as invoked, no further condition; "emu?" = only for an Android-only invocation (android_only_request);
# plain "phone" = never (handbook "The emulator lane" has the table and why, per check).
lanes_marker() { [ -f "$1" ] && awk 'NR<=6 && /^# lanes:/{sub(/^# lanes: */,""); print; exit}' "$1"; }
# android_only_request <script> <args...>: --dev auto's second condition - told, not guessed, that this run is
# Android-only: a literal --android-only, or (window-max.sh) a first argument of calc or video; and no argument
# names a Linux app/stage either way.
android_only_request() {
  local script=$1; shift; local a ao=0
  for a in "$@"; do case "$a" in --android-only) ao=1 ;; esac; grep -qE "$LINUX_ONLY" <<<"$(tr 'A-Z' 'a-z' <<<"$a")" && return 1; done
  [ $ao = 1 ] && return 0
  case "$(basename -- "$script")" in window-max.sh) case "${1:-}" in calc|video) return 0 ;; esac ;; esac
  return 1
}
# wt_of <abs path>: the PowOS worktree it lies in (wroot) and the path under it (wsub, "" = the root); fails outside.
# Agent worktrees made by tools/agents/worktree.sh new now live under $WTR (default ~/pw), outside $REPO - checked
# first since that path doesn't overlap $REPO at all. This is about a JOB's cmd/cwd referencing an agent worktree
# that's since been removed, never about the runner/base checkouts themselves (verify-runner, emu-runner,
# ship-runner*, powos-multiplatform - moving to $POWOS_RUN_ROOT, wt-move-rest), so the old $REPO/.claude/worktrees
# branch below is legacy-job compat only: a job queued before the agent-worktree move still names that path.
wt_of() {
  case "$1/" in
    "$WTR"/?*/*) local s=${1#"$WTR"/}; wroot=$WTR/${s%%/*}; wsub=${1#"$wroot"}; wsub=${wsub#/}; return 0 ;;
  esac
  [ -n "$REPO" ] || return 1
  case "$1/" in
    "$REPO"/.claude/worktrees/?*/*) local s=${1#"$REPO"/.claude/worktrees/}; wroot=$REPO/.claude/worktrees/${s%%/*} ;;
    "$REPO"/*) wroot=$REPO ;;
    *) return 1 ;;
  esac
  wsub=${1#"$wroot"}; wsub=${wsub#/}
}
# relify <sub>: make the job (cmd, cwd) repo-relative: cwd = <sub>, every PowOS worktree path inside an argument
# relative to it (a removed worktree's path then runs from the verify checkout). Sets rel=1.
relify() {
  local up= a R=${REPO//./\\.} W=${WTR//./\\.} out=()
  [ -n "$1" ] && up=$(printf %s "$1/" | sed -E 's#[^/]+#..#g')
  for a in "${cmd[@]}"; do
    # An existing file git doesn't track (a built package in one worktree's out/, a scratch script) stays absolute:
    # rewritten repo-relative it pointed into the verify checkout, where it doesn't exist (steam pkgrel 27 and 28
    # "FAIL install: no file /steam-...", 2026-10-23).
    if [[ "$a" == /* && -e "$a" ]] && ! git -C "$(dirname "$a")" ls-files --error-unmatch "$a" >/dev/null 2>&1; then out+=("$a"); continue; fi
    # $WTR/<name>/... (agent worktrees, outside the repo) strips the same way as the old $REPO/.claude/worktrees/<name>/...
    out+=("$(printf %s "$a" | sed -E "s#$W/[A-Za-z0-9._-]+/#$up#g; s#$W/[A-Za-z0-9._-]+\$#${up:-./}#; s#$R/\.claude/worktrees/[A-Za-z0-9._-]+/#$up#g; s#$R/\.claude/worktrees/[A-Za-z0-9._-]+\$#${up:-./}#; s#$R/#$up#g; s#^$R\$#${up:-./}#")")
  done
  cmd=("${out[@]}"); cwd=${1:-.}; rel=1
}
# verify_tree: the runner's checkout - made if missing (shell/node_modules linked from powos-multiplatform), then
# fast-forwarded to origin's tip.
verify_tree() {
  local VR=${1:-$VR}
  [ -z "${QUEUE_NO_TREE:-}" ] || return 0   # tests: never touch the real runner's checkout
  git -C "$REPO" fetch -q origin "$BASE" || echo "verify checkout: fetch failed - running on what it has"
  if [ ! -e "$VR/.git" ]; then
    git -C "$REPO" worktree add -q --detach "$VR" "origin/$BASE" || { echo "verify checkout: can't create $VR"; return 1; }
    # Marker land.sh and worktree.sh check (friction f57): only the verify runner touches this checkout.
    echo "the verify runner (tools/phone/verify/queue.sh)" > "$VR/.powos-runner-checkout"
  else
    # Only the runner uses it: a check that left files changed doesn't hold it back.
    git -C "$VR" merge -q --ff-only "origin/$BASE" 2>/dev/null || { echo "verify checkout: not a fast-forward - reset to origin"
      git -C "$VR" reset -q --hard "origin/$BASE"; }
  fi
  local nm=$POWOS_RUN_ROOT/powos-multiplatform/shell/node_modules
  [ -d "$nm" ] || nm=$REPO/.claude/worktrees/powos-multiplatform/shell/node_modules
  [ -e "$VR/shell/node_modules" ] || [ ! -d "$nm" ] || ln -s "$nm" "$VR/shell/node_modules"
}
# supersede_key <cmd...>: what makes two queued jobs of one task the same check (f317): the command without its
# --round N (an e2e round number) and, for kwin-install.sh, without its version (only the newest install matters).
supersede_key() {
  local a out=() skip=0 kw=0
  for a in "$@"; do
    [ $skip = 1 ] && { skip=0; continue; }
    [ "$a" = --round ] && { skip=1; continue; }
    [ $kw = 1 ] && continue
    out+=("$(basename -- "$a")"); [ "$(basename -- "$a")" = kwin-install.sh ] && kw=1
  done
  printf '%s\n' "${out[*]}"
}
case "${1:-}" in
add)
  shift; close=0; name=; screen=; budget=300; dev=phone
  while :; do case "${1:-}" in
    --close) close=1; shift ;; --name) name=${2:-}; shift 2 ;; --screen) screen=${2:-}; shift 2 ;; --dev) dev=${2:-}; shift 2 ;;
    --budget) budget=${2:-}; shift 2 ;; *) break ;; esac; done
  case "$dev" in phone|emu|auto) ;; *) echo "queue.sh: --dev phone|emu|auto"; exit 2 ;; esac
  [ $# -ge 2 ] || { echo "usage: queue.sh add [--close] [--dev phone|emu] [--name TEXT] [--screen inner|cover] [--budget S] <board-task> <cmd> [args...]"; exit 2; }
  [[ $budget =~ ^[1-9][0-9]*$ ]] || { echo "queue.sh: --budget <seconds>"; exit 2; }
  # A budget over the 300 s default needs a reason (QUEUE_BUDGET_WHY): game checks were given 900/1500 s to "pass",
  # and the user's rule is that a game check over 300 s is a FAIL, never a reason to wait longer (friction f7).
  if [ "$budget" -gt 300 ] && [ -z "${QUEUE_BUDGET_WHY:-}" ]; then
    echo "queue.sh: --budget $budget is over 300 s; a long check is a FAIL, not a reason to wait. Set QUEUE_BUDGET_WHY=\"...\" only for a check that is long by design (not a game launch)." >&2; exit 2
  fi
  task=$1; shift
  [[ $task =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$ ]] || { echo "queue.sh: bad task id: $task"; exit 2; }
  # f112: a board task id that doesn't exist was accepted and queued anyway - its result then had nowhere real to
  # land. Refuse it, with a did-you-mean from the open board, unless QUEUE_NEW_TASK=1 (the task is made for real,
  # `powos agents task add`, before or right after - never implicitly by queuing a check against a name nobody added).
  # f164: when the board is unreachable, try the offline cache (lib/ai/agents/powos-agents-cli has one as of commit
  # 1e618e92); only if that's also gone, allow with a warning.
  if [ -z "${QUEUE_NEW_TASK:-}" ] && command -v python3 >/dev/null; then
    # Get the CLI from the current worktree's root (git rev-parse --show-toplevel), not $REPO (the original repo),
    # so the lookup works even if the CLI is only on the current worktree's branch, not yet merged to main.
    WT=$(git rev-parse --show-toplevel 2>/dev/null) || WT=
    CLI=${WT:+$WT/lib/ai/agents/powos-agents-cli}
    [ -z "$CLI" ] || [ ! -f "$CLI" ] && CLI=${REPO:+$REPO/lib/ai/agents/powos-agents-cli}
    if [ -f "$CLI" ]; then
      ids=$("$CLI" task list --json 2>/dev/null | python3 -c 'import json,sys
try: print("\n".join(t.get("id","") for t in json.load(sys.stdin)))
except Exception: pass' 2>/dev/null)
      board_answered=1
      if [ -z "$ids" ]; then
        # Board may be unreachable; try the offline cache
        ids=$("$CLI" task list --json --offline 2>/dev/null | python3 -c 'import json,sys
try: print("\n".join(t.get("id","") for t in json.load(sys.stdin)))
except Exception: pass' 2>/dev/null) || ids=
        board_answered=0
      fi
    else
      ids=
      board_answered=0
    fi
    if [ -n "$ids" ] && ! grep -qxF "$task" <<<"$ids"; then
      like=$(grep -i "${task:0:8}" <<<"$ids" | head -3 | tr '\n' ' ')
      echo "queue.sh: no board task '$task'${like:+ - did you mean: $like}. Add it first (powos agents task add ...), or QUEUE_NEW_TASK=1 to queue against it anyway." >&2; exit 2
    elif [ -z "$ids" ] && [ $board_answered = 0 ]; then
      echo "queue.sh: board not reachable and no offline cache - queuing $task anyway, but the result may not land if it doesn't exist." >&2
    fi
  fi
  case "$screen" in ""|inner|cover) ;; *) echo "queue.sh: --screen inner|cover"; exit 2 ;; esac
  [ -x "$1" ] || [ -x "$here/$1" ] || command -v "$1" >/dev/null || { echo "queue.sh: not runnable: $1"; exit 2; }
  [ -x "$here/$1" ] && [ ! -x "$1" ] && set -- "$here/$1" "${@:2}"
  # The command's own script (past `env A=1 ...`) must be executable: the runner execs it, and a 100644 one fails the
  # phone window with rc=126 "Permission denied" (11-07: steam-launch-placeholder.sh, twice; test-verify-executable.sh).
  for a in "$@"; do case "$a" in */env|env|*=*) ;; *.sh) [ ! -f "$a" ] || [ -x "$a" ] || { echo "queue.sh: $a isn't executable - git update-index --chmod=+x $a, commit, push"; exit 2; }; break ;; *) break ;; esac; done
  if [ -z "$name" ]; then  # the script's name (past `env A=1 ...`)
    for a in "$@"; do case "$a" in */env|env|*=*) ;; *) name=$(basename "$a"); break ;; esac; done; name=${name%.sh}
  fi
  # f94: a check queued as "kwin 3.26" ran on 3.25 - naming a version in --name/the task proves nothing unless the
  # check itself checks it. Refuse a version-looking claim (N.N) unless the command either enforces it (sources
  # kwin-up.sh's kwin_install/kwin_up, which FAILs when the installed one is older) or prints what it actually ran
  # on as its own first output line ("VERSION ..." - the runner then records that line with the result, below).
  for v in "$name" "$task"; do
    [[ "$v" =~ [0-9]+\.[0-9]+ ]] || continue
    vok=0
    for a in "$@"; do [ -f "$a" ] && grep -qE 'kwin_install|kwin_up|(^|[^#[:alnum:]_])(echo|printf)[[:space:]]+.VERSION ' "$a" && vok=1; done
    [ $vok = 1 ] || { echo "queue.sh: '$v' names a version, but nothing in the command enforces it (kwin_install/kwin_up) or prints it (a first output line \"VERSION ...\") - that's exactly how a check named 3.26 ran on 3.25"; exit 2; }
  done
  # --dev auto: emu only when the check's own marker allows it AND the run was told (not guessed) to be
  # Android-only - never errors either way (see the header; the table is in the handbook).
  if [ "$dev" = auto ]; then
    dev=phone
    if ! basename -- "$1" 2>/dev/null | grep -qiE "$HW_ONLY"; then
      case " $(lanes_marker "$1") " in
        *" emu "*) dev=emu ;;                                                        # unconditional
        *" emu? "*) android_only_request "$1" "${@:2}" && dev=emu ;;                 # only if told so
      esac
    fi
    echo "queue.sh: --dev auto picked $dev for $(basename -- "$1")"
  fi
  # The emulator has no phone hardware: a game, Steam, frame pacing, the hinge or the phone's kernel is the phone's.
  # Past the filename check (launch-window.sh's Steam cold-start stage isn't named steam-*): a check that carries its
  # OWN "# lanes:" marker and says "phone" only (no "emu") is refused too - the marker knows what the filename can't.
  if [ "$dev" = emu ]; then
    # Report every offending name in one shot (not just the first): exiting on the first match made an agent with
    # several bad args in one `add` fix them one at a time, re-running and hitting the next - 8 retries of the same
    # command for what was really one fix (friction: queue.sh add retried 8x by one agent, 2026-10-24).
    bad=()
    for a in "$name" "$@"; do
      basename -- "$a" 2>/dev/null | grep -qiE "$HW_ONLY" && bad+=("$(basename -- "$a")")
    done
    if [ ${#bad[@]} -gt 0 ]; then
      echo "queue.sh: phone-hardware check(s) (games, Steam, fps, fold, kernel) - queue ALL of these without --dev emu: ${bad[*]}"; exit 2
    fi
    lm=$(lanes_marker "$1")
    [ -z "$lm" ] || case " $lm " in *" emu "*|*" emu? "*) ;; *) echo "queue.sh: $(basename -- "$1")'s own lanes marker ('$lm') says phone only - queue it without --dev emu"; exit 2 ;; esac
  fi
  # Broken checks never reach the phone (2026-10-23: about half the day's FAILs were the checks' own bugs - an unset
  # $2/$3, a zsh-unsplit "id name" arriving as one argument plus an empty one): every .sh in the command must parse
  # (bash -n; shellcheck at error level too when its image is here), and no argument may be empty unless meant.
  for a in "$@"; do
    [ -n "$a" ] || [ "${QUEUE_ALLOW_EMPTY:-0}" = 1 ] || { echo "queue.sh: an empty argument in: $* (zsh doesn't split \$var - write the words out; QUEUE_ALLOW_EMPTY=1 if meant)"; exit 2; }
    case "$a" in *.sh) [ -f "$a" ] || continue
      e=$(bash -n "$a" 2>&1) || { printf '%s\n' "$e" | head -3; echo "queue.sh: $a doesn't parse - not queued"; exit 2; }
      if docker image inspect koalaman/shellcheck:stable >/dev/null 2>&1; then
        # The script goes in on stdin: a bind mount of a Mac path fails under Colima unless that path is shared (f63).
        sc=$(docker run --rm -i koalaman/shellcheck:stable -S error -s bash - < "$a" 2>&1 | head -12)
        [ -z "$sc" ] || { echo "$sc"; echo "queue.sh: shellcheck errors in $a - not queued"; exit 2; }
      fi ;; esac
  done
  # Repo-relative when queued from (or running a command inside) a PowOS worktree: it runs in the verify checkout.
  cmd=("$@"); cwd=$(pwd -P); rel=0; from=
  if wt_of "$cwd"; then from=$wroot; relify "$wsub"
  else for a in "$@"; do wt_of "$a" && { from=$wroot; relify ""; break; }; done; fi
  # need: the queuing tree's commit - the check waits until the phone runs it (see shipped below), so a check queued
  # right after `ship.sh request` doesn't FAIL against the old build (prompt-glyph, icon-norm, 2026-10-23).
  need=; [ -n "$from" ] && need=$(git -C "$from" rev-parse HEAD 2>/dev/null || true)
  # The same check already waiting (same task, same command): no second copy - one agent's urgent check waited ~80 min
  # behind 8 duplicates (friction f41, 2026-10-23). QUEUE_DUP=1 queues it anyway.
  cl="cmd=($(printf '%q ' "${cmd[@]}")"
  if [ "${QUEUE_DUP:-0}" != 1 ]; then
    qd=$Q; [ "$dev" = emu ] && qd=$E   # per lane: the same check on the phone and on the emulator is two answers
    for o in "$qd"/*.job; do
      [ -f "$o" ] || continue
      grep -qxF "task=$(printf '%q' "$task")" "$o" && grep -qF "$cl" "$o" || continue
      # Same task+command, but the waiting job's need= is OLDER than this add's (it waits for an older ship; a re-add
      # after a newer ship is the agent asking to test the newer build): replace it, don't refuse (f258). A true
      # duplicate (its need equals or is a descendant of ours, or either side has none) is still refused.
      onid=$(sed -n 's/^need=//p' "$o" | head -1)
      if [ -n "$need" ] && [ -n "$onid" ] && [ "$onid" != "$need" ] && ! git -C "$from" merge-base --is-ancestor "$need" "$onid" 2>/dev/null; then
        drop_job "$o" "replaced by a re-add of the same check (it waited for older ship ${onid:0:9}, the add needs ${need:0:9})"; continue
      fi
      echo "already queued as $(basename "$o" .job) - not added again (QUEUE_DUP=1 to add anyway)"; exit 0
    done
    # f317: "test all" replayed 35 jobs, incl. stale ones: e2e part 1 twice (two rounds: only --round differed) and
    # kwin-install 3.35 AND 3.36 for one task. The same task + the same check (supersede_key: --round dropped; for
    # kwin-install.sh the script alone, a newer version replaces an older one) waiting: the newest add wins - the
    # older job goes to done/ as .superseded (it would only test an older build or a round nobody reviews).
    nk=$(supersede_key "${cmd[@]}")
    for o in "$qd"/*.job; do
      [ -f "$o" ] || continue
      grep -qxF "task=$(printf '%q' "$task")" "$o" || continue
      ok_=$(cmd=(); eval "$(grep -m1 '^cmd=' "$o")" 2>/dev/null; supersede_key "${cmd[@]}")
      [ -n "$nk" ] && [ "$ok_" = "$nk" ] || continue
      drop_job "$o" "superseded: the same check for this task, older - a newer add replaces it"
    done
  fi
  qd=$Q; [ "$dev" = emu ] && { qd=$E; mkdir -p "$E"; }
  j=$qd/$(date +%Y%m%d-%H%M%S)-$$-$task.job
  { printf 'task=%q\nclose=%s\ntries=0\ncwd=%q\nrel=%s\nfrom=%q\nname=%q\nscreen=%q\nbudget=%s\nneed=%s\nqt=%s\ncmd=(' "$task" "$close" "$cwd" "$rel" "$from" "$name" "$screen" "$budget" "$need" "$(date +%s)"
    printf '%q ' "${cmd[@]}"; printf ')\n'; } > "$j"
  echo "queued $(basename "$j" .job)$([ "$dev" = emu ] && echo " on the emulator (runs now)") - the result goes to board task $task"
  if [ "$dev" = emu ] && [ -z "${QUEUE_NO_RUN:-}" ]; then
    ( user_sh "$(printf 'powos agents task set %q --step %q >/dev/null 2>&1 || true\npowos agents check set %q %q queued --name %q --need %q >/dev/null 2>&1 || true' \
        "$task" "emulator check queued" "$task" "$(basename "$j" .job)" "emu:$name" "$need")" & ) >/dev/null 2>&1
    alive_runner "$(cat "$E/runner.lock/pid" 2>/dev/null)" || { nohup "$0" run-emu >> "$E/runner.log" 2>&1 & }
  elif [ -z "${QUEUE_NO_RUN:-}" ]; then
    # The board marker: the AI page offers "test now" on a task whose step says so (the result's step replaces it).
    # And the check itself (the board's work_check: its truthful "awaiting-check", and the done rule's facts).
    ( user_sh "$(printf 'powos agents task set %q --step %q >/dev/null 2>&1 || true\npowos agents check set %q %q queued --name %q --need %q >/dev/null 2>&1 || true' \
        "$task" "$QUEUED_STEP" "$task" "$(basename "$j" .job)" "$name" "$need")" & ) >/dev/null 2>&1
    # The launchd agent's runner, started now; without the agent, a runner of our own.
    runner_up || agent_kick || { nohup "$0" run >> "$Q/runner.log" 2>&1 & echo $! > "$Q/runner.pid"; }
  fi ;;
pause)  # the CLI pause (also what the pill's tap writes, with its own why): the runner (waiting or mid-check) sees
  # the phone's stop flag within 5 s
  shift; why= until=
  while [ $# -gt 0 ]; do case "$1" in
    --why) why=${2:-}; shift 2 || shift ;; --why=*) why=${1#--why=}; shift ;;
    --until) until=${2:-}; shift 2 || shift ;; --until=*) until=${1#--until=}; shift ;;
    *) echo "queue.sh pause: unknown $1" >&2; exit 2 ;; esac; done
  [ -n "${why// }" ] || { echo "queue.sh pause: --why TEXT required (who's pausing and why, for list/ship.sh status - friction f114)" >&2; exit 2; }
  who=$(who_default); who=${who:-unknown}
  printf 'who=%q\nwhy=%q\nuntil=%q\nat=%s\n' "$who" "$why" "$until" "$(date +%s)" > "$Q/paused"
  runner_up && phone_sh 'umask 022; : > /tmp/powos-verify-stop'
  echo "paused (by $who: $why${until:+, until $until}): nothing runs until resume (queue.sh resume, or resume / test all on the AI page)" ;;
resume)  # the AI page's resume: the go flag (go=all) the runner's wait watches
  rm -f "$Q/paused"
  runner_up && phone_sh 'umask 022; printf all > /tmp/.powos-verify-go && mv -f /tmp/.powos-verify-go /tmp/powos-verify-go'
  echo "resumed$(runner_up && echo ': every queued check runs now' || echo ' (no runner up: the next job starts one)')" ;;
list)
  echo "queued:"; ls "$Q"/*.job 2>/dev/null | sed 's|.*/|  |' || true
  pi=$(paused_info)
  echo "runner: $(runner_up && echo running || echo idle)$([ -z "$pi" ] || echo ", PAUSED $pi (queue.sh resume)")$(agent_loaded && echo " (launchd $LABEL)")"
  echo "emulator lane: $(ls "$E"/*.job 2>/dev/null | wc -l | tr -d ' ') queued, runner $(alive_runner "$(cat "$E/runner.lock/pid" 2>/dev/null)" && echo running || echo idle)$(n=$(ls "$E"/pending/*.sh 2>/dev/null | wc -l | tr -d ' '); [ "$n" = 0 ] || echo ", $n results waiting for the board")"
  # Depth alone (above) doesn't say where YOUR job sits - the queue is FIFO across every agent (f149), so a job
  # queued behind someone else's batch had no way to tell "3rd in line" from "30th" without listing done/ by hand.
  # Filenames sort chronologically (date-prefixed, see `add`'s `j=...`), so ls's default sort IS run order.
  ls "$E"/*.job >/dev/null 2>&1 && { i=0; for ej in $(ls "$E"/*.job | sort); do i=$((i + 1)); echo "    $i) $(basename "$ej" .job)"; done; }
  echo "last results:"; { ls -t "$Q/done" 2>/dev/null | grep "\.log$" | head -8 | while read -r f; do echo "  $f: $(tail -1 "$Q/done/$f")"; done; } || echo "  no results yet" ;;
summary)  # one line per finished job: finish time, id, PASS/FAIL/SKIP, first FAIL line (<=160 chars). Never grep runner.log.
  shift; since=; [ "${1:-}" = --since ] && since=${2:-}
  # f291: --since compares the full date-time. HH:MM is today's; a bare date is from its midnight.
  case "$since" in
    '') ;;
    [0-9][0-9]:[0-9][0-9]) since="$(date +%Y-%m-%d) $since" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) since="$since 00:00" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]) ;;
    *) echo "queue.sh summary: --since takes HH:MM, YYYY-MM-DD or 'YYYY-MM-DD HH:MM' (got '$since')" >&2; exit 2 ;;
  esac
  for lg in $(ls -tr "$Q/done" 2>/dev/null | grep '\.log$'); do
    f=$Q/done/$lg; id=${lg%.log}; t=$(date -r "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" +%H:%M)
    # the job id starts YYYYMMDD-HHMMSS (when it was queued): compare that, not the file's mtime
    if [[ $id =~ ^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2}) ]]; then key="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}"
    else key=$(date -r "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" +"%Y-%m-%d %H:%M"); fi
    [ -z "$since" ] || [[ "$key" > "$since" || "$key" == "$since" ]] || continue
    # The runner's own verdict (its last line, "SKIP ...: ") wins: a SKIPped check may have printed FAIL lines first.
    if tail -1 "$f" | grep -qE '^SKIP'; then v=SKIP; d=$(tail -1 "$f")
    elif grep -qE '^FAIL' "$f"; then v=FAIL; d=$(grep -m1 -E '^FAIL' "$f"); elif grep -qE '^SKIP' "$f"; then v=SKIP; d=$(grep -m1 -E '^SKIP' "$f")
    elif tail -1 "$f" | grep -qE '^PASS'; then v=PASS; d=; else v=PASS?; d=$(tail -1 "$f"); fi
    echo "$t $id $v${d:+ ${d:0:160}}"
  done
  # The idle windows' use over the same span (util.log, queue-util.py): verdict seconds vs wasted (rc 3s, SKIPs, gaps).
  se=0; [ -z "$since" ] || se=$(date -j -f '%Y-%m-%d %H:%M' "$since" +%s 2>/dev/null || date -d "$since" +%s 2>/dev/null || echo 0)
  util_line --since "$se" || true ;;
util)  # queue.sh util [--since EPOCH] [--windows]: the idle windows' utilization (queue-util.py over $Q/util.log)
  shift; util_line "$@" ;;
wait)  # queue.sh wait <job-id|prefix> [max_s=1500]: block until that job has a result, print its PASS/FAIL/SKIP lines only.
  id=${2:-}; max=${3:-1500}; [ -n "$id" ] || { echo "queue.sh wait <job-id> [max_s]"; exit 2; }
  end=$((SECONDS + max)); id=${id%.job}
  while :; do
    lg=$(ls "$Q/done/$id"*.log 2>/dev/null | head -1)
    # A log exists from the moment the job STARTS: it's finished only once its .job left the queue.
    queued=0; { ls "$Q/$id"*.job || ls "$E/$id"*.job; } >/dev/null 2>&1 && queued=1
    if [ -n "$lg" ] && [ $queued = 0 ]; then grep -E '^(PASS|FAIL|SKIP)' "$lg" | cut -c1-200 | head -20 || true; grep -qE '^(PASS|FAIL|SKIP)' "$lg" || tail -1 "$lg"; tail -1 "$lg" | grep -qE '^SKIP' && exit 0; grep -qE '^FAIL' "$lg" && exit 1; exit 0; fi
    # each lane alone: one unmatched glob made ls fail and wait said "no job" for every phone job
    [ $queued = 1 ] || [ -n "$lg" ] || { echo "queue.sh wait: no queued or finished job '$id' (see queue.sh list)"; exit 2; }
    [ "$SECONDS" -lt "$end" ] || { echo "queue.sh wait: $id still queued/running after ${max}s - hand back with the job id"; exit 3; }
    sleep 5
  done ;;
run)
  [ -n "$REPO" ] || { echo "queue.sh run: not in a PowOS checkout"; exit 2; }
  # Nothing queued (launchd starts it at load): gone again at once.
  ls "$Q"/*.job >/dev/null 2>&1 || exit 0
  # ONE runner, ever (launchd's or a hand-started one): the lock dir $Q/runner.lock holds its pid (exec keeps it, so
  # the private copy below already holds it). A dead holder's lock is taken over; a live one's: exit at once.
  L=$Q/runner.lock
  if [ "$(cat "$L/pid" 2>/dev/null)" != $$ ]; then
    # A runner from before the lock (only its runner.pid): running too.
    p=$(cat "$Q/runner.pid" 2>/dev/null)
    if [ ! -d "$L" ] && [ "$p" != $$ ] && alive_runner "$p"; then echo "$(date +%T) runner already running (pid $p)"; exit 0; fi
    for _ in 1 2; do
      mkdir "$L" 2>/dev/null && { echo $$ > "$L/pid"; break; }
      p=$(cat "$L/pid" 2>/dev/null)
      if alive_runner "$p"; then echo "$(date +%T) runner already running (pid $p)"; exit 0; fi
      [ -z "$p" ] && sleep 1 && p=$(cat "$L/pid" 2>/dev/null) && [ -n "$p" ] && continue   # being taken right now
      rm -rf "$L"   # stale: its runner is gone
    done
    [ "$(cat "$L/pid" 2>/dev/null)" = $$ ] || { echo "$(date +%T) runner lock $L busy - exiting"; exit 0; }
  fi
  echo $$ > "$Q/runner.pid"
  if [ -z "${QUEUE_COPY:-}" ]; then
    cd "$VR" 2>/dev/null || cd "$HOME"   # never a worktree that may be removed under it (getcwd errors)
    # A private copy of the verify checkout's queue.sh: bash reads a script as it runs, and checkouts get pulled into.
    verify_tree || exit 1
    c=$(mktemp "${TMPDIR:-/tmp}/powos-queue.XXXXXX") && cp "$VR/tools/phone/verify/queue.sh" "$c" || exit 1
    QUEUE_SUM=$(runner_sum "$c") QUEUE_COPY=$c QUEUE_HERE=$VR/tools/phone/verify exec bash "$c" run
  fi
  rm -f "$QUEUE_COPY"; unset QUEUE_COPY   # bash keeps it open
  . "$here/window-lock.sh"
  board() {  # board <task> <text> [done] [image]: the result on the owner's task (closed too when done=1), as the session user
    # First the check's result (work_check: the module's done rule reads it - "done" means this passed on a shipped
    # build; the job's own vars: n, name, need, qt, r, line), then the step, then the close. An INVALID or SKIP result is
    # friction too (a check that couldn't say yes or no) - EXCEPT "SKIP phone in use": that's the retry loop (below,
    # rc=3) having re-queued it up to 5 times and finally giving up for THIS window, which is correct behaviour (the
    # user was on the phone), not a bug in the check - filing it as flaky-check friction every time someone uses
    # their own phone was noise, not signal (f50, f56, 2026-10-24).
    local s st=${r%% *} sh=1; shipped "$need" "$qt" || sh=0
    s=$(printf 'powos agents check set %q %q %q --name %q --line %q --need %q --shipped %s >/dev/null 2>&1 || true\n' \
        "$1" "$n" "$st" "${name:-}" "$(printf %s "$line" | cut -c1-280)" "$need" "$sh"
      if { [ "$st" = SKIP ] || [ "$st" = INVALID ]; } && [ "$r" != "SKIP phone in use" ]; then
        printf 'powos friction add --area verify --kind flaky-check %q --repro %q --evidence %q --by verify-queue >/dev/null 2>&1 || true\n' \
          "check ${name:-$1} was $st: $(printf %s "$line" | cut -c1-100)" "tools/phone/verify/queue.sh add $1 $(printf %s "${cmd[*]}" | cut -c1-200)" "~/.cache/powos-verify-queue/done/$n.log"; fi
      printf 'powos agents task set %q --step %q %s >/dev/null 2>&1 || true\n' "$1" "$2" "${4:+--image $(printf %q "$4")}"
      # Mail only what needs acting on (a FAIL, not a PASS or SKIP; QUEUE_MAIL_ALL=1 mails passes too): a pass is on the board already, and
      # each mail wakes the coordinator for a full turn (the self-optimize round, 2026-10-23: the top token cost).
      # FAILs no longer mail the coordinator one by one: the board sweep's 10-min digest lists every FAIL nobody picked
      # up (self-optimize round 4, 2026-10-23: per-FAIL mails were the coordinator's main wake-up, 808k ctx per turn).
      # QUEUE_MAIL_FAILS=1 brings the per-FAIL mail back; QUEUE_MAIL_ALL=1 mails passes too.
      if { [[ $2 == *FAIL* ]] && [ "${QUEUE_MAIL_FAILS:-0}" = 1 ]; } || [ "${QUEUE_MAIL_ALL:-0}" = 1 ]; then
        printf 'powos comms send %q %q --from verify-queue >/dev/null 2>&1 || true\n' "${QUEUE_MAIL_TO:-coder}" "$1: $2"; fi
      [ "${3:-0}" = 1 ] && printf 'powos agents task done %q >/dev/null 2>&1 || true\n' "$1")
    user_sh "$s" || echo "board update failed for $1: $2"; }
  jstr() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
  # status <job mark> <json> [more]: the pill's file (VerifyRun.kt watches /run/powos-app/verify/status.json; the old
  # verify-status.json too, for APKs before the heartbeat), the job mark, the stop flag cleared; [more]: more shell
  # (clearing the go flag). One adb call, at most 15 s.
  status() { phone_sh "$(printf 'umask 022; printf %%s %q > /tmp/powos-verify-job; rm -f /tmp/powos-verify-stop /tmp/powos-verify-step; %s; %s' "$1" "$(put "$2")" "${3:-:}")" >/dev/null; }
  # beat <json> <step> <step s>: the heartbeat - the pill's file again; prints "stop" when the pill's tap wrote the stop flag.
  beat() { phone_sh "$(printf 'umask 022; %s; [ -e /tmp/powos-verify-stop ] && echo stop; :' "$(put "$1" "$2" "$3")")" | tr -d '\r' | tail -1; }
  # put <json> [step] [step s]: the pill's file. The SUB-STEP: the check's own (PowOS's /tmp/powos-verify-step, plain
  # text, cleared at each job's start; its age = the file's mtime) if it wrote one, else <step> (the log's last
  # meaningful line, logstep) and <step s>. It fills the json's @@STEP@@ / @@STEPEL@@, and @@HINT@@ (the pill's third
  # line, "prev" - shown as "<prev> · tap to stop" by every APK) becomes "<step> · 45 s"; no step: the last result.
  put() { local f
    printf 'J=%q; S=%q; E=%q; H=%q; ' "$1" "${2:-}" "${3:-0}" "$(js_hint)"
    cat <<'EOS'
F=$(head -1 /tmp/powos-verify-step 2>/dev/null | tr -d '\000-\037"\\|&' | cut -c1-80)
[ -n "$F" ] && { S=$F; E=$(( $(date +%s) - $(stat -c %Y /tmp/powos-verify-step) )); }
if [ -n "$S" ]; then [ "$E" -lt 60 ] && H="$S · $E s" || H="$S · $((E / 60)) min $(printf %02d $((E % 60))) s"; fi
J=$(printf %s "$J" | sed "s|@@STEP@@|$S|; s|@@STEPEL@@|$E|; s|@@HINT@@|$H|")
EOS
    for f in verify/status.json verify-status.json; do
      printf 'mkdir -p /run/powos-app/verify; printf %%s "$J" > /run/powos-app/%s.tmp && mv -f /run/powos-app/%s.tmp /run/powos-app/%s; ' "$f" "$f" "$f"; done; printf ':'; }
  # js_hint: the hint when there's no step - the last result, made safe for put's sed and the json.
  js_hint() { printf %s "${prev:-}" | tr -d '\000-\037"\\|&'; }
  # logstep <log>: the log's last meaningful line (no adb push/pull noise, no blank or progress lines; bf-lib's
  # "-- 12:00:00 " prefix dropped), safe for put, at most 60 chars.
  # kill_step <log> <last step seen>: the step a budget-killed check was in (its last `pill` line, untruncated).
  kill_step() { local s; s=$(grep -a '^-- [0-9:]\{8\} ' "$1" | tail -1 | sed 's/^-- [0-9:]* //'); echo "FAIL timeout at step: ${s:-${2:-unknown (no step published)}}"; }
  logstep() { tail -c 6000 "$1" 2>/dev/null | perl -CSD -ne 's/\r/\n/g; for (split /\n/) { s/\e\[[0-9;?]*[A-Za-z]//g;
      s/^-- \d\d:\d\d:\d\d //; s/[[:cntrl:]"\\|&]//g; s/^\s+|\s+$//g;
      next if $_ eq "" || /\d+ files? (pushed|pulled|skipped)|bytes in [\d.]+ ?s\)|^\[\s*\d+%\]|^adb: |Broken pipe|^\d+(\.\d+)? [KM]B\/s/; $l = $_ }
      END { $l //= ""; print length($l) > 60 ? substr($l, 0, 59) . "\x{2026}" : $l }'; }
  # `kill <runner.pid>` stops the window and its check too, frees the verify lock if this runner held it, and hides the pill.
  trap 'for c in $(pgrep -P $$); do killtree $c; done; [ "$(cut -d" " -f1 "$HOME/.cache/powos-verify.lock/who" 2>/dev/null)" = verify-queue ] && rm -rf "$HOME/.cache/powos-verify.lock"; RSTATE=stopped status "" "{\"done\":true,\"summary\":\"Phone checks stopped (the runner was stopped)\"}"; rm -f "$Q/runner.pid"; rm -rf "$Q/runner.lock"; exit 143' TERM
  # shipped <commit> <queued at>: 0 when the phone runs that commit - in the live shell (ship service's live), and in
  # the installed APK too when the APK's inputs differ from it. No commit, an unknown one (unpushed), or queued over
  # NEED_MAX_S (2 h: a refused ship) ago: 0 - it runs anyway. Only what the ship service ships counts (ship.sh's
  # apk_inputs, shell/): a commit of rootfs packages or check scripts (targets/android/pkgs, tools/) is never "shipped"
  # by it - waiting for that held games checks for 2 h (all of targets/android counted for the APK, 2026-10-23).
  # shell/dev and shell/test never reach the phone (ship.sh's delta skips them): a preview-data commit held every check
  # queued after it for 2 h, waiting for a ship that never comes (2026-10-23, local.hue-rooms.json).
  ship_paths() { git -C "$VR" diff --name-only "$1" "$2" -- "$3" 2>/dev/null | grep -vE 'app/version.properties$|^shell/(dev|test)/'; }
  # The APK test diffs from the merge base of the installed build and the commit - what the commit brings that the
  # APK lacks - never the two trees: inst..c also listed the installed build's own newer changes, so a docs commit
  # branched before the last APK waited for an APK ship that never comes (11-05: a9f1dca32 vs installed 7f594c115's
  # VerifyRun.kt, "waits for its ship" forever). A held/failed APK ship leaves inst behind, so a commit WITH APK
  # inputs keeps waiting (11-04: APK ships held while the phone was offline).
  # The shell test also passes when the ship service PROCESSED an origin tip containing the commit and found
  # nothing to push (its <ship dir>/processed, written on "nothing differs from what's live" and on a live push) -
  # a held/failed shell ship never writes it.
  shipped() {
    local c=$1 live inst done_tip sd=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}; [ -n "$c" ] || return 0
    [ $(( $(date +%s) - ${2:-0} )) -lt "${NEED_MAX_S:-7200}" ] || return 0
    git -C "$VR" cat-file -e "$c^{commit}" 2>/dev/null || return 0
    live=$(cat "$sd/live" 2>/dev/null); inst=$(cat "${INSTALLED_FILE:-$HOME/.cache/powos-installed-commit}" 2>/dev/null)
    done_tip=$(cat "$sd/processed" 2>/dev/null)
    if [ -n "$inst" ] && ! git -C "$VR" merge-base --is-ancestor "$c" "$inst" 2>/dev/null; then
      local ib; ib=$(git -C "$VR" merge-base "$inst" "$c" 2>/dev/null) || ib=$inst
      [ -z "$(ship_paths "$ib" "$c" targets/android/app; ship_paths "$ib" "$c" targets/android/build-app.sh)" ] || return 1
    fi
    [ -z "$live" ] || git -C "$VR" merge-base --is-ancestor "$c" "$live" 2>/dev/null \
      || { [ -n "$done_tip" ] && git -C "$VR" merge-base --is-ancestor "$c" "$done_tip" 2>/dev/null; } \
      || [ -z "$(ship_paths "$(git -C "$VR" merge-base "$live" "$c" 2>/dev/null)" "$c" shell)" ]; }
  # pause <summary>: the user's stop - recorded (the runner stays, runs nothing until the phone's go flag), the pill gone.
  # who=the phone: this pause comes from the status pill's tap, not a CLI caller - still gets a why (friction f114:
  # a paused queue with no reason or owner shown).
  pause() { printf 'who=the phone\nwhy=%q\nuntil=\nat=%s\n' "$1" "$(date +%s)" > "$Q/paused"
    RSTATE=paused status "" "{\"done\":true,\"paused\":true,\"summary\":$(jstr "$1 · resume on the AI page")}"; }
  # wait_pill: while the wait for a window lasts past WAIT_PILL_S (the user is on the phone: a free phone ends it at
  # once) and checks could run, the pill says they wait - rewritten every 150 s with a 200 s life (VerifyRun's ttl), so
  # a runner gone without a word leaves it at most that long. Only the pill's file: the stop flag stays for the wait.
  # Runs in the background; the wait's end (or the window's) kills it.
  wait_pill() { local r=0 j
    for j in "$Q"/*.job; do [ -f "$j" ] && ( need=; qt=0; . "$j"; shipped "$need" "$qt" ) && r=$((r + 1)); done
    [ $r -gt 0 ] || return 0
    sleep "${WAIT_PILL_S:-10}"
    while :; do phone_sh "umask 022; $(put "{\"done\":true,\"wait\":true,\"n\":$r,\"ttl\":200}")" >/dev/null; sleep 150 & wait $!; done; }
  # select_jobs GO: this window's jobs in queue order -> sel[]; held = how many wait for their ship. A job waiting for
  # its ship never blocks the ones behind it (11-02: the head job's "waits for its ship" held the queue while the ship
  # service waited on a dozing phone): it's skipped here, every runnable job behind it runs, and it's looked at again
  # next window. A "test now" of exactly its task runs it anyway. Sources each job: call it in a subshell or the window's.
  # AWAY=1 (the window came with " game=away": a game left running, nobody's input for GAME_IDLE_S, idle.sh): a job that
  # would close the game or Steam (closes_game) is skipped and stays queued - counted as held; covering it is fine.
  # A "test now" (go) runs everything: the user handed the phone over.
  # closes_game <cmd...>: a games/Steam check by name (HW_ONLY's games part), or a script that stops the game, Steam or
  # the session (bf-stop, pkill steam/reaper, kwin_restart / kwin_up, power logout).
  closes_game() { local a f
    for a in "$@"; do
      basename -- "$a" 2>/dev/null | grep -qiE '^(bf-|steam-|td-launch|mc-launch|games?-)' && return 0
      f=$a; [ -f "$f" ] || f=$VR/$a; [ -f "$f" ] || continue
      grep -qE "bf-stop|kwin_restart|kwin_up|power logout|pkill[^|;]*(steam|reaper|SteamLaunch)|killall[^|;]*steam|force-stop[^|;]*steam" "$f" 2>/dev/null && return 0
    done; return 1; }
  # job_held <go> <job name>: (the job's vars sourced) it stays queued this window - prints why, returns 0. Shared by
  # select_jobs and the window's "queued to go first" look, so a held job never ends a window it couldn't run in.
  job_held() { local go=$1 n=${2:-job}
    # Backing off after its 5th rc 3 (rc3_requeue): stays queued, held until then; a "test now" for it runs it at once.
    if [ "$task" != "$go" ] && rc3_waits "$after"; then echo "$(date +%T) $n: exited 3 $tries times - stays queued, next try after $(date -r "$after" +%T 2>/dev/null || date -d "@$after" +%T)"; return 0; fi
    if [ -z "$go" ] && [ "${AWAY:-0}" = 1 ] && ( [ "$rel" = 1 ] && cd "$VR/$cwd" 2>/dev/null || cd "$cwd" 2>/dev/null; closes_game "${cmd[@]}" ); then
      echo "$(date +%T) $n: would close the game left running (nobody playing) - skipped, stays queued"; return 0; fi
    if [ "$task" != "$go" ] && ! shipped "$need" "$qt"; then echo "$(date +%T) $n: waits for its ship (${need:0:9}) - skipped, the jobs behind it run"; return 0; fi
    return 1; }
  # first_waiting <job> <go>: a job sorting before <job>, not in this window's sel, that the next window would run
  # (prints its name). Sources jobs: call it in $( ).
  first_waiting() { local j=$1 go=$2 f
    for f in "$Q"/*.job; do
      [ "$f" \< "$j" ] || break
      case " ${sel[*]} " in *" $f "*) continue ;; esac
      need=; qt=0; task=; after=0; tries=0; cwd=; rel=0; cmd=(); . "$f"
      # A task-specific test request must not yield forever to a job it cannot select next window.
      [ -z "$go" ] || [ "$go" = all ] || [ "$task" = "$go" ] || continue
      job_held "$go" >/dev/null && continue
      basename "$f" .job; return 0
    done; return 1; }
  select_jobs() { local go=$1 j; sel=(); held=0
    for j in "$Q"/*.job; do
      [ -f "$j" ] || continue
      task=; need=; qt=0; cwd=; rel=0; after=0; tries=0; cmd=(); . "$j"
      [ -z "$go" ] || [ "$go" = all ] || [ "$task" = "$go" ] || continue
      job_held "$go" "$(basename "$j" .job)" && { held=$((held + 1)); continue; }
      sel+=("$j")
    done; }
  # The runner stays while anything is queued (a "test now" needs one waiting): a window that didn't come is waited for again.
  while ls "$Q"/*.job >/dev/null 2>&1; do
    verify_tree
    # A fix to the runner itself takes effect between windows: the pulled queue.sh differs from the copy it started
    # from -> start again from it (same pid: the runner lock stays ours). Before, a fix waited for the runner to end -
    # with checks always queued, never (2026-10-23).
    # The sum covers window-lock.sh too (sourced once at start): 11-07 its self-input fix shipped 22:32 and the runner
    # kept the old wl_wake/wl_sleep all night - every wake still read as the user picking the phone up.
    if [ -n "${QUEUE_SUM:-}" ] && [ -z "${QUEUE_NO_TREE:-}" ] && [ "$(runner_sum "$VR/tools/phone/verify/queue.sh")" != "$QUEUE_SUM" ]; then
      echo "$(date +%T) queue.sh/window-lock.sh changed on origin - the runner starts again from it"; unset QUEUE_SUM
      exec bash "$VR/tools/phone/verify/queue.sh" run
    fi
    # Paused: the wait returns for the go flag only (resume / test all / test now), never for a free window.
    # Nothing runnable (every queued job waits for its ship): no window taken - the phone isn't woken or locked for
    # nothing; only a "test now" (the go flag) is waited for, NEED_POLL_S (60) s, then the queue is looked at again.
    nowin=; wmax=${WAIT_S:-7200}
    if [ -e "$Q/paused" ]; then export GO_ONLY=1 VERIFY_STATE=paused; echo "$(date +%T) paused - waiting for resume on the phone"
    elif ! ( select_jobs "" >/dev/null; [ ${#sel[@]} -gt 0 ] ); then export GO_ONLY=1 VERIFY_STATE=waiting; nowin=1; wmax=${NEED_POLL_S:-60}
    else unset GO_ONLY; export VERIFY_STATE=waiting; fi
    w0=$(date +%s)
    wpp=; [ -n "${GO_ONLY:-}" ] || { wait_pill & wpp=$!; }
    ( export VERIFY_GO=1 WL_PHONE=$phone
      window_lock verify-queue "${QUEUE_IDLE_S:-120}" "$wmax" >/dev/null || exit 3
      [ -n "$wpp" ] && endjob "$wpp"
      rm -f "$Q/paused"; RSTATE=running   # a go ends a pause
      go=; case "${WL_GOT:-}" in go=*) go=${WL_GOT#go=}; go=${go%% *} ;; esac
      AWAY=0; case "${WL_GOT:-}" in *game=away*) AWAY=1; echo "$(date +%T) a game is running with nobody playing: checks leave it alone" ;; esac
      select_jobs "$go"; order_jobs
      # The window's span for the utilization ledger, and a game a job left warm for a next job that never came (the
      # window ended: an install, a touch) closed again - else idle.sh reads it as the user playing for GAME_IDLE_S.
      wopen=$(date +%s); trap 'warm_stop; util_rec W "$wopen" "$(date +%s)"; wl_done; wl_release' EXIT   # wl_release: this trap replaces window_lock's (one EXIT trap per shell) - without it the lock outlived the window (11-07 12:28)
      # wl_done: the window ends - if the queue woke the phone (wl_wake), say for how many jobs (runner.log and the
      # util ledger's K line), then the user's settings back and the screen off again (wl_sleep: not after a touch).
      wl_done() { [ -n "${WL_DID:-}" ] || [ -e "$WL_WOKE" ] || return 0; echo "$(date +%T) woke the phone for ${k:-0} jobs"; util_rec K "$(date +%s)" "${k:-0}"; wl_sleep "$phone"; }
      N=${#sel[@]}; k=0; pass=0; fail=0; first=; prev=; results=
      [ $N -gt 0 ] || { status "" '{"done":true}' "rm -f /tmp/powos-verify-go"; [ $held = 0 ] && exit 5; exit 7; }
      # f317: what a "test all" costs, before it starts: the count and the summed budgets (an upper bound).
      est=0; for j in "${sel[@]}"; do b=$(sed -n 's/^budget=//p' "$j" | head -1); est=$((est + ${b:-300})); done
      [ -n "$go" ] && echo "$(date +%T) go from the phone: $go ($N checks, at most ~$(( (est + 59) / 60 )) min)"
      for j in "${sel[@]}"; do
        # Gone since the window picked it (renamed or removed outside the queue): said, never a silent skip.
        [ -f "$j" ] || { echo "$(date +%T) $(basename "$j" .job): left the queue dir since this window picked it (renamed or removed by hand?) - not run"; continue; }
        # f97: a `queue.sh pause` mid-window (its stop flag only reaches a check that's ALREADY running, via beat's
        # look below) used to leave the runner chewing through the rest of this window's jobs regardless, holding
        # the lock the whole time while the phone dozed and the queue already said paused. A paused (or now-idle,
        # nothing left selected) runner gives the window back at once instead of finishing it out.
        if [ -e "$Q/paused" ]; then
          echo "$(date +%T) paused mid-window - releasing it now ($((N - k)) still queued)"
          pause "Phone checks paused: $pass passed, $fail failed, $((N - k)) still queued"; exit 4
        fi
        # A runnable job that sorts before this one but came in after the window began (a job queued to go first, e.g.
        # an install the next checks depend on) ends the window, and the next window re-picks in order. Before, it
        # waited for the whole batch: 58 checks, hours (06:22).
        # Only a job the next window WOULD select counts (job_held, the same rules as select_jobs): 11-07 22:51-00:14 the
        # head job, backing off after its rc 3s, sorted first and ended every window at once - "queued to go first -
        # re-picking", "woke the phone for 0 jobs" four times, 23 queued and one ran in 2 h.
        f=$(first_waiting "$j" "$go") && { echo "$(date +%T) $f queued to go first - re-picking the window"; exit 4; }
        task=; need=; qt=0; after=0
        # An APK install waits for this window (ship-apk wrote wants-phone): yield before the next check - the install
        # restarts the app anyway, and the rest run in the next window against the new build.
        wp=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}/wants-phone
        ip=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}/installing
        if { [ -f "$wp" ] && kill -0 "$(cat "$wp" 2>/dev/null)" 2>/dev/null; } ||
           { [ -f "$ip" ] && kill -0 "$(cat "$ip" 2>/dev/null)" 2>/dev/null; }; then
          echo "$(date +%T) yielding the window to an APK install ($((N - k)) checks wait for the next window)"
          status "" "{\"done\":true,\"summary\":$(jstr "Phone checks paused for an update install: $pass passed, $fail failed")}"
          exit 4
        fi
        # The checkout to origin's tip before EACH job, not just each window: a window can last an hour, and a check
        # pushed after it began was missing ("No such file", rc 126/127, 2026-10-23).
        verify_tree >/dev/null 2>&1 || true
        # Keep the verify lock fresh for the whole window: ship-apk and rooted.sh treat a lock untouched for 10 min as
        # stale, so a long window let an APK install land mid-check (07:06:37, friction f22).
        touch "$HOME/.cache/powos-verify.lock" 2>/dev/null
        # The phone gone (VPN drop, reboot): leave the window with every job still queued instead of failing each one at
        # its setup ("can't push powos-open-task" FAILs burned the test-set runs during the 06:28 reboot).
        if ! perl -e 'alarm shift; exec @ARGV' 15 "$phone/adb.sh" shell true >/dev/null 2>&1; then
          echo "$(date +%T) the phone isn't reachable - leaving the window, jobs stay queued"; exit 3
        fi
        task=; close=0; tries=0; after=0; cwd=$PWD; rel=0; from=; name=; screen=; budget=300; need=; qt=0; cmd=(); . "$j"
        # A job from before repo-relative jobs: its worktree may be gone - run it in the verify checkout instead.
        if [ "$rel" != 1 ] && [[ "$cwd ${cmd[*]}" == *"$REPO/.claude/worktrees/"* ]]; then
          if wt_of "$cwd"; then relify "$wsub"; else relify ""; fi
        fi
        [ "$rel" = 1 ] && cwd=$VR/$cwd
        # f106: a game check (Broforce etc, ~14 min) saw the screen go off mid-window - the runner only woke it once,
        # at the window's start (wl_wake, window-lock.sh). PowosWindowActivity's own keep-on only covers a
        # full-screen task once it has one; the setup/measure gaps around it need the same wl_wake, kept up for as
        # long as this job runs, the same way wl_sleep already restores sleep once the whole window ends.
        game=0; for a in "${cmd[@]}"; do basename -- "$a" 2>/dev/null | grep -qiE "$HW_ONLY" && game=1; done
        n=$(basename "$j" .job); log=$Q/done/$n.log; k=$((k + 1))
        # Warm hand-over: the next job drives the same game -> QUEUE_NEXT_APP tells this one (bf-pacing) to leave it
        # running ("WARM: ..." in its log) for the next to reuse; a game left warm for another app is closed first.
        # Only a check that takes the hand-over (bf-pacing.sh reads its warm marker) gets one: game-resize would take a
        # running game for the user's.
        gk=$(game_key "${cmd[@]}"); nk=; [ -n "$gk" ] && [ -n "${sel[$k]:-}" ] && nk=$( cmd=(); cwd=.; rel=0; . "${sel[$k]}"; [ "$rel" = 1 ] && cwd=$VR/$cwd; warm_takes "$cwd" "${cmd[@]}" && game_key "${cmd[@]}" )
        nextapp=; [ -n "$gk" ] && [ "$nk" = "$gk" ] && nextapp=$gk
        [ -s "$Q/warm" ] && [ "$(cat "$Q/warm")" != "$gk" ] && warm_stop
        echo "$(date +%T) run $n: ${cmd[*]}"
        js() { printf '{"name":%s,"task":%s,"k":%s,"n":%s,"screen":%s,"el":%s,"budget":%s,"prev":"@@HINT@@","step":"@@STEP@@","stepel":@@STEPEL@@}' \
          "$(jstr "${name:-$task}")" "$(jstr "$task")" $k $N "$(jstr "$screen")" "$1" "$budget"; }
        status "$n" "$(js 0)" "$([ $k = 1 ] && echo 'rm -f /tmp/powos-verify-go')"
        # f291: the first line names the build the check ran on: the installed APK and the live shell (ship.sh's state).
        ia=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null); lv=$(cat "${SHIP_DIR:-$HOME/.cache/powos-ship-queue}/live" 2>/dev/null)
        printf 'build: %s shell=%s\n' "${ia:--}" "${lv:--}" > "$log"
        [ -s "$log.tries" ] && echo "try $((tries + 1)): the earlier tries' logs (each ended rc 3) are in $log.tries" >> "$log"
        ( cd "$cwd" && unset VERIFY_GO && export LOCK_HELD=1 QUEUE_NEXT_APP=$nextapp && "$here/preflight.sh" "${cmd[@]}" && exec "${cmd[@]}" ) >> "$log" 2>&1 & jp=$!   # preflight: rc 5 + "ENV: why" when the phone cannot run it
        # The heartbeat: every HB_S s the pill hears check, k/N, elapsed; a tap's stop flag or the budget ends the check.
        # The sub-step: the check's own (put) or its log's last line, timed from when that line first showed.
        t0=$(date +%s); why=; ls_=; lt=$t0
        # f117: the budget kill once came ~20 min late because a hung adb call (inside beat, below) blocked this
        # whole loop - el was only ever checked AFTER beat returned. Its own timer now watches wall time and kills
        # jp directly, no adb, so a stuck beat can delay the heartbeat but never the kill.
        rm -f "$log.timedout"
        ( while kill -0 $jp 2>/dev/null; do
            [ $(( $(date +%s) - t0 )) -lt "$budget" ] || { : > "$log.timedout"; killtree $jp; break; }
            sleep 2
          done ) & budp=$!
        while kill -0 $jp 2>/dev/null; do
          for _ in $(seq "${HB_S:-4}"); do kill -0 $jp 2>/dev/null || break; sleep 1; done
          touch "$HOME/.cache/powos-verify.lock" 2>/dev/null   # fresh through a long check too (f22)
          kill -0 $jp 2>/dev/null || break
          [ "$game" = 1 ] && wl_wake "$phone" >/dev/null 2>&1   # f106: keep the screen on through the whole check
          # The phone was woken by the queue and a real input came: stop now, settings back - the user's phone again.
          wl_touched "$phone" && { why=touched; wl_restore "$phone"; break; }
          el=$(( $(date +%s) - t0 ))
          [ $el -ge "$budget" ] && { why=timeout; break; }
          l=$(logstep "$log"); [ "$l" = "$ls_" ] || { ls_=$l; lt=$(date +%s); }
          # The pill's x (its only touch target since the whole pill stopped taking touches; e2e-lib refuses taps on
          # the pill's frame) - injected or real, a stop is a stop: verify/pill-stop.sh taps it.
          [ "$(beat "$(js $el)" "$ls_" $(( $(date +%s) - lt )))" = stop ] && { why=stop; break; }
        done
        kill "$budp" 2>/dev/null; wait "$budp" 2>/dev/null
        [ -n "$why" ] || [ ! -e "$log.timedout" ] || why=timeout; rm -f "$log.timedout"
        [ -n "$why" ] && endjob $jp
        wait $jp; rc=$?
        # A killed check's phone side keeps running (td-launch-phone.sh outlived its budget kill by 2 min and overlapped
        # the next check, 04:31): end every <check>-phone.sh of this job on the phone too.
        if [ -n "$why" ]; then
          for a in "${cmd[@]}"; do case "$a" in *.sh) b=$(basename "$a" .sh)
            phone_sh "pkill -f '$b-phone.sh' 2>/dev/null; :" >/dev/null 2>&1 ;; esac; done
        fi
        # A check that had already stopped for the user (its last verdict line "SKIP:", e.g. e2e's "aborted - the user
        # touched the phone") and then ran past its budget in its own clean-up (11-01 17:58, round 204 part 1: FAIL
        # timeout at "SKIP: ... aborted") is what it said it was: rc 3, re-queued for the next window, not a FAIL.
        if [ "$why" = timeout ] && grep -E '^(PASS|FAIL|SKIP)' "$log" | tail -1 | grep -q '^SKIP:'; then
          echo "SKIP: past its ${budget}s budget in its clean-up, after it had already stopped for the user" >> "$log"
          echo "$(date +%T) $n: past its budget after its own SKIP - re-queued, not a FAIL"; why=; rc=3
        fi
        if [ "$why" = timeout ]; then
          rc=124; echo "FAIL timeout: still running after its ${budget}s budget - killed" >> "$log"
          kill_step "$log" "$ls_" >> "$log"
          echo "$(date +%T) $n: past its ${budget}s budget - killed"
        fi
        # Stopped for the user's input on a phone the queue woke: rc 3 touched - stays queued, the window ends below.
        [ "$why" = touched ] && { echo "$(date +%T) $n: the user picked up the phone the queue woke - stopped, stays queued"; why=; rc=3; }
        if [ "$why" = stop ]; then
          echo "$(date +%T) $n: stopped from the phone - stays queued, paused"; util_rec J "$t0" "$(date +%s)" stopped "$n"
          pause "Phone checks paused: $pass passed, $fail failed, $((N - k + 1)) still queued"
          exit 4
        fi
        t1=$(date +%s); warm_after "$log" "$gk"
        pfinal=
        if [ $rc = 3 ]; then
          # Touched or not comes from the input source (rc3_kind), read right after the check: idle shorter than its
          # run = a finger came. Nobody touched it and it burnt the phone's time: precond - at QUEUE_PRECOND_MAX (3)
          # tries a verdict ("FAIL precondition: <why>"), never an endless rc 3 loop while the phone sits idle.
          idl=$("$phone/idle.sh" 2>/dev/null | sed -n 's/.*idle=\([0-9]*\).*/\1/p')
          kind=$(rc3_kind $((t1 - t0)) "$idl"); util_rec J "$t0" "$t1" "$kind" "$n"
          if [ "$kind" = precond ]; then
            pt=$(rc3_precond "$j")
            if [ "${pt:-0}" -ge "${QUEUE_PRECOND_MAX:-3}" ]; then
              why3=$(grep -E '^(INVALID|SKIP|FAIL)' "$log" | tail -1 | cut -c1-160)
              echo "FAIL precondition: ${why3:-exit 3 with no reason line} - $pt tries of $((t1 - t0)) s with nobody on the phone (each try: done/$n.log.tries)" >> "$log"
              echo "$(date +%T) $n: rc 3 with the phone idle $pt times (its setup fails, not a touch) - FAIL precondition, no more retries"
              rc=1; pfinal=1
            fi
          fi
        fi
        if [ $rc = 3 ]; then
          aft=$(rc3_requeue "$j" "$log" "$tries")
          if [ "${aft:-0}" = 0 ]; then echo "$(date +%T) $n: rc 3 ($kind$([ "$kind" = precond ] && echo " $pt/${QUEUE_PRECOND_MAX:-3}: nobody touched the phone, its setup failed"; [ "$kind" = early ] && echo ": not ready yet")), again next window"
          else
            echo "$(date +%T) $n: rc 3 ($kind) for the $((tries + 1))th time - stays queued, next try after $(date -r "$aft" +%T)"
            # The board hears it once, as a step (no check verdict: not a PASS, FAIL or SKIP - it still runs).
            [ $((tries + 1)) = 5 ] && user_sh "$(printf 'powos agents task set %q --step %q >/dev/null 2>&1 || true' "$task" \
              "$QUEUED_STEP: exited 3 five times ($(grep -E '^(INVALID|SKIP|FAIL)' "$log" | tail -1 | cut -c1-120)) - stays queued, retried every few min (log ~/.cache/powos-verify-queue/done/$n.log.tries)")" &
          fi
          # Leave the window only when the user really came back (a finger in the last QUEUE_IDLE_S): rc 3 also means
          # "not on the phone yet" (plasma-notify: no PlasmaBridge in the APK), which ended every window at its first
          # job while the user was away charging (01:46, 18 checks never ran).
          if [ -n "$idl" ] && [ "$idl" -ge "${QUEUE_IDLE_S:-120}" ]; then
            echo "$(date +%T) $n: rc 3 but the phone is still idle (${idl}s) - next check"; util_hourly; continue
          fi
          status "" "{\"done\":true,\"summary\":$(jstr "Phone checks wait for the next free window (the phone was touched): $pass passed, $fail failed")}"
          exit 4   # leave the window: the user is on the phone
        fi
        # A check that printed FAIL but exited 0 (float-windows did) failed.
        [ $rc = 0 ] && grep -q '^FAIL' "$log" && rc=1
        # The phone/CDP not answering is the environment, not a product bug: shot.sh refuses a dozing screen and a dead CDP
        # (cdp: no answer within N s) both surface inside a check's own FAIL line (they were counted as product FAILs).
        if [ $rc != 0 ] && [ $rc != 5 ] && ! grep -q '^ENV:' "$log"; then
          envl=$(grep -m1 -E '(^|[^a-z])shot: refused - the screen is|cdp: no answer within [0-9]+ s' "$log"); [ -z "$envl" ] || { echo "ENV: $envl" >> "$log"; rc=5; }; fi
        envskip=0; [ $rc = 5 ] && grep -q '^ENV:' "$log" && envskip=1   # preflight.sh: the phone cannot run it
        # Environment, not product (board: "a phone FAIL means a real product bug"): exit 5 without an ENV: line (a test
        # error), killed by a signal not ours (137 SIGKILL / 143 SIGTERM; our budget kill is rc 124 = FAIL timeout), or
        # the check's first verdict line saying "SKIP:" -> SKIP. Only rc 1 (and other real non-zero rcs) and timeouts FAIL.
        skipwhy=
        if [ $envskip = 0 ] && [ "$why" != timeout ]; then
          if [ $rc = 5 ]; then skipwhy="test error (rc 5): $(grep -m1 -E '^(SKIP|ENV|FAIL)' "$log" | cut -c1-120)"
          elif [ $rc = 137 ] || [ $rc = 143 ]; then skipwhy="killed (rc $rc)"
          elif grep -m1 -E '^(PASS|FAIL|SKIP)' "$log" | grep -q '^SKIP:'; then skipwhy="$(grep -m1 '^SKIP:' "$log" | cut -c7-126)"; fi
        fi
        [ -n "$skipwhy" ] && envskip=1
        mv "$j" "$Q/done/$n.job"
        # (rc 3 gets here only as a FAIL precondition, pfinal; every other rc 3 stays queued, above.)
        if [ -n "$skipwhy" ]; then r="SKIP $skipwhy"; elif [ $envskip = 1 ]; then r="SKIP can't run (ENV): $(sed -n 's/^ENV: //p' "$log" | head -1)"; elif [ -n "$pfinal" ]; then r="FAIL precondition"; elif [ $rc != 0 ] && grep -q '^INVALID' "$log"; then r="INVALID rc=$rc"; else
        r=$([ $rc = 0 ] && echo PASS || { [ "$why" = timeout ] && echo "FAIL timeout" || echo "FAIL rc=$rc"; }); fi; echo "$r: $(tail -1 "$log")" >> "$log"
        prev="${name:-$task}: $r"
        img=
        if [ $rc != 0 ] && [ $rc != 3 ] && [ $envskip = 0 ]; then
          results="${results:-}${name:-$task}"$'\t'"F"$'\n'; fail=$((fail + 1)); [ -n "$first" ] || first=${name:-$task}$([ "$why" = timeout ] && echo ": timeout")
          # What the screen showed when it failed: the board task's review image (the pill keeps out of screencaps).
          f=verify-$(printf %s "$n" | tr -c 'A-Za-z0-9._-' '-').png
          "$phone/adb.sh" shell "su -c 'mkdir -p /data/powos/root/home/powos/design-qa'" >/dev/null 2>&1
          "$phone/shot.sh" --phone "/data/powos/root/home/powos/design-qa/$f" >/dev/null 2>&1 && img=/home/powos/design-qa/$f
        else results="${results:-}${name:-$task}"$'\t'"P"$'\n'; pass=$((pass + 1)); fi
        line=$(grep '^FAIL' "$log" | head -1); [ $rc != 0 ] && [ -n "$line" ] || line=$(tail -2 "$log" | head -1)
        # f94: a check that prints its real version ("VERSION ...", its first line) gets that recorded with the
        # result - so a name that claims a version is checkable against what it actually says it ran on.
        ver=$(head -1 "$log" 2>/dev/null | grep -oE '^VERSION .*' | cut -c1-80)
        [ -z "$skipwhy" ] || line=$r
        board "$task" "verify $r: $(printf %s "$line" | cut -c1-160)${ver:+ ($ver)} (log ~/.cache/powos-verify-queue/done/$n.log)" "$([ $rc = 0 ] && [ -z "$skipwhy" ] && echo $close || echo 0)" "$img"
        echo "$(date +%T) $n: $r"
        case $r in PASS*) uc=pass ;; "FAIL timeout"*) uc=timeout ;; FAIL*|INVALID*) uc=fail ;; *) uc=skip ;; esac
        [ -n "$pfinal" ] && uc=precond   # its last try burnt the time like the others: no verdict worth the seconds
        util_rec J "$t0" "$t1" "$uc" "$n"; util_hourly
      done
      # Only the LATEST result per check counts: a check that failed and then passed in this same window (a re-queue)
      # is a pass, not a stale fail in the notification.
      if [ -n "${results:-}" ]; then
        read -r pass fail first <<<"$(printf '%s' "$results" | awk -F'\t' '{r[$1]=$2} END {p=0;f=0;fs=""; for(k in r){ if(r[k]=="P")p++; else {f++; if(fs=="")fs=k}} print p, f, (fs==""?"-":fs)}')"
        [ "$first" != - ] || first=
      fi
      sum="Phone checks: $pass passed"; [ $fail = 0 ] || sum="$sum, $fail failed ($first$([ $fail -gt 1 ] && echo ", ..."))"
      status "" "{\"done\":true,\"summary\":$(jstr "$sum")}" ) & wait $!
    rc=$?; [ -n "$wpp" ] && endjob "$wpp"   # the wait ended without a window (exit 3/6): its pill writes end before pause's
    [ -e "$WL_WOKE" ] && wl_sleep "$phone"   # woken but no window came (or the window's own wl_done couldn't): settings back
    if [ -n "$nowin" ] && [ $rc = 3 ]; then
      echo "$(date +%T) every queued check waits for its ship - no window taken, looking again in ${NEED_POLL_S:-60} s"
      w0=$(( ${NEED_POLL_S:-60} - ($(date +%s) - w0) )); [ $w0 -gt 0 ] && sleep $w0   # a wait that returned at once (no phone)
    elif [ $rc = 3 ]; then echo "$(date +%T) no free window in ${WAIT_S:-7200}s - waiting again"; fi
    [ $rc = 6 ] && { echo "$(date +%T) stopped from the phone - paused"; pause "Phone checks paused"; }
    [ $rc = 7 ] && sleep "${NEED_POLL_S:-60}"
    # Yielded to an APK install: don't take the phone back until it's done (its wants-phone mark goes), 15 min at most.
    wp=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}/wants-phone
    for _ in $(seq 90); do [ -f "$wp" ] && kill -0 "$(cat "$wp" 2>/dev/null)" 2>/dev/null || break; sleep 10; done   # every queued check waits for a ship: look again in a minute
  done
  RSTATE=idle phone_sh ':' >/dev/null
  wl_sleep "$phone"   # the screen back off if the queue woke it (window-lock.sh)
  rm -f "$Q/runner.pid"; rm -rf "$Q/runner.lock" ;;
run-emu) . "${QUEUE_COPY:-$here}/queue-emu.sh" ;;
*) sed -n 2,23p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
