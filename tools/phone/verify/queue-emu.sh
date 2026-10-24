# shellcheck shell=bash
# tools/phone/verify/queue-emu.sh (sourced by `queue.sh run-emu`): the emulator lane's runner. Jobs queued with
# `queue.sh add --dev emu ...` ($Q/emu/*.job) run at once, one after another, against the emulator (tools/emu/emu.sh,
# POWOS_DEVICE=emu): no free phone window, no verify lock (nobody uses the emulator), no status pill. Before them the
# emulator is started from its snapshot and runs the APK of origin's tip - a job whose commit that build lacks gets the
# newer build first (the lane's ship wait). Same budget kill, same PASS / FAIL / INVALID rules and logs
# ($Q/done/<job>.log) as the phone's runner; each result goes onto the board task (the board lives on the phone: when it
# can't be reached, the result waits in $Q/emu/pending/ and is sent with the next one). One runner (its lock
# $Q/emu/runner.lock), in its own checkout ($POWOS_RUN_ROOT/emu-runner, at origin's tip), from a private copy.
[ -n "$REPO" ] || { echo "queue.sh run-emu: not in a PowOS checkout"; exit 2; }
mkdir -p "$E/pending" "$Q/done"
ls "$E"/*.job >/dev/null 2>&1 || exit 0
L=$E/runner.lock
if [ "$(cat "$L/pid" 2>/dev/null)" != $$ ]; then
  if ! mkdir "$L" 2>/dev/null; then
    alive_runner "$(cat "$L/pid" 2>/dev/null)" && { echo "$(date +%T) emu runner already running"; exit 0; }
    rm -rf "$L"; mkdir "$L" 2>/dev/null || exit 0
  fi
  echo $$ > "$L/pid"
fi
# A private copy (bash reads a script as it runs; checkouts get pulled into) from the lane's checkout at origin's tip.
if [ -z "${QUEUE_COPY:-}" ]; then
  cd "$HOME" || exit 1
  src=$here
  if [ -z "${QUEUE_NO_TREE:-}" ]; then verify_tree "$ET" || exit 1; src=$ET/tools/phone/verify; fi
  c=$(mktemp -d "${TMPDIR:-/tmp}/powos-queue-emu.XXXXXX") && cp "$src/queue.sh" "$src/queue-emu.sh" "$c/" || exit 1
  QUEUE_COPY=$c QUEUE_HERE=$src exec bash "$c/queue.sh" run-emu
fi
trap 'rm -rf "$QUEUE_COPY" "$L"' EXIT
trap 'for c in $(pgrep -P $$); do killtree $c; done; exit 143' TERM
ER=$(cd "$here/../../.." && pwd -P)   # the checkout the jobs run in (the lane's, or this one under QUEUE_NO_TREE)
emu() { "$ER/tools/emu/emu.sh" "$@" >> "$E/runner.log" 2>&1; }
emu_commit() { POWOS_DEVICE=emu "$phone/adb.sh" shell cat /data/local/tmp/powos-emu-commit 2>/dev/null | tr -d '\r'; }
# flush: the results the board hasn't taken yet, oldest first (the phone may be off the VPN).
flush() { local f
  for f in "$E"/pending/*.sh; do [ -f "$f" ] || continue
    perl -e 'alarm shift; exec @ARGV' 30 "$phone/user.sh" "$f" >/dev/null 2>&1 && rm -f "$f" || { echo "$(date +%T) board not reachable - $(ls "$E"/pending/*.sh | wc -l | tr -d ' ') results wait"; return 0; }
  done; }
# result <job> <n> <r> <line> <shipped>: the result for the board (pending until it's taken).
result() { local s st=${3%% *}
  s=$(printf 'powos agents check set %q %q %q --name %q --line %q --need %q --shipped %s >/dev/null 2>&1 || true\n' \
      "$task" "$2" "$st" "emu:${name:-$task}" "$(printf %s "$4" | cut -c1-280)" "$need" "$5"
    if [ "$st" = SKIP ] || [ "$st" = INVALID ]; then
      printf 'powos friction add --area verify --kind flaky-check %q --repro %q --evidence %q --by verify-queue >/dev/null 2>&1 || true\n' \
        "emulator check ${name:-$task} was $st: $(printf %s "$4" | cut -c1-100)" "tools/phone/verify/queue.sh add --dev emu $task $(printf %s "${cmd[*]}" | cut -c1-200)" "~/.cache/powos-verify-queue/done/$2.log"; fi
    printf 'powos agents task set %q --step %q >/dev/null 2>&1 || true\n' "$task" "emulator $3: $(printf %s "$4" | cut -c1-160) (log ~/.cache/powos-verify-queue/done/$2.log)"
    [ "$st" = PASS ] && [ "$close" = 1 ] && printf 'powos agents task done %q >/dev/null 2>&1 || true\n' "$task")
  printf '%s\n' "$s" > "$E/pending/$2.sh"; }
flush
while ls "$E"/*.job >/dev/null 2>&1; do
  verify_tree "$ET" >/dev/null 2>&1 || true
  echo "$(date +%T) emulator up (origin's tip)"
  if ! emu start; then
    echo "$(date +%T) the emulator didn't come up - every job INVALID ($E/runner.log)"
    for j in "$E"/*.job; do [ -f "$j" ] || continue
      task=; close=0; name=; need=; cmd=(); . "$j"; n=$(basename "$j" .job)
      echo "INVALID: the emulator didn't start (tools/emu/emu.sh start; $E/runner.log)" > "$Q/done/$n.log"
      mv "$j" "$Q/done/$n.job"; result "$j" "$n" "INVALID" "the emulator didn't start" 0; done
    flush; break
  fi
  ec=$(emu_commit)
  for j in "$E"/*.job; do
    [ -f "$j" ] || continue
    task=; close=0; cwd=$ER; rel=0; from=; name=; budget=300; need=; cmd=(); . "$j"
    [ "$rel" = 1 ] && cwd=$ER/$cwd
    n=$(basename "$j" .job); log=$Q/done/$n.log
    # Nobody is watching the emulator between jobs (unlike the phone, where sleeping is the user's choice): keep its
    # screen on right before every job, not just at boot - the phone's "never wake the screen" rule in e2e-lib.sh
    # must never apply here (f72, 2026-10-24).
    emu wake
    # The ship wait: a job from a commit the emulator's build lacks (pushed after it) gets origin's newer tip first.
    if [ -n "$need" ] && git -C "$ER" cat-file -e "$need^{commit}" 2>/dev/null && ! git -C "$ER" merge-base --is-ancestor "$need" "$ec" 2>/dev/null; then
      verify_tree "$ET" >/dev/null 2>&1 || true; echo "$(date +%T) $n: needs ${need:0:9} - building origin's tip for the emulator"; emu install; ec=$(emu_commit)
    fi
    sh=1; [ -n "$need" ] && git -C "$ER" cat-file -e "$need^{commit}" 2>/dev/null && ! git -C "$ER" merge-base --is-ancestor "$need" "$ec" 2>/dev/null && sh=0
    echo "$(date +%T) run $n on the emulator: ${cmd[*]}"
    ( cd "$cwd" && export POWOS_DEVICE=emu LOCK_HELD=1 && exec "${cmd[@]}" ) > "$log" 2>&1 & jp=$!
    t0=$(date +%s); why=
    while kill -0 $jp 2>/dev/null; do sleep 1; [ $(( $(date +%s) - t0 )) -ge "$budget" ] && { why=timeout; endjob $jp; break; }; done
    wait $jp; rc=$?
    [ "$why" = timeout ] && { rc=124; echo "FAIL timeout: still running after its ${budget}s budget - killed" >> "$log"; }
    [ $rc = 0 ] && grep -q '^FAIL' "$log" && rc=1
    if [ $rc = 0 ]; then r=PASS; elif [ $rc = 3 ]; then r="SKIP rc=3"; elif grep -q '^INVALID' "$log"; then r="INVALID rc=$rc"
    elif [ "$why" = timeout ]; then r="FAIL timeout"; else r="FAIL rc=$rc"; fi
    echo "$r: $(tail -1 "$log")" >> "$log"
    mv "$j" "$Q/done/$n.job"
    line=$(grep '^FAIL' "$log" | head -1); [ $rc != 0 ] && [ -n "$line" ] || line=$(tail -2 "$log" | head -1)
    result "$j" "$n" "$r" "$line" "$sh"; flush
    echo "$(date +%T) $n: $r"
  done
done
