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
#   queue.sh list                               queued, running and the last results
#   queue.sh run                                the runner (started by add; stays while anything is queued)
# The runner waits for ONE free window (window-lock.sh: screen on, no touch for 120 s, then the verify lock), runs every
# queued check in it with LOCK_HELD=1, then releases the lock. "Test now" on the AI page (VerifyRun.kt) writes the phone's
# go flag (/tmp/powos-verify-go in PowOS: a task id or "all"): the wait returns at once and only that task's checks run.
# While a check runs, the phone shows a status pill (VerifyRun.kt, fed /run/powos-app/verify/status.json): a heartbeat
# every HB_S (4) s carries the check, k/N and elapsed time; no beat for 30 s and the pill hides itself. Its tap writes
# /tmp/powos-verify-stop, which the next beat sees: the check is killed and stays queued. A check that exits 3 (a real touch, no window)
# goes back on the queue for the next window, at most 3 tries (a stop from the pill doesn't count). A check that exits 0
# but printed a line starting with FAIL is a FAIL. Each result goes onto the check's board task (`--step`, the log's
# last line; a FAIL also gets a screenshot as its review image), a mail to the coder inbox (QUEUE_MAIL_TO) and the log
# stays in ~/.cache/powos-verify-queue/done/. Queue a check and END YOUR TURN: the result shows on the board (handbook,
# Efficiency). Paths: a job queued from inside any PowOS worktree is stored repo-relative and runs in the runner's own
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
runner_up() { kill -0 "$(cat "$Q/runner.pid" 2>/dev/null)" 2>/dev/null; }
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
  j=$Q/$(date +%Y%m%d-%H%M%S)-$$-$task.job
  { printf 'task=%q\nclose=%s\ntries=0\ncwd=%q\nrel=%s\nfrom=%q\nname=%q\nscreen=%q\nbudget=%s\ncmd=(' "$task" "$close" "$cwd" "$rel" "$from" "$name" "$screen" "$budget"
    printf '%q ' "${cmd[@]}"; printf ')\n'; } > "$j"
  echo "queued $(basename "$j" .job) - the result goes to board task $task"
  if [ -z "${QUEUE_NO_RUN:-}" ]; then
    # The board marker: the AI page offers "test now" on a task whose step says so (the result's step replaces it).
    ( user_sh "$(printf 'powos agents task set %q --step %q >/dev/null 2>&1 || true' "$task" "$QUEUED_STEP")" & ) >/dev/null 2>&1
    runner_up || { nohup "$0" run >> "$Q/runner.log" 2>&1 & echo $! > "$Q/runner.pid"; }
  fi ;;
list)
  echo "queued:"; ls "$Q"/*.job 2>/dev/null | sed 's|.*/|  |' || true
  echo "runner: $(runner_up && echo running || echo idle)"
  echo "last results:"; ls -t "$Q/done" 2>/dev/null | grep "\.log$" | head -8 | while read -r f; do echo "  $f: $(tail -1 "$Q/done/$f")"; done ;;
run)
  [ -n "$REPO" ] || { echo "queue.sh run: not in a PowOS checkout"; exit 2; }
  if [ -z "${QUEUE_COPY:-}" ]; then
    # A private copy of the verify checkout's queue.sh: bash reads a script as it runs, and checkouts get pulled into.
    verify_tree || exit 1
    c=$(mktemp "${TMPDIR:-/tmp}/powos-queue.XXXXXX") && cp "$VR/tools/phone/verify/queue.sh" "$c" || exit 1
    QUEUE_COPY=$c QUEUE_HERE=$VR/tools/phone/verify exec bash "$c" run
  fi
  rm -f "$QUEUE_COPY"; unset QUEUE_COPY   # bash keeps it open
  . "$here/window-lock.sh"
  board() {  # board <task> <text> [done] [image]: the result on the owner's task (closed too when done=1), as the session user
    local s; s=$(printf 'powos agents task set %q --step %q %s >/dev/null 2>&1 || true\n' "$1" "$2" "${4:+--image $(printf %q "$4")}"
      printf 'powos comms send %q %q --from verify-queue >/dev/null 2>&1 || true\n' "${QUEUE_MAIL_TO:-coder}" "$1: $2"
      [ "${3:-0}" = 1 ] && printf 'powos agents task done %q >/dev/null 2>&1 || true\n' "$1")
    user_sh "$s" || echo "board update failed for $1: $2"; }
  jstr() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
  # status <job mark> <json> [more]: the pill's file (VerifyRun.kt watches /run/powos-app/verify/status.json; the old
  # verify-status.json too, for APKs before the heartbeat), the job mark, the stop flag cleared; [more]: more shell
  # (clearing the go flag). One adb call, at most 15 s.
  status() { phone_sh "$(printf 'umask 022; %s; printf %%s %q > /tmp/powos-verify-job; rm -f /tmp/powos-verify-stop; %s' "$(put "$2")" "$1" "${3:-:}")" >/dev/null; }
  # beat <json>: the heartbeat - the pill's file again; prints "stop" when the pill's tap wrote the stop flag.
  beat() { phone_sh "$(printf 'umask 022; %s; [ -e /tmp/powos-verify-stop ] && echo stop; :' "$(put "$1")")" | tr -d '\r' | tail -1; }
  put() { local f
    for f in verify/status.json verify-status.json; do
      printf 'mkdir -p /run/powos-app/verify; printf %%s %q > /run/powos-app/%s.tmp && mv -f /run/powos-app/%s.tmp /run/powos-app/%s; ' "$1" "$f" "$f" "$f"; done; printf ':'; }
  # phone_sh <script>: run it in PowOS as root; killed after 15 s (a hung adb never holds the runner).
  phone_sh() { local b; b=$(printf '%s\n' "$1" | base64 | tr -d '\n')
    perl -e 'alarm shift; exec @ARGV' 15 "$phone/adb.sh" shell "su -c 'sh /data/powos/powos-run.sh \"echo $b | base64 -d | bash\"'" 2>/dev/null; }
  killtree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do killtree "$c" "${2:-TERM}"; done; kill -"${2:-TERM}" "$1" 2>/dev/null; }
  # endjob <pid>: TERM its tree, KILL what's left after 5 s.
  endjob() { killtree "$1"; for _ in 1 2 3 4 5; do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done; killtree "$1" KILL; }
  # `kill <runner.pid>` stops the window and its check too, frees the verify lock if this runner held it, and hides the pill.
  trap 'for c in $(pgrep -P $$); do killtree $c; done; [ "$(cut -d" " -f1 "$HOME/.cache/powos-verify.lock/who" 2>/dev/null)" = verify-queue ] && rm -rf "$HOME/.cache/powos-verify.lock"; status "" "{\"done\":true,\"summary\":\"Phone checks stopped (the runner was stopped)\"}"; rm -f "$Q/runner.pid"; exit 143' TERM
  # The runner stays while anything is queued (a "test now" needs one waiting): a window that didn't come is waited for again.
  while ls "$Q"/*.job >/dev/null 2>&1; do
    verify_tree
    ( export VERIFY_GO=1
      window_lock verify-queue "${QUEUE_IDLE_S:-120}" "${WAIT_S:-7200}" >/dev/null || exit 3
      go=; case "${WL_GOT:-}" in go=*) go=${WL_GOT#go=}; go=${go%% *} ;; esac
      sel=()
      for j in "$Q"/*.job; do
        [ -f "$j" ] || continue
        task=; . "$j"
        [ -z "$go" ] || [ "$go" = all ] || [ "$task" = "$go" ] && sel+=("$j")
      done
      N=${#sel[@]}; k=0; pass=0; fail=0; first=; prev=
      [ $N -gt 0 ] || { status "" '{"done":true}' "rm -f /tmp/powos-verify-go"; exit 5; }
      [ -n "$go" ] && echo "$(date +%T) go from the phone: $go ($N checks)"
      for j in "${sel[@]}"; do
        [ -f "$j" ] || continue
        task=; close=0; tries=0; cwd=$PWD; rel=0; from=; name=; screen=; budget=300; cmd=(); . "$j"
        # A job from before repo-relative jobs: its worktree may be gone - run it in the verify checkout instead.
        if [ "$rel" != 1 ] && [[ "$cwd ${cmd[*]}" == *"$REPO/.claude/worktrees/"* ]]; then
          if wt_of "$cwd"; then relify "$wsub"; else relify ""; fi
        fi
        [ "$rel" = 1 ] && cwd=$VR/$cwd
        n=$(basename "$j" .job); log=$Q/done/$n.log; k=$((k + 1))
        echo "$(date +%T) run $n: ${cmd[*]}"
        js() { printf '{"name":%s,"task":%s,"k":%s,"n":%s,"screen":%s,"el":%s,"budget":%s,"prev":%s}' "$(jstr "${name:-$task}")" \
          "$(jstr "$task")" $k $N "$(jstr "$screen")" "$1" "$budget" "$(jstr "$prev")"; }
        status "$n" "$(js 0)" "$([ $k = 1 ] && echo 'rm -f /tmp/powos-verify-go')"
        ( cd "$cwd" && unset VERIFY_GO && export LOCK_HELD=1 && exec "${cmd[@]}" ) > "$log" 2>&1 & jp=$!
        # The heartbeat: every HB_S s the pill hears check, k/N, elapsed; a tap's stop flag or the budget ends the check.
        t0=$(date +%s); why=
        while kill -0 $jp 2>/dev/null; do
          for _ in $(seq "${HB_S:-4}"); do kill -0 $jp 2>/dev/null || break; sleep 1; done
          kill -0 $jp 2>/dev/null || break
          el=$(( $(date +%s) - t0 ))
          [ $el -ge "$budget" ] && { why=timeout; break; }
          [ "$(beat "$(js $el)")" = stop ] && { why=stop; break; }
        done
        [ -n "$why" ] && endjob $jp
        wait $jp; rc=$?
        if [ "$why" = timeout ]; then
          rc=124; echo "FAIL timeout: still running after its ${budget}s budget - killed" >> "$log"
          echo "$(date +%T) $n: past its ${budget}s budget - killed"
        fi
        if [ "$why" = stop ]; then
          echo "$(date +%T) $n: stopped from the phone - stays queued"
          status "" "{\"done\":true,\"summary\":$(jstr "Phone checks stopped: $pass passed, $fail failed, $((N - k + 1)) still queued")}"
          exit 4
        fi
        if [ $rc = 3 ] && [ $tries -lt 2 ]; then
          sed -i '' "s/^tries=.*/tries=$((tries + 1))/" "$j"; echo "$(date +%T) $n: no window / touched (rc 3), again next window"
          status "" "{\"done\":true,\"summary\":$(jstr "Phone checks paused (the phone was touched): $pass passed, $fail failed")}"
          exit 4   # leave the window: the user is on the phone
        fi
        # A check that printed FAIL but exited 0 (float-windows did) failed.
        [ $rc = 0 ] && grep -q '^FAIL' "$log" && rc=1
        mv "$j" "$Q/done/$n.job"
        r=$([ $rc = 0 ] && echo PASS || { [ "$why" = timeout ] && echo "FAIL timeout" || echo "FAIL rc=$rc"; }); echo "$r: $(tail -1 "$log")" >> "$log"
        prev="${name:-$task}: $r"
        img=
        if [ $rc != 0 ]; then
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
  done
  rm -f "$Q/runner.pid" ;;
*) sed -n 2,13p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
