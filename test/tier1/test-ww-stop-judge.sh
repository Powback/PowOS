#!/bin/bash
# test-ww-stop-judge.sh: ww-stop.sh's verdict on window-render.sh --hidden's output (board task
# linux-web-window-stop-takes-2-1-s-after-d9d7edcd): the stop time is read from its PASS line's "linux stopMs=N" and
# gated below 2 s; a NOT JUDGED run (rc 2) and a Linux step that didn't run stay queued (3), never a PASS.
set -uo pipefail
s=$(cd "$(dirname "$0")/../.." && pwd)/tools/phone/verify/ww-stop.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/ww-stop.XXXXXX"); trap 'rm -rf "$T"' EXIT
fails=0
pass_line() { printf 'linux: (c) stop returned in %s ms\nwindow-render: PASS (hidden: task 9 on display 98 drew the app, the tap reached it; linux stopMs=%s; 41 s) - /x\n' "$1" "$1"; }
case_() {  # case_ <name> <want rc> <window-render rc> <output>
  printf '%s\n' "$4" > "$T/out"; got=$("$s" --parse "$T/out" "$3"); rc=$?
  [ "$rc" = "$2" ] && echo "PASS $1 (rc $rc: $got)" || { echo "FAIL $1: rc $rc, want $2 ($got)"; fails=$((fails + 1)); }; }
case_ fast 0 0 "$(pass_line 87)"
case_ slow 1 0 "$(pass_line 2100)"
case_ blocked 1 0 "$(pass_line -1)"
case_ no-stopms 1 0 "window-render: PASS (hidden: task 9 on display 98 drew the app, the tap reached it; 41 s) - /x"
case_ not-judged 3 2 "window-render: NOT JUDGED (the phone is Dozing) - /x"
case_ not-run 3 0 "linux: not run (web windows don't take Linux windows here)
$(pass_line -1 | tail -1)"
case_ render-fail 1 1 "FAIL: linux: the consumer's stop took 1500 ms (want <= 1000; -1 = still blocked after 3 s)
window-render: FAIL (hidden: linux) - /x"
exit $fails
