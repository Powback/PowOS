#!/bin/bash
# test-queue-history.sh: the verify queue uses each check's own history (11-09: 45% of 15336 s of idle windows went to
# verdicts; 16% to 300 s default-budget timeout kills, 12% to checks cut off by the user coming back in short windows,
# 8% to the runner's gaps between jobs).
#   queue-util.py --history  per-script runs/p50/budget from runner.log
#   job_budget               only the 300 s default follows history (shorter for always-fast checks, longer for checks
#                            that pass past 240 s by design, never longer for games, never shorter for installs)
#   order_quick              quickest first, installs before all, never ahead of an earlier job of its own task
#   shipped memo             one shipped_git per (commit, ship records) per window
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd); src=$root/tools/phone/verify/queue.sh; util=$root/tools/phone/verify/queue-util.py
fns=$(sed -n '/^hist_of() {/,/^# rc3_waits/p' "$src")
for f in hist_of job_budget order_quick; do grep -q "^$f() {" <<<"$fns" || { echo "FAIL couldn't find $f in queue.sh"; exit 1; }; done
eval "$fns"
T=$(mktemp -d "${TMPDIR:-/tmp}/qhist.XXXXXX"); trap 'rm -rf "$T"' EXIT
fails=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1${2:+ - $2}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2', want '$3'"; }

# A runner.log: fast.sh 6 runs of 30-50 s, long.sh 3 passes of 280-366 s + a timeout, bf-slow.sh (a game) passes of 290 s,
# kwin-install.sh 6 quick runs, rare.sh 2 runs (too few), an rc 3 run (no verdict: not counted as a completion).
L=$T/runner.log; : > "$L"; t=3600
run() { local n=$1 s=$2 d=$3 v=$4
  printf '%02d:%02d:%02d run %s: env X=1 tools/phone/verify/%s --a\n' $((t / 3600)) $((t % 3600 / 60)) $((t % 60)) "$n" "$s" >> "$L"
  t=$((t + d)); printf '%02d:%02d:%02d %s: %s\n' $((t / 3600)) $((t % 3600 / 60)) $((t % 60)) "$n" "$v" >> "$L"; t=$((t + 5)); }
for d in 30 40 50 35 45 42; do run j$d fast.sh $d "PASS: ok"; done
run jf fast.sh 10 "no window / touched (rc 3), again next window"
for d in 280 366 300; do run l$d long.sh $d "PASS: ok"; done; run lt long.sh 300 "FAIL timeout: still running after its 300s budget - killed"
for d in 290 295 299; do run b$d bf-slow.sh $d "PASS: ok"; done
for d in 20 25 30 22 28 26; do run k$d kwin-install.sh $d "PASS: installed"; done
run r1 rare.sh 20 "FAIL rc=1: x"; run r2 rare.sh 20 "PASS: y"
HIST=$(python3 -I "$util" --history "$L")
eq "fast.sh: 6 completions, longest 50 s -> 2x50+60 = 160 s (the rc 3 try counted as a run, not a completion)" "$(grep '^fast.sh ' <<<"$HIST")" "fast.sh 7 42 160"
eq "long.sh: passes past 240 s -> 1.25 x 366 + 30 = 487 s" "$(grep '^long.sh ' <<<"$HIST" | awk '{print $4}')" 487
eq "bf-slow.sh: a game never gets more than the default" "$(grep '^bf-slow.sh ' <<<"$HIST" | awk '{print $4}')" 0
eq "kwin-install.sh: an install is never cut shorter" "$(grep '^kwin-install.sh ' <<<"$HIST" | awk '{print $4}')" 0
eq "rare.sh: 2 runs - no history budget" "$(grep '^rare.sh ' <<<"$HIST" | awk '{print $4}')" 0
eq "a missing runner.log -> no lines" "$(python3 -I "$util" --history "$T/none")" ""

# hist_of / job_budget
eq "hist_of finds the script inside env/args" "$(hist_of env X=1 tools/phone/verify/fast.sh 3)" "7 42 160"
eq "hist_of inside bash -c \"...\"" "$(hist_of bash -c "cd x && tools/phone/verify/long.sh --a" | awk '{print $3}')" 487
eq "hist_of: unknown check -> empty" "$(hist_of tools/phone/verify/new.sh)" ""
eq "default 300 -> fast.sh's 160" "$(job_budget 300 tools/phone/verify/fast.sh)" 160
eq "default 300 -> long.sh's 487" "$(job_budget 300 tools/phone/verify/long.sh)" 487
eq "an explicit --budget is the caller's" "$(job_budget 450 tools/phone/verify/fast.sh)" 450
eq "no history -> the default" "$(job_budget 300 tools/phone/verify/new.sh)" 300
eq "QUEUE_HIST_BUDGET=0 -> off" "$(QUEUE_HIST_BUDGET=0 job_budget 300 tools/phone/verify/long.sh)" 300
eq "no \$HIST (runner.log unreadable) -> the default" "$(HIST= job_budget 300 tools/phone/verify/long.sh)" 300

# order_quick: long (A), new (B), fast (C), long then fast of task D, kwin-install (E)
mk() { printf 'task=%s\ncmd=(%s)\n' "$3" "$2" > "$T/$1.job"; echo "$T/$1.job"; }
sel=("$(mk 01 'tools/phone/verify/long.sh' A)" "$(mk 02 'tools/phone/verify/new.sh' B)" "$(mk 03 'tools/phone/verify/fast.sh' C)"
     "$(mk 04 'tools/phone/verify/long.sh' D)" "$(mk 05 'tools/phone/verify/fast.sh' D)" "$(mk 06 'tools/phone/verify/kwin-install.sh 3.9' E)")
order_quick; got=$(for j in "${sel[@]}"; do basename "$j" .job; done | tr '\n' ' ')
eq "installs first, then quickest first; task D's fast check stays behind its own earlier long one" "$got" "06 03 02 01 04 05 "
sel=("$T/01.job" "$T/02.job" "$T/03.job"); QUEUE_QUICK_FIRST=0 order_quick
eq "QUEUE_QUICK_FIRST=0 -> queue order" "$(for j in "${sel[@]}"; do basename "$j" .job; done | tr '\n' ' ')" "01 02 03 "
sel=(); order_quick; eq "no jobs -> none" "${#sel[@]}" 0

# The shipped memo: one shipped_git per key per window; a new ship record is a new key.
memo=$(sed -n '/^  shipped() {/,/return \$hit; }$/p' "$src"); [ -n "$memo" ] || bad "couldn't find the shipped memo"
eval "$memo"
calls=0; shipped_git() { calls=$((calls + 1)); [ "$1" = good ]; }
SD=$T/ship; mkdir -p "$SD"; echo L1 > "$SD/live"; export SHIP_DIR=$SD INSTALLED_FILE=$T/inst; echo I1 > "$T/inst"
SHIP_MEMO=$T/memo; : > "$SHIP_MEMO"; now=$(date +%s)
shipped good $now; r1=$?; shipped good $now; r2=$?; shipped bad $now; r3=$?; shipped bad $now; r4=$?
eq "memo: answers kept, one shipped_git per commit" "$r1$r2$r3$r4:$calls" "0011:2"
echo L2 > "$SD/live"; shipped bad $now; eq "a ship mid-window (live changed) asks again" "$calls" 3
SHIP_MEMO= ; shipped good $now; eq "no SHIP_MEMO (outside a window, the tests): straight to shipped_git" "$calls" 4
SHIP_MEMO=$T/memo; shipped "" $now && ok "no need commit -> shipped" || bad "no need -> shipped"

# The runner wires them in.
grep -qF 'select_jobs "$go"; order_quick; order_jobs' "$src" && ok "runner: order_quick before order_jobs" || bad "runner: order_quick"
grep -qF 'hb=$(job_budget "$budget" "${cmd[@]}")' "$src" && ok "runner: job_budget per job" || bad "runner: job_budget"
grep -qF 'queue-util.py" --history "$Q/runner.log"' "$src" && ok "runner: history once per window" || bad "runner: history"
grep -qF 'SHIP_MEMO=$Q/shipmemo; : > "$SHIP_MEMO"' "$src" && ok "runner: a fresh memo per window" || bad "runner: memo per window"
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
