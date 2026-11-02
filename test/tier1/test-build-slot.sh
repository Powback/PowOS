#!/bin/bash
# build-slot.sh lanes (f316): quick checks never wait behind a heavy build; 1 heavy at a time; 2 quick at a time;
# a lock left by the pre-lanes version (same dir as heavy) still holds heavy and a dead one is reclaimed.
# Deterministic: no wall-clock assumptions. Every job touches a marker when it holds its slot and then holds it
# until the test touches its release flag; the test waits on those events (generous timeout, only hit on a real
# failure) and never on fixed sleeps, so a slow CI runner only makes it slower, not flaky. ~2 s normally.
set -uo pipefail
B=$(cd "$(dirname "$0")/../.." && pwd)/tools/agents/build-slot.sh
export XDG_CACHE_HOME; XDG_CACHE_HOME=$(mktemp -d)
export BUILD_SLOT_POLL_S=0.1
L=$XDG_CACHE_HOME/log; R=$XDG_CACHE_HOME/release; T=${BUILD_SLOT_TEST_TIMEOUT_S:-60}
pass=0; failn=0; holder=""
finish() {
  touch "$R".all; [ -z "$holder" ] || kill "$holder" 2>/dev/null; wait
  echo "Results: $pass passed, $failn failed"; rm -rf "$XDG_CACHE_HOME"
}
trap finish EXIT
ok() { if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1 [$(diag)]"; failn=$((failn+1)); fi; }
# diag: what the jobs and locks look like at a failure - who holds (marker), who printed a wait, every lock dir.
diag() {
  local f d; printf 'holding:'; for f in "$L".*; do case $f in *.err) ;; *) printf ' %s' "${f##*.}" ;; esac; done
  printf '; err:'; for f in "$L".*.err; do [ -s "$f" ] && printf ' %s=%s' "$(basename "$f" .err)" "$(tr '\n' '|' < "$f")"; done
  printf '; locks:'; for d in "$XDG_CACHE_HOME"/powos-build-slot*; do [ -e "$d" ] && printf ' %s(pid=%s label=%s)' \
    "${d##*/}" "$(cat "$d/pid" 2>/dev/null)" "$(cat "$d/label" 2>/dev/null)"; done
}
# waitfor <cond>: poll until <cond> is true, up to $T s. Events, not durations.
waitfor() { local i=0; while ! eval "$1"; do i=$((i+1)); [ "$i" -le $((T*20)) ] || return 1; sleep 0.05; done; }
# run <name> <label>: a job that marks "holding" and holds its slot until $R.<name> (or $R.all) exists.
run() {
  bash "$B" "$2" -- bash -c "touch '$L.$1'; until [ -e '$R.$1' ] || [ -e '$R.all' ]; do sleep 0.05; done" \
    > "$L.$1.err" 2>&1 &
}
held() { n=0; for q in "$@"; do [ -f "$L.$q" ] && n=$((n+1)); done; echo $n; }
waiting() { grep -l "waiting for $1" "$L".*.err 2>/dev/null | wc -l | tr -d ' '; }

# heavy lane: one at a time; quick lane ignores it
run h1 "build-pkgs kwin"; waitfor '[ -f "$L.h1" ]'
run q1 "compile-check x"; run h2 "build-pkgs b"
waitfor '[ -f "$L.q1" ]'; ok "quick runs beside a heavy" '[ -f "$L.q1" ]'
waitfor 'grep -q "waiting for heavy" "$L.h2.err"'
ok "second heavy waits" '[ ! -f "$L.h2" ] && grep -q "waiting for heavy" "$L.h2.err"'
touch "$R.q1" "$R.h1"; waitfor '[ -f "$L.h2" ]'; ok "second heavy ran after" '[ -f "$L.h2" ]'
touch "$R.h2"; wait

# quick lane: three at once, exactly two hold (which two is a race - count, don't name), the third waits
rm -f "$L".*.err
run q2 "compile-check a"; run q3 "gate b"; run q4 "compile-check c"
waitfor '[ "$(held q2 q3 q4)" -ge 2 ] && [ "$(waiting "quick slot")" -ge 1 ]'
ok "two quick at once, third waits" '[ "$(held q2 q3 q4)" = 2 ] && [ "$(waiting "quick slot")" = 1 ]'
for q in q2 q3 q4; do [ -f "$L.$q" ] && touch "$R.$q"; done
waitfor '[ "$(held q2 q3 q4)" = 3 ]'; ok "third quick ran after" '[ "$(held q2 q3 q4)" = 3 ]'
touch "$R.q2" "$R.q3" "$R.q4"; wait

# old-version lock: heavy dir with a live pid blocks heavy, not quick; once that pid dies it is reclaimed
rm -f "$L".*.err
D=$XDG_CACHE_HOME/powos-build-slot; mkdir "$D"; sleep 600 & holder=$!; echo $holder > "$D/pid"; echo old > "$D/label"
run q5 "compile-check d"; run h3 "build-pkgs z"
waitfor '[ -f "$L.q5" ] && grep -q "waiting for heavy" "$L.h3.err"'
ok "old lock: quick passes, heavy waits" '[ -f "$L.q5" ] && [ ! -f "$L.h3" ]'
kill "$holder"; wait "$holder" 2>/dev/null; holder=""
waitfor '[ -f "$L.h3" ]'; ok "old lock released, heavy ran" '[ -f "$L.h3" ]'
touch "$R.q5" "$R.h3"; wait
mkdir "$D"; echo 999999 > "$D/pid"; run h4 "build-pkgs y"
waitfor '[ -f "$L.h4" ]'; ok "dead lock reclaimed" '[ -f "$L.h4" ]'
touch "$R.h4"; wait
ok "no locks left" '[ -z "$(ls "$XDG_CACHE_HOME" | grep powos-build-slot)" ]'
[ "$failn" = 0 ]
