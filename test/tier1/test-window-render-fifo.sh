#!/bin/bash
# test-window-render-fifo.sh - the ship's device window check can never hang on its helper's stdin fifo, nor hold the
# ship service (11-11 14:50: window-render.sh --hidden PASSed, then its cleanup's `echo release 145 > .../in` blocked
# forever - the helper reading that fifo had exited - and every ship waited 2.5 h).
#   fifo_put_cmd  (window-render.sh, the phone-side write) against real fifos: no reader + helper gone -> "gone" at once;
#                 helper pid alive but nobody reading -> returns at once (1<>, never `>`); a live reader gets the line.
#   mt            bounds a hanging command and its whole process group, also behind a pipe (rc 124).
#   gate_deadline (ship.sh) KILLs a check whose TERM trap starts a new hanging child after the first sweep.
#   no raw `> $dir/in` write left in window-render.sh.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WR=$ROOT/tools/phone/verify/window-render.sh SH=$ROOT/tools/phone/ship.sh
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   - $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL - $1"; }
t=$(mktemp -d "${TMPDIR:-/tmp}/wr-fifo.XXXXXX"); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$t"' EXIT
eval "$(sed -n '/^# >>> fifo-bounds/,/^# <<< fifo-bounds/p' "$WR")"
eval "$(grep -E '^(killtree|gate_deadline)\(\)' "$SH")"
type mt fifo_put_cmd killtree gate_deadline >/dev/null 2>&1 && ok "helpers extracted" || { bad "helpers missing"; exit 1; }
secs() { local s=$SECONDS; "$@"; echo $((SECONDS - s)); }

# 1. No reader, helper gone (no pid file): skipped, never opened.
mkfifo "$t/in"
r=$(mt 10 sh -c "$(fifo_put_cmd "$t" "release 145")"); rc=$?
[ $rc = 0 ] && [ "$r" = gone ] && ok "no helper: '$r' at once" || bad "no helper: rc $rc '$r' (124 = it blocked)"
# 2. The helper's pid file names a dead process: gone.
sh -c 'exit 0' & dead=$!; wait $dead; echo $dead > "$t/helper"
r=$(mt 10 sh -c "$(fifo_put_cmd "$t" "release 145")"); rc=$?
[ $rc = 0 ] && [ "$r" = gone ] && ok "dead helper pid: '$r'" || bad "dead helper pid: rc $rc '$r'"
# 3. The helper alive but nothing reads the fifo (the 11-11 case with a pid still around): the write returns at once.
sleep 30 & alive=$!; echo $alive > "$t/helper"
r=$(mt 10 sh -c "$(fifo_put_cmd "$t" "release 145")"); rc=$?
[ $rc = 0 ] && [ "$r" = sent ] && ok "no reader: the write didn't block" || bad "no reader: rc $rc '$r' (124 = it blocked)"
kill $alive 2>/dev/null; wait $alive 2>/dev/null
# 4. A live reader (the helper, its stdin held open by a holder) gets the line.
rm -f "$t/in"; mkfifo "$t/in"
sh -c "exec sleep 20 > '$t/in'" & holder=$!
sh -c "echo \$\$ > '$t/helper'; exec head -n1 < '$t/in' > '$t/got'" & helper=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$t/helper" ] && [ "$(cat "$t/helper")" = "$helper" ] && break; sleep 0.2; done
r=$(mt 10 sh -c "$(fifo_put_cmd "$t" "resize 145 810 1125 442")")
wait $helper 2>/dev/null; kill $holder 2>/dev/null
[ "$r" = sent ] && [ "$(cat "$t/got" 2>/dev/null)" = "resize 145 810 1125 442" ] && ok "live helper: line delivered" || bad "live helper: '$r' got '$(cat "$t/got" 2>/dev/null)'"
# 5. The old unbounded write really hangs here (the fixture is real), and mt ends it.
rm -f "$t/in"; mkfifo "$t/in"
s=$(secs mt 2 sh -c "echo release 145 > '$t/in'"); [ "$s" -le 5 ] && ok "mt ends a blocked fifo open (${s} s)" || bad "mt took ${s} s"
# 6. mt kills the whole group, behind a pipe (an orphaned grandchild would keep tr waiting).
s=$(secs sh -c "$(declare -f mt); mt 2 sh -c 'sleep 60 & sleep 60' | tr -d x")
[ "$s" -le 6 ] && ok "mt behind a pipe returns (${s} s)" || bad "mt behind a pipe: ${s} s"
mt 1 sleep 5; rc=$?; [ $rc = 124 ] && ok "mt deadline rc 124" || bad "mt rc $rc"
mt 5 sh -c 'exit 3'; rc=$?; [ $rc = 3 ] && ok "mt passes the rc through" || bad "mt rc $rc (want 3)"
# 7. gate_deadline: a check that TERM-traps into a hanging cleanup (a new child after the sweep) is KILLed.
cat > "$t/check.sh" <<'EOF'
trap 'sleep 600; exit 1' TERM
sleep 600 & wait
EOF
bash "$t/check.sh" & gp=$!
WINDOW_GATE_GRACE_S=2 gate_deadline 1 "$gp"; wdg=$!
s=$SECONDS; wait $gp; rc=$?; s=$((SECONDS - s)); kill $wdg 2>/dev/null
[ $rc = 137 ] && [ $s -le 8 ] && ok "gate_deadline KILLs a hung cleanup (${s} s, rc $rc)" || bad "gate_deadline: rc $rc after ${s} s"
# 8. Every write to the helper's fifo in window-render.sh goes through fput / 1<>.
n=$(grep -nE '(echo|printf)[^#]*[^<1]> *\$dir/in' "$WR" | grep -v 'exec sleep')
[ -z "$n" ] && ok "no blocking '> \$dir/in' write left" || bad "blocking fifo write: $n"
grep -q 'gate_deadline "${WINDOW_GATE_TIMEOUT_S:-240}" "$gp"' "$SH" && ok "window_gate uses gate_deadline" || bad "window_gate has no hard deadline"
echo "test-window-render-fifo: $pass passed, $fail failed"
[ $fail = 0 ]
