#!/bin/bash
# tools/phone/verify/queue.sh: ONE queue for every on-device check, so no agent waits on the phone itself.
#   queue.sh add [--close] [--name TEXT] [--screen inner|cover] [--budget S] <board-task> <cmd> [args...]
#        queue a Mac-side check (a tools/phone/verify/*.sh or any command that drives the phone) and return at once;
#        starts the runner if none runs, and marks the board task's step "phone check queued" (the AI page's "test now")
#        env vars: queue them through env, e.g. `queue.sh add t env PROFILE=1 shell/dev/perf/drag-raster.sh 12`
#        --close: a PASS also marks the board task done (use when this check is the task's last proof)
#        --name: what the phone's status pill says is being tested (default: the script's name)
#        --screen: the screen it needs (the pill asks to fold / unfold); default either
#        --budget: seconds it may run (default 300); past it the runner kills it: "FAIL timeout" on the board and pill
#   queue.sh list                               queued, running, paused and the last results
#   queue.sh pause | resume                     pause the runner (what the pill's tap does) / resume it (go=all)
#   queue.sh run                                the runner: launchd's agent com.powos.verify-runner (runner-deploy.sh)
#        starts it when add kicks it (launchctl kickstart) and again if it dies; without the agent, add starts one. Stays while anything is queued.
# The runner waits for ONE free window (window-lock.sh: screen on, no touch for 120 s, then the verify lock), runs every
# queued check in it with LOCK_HELD=1, then releases the lock. "Test now" on the AI page (VerifyRun.kt) writes the phone's
# go flag (/tmp/powos-verify-go in PowOS: a task id or "all"): the wait returns at once and only that task's checks run.
# While a check runs, the phone shows a status pill (VerifyRun.kt, fed /run/powos-app/verify/status.json): a heartbeat
# every HB_S (4) s carries the check, k/N, elapsed time and the SUB-STEP with its own time ("waiting for the game window
# · 45 s": the check's /tmp/powos-verify-step - bf-lib.sh pill - else its log's last line); no beat for 30 s and the pill hides itself. Its tap writes
# /tmp/powos-verify-stop, which the next beat sees: the check is killed and stays queued. A check that exits 3 (a real touch, no window)
# goes back on the queue for the next window, at most 3 tries (a stop from the pill doesn't count). A check that exits 0
# but printed a line starting with FAIL is a FAIL. Each result goes onto the check's board task (`--step`, the log's
# last line; a FAIL also gets a screenshot as its review image), a mail to the coder inbox (QUEUE_MAIL_TO) and the log
# stays in ~/.cache/powos-verify-queue/done/. Queue a check and END YOUR TURN: the result shows on the board (handbook,
# Efficiency). Paused (the pill's tap, `queue.sh pause`: ~/.cache/powos-verify-queue/paused): the runner stays up but
# runs nothing until the phone's go flag (the AI page's "resume", "test all", "test now"); its state goes to the phone's
# /data/local/tmp/powos-verify-runner (waiting | paused | running | idle), the waits touch it every 5 s (the heartbeat
# the AI page reads: paused or stale -> "checks paused · resume"). Paths: a job queued from inside any PowOS worktree is stored repo-relative and runs in the runner's own
# checkout (.claude/worktrees/verify-runner, fast-forwarded to origin before each window), so removing the worktree it
# came from is fine - push before you queue. The runner runs a private copy of that checkout's queue.sh.
set -uo pipefail
here=${QUEUE_HERE:-$(cd "$(dirname "$0")" && pwd -P)}; unset QUEUE_HERE; phone=${QUEUE_PHONE:-$(cd "$here/.." && pwd -P)}
BASE=worktree-powos-multiplatform
REPO=$(cd "$here" && cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")" 2>/dev/null && pwd -P || true)
[ "$REPO" = / ] && REPO=
VR=$REPO/.claude/worktrees/verify-runner   # the runner's checkout: only the runner touches it
Q=${QUEUE_DIR:-$HOME/.cache/powos-verify-queue}; mkdir -p "$Q/done"
QUEUED_STEP="phone check queued"   # shell/ui/powai.tsx matches this text
# user_sh <script text>: run it inside PowOS as the session user (its `powos ...`), quietly.
user_sh() { local s; s=$(mktemp "$Q/user.XXXX"); printf '%s\n' "$1" > "$s"; "$phone/user.sh" "$s" >/dev/null 2>&1; local rc=$?; rm -f "$s"; return $rc; }
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
# phone_sh <script>: run it in PowOS as root; killed after 15 s (a hung adb never holds the runner). RSTATE set: the
# runner's state word for the AI page goes to the phone's /data/local/tmp/powos-verify-runner first (its heartbeat).
phone_sh() { local b; b=$(printf '%s\n' "$1" | base64 | tr -d '\n')
  perl -e 'alarm shift; exec @ARGV' 15 "$phone/adb.sh" shell "${RSTATE:+printf $RSTATE > /data/local/tmp/powos-verify-runner; }su -c 'sh /data/powos/powos-run.sh \"echo $b | base64 -d | bash\"'" 2>/dev/null; }
# wt_of <abs path>: the PowOS worktree it lies in (wroot) and the path under it (wsub, "" = the root); fails outside.
wt_of() {
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
  local up= a R=${REPO//./\\.} out=()
  [ -n "$1" ] && up=$(printf %s "$1/" | sed -E 's#[^/]+#..#g')
  for a in "${cmd[@]}"; do
    out+=("$(printf %s "$a" | sed -E "s#$R/\.claude/worktrees/[A-Za-z0-9._-]+/#$up#g; s#$R/\.claude/worktrees/[A-Za-z0-9._-]+\$#${up:-./}#; s#$R/#$up#g; s#^$R\$#${up:-./}#")")
  done
  cmd=("${out[@]}"); cwd=${1:-.}; rel=1
}
# verify_tree: the runner's checkout - made if missing (shell/node_modules linked from powos-multiplatform), then
# fast-forwarded to origin's tip.
verify_tree() {
  [ -z "${QUEUE_NO_TREE:-}" ] || return 0   # tests: never touch the real runner's checkout
  git -C "$REPO" fetch -q origin "$BASE" || echo "verify checkout: fetch failed - running on what it has"
  if [ ! -e "$VR/.git" ]; then
    git -C "$REPO" worktree add -q --detach "$VR" "origin/$BASE" || { echo "verify checkout: can't create $VR"; return 1; }
  else
    # Only the runner uses it: a check that left files changed doesn't hold it back.
    git -C "$VR" merge -q --ff-only "origin/$BASE" 2>/dev/null || { echo "verify checkout: not a fast-forward - reset to origin"
      git -C "$VR" reset -q --hard "origin/$BASE"; }
  fi
  local nm=$REPO/.claude/worktrees/powos-multiplatform/shell/node_modules
  [ -e "$VR/shell/node_modules" ] || [ ! -d "$nm" ] || ln -s "$nm" "$VR/shell/node_modules"
}
case "${1:-}" in
add)
  shift; close=0; name=; screen=; budget=300
  while :; do case "${1:-}" in
    --close) close=1; shift ;; --name) name=${2:-}; shift 2 ;; --screen) screen=${2:-}; shift 2 ;;
    --budget) budget=${2:-}; shift 2 ;; *) break ;; esac; done
  [ $# -ge 2 ] || { echo "usage: queue.sh add [--close] [--name TEXT] [--screen inner|cover] [--budget S] <board-task> <cmd> [args...]"; exit 2; }
  [[ $budget =~ ^[1-9][0-9]*$ ]] || { echo "queue.sh: --budget <seconds>"; exit 2; }
  task=$1; shift
  [[ $task =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$ ]] || { echo "queue.sh: bad task id: $task"; exit 2; }
  case "$screen" in ""|inner|cover) ;; *) echo "queue.sh: --screen inner|cover"; exit 2 ;; esac
  [ -x "$1" ] || [ -x "$here/$1" ] || command -v "$1" >/dev/null || { echo "queue.sh: not runnable: $1"; exit 2; }
  [ -x "$here/$1" ] && [ ! -x "$1" ] && set -- "$here/$1" "${@:2}"
  if [ -z "$name" ]; then  # the script's name (past `env A=1 ...`)
    for a in "$@"; do case "$a" in */env|env|*=*) ;; *) name=$(basename "$a"); break ;; esac; done; name=${name%.sh}
  fi
  # Repo-relative when queued from (or running a command inside) a PowOS worktree: it runs in the verify checkout.
  cmd=("$@"); cwd=$(pwd -P); rel=0; from=
  if wt_of "$cwd"; then from=$wroot; relify "$wsub"
  else for a in "$@"; do wt_of "$a" && { from=$wroot; relify ""; break; }; done; fi
  # need: the queuing tree's commit - the check waits until the phone runs it (see shipped below), so a check queued
  # right after `ship.sh request` doesn't FAIL against the old build (prompt-glyph, icon-norm, 2026-10-23).
  need=; [ -n "$from" ] && need=$(git -C "$from" rev-parse HEAD 2>/dev/null || true)
  j=$Q/$(date +%Y%m%d-%H%M%S)-$$-$task.job
  { printf 'task=%q\nclose=%s\ntries=0\ncwd=%q\nrel=%s\nfrom=%q\nname=%q\nscreen=%q\nbudget=%s\nneed=%s\nqt=%s\ncmd=(' "$task" "$close" "$cwd" "$rel" "$from" "$name" "$screen" "$budget" "$need" "$(date +%s)"
    printf '%q ' "${cmd[@]}"; printf ')\n'; } > "$j"
  echo "queued $(basename "$j" .job) - the result goes to board task $task"
  if [ -z "${QUEUE_NO_RUN:-}" ]; then
    # The board marker: the AI page offers "test now" on a task whose step says so (the result's step replaces it).
    ( user_sh "$(printf 'powos agents task set %q --step %q >/dev/null 2>&1 || true' "$task" "$QUEUED_STEP")" & ) >/dev/null 2>&1
    # The launchd agent's runner, started now; without the agent, a runner of our own.
    runner_up || agent_kick || { nohup "$0" run >> "$Q/runner.log" 2>&1 & echo $! > "$Q/runner.pid"; }
  fi ;;
pause)  # what the pill's tap does: the runner (waiting or mid-check) sees the phone's stop flag within 5 s
  touch "$Q/paused"
  runner_up && phone_sh 'umask 022; : > /tmp/powos-verify-stop'
  echo "paused: nothing runs until resume (queue.sh resume, or resume / test all on the AI page)" ;;
resume)  # the AI page's resume: the go flag (go=all) the runner's wait watches
  rm -f "$Q/paused"
  runner_up && phone_sh 'umask 022; printf all > /tmp/.powos-verify-go && mv -f /tmp/.powos-verify-go /tmp/powos-verify-go'
  echo "resumed$(runner_up && echo ': every queued check runs now' || echo ' (no runner up: the next job starts one)')" ;;
list)
  echo "queued:"; ls "$Q"/*.job 2>/dev/null | sed 's|.*/|  |' || true
  echo "runner: $(runner_up && echo running || echo idle)$([ -e "$Q/paused" ] && echo ", PAUSED (queue.sh resume)")$(agent_loaded && echo " (launchd $LABEL)")"
  echo "last results:"; ls -t "$Q/done" 2>/dev/null | grep "\.log$" | head -8 | while read -r f; do echo "  $f: $(tail -1 "$Q/done/$f")"; done ;;
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
    QUEUE_SUM=$(cksum < "$c") QUEUE_COPY=$c QUEUE_HERE=$VR/tools/phone/verify exec bash "$c" run
  fi
  rm -f "$QUEUE_COPY"; unset QUEUE_COPY   # bash keeps it open
  . "$here/window-lock.sh"
  board() {  # board <task> <text> [done] [image]: the result on the owner's task (closed too when done=1), as the session user
    local s; s=$(printf 'powos agents task set %q --step %q %s >/dev/null 2>&1 || true\n' "$1" "$2" "${4:+--image $(printf %q "$4")}"
      # Mail only what needs acting on (a FAIL, not a PASS or SKIP; QUEUE_MAIL_ALL=1 mails passes too): a pass is on the board already, and
      # each mail wakes the coordinator for a full turn (the self-optimize round, 2026-10-23: the top token cost).
      if [[ $2 == *FAIL* ]] || [ "${QUEUE_MAIL_ALL:-0}" = 1 ]; then
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
  logstep() { tail -c 6000 "$1" 2>/dev/null | perl -CSD -ne 's/\r/\n/g; for (split /\n/) { s/\e\[[0-9;?]*[A-Za-z]//g;
      s/^-- \d\d:\d\d:\d\d //; s/[[:cntrl:]"\\|&]//g; s/^\s+|\s+$//g;
      next if $_ eq "" || /\d+ files? (pushed|pulled|skipped)|bytes in [\d.]+ ?s\)|^\[\s*\d+%\]|^adb: |Broken pipe|^\d+(\.\d+)? [KM]B\/s/; $l = $_ }
      END { $l //= ""; print length($l) > 60 ? substr($l, 0, 59) . "\x{2026}" : $l }'; }
  killtree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c" "${2:-TERM}"; done; kill -"${2:-TERM}" "$1" 2>/dev/null; }
  # endjob <pid>: TERM its tree, KILL what's left after 5 s.
  endjob() { killtree "$1"; for _ in 1 2 3 4 5; do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done; killtree "$1" KILL; }
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
  shipped() {
    local c=$1 live inst; [ -n "$c" ] || return 0
    [ $(( $(date +%s) - ${2:-0} )) -lt "${NEED_MAX_S:-7200}" ] || return 0
    git -C "$VR" cat-file -e "$c^{commit}" 2>/dev/null || return 0
    live=$(cat "${SHIP_DIR:-$HOME/.cache/powos-ship-queue}/live" 2>/dev/null); inst=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null)
    if [ -n "$inst" ] && ! git -C "$VR" merge-base --is-ancestor "$c" "$inst" 2>/dev/null \
       && [ -n "$(ship_paths "$inst" "$c" targets/android/app; ship_paths "$inst" "$c" targets/android/build-app.sh)" ]; then return 1; fi
    [ -z "$live" ] || git -C "$VR" merge-base --is-ancestor "$c" "$live" 2>/dev/null \
      || [ -z "$(ship_paths "$(git -C "$VR" merge-base "$live" "$c" 2>/dev/null)" "$c" shell)" ]; }
  # pause <summary>: the user's stop - recorded (the runner stays, runs nothing until the phone's go flag), the pill gone.
  pause() { touch "$Q/paused"; RSTATE=paused status "" "{\"done\":true,\"summary\":$(jstr "$1 · resume on the AI page")}"; }
  # The runner stays while anything is queued (a "test now" needs one waiting): a window that didn't come is waited for again.
  while ls "$Q"/*.job >/dev/null 2>&1; do
    verify_tree
    # A fix to the runner itself takes effect between windows: the pulled queue.sh differs from the copy it started
    # from -> start again from it (same pid: the runner lock stays ours). Before, a fix waited for the runner to end -
    # with checks always queued, never (2026-10-23).
    if [ -n "${QUEUE_SUM:-}" ] && [ -z "${QUEUE_NO_TREE:-}" ] && [ "$(cksum < "$VR/tools/phone/verify/queue.sh" 2>/dev/null)" != "$QUEUE_SUM" ]; then
      echo "$(date +%T) queue.sh changed on origin - the runner starts again from it"; unset QUEUE_SUM
      exec bash "$VR/tools/phone/verify/queue.sh" run
    fi
    # Paused: the wait returns for the go flag only (resume / test all / test now), never for a free window.
    if [ -e "$Q/paused" ]; then export GO_ONLY=1 VERIFY_STATE=paused; echo "$(date +%T) paused - waiting for resume on the phone"
    else unset GO_ONLY; export VERIFY_STATE=waiting; fi
    ( export VERIFY_GO=1 WL_PHONE=$phone
      window_lock verify-queue "${QUEUE_IDLE_S:-120}" "${WAIT_S:-7200}" >/dev/null || exit 3
      rm -f "$Q/paused"; RSTATE=running   # a go ends a pause
      go=; case "${WL_GOT:-}" in go=*) go=${WL_GOT#go=}; go=${go%% *} ;; esac
      sel=(); held=0
      for j in "$Q"/*.job; do
        [ -f "$j" ] || continue
        task=; need=; qt=0; . "$j"
        [ -z "$go" ] || [ "$go" = all ] || [ "$task" = "$go" ] || continue
        # Not on the phone yet: it waits for its ship (a "test now" of exactly this task runs it anyway).
        if [ "$task" != "$go" ] && ! shipped "$need" "$qt"; then held=$((held + 1)); echo "$(date +%T) $(basename "$j" .job): waits for its ship (${need:0:9})"; continue; fi
        sel+=("$j")
      done
      N=${#sel[@]}; k=0; pass=0; fail=0; first=; prev=
      [ $N -gt 0 ] || { status "" '{"done":true}' "rm -f /tmp/powos-verify-go"; [ $held = 0 ] && exit 5; exit 7; }
      [ -n "$go" ] && echo "$(date +%T) go from the phone: $go ($N checks)"
      for j in "${sel[@]}"; do
        [ -f "$j" ] || continue
        # An APK install waits for this window (ship-apk wrote wants-phone): yield before the next check - the install
        # restarts the app anyway, and the rest run in the next window against the new build.
        wp=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}/wants-phone
        if [ -f "$wp" ] && kill -0 "$(cat "$wp" 2>/dev/null)" 2>/dev/null; then
          echo "$(date +%T) yielding the window to an APK install ($((N - k)) checks wait for the next window)"
          status "" "{\"done\":true,\"summary\":$(jstr "Phone checks paused for an update install: $pass passed, $fail failed")}"
          exit 4
        fi
        # The checkout to origin's tip before EACH job, not just each window: a window can last an hour, and a check
        # pushed after it began was missing ("No such file", rc 126/127, 2026-10-23).
        verify_tree >/dev/null 2>&1 || true
        task=; close=0; tries=0; cwd=$PWD; rel=0; from=; name=; screen=; budget=300; need=; qt=0; cmd=(); . "$j"
        # A job from before repo-relative jobs: its worktree may be gone - run it in the verify checkout instead.
        if [ "$rel" != 1 ] && [[ "$cwd ${cmd[*]}" == *"$REPO/.claude/worktrees/"* ]]; then
          if wt_of "$cwd"; then relify "$wsub"; else relify ""; fi
        fi
        [ "$rel" = 1 ] && cwd=$VR/$cwd
        n=$(basename "$j" .job); log=$Q/done/$n.log; k=$((k + 1))
        echo "$(date +%T) run $n: ${cmd[*]}"
        js() { printf '{"name":%s,"task":%s,"k":%s,"n":%s,"screen":%s,"el":%s,"budget":%s,"prev":"@@HINT@@","step":"@@STEP@@","stepel":@@STEPEL@@}' \
          "$(jstr "${name:-$task}")" "$(jstr "$task")" $k $N "$(jstr "$screen")" "$1" "$budget"; }
        status "$n" "$(js 0)" "$([ $k = 1 ] && echo 'rm -f /tmp/powos-verify-go')"
        ( cd "$cwd" && unset VERIFY_GO && export LOCK_HELD=1 && exec "${cmd[@]}" ) > "$log" 2>&1 & jp=$!
        # The heartbeat: every HB_S s the pill hears check, k/N, elapsed; a tap's stop flag or the budget ends the check.
        # The sub-step: the check's own (put) or its log's last line, timed from when that line first showed.
        t0=$(date +%s); why=; ls_=; lt=$t0
        while kill -0 $jp 2>/dev/null; do
          for _ in $(seq "${HB_S:-4}"); do kill -0 $jp 2>/dev/null || break; sleep 1; done
          kill -0 $jp 2>/dev/null || break
          el=$(( $(date +%s) - t0 ))
          [ $el -ge "$budget" ] && { why=timeout; break; }
          l=$(logstep "$log"); [ "$l" = "$ls_" ] || { ls_=$l; lt=$(date +%s); }
          if [ "$(beat "$(js $el)" "$ls_" $(( $(date +%s) - lt )))" = stop ]; then
            # A stop counts only from a real finger: an injected tap (the manager's QA agent driving the phone hit the
            # pill at 04:09, no touch for 91 min) leaves the touch counters untouched (idle.sh), so it's ignored.
            ti=$("$phone/idle.sh" 2>/dev/null | sed -n 's/.*idle=\([0-9]*\).*/\1/p')
            if [ -n "$ti" ] && [ "$ti" -gt 30 ]; then
              echo "$(date +%T) $n: stop flag without a real touch (idle ${ti}s) - ignored"; phone_sh 'rm -f /tmp/powos-verify-stop' >/dev/null
            else why=stop; break; fi
          fi
        done
        [ -n "$why" ] && endjob $jp
        wait $jp; rc=$?
        if [ "$why" = timeout ]; then
          rc=124; echo "FAIL timeout: still running after its ${budget}s budget - killed" >> "$log"
          echo "$(date +%T) $n: past its ${budget}s budget - killed"
        fi
        if [ "$why" = stop ]; then
          echo "$(date +%T) $n: stopped from the phone - stays queued, paused"
          pause "Phone checks paused: $pass passed, $fail failed, $((N - k + 1)) still queued"
          exit 4
        fi
        if [ $rc = 3 ] && [ $tries -lt 5 ]; then
          sed -i '' "s/^tries=.*/tries=$((tries + 1))/" "$j"; echo "$(date +%T) $n: no window / touched (rc 3), again next window"
          # Leave the window only when the user really came back (a finger in the last QUEUE_IDLE_S): rc 3 also means
          # "not on the phone yet" (plasma-notify: no PlasmaBridge in the APK), which ended every window at its first
          # job while the user was away charging (01:46, 18 checks never ran).
          idl=$("$phone/idle.sh" 2>/dev/null | sed -n 's/.*idle=\([0-9]*\).*/\1/p')
          if [ -n "$idl" ] && [ "$idl" -ge "${QUEUE_IDLE_S:-120}" ]; then
            echo "$(date +%T) $n: rc 3 but the phone is still idle (${idl}s) - next check"; continue
          fi
          status "" "{\"done\":true,\"summary\":$(jstr "Phone checks wait for the next free window (the phone was touched): $pass passed, $fail failed")}"
          exit 4   # leave the window: the user is on the phone
        fi
        # A check that printed FAIL but exited 0 (float-windows did) failed.
        [ $rc = 0 ] && grep -q '^FAIL' "$log" && rc=1
        mv "$j" "$Q/done/$n.job"
        # rc 3 six times = the user kept using the phone: a SKIP (no mail, not a fail), not a bug in the check.
        if [ $rc = 3 ]; then r="SKIP phone in use"; else
        r=$([ $rc = 0 ] && echo PASS || { [ "$why" = timeout ] && echo "FAIL timeout" || echo "FAIL rc=$rc"; }); fi; echo "$r: $(tail -1 "$log")" >> "$log"
        prev="${name:-$task}: $r"
        img=
        if [ $rc != 0 ] && [ $rc != 3 ]; then
          fail=$((fail + 1)); [ -n "$first" ] || first=${name:-$task}$([ "$why" = timeout ] && echo ": timeout")
          # What the screen showed when it failed: the board task's review image (the pill keeps out of screencaps).
          f=verify-$(printf %s "$n" | tr -c 'A-Za-z0-9._-' '-').png
          "$phone/adb.sh" shell "su -c 'mkdir -p /data/powos/root/home/powos/design-qa'" >/dev/null 2>&1
          "$phone/shot.sh" --phone "/data/powos/root/home/powos/design-qa/$f" >/dev/null 2>&1 && img=/home/powos/design-qa/$f
        else pass=$((pass + 1)); fi
        line=$(grep '^FAIL' "$log" | head -1); [ $rc != 0 ] && [ -n "$line" ] || line=$(tail -2 "$log" | head -1)
        board "$task" "verify $r: $(printf %s "$line" | cut -c1-160) (log ~/.cache/powos-verify-queue/done/$n.log)" "$([ $rc = 0 ] && echo $close || echo 0)" "$img"
        echo "$(date +%T) $n: $r"
      done
      sum="Phone checks: $pass passed"; [ $fail = 0 ] || sum="$sum, $fail failed ($first$([ $fail -gt 1 ] && echo ", ..."))"
      status "" "{\"done\":true,\"summary\":$(jstr "$sum")}" ) & wait $!
    rc=$?; [ $rc = 3 ] && echo "$(date +%T) no free window in ${WAIT_S:-7200}s - waiting again"
    [ $rc = 6 ] && { echo "$(date +%T) stopped from the phone - paused"; pause "Phone checks paused"; }
    [ $rc = 7 ] && sleep "${NEED_POLL_S:-60}"
    # Yielded to an APK install: don't take the phone back until it's done (its wants-phone mark goes), 15 min at most.
    wp=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}/wants-phone
    for _ in $(seq 90); do [ -f "$wp" ] && kill -0 "$(cat "$wp" 2>/dev/null)" 2>/dev/null || break; sleep 10; done   # every queued check waits for a ship: look again in a minute
  done
  RSTATE=idle phone_sh ':' >/dev/null
  wl_sleep "$phone"   # the screen back off if the queue woke it (window-lock.sh)
  rm -f "$Q/runner.pid"; rm -rf "$Q/runner.lock" ;;
*) sed -n 2,15p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
