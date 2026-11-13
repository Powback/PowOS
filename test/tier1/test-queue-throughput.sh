#!/bin/bash
# test-queue-throughput.sh: the verify queue spends the phone's idle windows on verdicts (11-07 03:3x: six ABZU fps runs
# of ~85 s each ended rc 3, logged "no window / touched", with idle=507 - retried forever while the phone sat in the
# switcher; the user: "most if not all the mobile testing time gets spent idle").
#   rc3_kind      touched only when the input source (idle.sh's idle) is shorter than the run; else early / precond
#   rc3_precond   counts precond tries; the runner turns the 3rd into "FAIL precondition", not another retry
#   game_key / order_jobs   same-game jobs back to back, the others in queue order
#   queue-util.py the utilization line from util.log and from an old runner.log
# Drives queue.sh's own functions (the runner needs a phone).
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd); src=$root/tools/phone/verify/queue.sh; util=$root/tools/phone/verify/queue-util.py
fns=$(sed -n '/^rc3_kind() {/,/^  echo precond; }$/p; /^rc3_precond() {/,/echo "\$p"; }$/p; /^warm_takes() {/p; /^warm_after() {/p; /^game_key() {/,/^  \[ \$g = 1 \] && echo/p; /^order_jobs() {/,/^  sel=(/p' "$src")
for f in rc3_kind rc3_precond warm_takes warm_after game_key order_jobs; do
  grep -q "^$f() {" <<<"$fns" || { echo "FAIL couldn't find $f in queue.sh"; exit 1; }; done
eval "$fns"
T=$(mktemp -d "${TMPDIR:-/tmp}/qthru.XXXXXX"); trap 'rm -rf "$T"' EXIT
fails=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1${2:+ - $2}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2', want '$3'"; }

# rc3_kind <elapsed> <idle>
eq "ABZU 03:34: 85 s run, idle 368 s -> precond (nobody touched it)" "$(rc3_kind 85 368)" precond
eq "a finger 10 s ago during an 85 s run -> touched" "$(rc3_kind 85 10)" touched
eq "idle unknown (idle.sh offline) -> touched (the safe old meaning)" "$(rc3_kind 85 '')" touched
eq "perf-scenarios 'need 600 s idle' after 3 s -> early (not ready yet, cheap)" "$(rc3_kind 3 208)" early

# rc3_precond: ptries counted in the job, one line
j=$T/a.job; printf 'task=t\ntries=0\ncmd=(true)\n' > "$j"
eq "1st precond try" "$(rc3_precond "$j")" 1
eq "2nd precond try" "$(rc3_precond "$j")" 2
eq "3rd precond try (the runner's cap)" "$(rc3_precond "$j")" 3
[ "$(grep -c '^ptries=' "$j")" = 1 ] && ok "one ptries= line" || bad "one ptries= line" "$(cat "$j")"

# The runner: precond at the cap -> FAIL precondition (a verdict, the job leaves the queue); touched/early stay queued.
grep -q 'kind=$(rc3_kind $((t1 - t0)) "$idl")' "$src" && ok "runner classifies rc 3 from the idle source" || bad "runner uses rc3_kind"
grep -q 'ge "${QUEUE_PRECOND_MAX:-3}" ]; then' "$src" && grep -q 'echo "FAIL precondition: ' "$src" && grep -q 'rc=1; pfinal=1' "$src" \
  && ok "precond at QUEUE_PRECOND_MAX -> FAIL precondition with its reason" || bad "precond cap -> FAIL precondition"
grep -q 'r="FAIL precondition"' "$src" && ok "board verdict reads FAIL precondition" || bad "FAIL precondition verdict"

# game_key
eq "env APP= bf-pacing" "$(game_key env APP=384190 WIN_NAME=AbzuGame tools/phone/verify/bf-pacing.sh env:TU_DEBUG=startup)" 384190
eq "game-resize.sh <appid>" "$(game_key tools/phone/verify/game-resize.sh 557340)" 557340
eq "bf-* without APP = Broforce" "$(game_key tools/phone/verify/bf-pacing.sh base)" 274190
eq "a non-game check has no key" "$(game_key tools/phone/verify/folder-clip.sh 3)" ""
# warm_takes <dir> <cmd...>: only a bf-pacing.sh that reads the warm marker (11-07 12:08: frozen copies in
# ~/.cache/abzu-tools had no hand-over, took the queue's ABZU for the user's, and it stayed up for window-bench).
mkdir -p "$T/new/v" "$T/old/v"; echo 'WM=/data/powos/root/var/tmp/powos-warm-$APP' > "$T/new/v/bf-pacing.sh"; echo 'echo no hand-over' > "$T/old/v/bf-pacing.sh"
warm_takes "$T/new" env APP=1 v/bf-pacing.sh base && ok "bf-pacing (relative, knows the marker) takes a warm game" || bad "bf-pacing takes a warm game"
warm_takes / env APP=1 "$T/new/v/bf-pacing.sh" base && ok "bf-pacing (absolute path) takes a warm game" || bad "absolute bf-pacing takes a warm game"
warm_takes / env APP=1 "$T/old/v/bf-pacing.sh" base && bad "a frozen bf-pacing copy without the hand-over must not get the warm game" || ok "a frozen bf-pacing copy without the hand-over gets no warm game"
warm_takes "$T/new" x/game-resize.sh 384190 && bad "game-resize must not take a warm game" || ok "game-resize doesn't take a warm game"
grep -qF 'warm_takes "$cwd" "${cmd[@]}"' "$src" && ok "runner: warm_takes from the next job's own dir" || bad "runner: warm_takes with the job's dir"

# warm_after <log> <gk>: the warm-stop rule - a game is warm only while a WARM: line hands it on; else it is closed
Q=$T/q; mkdir -p "$Q"; stopped=0; warm_stop() { [ -s "$Q/warm" ] && stopped=$((stopped + 1)); rm -f "$Q/warm"; }
echo 'WARM: AbzuGame left running for the next check of app 384190' > "$T/w.log"; echo 'the user'"'"'s AbzuGame is up and awake (they play it?) - skip' > "$T/n.log"
warm_after "$T/w.log" 384190; eq "WARM: line -> the game stays warm for the next job" "$(cat "$Q/warm" 2>/dev/null):$stopped" "384190:0"
warm_after "$T/n.log" 384190; eq "12:08 case: handed the warm game, no WARM: (rc 3 early) -> closed at once" "$(cat "$Q/warm" 2>/dev/null):$stopped" ":1"
warm_after "$T/n.log" ""; eq "nothing warm, a non-game job -> nothing to close" "$(cat "$Q/warm" 2>/dev/null):$stopped" ":1"
echo 384190 > "$Q/warm"; warm_after "$T/w.log" ""; eq "a stray WARM: from a non-game job never keeps a game" "$(cat "$Q/warm" 2>/dev/null):$stopped" ":2"
grep -qF 'warm_after "$log" "$gk"' "$src" && ok "runner: warm_after after every job" || bad "runner: warm_after after every job"
grep -qF '[ -s "$Q/warm" ] && [ "$(cat "$Q/warm")" != "$gk" ] && warm_stop' "$src" && ok "runner: a warm game closed before a job of another app" || bad "runner: warm_stop before another app's job"

# order_jobs: ABZU, window-bench, ABZU, resize ABZU, perf, Besiege -> ABZU x3 back to back where the first was
mk() { printf 'task=%s\ncmd=(%s)\n' "${3:-t$1}" "$2" > "$T/$1.job"; echo "$T/$1.job"; }
sel=("$(mk 01 'env APP=384190 bf-pacing.sh base')" "$(mk 02 'window-bench.sh --round before')" "$(mk 03 'env APP=384190 bf-pacing.sh env:X=1')"
     "$(mk 04 'game-resize.sh 384190')" "$(mk 05 'perf-scenarios.sh --only swipe')" "$(mk 06 'game-resize.sh 346010')")
order_jobs; got=$(for j in "${sel[@]}"; do basename "$j" .job; done | tr '\n' ' ')
eq "same-game jobs back to back, the rest in queue order" "$got" "01 03 04 02 05 06 "
# 11-08 00:57: a games job (game-audio), the fps task's installs, then its fps measurement: the measurement must not be
# pulled into the games job's group ahead of its own task's installs (it measured the old KWin/Xwayland twice).
sel=("$(mk 11 'bash -c "cd x && /tmp/game-audio-run.sh"' audio)" "$(mk 12 'pkg-install.sh xwayland-kgsl-14.pkg' bf)" "$(mk 13 'kwin-install.sh 3.73' bf)"
     "$(mk 14 'bf-pacing.sh play' bf)" "$(mk 15 'game-present-rate.sh' stall)" "$(mk 16 'bf-pacing.sh play' bf)")
order_jobs; got=$(for j in "${sel[@]}"; do basename "$j" .job; done | tr '\n' ' ')
eq "a job never runs ahead of its own task's earlier jobs (installs first); other tasks still group" "$got" "11 15 12 13 14 16 "
sel=(); order_jobs; eq "no jobs -> none" "${#sel[@]}" 0

# queue-util.py: util.log -> useful vs wasted
cat > "$T/util.log" <<'EOF'
J 1000 1200 pass a
J 1205 1290 precond b
J 1292 1300 early c
J 1302 1400 fail d
W 1000 1500
EOF
out=$(python3 -I "$util" "$T/util.log")
eq "util.log line" "$out" "utilization: 1 windows, 500s window time, 298s on 2 verdicts (59%); wasted 202s: early 8s, precond 85s, gaps 109s"
printf 'J 1500 1800 timeout e\nW 1500 1800\n' >> "$T/util.log"
eq "timeouts named" "$(python3 -I "$util" "$T/util.log")" "utilization: 2 windows, 800s window time, 598s on 3 verdicts (74% - 300s of it timeouts); wasted 202s: early 8s, precond 85s, gaps 109s"
eq "--since drops older records" "$(python3 -I "$util" --since 5000 "$T/util.log")" "utilization: 0 windows, 0s window time, 0s on 0 verdicts (0%); wasted 0s: none, gaps 0s"
# ... and from an old runner.log: an rc 3 followed by "still idle" counts as precond
cat > "$T/runner.log" <<'EOF'
03:32:55 run x-abz: env APP=384190 tools/phone/verify/bf-pacing.sh env:TU_DEBUG=startup
03:34:20 x-abz: no window / touched (rc 3), again next window
03:34:21 x-abz: rc 3 but the phone is still idle (368s) - next check
03:34:23 run y-abz: env APP=384190 tools/phone/verify/bf-pacing.sh base
03:37:23 y-abz: PASS
EOF
eq "runner.log line" "$(python3 -I "$util" --runner-log "$T/runner.log")" "utilization: 1 windows, 268s window time, 180s on 1 verdicts (67%); wasted 88s: precond 85s, gaps 3s"

# The runner records it: per job, per window, hourly, and in summary.
for p in 'util_rec J "$t0" "$t1" "$uc" "$n"; util_hourly' 'trap '"'"'warm_stop; util_rec W "$wopen" "$(date +%s)"; wl_done; wl_release'"'"' EXIT' \
         'order_quick; order_jobs' 'util_line --since "$se"' 'QUEUE_NEXT_APP=$nextapp'; do
  grep -qF "$p" "$src" && ok "runner: $p" || bad "runner wiring missing" "$p"; done

# A skipped check is NOT a passing check. Execute the runner's actual accounting branch without a device.
# This includes rc=0 + SKIP: (a check may skip successfully), not just environment errors.
account=$(sed -n '/^        if \[ \$envskip = 1 \]; then$/,/^        else results=.*pass=.*fi$/p' "$src")
summary=$(grep 'read -r pass fail skipped first' "$src")
[ -n "$account" ] && [ -n "$summary" ] || { bad "runner skip accounting found"; exit 1; }
for rc in 0 5 137 143; do
  results=; name=window-check; task=windows; pass=0; fail=0; skipped=0; envskip=1
  eval "$account"
  eval "$summary"
  eq "SKIP rc=$rc never becomes PASS or FAIL" "$pass:$fail:$skipped" "0:0:1"
done
# Only the latest attempt per name counts, including a skip after a pass and a real pass after a skip.
results=$'window-check\tP\nwindow-check\tS\nother-check\tF\n'; eval "$summary"
eq "latest SKIP supersedes earlier PASS" "$pass:$fail:$skipped:$first" "0:1:1:other-check"
results=$'window-check\tS\nwindow-check\tP\n'; eval "$summary"
eq "real retry PASS supersedes SKIP" "$pass:$fail:$skipped:$first" "1:0:0:-"
grep -qF '$skipped skipped (not judged)' "$src" && ok "notification names unjudged checks" || bad "notification names unjudged checks"

echo; [ $fails = 0 ] && { echo "All tests passed"; exit 0; }; echo "$fails tests failed"; exit 1
