#!/bin/bash
# shellcheck disable=SC2034  # out/rc are read inside ok()'s eval strings
# shell/dev/gate.sh always ends with a verdict line, and the job bookkeeping (tools/jobs/job.sh job_gc,
# job_disk_guard) never changes it. 11-26: apps ship d3e7e83c1's gate printed four ok scenes and then nothing, rc 1 -
# the widget block turned set -e back on and its grep found no line in a dead sweep's log. No docker, no browser.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
G=$ROOT/shell/dev/gate.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 failn=0
ok() { if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; failn=$((failn+1)); fi; }

# 1. After the browser section's EXIT trap the gate never turns set -e back on.
trap_line=$(grep -n "^trap 'grc=\$?" "$G" | cut -d: -f1)
ok "gate.sh has the verdict EXIT trap" '[ -n "$trap_line" ]'
ok "no set -e after it" '! tail -n +"${trap_line:-1}" "$G" | grep -qE "^[[:space:]]*set -e[[:space:]]*$"'
ok "the widget-log filter cannot end the gate" 'grep -F "\"\$work/widgets.log\" | sed" "$G" | grep -q "|| true$"'
ok "the final line carries the exit" 'grep -q "gate_verdict=1" "$G" && grep -q "pushed file(s)\")) - exit \$fail\"" "$G"'

# 2. The trap itself: an exit before the summary prints the no-verdict line with its rc; after the verdict, nothing.
trap_text=$(sed -n "${trap_line},$((trap_line + 1))p" "$G")
cat > "$T/early.sh" <<EOS
set -e
hostload_pid=999999 work=$T/w slot=
kill_containers() { :; }; job_cleanup() { :; }
$trap_text
echo "ok   app x (1 ms)"
false
echo unreachable
EOS
out=$(bash "$T/early.sh" 2>&1); rc=$?
ok "early exit: rc kept (1)" '[ $rc = 1 ]'
ok "early exit: no-verdict line with the rc" 'printf "%s" "$out" | grep -q "^gate: FAIL - ended before its verdict (exit 1"'
sed 's/^false$/gate_verdict=1; echo "gate: pass in 1 s (head) - exit 0"/' "$T/early.sh" > "$T/done.sh"
out=$(bash "$T/done.sh" 2>&1); rc=$?
ok "verdict printed: rc 0, no extra line" '[ $rc = 0 ] && ! printf "%s" "$out" | grep -q "ended before its verdict"'

# 3. The bookkeeping returns 0 when the engine or the machine can't be asked.
. "$ROOT/tools/jobs/job.sh"
export JOB_CTX=powos-test-no-such-context JOB_ON_HUB=""
ok "job_gc: no engine -> 0" 'job_gc gate >/dev/null 2>&1'
ok "job_disk_guard: unknown context -> 0 (no false refusal)" 'job_disk_guard >/dev/null 2>&1'
export JOB_ON_HUB=1
ok "job_disk_guard: the hub -> 0" 'job_disk_guard >/dev/null 2>&1'

echo "test-gate-verdict: $pass passed, $failn failed"
[ "$failn" = 0 ]
