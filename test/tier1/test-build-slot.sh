#!/bin/bash
# build-slot.sh lanes (f316): quick checks never wait behind a heavy build; 1 heavy at a time; 2 quick at a time;
# a lock left by the pre-lanes version (same dir as heavy) still holds heavy and a dead one is reclaimed. ~6 s.
set -uo pipefail
B=$(cd "$(dirname "$0")/../.." && pwd)/tools/agents/build-slot.sh
export XDG_CACHE_HOME; XDG_CACHE_HOME=$(mktemp -d); trap 'rm -rf "$XDG_CACHE_HOME"' EXIT
export BUILD_SLOT_POLL_S=0.1
L=$XDG_CACHE_HOME/log; fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=1; fi; }
run() { bash "$B" "$2" -- bash -c "echo start >> $L.$1; sleep $3; echo end >> $L.$1" > "$L.$1.err" 2>&1 & }

run h1 "build-pkgs kwin" 2; sleep 0.4
run q1 "compile-check x" 0.5; run h2 "build-pkgs b" 0.5; sleep 0.3
ok "quick runs beside a heavy" '[ -f "$L.q1" ]'
ok "second heavy waits" '[ ! -f "$L.h2" ] && grep -q "waiting for heavy" "$L.h2.err"'
wait
ok "second heavy ran after" '[ -f "$L.h2" ]'

run q2 "compile-check a" 1; run q3 "gate b" 1; run q4 "compile-check c" 0.2; sleep 0.5
ok "two quick at once, third waits" '[ -f "$L.q2" ] && [ -f "$L.q3" ] && [ ! -f "$L.q4" ]'
wait
ok "third quick ran after" '[ -f "$L.q4" ]'

# old-version lock: heavy dir with a live pid blocks heavy, not quick; a dead pid is reclaimed
D=$XDG_CACHE_HOME/powos-build-slot; mkdir "$D"; sleep 3 & echo $! > "$D/pid"; echo old > "$D/label"
run q5 "compile-check d" 0.1; run h3 "build-pkgs z" 0.1; sleep 1
ok "old lock: quick passes, heavy waits" '[ -f "$L.q5" ] && [ ! -f "$L.h3" ]'
wait
ok "old lock released, heavy ran" '[ -f "$L.h3" ]'
mkdir "$D"; echo 999999 > "$D/pid"; run h4 "build-pkgs y" 0.1; wait
ok "dead lock reclaimed" '[ -f "$L.h4" ]'
ok "no locks left" '[ -z "$(ls "$XDG_CACHE_HOME" | grep powos-build-slot)" ]'
exit $fails
