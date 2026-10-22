#!/bin/bash
# tools/phone/verify/queue.sh: ONE queue for every on-device check, so no agent waits on the phone itself.
#   queue.sh add <board-task> <cmd> [args...]   queue a Mac-side check (a tools/phone/verify/*.sh or any command that
#                                               drives the phone) and return at once; starts the runner if none runs
#        env vars: queue them through env, e.g. `queue.sh add t env PROFILE=1 shell/dev/perf/drag-raster.sh 12`
#   queue.sh list                               queued, running and the last results
#   queue.sh run                                the runner (started by add; exits when the queue is empty)
# The runner waits for ONE free window (window-lock.sh: screen on, no touch for 120 s, then the verify lock), runs every
# queued check in it with LOCK_HELD=1, then releases the lock. A check that exits 3 (a real touch, no window) goes back
# on the queue for the next window, at most 3 tries. Each result goes onto the check's board task (`--step`, the log's
# last line), a mail to the coder inbox (QUEUE_MAIL_TO) and the log stays in ~/.cache/powos-verify-queue/done/. Queue a check and END YOUR TURN: the result shows
# on the board (handbook, Efficiency).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); phone=$(cd "$here/.." && pwd)
Q=$HOME/.cache/powos-verify-queue; mkdir -p "$Q/done"
case "${1:-}" in
add)
  [ $# -ge 3 ] || { echo "usage: queue.sh add <board-task> <cmd> [args...]"; exit 2; }
  task=$2; shift 2
  [ -x "$1" ] || [ -x "$here/$1" ] || command -v "$1" >/dev/null || { echo "queue.sh: not runnable: $1"; exit 2; }
  [ -x "$here/$1" ] && [ ! -x "$1" ] && set -- "$here/$1" "${@:2}"
  j=$Q/$(date +%Y%m%d-%H%M%S)-$$-$task.job
  { printf 'task=%q\ntries=0\ncwd=%q\ncmd=(' "$task" "$PWD"; printf '%q ' "$@"; printf ')\n'; } > "$j"
  echo "queued $(basename "$j" .job) - the result goes to board task $task"
  if [ -z "${QUEUE_NO_RUN:-}" ] && ! kill -0 "$(cat "$Q/runner.pid" 2>/dev/null)" 2>/dev/null; then
    nohup "$0" run >> "$Q/runner.log" 2>&1 & echo $! > "$Q/runner.pid"
  fi ;;
list)
  echo "queued:"; ls "$Q"/*.job 2>/dev/null | sed 's|.*/|  |' || true
  echo "runner: $(kill -0 "$(cat "$Q/runner.pid" 2>/dev/null)" 2>/dev/null && echo running || echo idle)"
  echo "last results:"; ls -t "$Q/done" 2>/dev/null | grep "\.log$" | head -8 | while read -r f; do echo "  $f: $(tail -1 "$Q/done/$f")"; done ;;
run)
  . "$here/window-lock.sh"
  board() {  # board <task> <text>: the result on the owner's task, as the session user on the phone
    local s; s=$(mktemp "$Q/board.XXXX"); { printf 'powos agents task set %q --step %q >/dev/null 2>&1 || true\n' "$1" "$2"
      printf 'powos comms send %q %q --from verify-queue >/dev/null 2>&1 || true\n' "${QUEUE_MAIL_TO:-coder}" "$1: $2"; } > "$s"
    "$phone/user.sh" "$s" >/dev/null 2>&1 || echo "board update failed for $1: $2"; rm -f "$s"; }
  while ls "$Q"/*.job >/dev/null 2>&1; do
    ( window_lock verify-queue 120 "${WAIT_S:-7200}" >/dev/null || exit 3
      for j in "$Q"/*.job; do
        [ -f "$j" ] || continue
        task=; tries=0; cwd=$PWD; cmd=(); . "$j"
        n=$(basename "$j" .job); log=$Q/done/$n.log
        echo "$(date +%T) run $n: ${cmd[*]}"
        ( cd "$cwd" && LOCK_HELD=1 "${cmd[@]}" ) > "$log" 2>&1; rc=$?
        if [ $rc = 3 ] && [ $tries -lt 2 ]; then
          sed -i '' "s/^tries=.*/tries=$((tries + 1))/" "$j"; echo "$(date +%T) $n: no window / touched (rc 3), again next window"
          exit 4   # leave the window: the user is on the phone
        fi
        mv "$j" "$Q/done/$n.job"
        r=$([ $rc = 0 ] && echo PASS || echo "FAIL rc=$rc"); echo "$r: $(tail -1 "$log")" >> "$log"
        board "$task" "verify $r: $(tail -2 "$log" | head -1 | cut -c1-160) (log ~/.cache/powos-verify-queue/done/$n.log)"
        echo "$(date +%T) $n: $r"
      done )
    rc=$?; [ $rc = 3 ] && { echo "$(date +%T) no free window in ${WAIT_S:-7200}s - jobs stay queued"; break; }
  done
  rm -f "$Q/runner.pid" ;;
*) sed -n 2,10p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
