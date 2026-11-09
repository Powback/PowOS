#!/bin/bash
# powos-rooted-session's keep(): a session process that exits (11-08 16:55 powos-sleep-gui died unseen and launches
# were never announced again - steam-launch-placeholder) is started again, with a back-off, and says so in its log.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'kill $kp 2>/dev/null; rm -rf "$T"' EXIT
eval "$(sed -n '/^keep() {/,/^}/p' "$ROOT/targets/android/rooted/powos-rooted-session")"
type keep >/dev/null 2>&1 || { echo "FAIL: no keep() in powos-rooted-session"; exit 1; }
grep -q '^bg powos-sleep-gui keep as_user powos-sleep-gui$' "$ROOT/targets/android/rooted/powos-rooted-session" ||
  { echo "FAIL: powos-sleep-gui is not started through keep"; exit 1; }
( keep sh -c "echo run >> '$T/runs'; exit 3" ) > "$T/log" 2>&1 & kp=$!
sleep 7.5; kill $kp 2>/dev/null; wait $kp 2>/dev/null
n=$(wc -l < "$T/runs" | tr -d ' ')
fail=0
[ "$n" -ge 2 ] && [ "$n" -le 4 ] || { echo "FAIL: ran $n times in 7.5 s (want 2-4: 2 s, 4 s back-off)"; fail=1; }
grep -q 'keep: sh -c .* exited (rc 3), again in 2 s' "$T/log" || { echo "FAIL: no exit line: $(cat "$T/log")"; fail=1; }
grep -q 'again in 4 s' "$T/log" || { echo "FAIL: no back-off: $(cat "$T/log")"; fail=1; }
[ $fail = 0 ] && echo "test-session-keep: ok ($n runs)"; exit $fail
