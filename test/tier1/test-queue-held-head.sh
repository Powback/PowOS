#!/bin/bash
# test-queue-held-head.sh: a held job at the head of the queue never ends a window it couldn't run in (11-07 22:51-00:14:
# ww-glue backing off after its rc 3s sorted first, every woken window logged "queued to go first - re-picking the
# window" and "woke the phone for 0 jobs" - 23 queued, one ran in 2 h). Drives queue.sh's own job_held / select_jobs /
# first_waiting with three jobs: a backing-off head, a runnable one, a late runnable one that came in mid-window.
# Also: the runner restarts when window-lock.sh changes, not only queue.sh (the self-input fix sat unloaded all night).
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)/tools/phone/verify/queue.sh
fns=$(sed -n '/^rc3_waits() {/p; /^runner_sum() {/p' "$src")
f2=$(sed -n '/^  job_held() {/,/^    return 1; }$/p; /^  first_waiting() {/,/^    done; return 1; }$/p; /^  select_jobs() {/,/^    done; }$/p' "$src")
[ -n "$fns" ] && [ -n "$f2" ] && grep -q 'first_waiting()' <<<"$f2" && grep -q 'runner_sum()' <<<"$fns" || { echo "FAIL couldn't find the functions in queue.sh"; exit 1; }
eval "$fns"; eval "$f2"
shipped() { return 0; }; closes_game() { return 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/held-head.XXXXXX"); trap 'rm -rf "$T"' EXIT
Q=$T/q; mkdir -p "$Q"
fails=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1${2:+ - $2}"; fails=$((fails + 1)); }
now=$(date +%s)
mk() { printf 'task=%s\ntries=%s\nafter=%s\nneed=\nqt=0\ncwd=.\nrel=0\ncmd=(true)\n' "$2" "$3" "$4" > "$Q/$1.job"; }
mk 20261107-183520-85542-native-windows ww-glue 12 $((now + 1800))   # backing off (rc 3 x12)
mk 20261107-190000-1-other other 0 0
select_jobs "" >/dev/null
[ ${#sel[@]} = 1 ] && [ "$(basename "${sel[0]}")" = 20261107-190000-1-other.job ] && ok "the backing-off head is held, the job behind it is selected" || bad "selection" "${sel[*]}"
go=; j=${sel[0]}
w=$(first_waiting "$j" "$go") && bad "the held head ended the window ('$w queued to go first')" || ok "a held head job doesn't end the window: the runnable job runs"
# Its backoff over (or a fresh job queued before it mid-window): that one does go first.
mk 20261107-183520-85542-native-windows ww-glue 12 $((now - 5))
w=$(first_waiting "$j" "$go") && [ "$w" = 20261107-183520-85542-native-windows ] && ok "once its backoff is over it goes first (re-pick)" || bad "backoff over: re-pick" "w=$w"
mk 20261107-183520-85542-native-windows ww-glue 12 $((now + 1800)); mk 20261107-180000-2-late late 0 0
w=$(first_waiting "$j" "$go") && [ "$w" = 20261107-180000-2-late ] && ok "a runnable job queued ahead mid-window still goes first" || bad "late job first" "w=$w"
# A "test now" of the held task runs it: its job counts again.
rm -f "$Q/20261107-180000-2-late.job"
w=$(first_waiting "$j" ww-glue) ; [ "$w" = 20261107-183520-85542-native-windows ] && ok "test now of the held task: it goes first" || bad "test now" "w=$w"
# runner_sum covers window-lock.sh.
VR=$T/vr; mkdir -p "$VR/tools/phone/verify"; echo a > "$VR/tools/phone/verify/queue.sh"; echo one > "$VR/tools/phone/verify/window-lock.sh"
s1=$(runner_sum "$VR/tools/phone/verify/queue.sh"); echo two > "$VR/tools/phone/verify/window-lock.sh"; s2=$(runner_sum "$VR/tools/phone/verify/queue.sh")
[ "$s1" != "$s2" ] && ok "the runner's sum changes with window-lock.sh (it restarts on a window-lock fix)" || bad "runner_sum ignores window-lock.sh"
grep -q 'QUEUE_SUM=$(runner_sum "$c")' "$src" && grep -q '"$(runner_sum "$VR/tools/phone/verify/queue.sh")" != "$QUEUE_SUM"' "$src" && ok "queue.sh starts and compares with runner_sum" || bad "runner_sum wiring"
[ $fails = 0 ] && echo "all passed" || echo "$fails failed"
exit $(( fails > 0 ))
