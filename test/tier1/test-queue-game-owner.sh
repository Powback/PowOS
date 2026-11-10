#!/bin/bash
# test-queue-game-owner.sh: the verify queue closes a game it started, whatever way the job ended, and never the user's.
# 11-10 05:03-06:16: game-input-alive started Broforce, was stopped "touched" with adb down; game_left got no answer,
# the runner re-exec'd, nothing remembered the queue started it - idle.sh said game=away and every games job was
# skipped for hours. Covers queue.sh's game ownership block (game_left, game_adopt, jw_seed) with game_up/game_since/
# warm_stop mocked: a touched job whose end look failed, a job killed with the runner (re-exec/TERM), the user's game
# (started outside every run, or up before the job), the ledger seeded from util.log, and the runner's call sites.
set -u
src=$(cd "$(dirname "$0")/../.." && pwd)/tools/phone/verify/queue.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/queue-game-owner.XXXXXX"); trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "$2" | sed 's/^/       /'; }
fns=$(sed -n '/^# --- game ownership:/,/^# --- end game ownership ---$/p; /^game_key() {/,/^  \[ \$g = 1 \] && echo/p' "$src")
[ -n "$fns" ] || { echo "FAIL could not extract the game ownership block"; exit 1; }
eval "$fns"
# Mocks: GUP = game_up's answer ("" = adb failed), GSINCE = game_since's; warm_stop records what it closed and why.
game_up() { echo "${GUP-none}"; }
game_since() { echo "${GSINCE-none}"; }
warm_stop() { local a; a=$(cat "$Q/warm" 2>/dev/null); rm -f "$Q/warm"; [ -n "$a" ] && echo "CLOSED $a: $1" >> "$Q/closed"; }
fresh() { Q=$T/q$1; rm -rf "$Q"; mkdir -p "$Q/done"; }
J=20261110-032911-73169-game-input
t0=1794283391; t1=1794283464

# 1. touched job, the phone didn't answer at its end (the 05:04 case): the ledger keeps its run; the next window's
#    game_adopt finds Broforce started at 05:03:29 inside it and closes it, naming the job.
fresh 1; echo "$J none $t0 300" > "$Q/job-game-before"
out=$(GUP= game_left none "$J" "$t0")
grep -q "didn't answer" <<<"$out" && [ ! -e "$Q/job-game-before" ] && grep -q "^$J $t0 [0-9]*$" "$Q/job-windows.log" \
  && ok "touched + adb down: game_left logs it and writes the run to the ledger" || bad "touched ledger line" "$out$(cat "$Q/job-windows.log" 2>/dev/null)"
sed -i.b "s/^$J $t0 .*/$J $t0 $t1/" "$Q/job-windows.log"
out=$(GSINCE="274190 $((t0 + 19))" game_adopt window; echo rc=$?)
grep -q rc=0 <<<"$out" && grep -q "^CLOSED 274190: $J started it" "$Q/closed" 2>/dev/null \
  && ok "game_adopt: a game started inside the job's run is the queue's - closed, the job named" || bad "adopt touched" "$out$(cat "$Q/closed" 2>/dev/null)"
# ... and a working adb at the end closes it right there (the usual path).
fresh 1b; out=$(GUP=274190 game_left none "$J" "$t0")
grep -q "^CLOSED 274190: $J started it and left it running" "$Q/closed" 2>/dev/null && ok "game_left: adb answers - closed at the job's end" || bad "game_left close" "$out"
# ... unless it was handed on warm (the next job reuses it).
fresh 1c; echo 274190 > "$Q/warm"; GUP=274190 game_left none "$J" "$t0" >/dev/null
[ ! -e "$Q/closed" ] && [ "$(cat "$Q/warm")" = 274190 ] && ok "game_left: a warm hand-over stays up" || bad "warm hand-over"

# 2. the runner stopped / re-exec'd mid-job: only job-game-before is left. The next start's game_adopt turns it into a
#    run (start .. start + budget + 60, at most now) and closes the game started in it.
fresh 2; now=$(date +%s); s=$((now - 200)); echo "$J none $s 300" > "$Q/job-game-before"
out=$(GSINCE="274190 $((s + 30))" game_adopt "runner start"; echo rc=$?)
grep -q rc=0 <<<"$out" && grep -q "ended without its game look" <<<"$out" && [ ! -e "$Q/job-game-before" ] \
  && grep -qE "^$J $s ($now|$((now + 1)))\$" "$Q/job-windows.log" && grep -q "^CLOSED 274190: $J" "$Q/closed" 2>/dev/null \
  && ok "runner killed mid-job: its run recovered (capped at now), the game closed at the next start" || bad "re-exec adopt" "$out$(cat "$Q/job-windows.log")"
# ... a long-dead one is capped at start + budget + 60: a game started after that is not the queue's.
fresh 2b; s=$((now - 5000)); echo "$J none $s 300" > "$Q/job-game-before"
out=$(GSINCE="274190 $((s + 1000))" game_adopt "runner start"; echo rc=$?)
grep -q rc=1 <<<"$out" && [ ! -e "$Q/closed" ] && grep -q "^$J $s $((s + 360))$" "$Q/job-windows.log" \
  && ok "dead runner's job: window capped at its budget + 60 s; a later game left alone" || bad "cap" "$out$(cat "$Q/job-windows.log")"

# 3. the user's game: never closed.
fresh 3; echo "$J $t0 $t1" > "$Q/job-windows.log"
out=$(GSINCE="274190 $((t0 - 600))" game_adopt window; echo rc=$?)
grep -q rc=1 <<<"$out" && [ ! -e "$Q/closed" ] && grep -q "the user's - left alone" <<<"$out" \
  && ok "a game started before the job's run: the user's, left alone" || bad "user's game before" "$out"
out=$(GSINCE="274190 $((t0 - 600))" game_adopt window)
[ -z "$out" ] && ok "said once per game, not every window" || bad "said once" "$out"
out=$(GSINCE="274190 $((t1 + 120))" game_adopt window; echo rc=$?)
grep -q rc=1 <<<"$out" && [ ! -e "$Q/closed" ] && ok "a game started after the run: the user's, left alone" || bad "user's game after" "$out"
# a game up before the job (game_left's before = an app): no ledger line, nothing closed, the record gone.
fresh 3b; echo "$J 274190 $t0 300" > "$Q/job-game-before"
GUP=274190 game_left 274190 "$J" "$t0" >/dev/null
[ ! -e "$Q/job-windows.log" ] && [ ! -e "$Q/closed" ] && [ ! -e "$Q/job-game-before" ] && ok "game up before the job: not recorded, not closed" || bad "before game"
# ... and the same left over from a killed runner: still not the queue's.
fresh 3c; echo "$J 274190 $t0 300" > "$Q/job-game-before"
out=$(GSINCE="274190 $((t0 - 60))" game_adopt "runner start"; echo rc=$?)
grep -q rc=1 <<<"$out" && [ ! -e "$Q/closed" ] && [ ! -e "$Q/job-game-before" ] && ok "killed job that had a game before: the game left alone" || bad "killed with game before" "$out"
# adb failed before the job (before unknown): treated as maybe the user's.
fresh 3d; GUP=274190 game_left "" "$J" "$t0" >/dev/null
[ ! -e "$Q/job-windows.log" ] && [ ! -e "$Q/closed" ] && ok "unknown before (adb failed): never recorded as the queue's" || bad "unknown before"
# no game up / adb down at adopt: nothing.
fresh 3e; echo "$J $t0 $t1" > "$Q/job-windows.log"
out=$(GSINCE= game_adopt window; echo rc=$?); grep -q rc=1 <<<"$out" && [ ! -e "$Q/closed" ] && ok "adb down at adopt: nothing done" || bad "adb down adopt" "$out"

# 4. jw_seed: the ledger's first fill from util.log's J records of games jobs (the queued/done job files' cmd).
fresh 4; now=$(date +%s)
printf 'task=x\ncmd=(tools/phone/verify/game-input-alive.sh)\n' > "$Q/$J.job"
printf 'task=y\ncmd=(tools/phone/verify/ww-resize.sh)\n' > "$Q/done/other.job"
{ echo "J $((now - 3000)) $((now - 2900)) touched $J"; echo "J $((now - 2800)) $((now - 2700)) pass other"
  echo "J $((now - 400000)) $((now - 399900)) pass $J"; echo "W $((now - 3000)) $((now - 2000))"; } > "$Q/util.log"
out=$(jw_seed)
[ "$(cat "$Q/job-windows.log")" = "$J $((now - 3000)) $((now - 2900))" ] && grep -q "1 games-job runs" <<<"$out" \
  && ok "jw_seed: recent games-job runs only" || bad "seed" "$out$(cat "$Q/job-windows.log")"
echo "keep" > "$Q/job-windows.log"; jw_seed >/dev/null; [ "$(cat "$Q/job-windows.log")" = keep ] && ok "jw_seed: an existing ledger is kept" || bad "seed keeps"

# 5. the runner's call sites.
for p in 'echo "$n ${g0:-unknown} $(date +%s) $budget" > "$Q/job-game-before"' \
         '[ "$g0" = - ] || game_left "$g0" "$n" "$t0"
          pause' \
         'warm_after "$log" "$gk"; [ "$g0" = - ] || game_left "$g0" "$n" "$t0"' \
         'jw_seed; game_adopt "runner start" || :' \
         '[ "$AWAY" = 1 ] && game_adopt window && { AWAY=0;'; do
  grep -qF -- "$p" "$src" && ok "queue.sh: ${p:0:60}" || bad "queue.sh call site missing: $p"; done
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
