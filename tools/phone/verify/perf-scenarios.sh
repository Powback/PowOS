#!/bin/bash
# tools/phone/verify/perf-scenarios.sh: the perf task's own three interactions measured on the phone with the shell's
# recorder (fpsmeter.tsx: the status bar's meter, one recording per scenario) - home's page swipes, the launcher
# (drawer) opened and shut, the shade pulled down and pushed away. Each scenario: the meter clicked over CDP (no touch:
# a DOM click on the bar's own page), the gesture N times by injected input (e2e-lib.sh: aborts when the user touches
# the phone), the meter clicked again, the new perf-*.json pulled to $OUT/<scenario>.json and its summary printed
# (fps p50/p5, frames over 33 ms, long tasks, native stalls, top renders). Runs only after the user has left the phone
# for PERF_IDLE_S (default 600 s). Note: each recording is also posted to PowOS AI as the meter always does.
#   perf-scenarios.sh [--round R] [--only swipe|launcher|shade] [--reps N]
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
# The user's finger away >= PERF_IDLE_S (600) by the touch panels' IRQs (idle.sh); e2e's own gate (dumpsys power's
# activity, moved by app wakes too) keeps its usual 120 s - asking 600 of it skipped a free window (act 461, idle 629).
PERF_IDLE_S=${PERF_IDLE_S:-600}
s=$("$T/idle.sh"); i=${s#idle=}; i=${i%% *}
[ "${i:-0}" -ge "$PERF_IDLE_S" ] || { echo "SKIP: user touched the phone ${i:-?} s ago (need $PERF_IDLE_S): $s"; exit 3; }
ONLY=; REPS=3; ARGS=()
while [ $# -gt 0 ]; do case "$1" in --only) ONLY=$2; shift 2 ;; --reps) REPS=$2; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
e2e_args "${ARGS[@]}"
e2e_init perf-scenarios
PDIRF=/data/data/com.powos.app/files/run/powos-ai-shared
newest() { sh_ "ls -t $PDIRF 2>/dev/null | grep -m1 '^perf-'"; }
METER0=
meter_back() { [ -n "$METER0" ] && ev "importShim('./bridge.ts').then(b=>b.powos.store.set('perf.meter',$METER0)).then(()=>'ok')" >/dev/null; METER0=; }
e2e_setup
METER0=$(ev 'importShim("./bridge.ts").then(b=>b.powos.store.get("perf.meter")).then(v=>JSON.stringify(v??null))')
case $METER0 in null|\{*) ;; *) METER0= ;; esac
log "perf.meter at start: ${METER0:-unreadable}"

# rec_on / rec_off <scenario>: the meter's record button, clicked on the status bar's page.
rec_on() { BEFORE=$(newest); ev "(document.querySelector('.fps-meter').click(),'ok')" statusbar >/dev/null; sleep 0.8; }
rec_off() {
  ev "(document.querySelector('.fps-meter').click(),'ok')" statusbar >/dev/null
  local f= i; for i in $(seq 1 20); do sleep 1; f=$(newest); [ -n "$f" ] && [ "$f" != "$BEFORE" ] && break; f=; done
  [ -n "$f" ] || { fail "$1: no new perf trace after the stop"; return 1; }
  sh_ "cat $PDIRF/$f" > "$OUT/$1.json"
  log "$1: $f -> $OUT/$1.json"
  python3 "$here/perf-summary.py" "$1" "$OUT/$1.json" | tee -a "$OUT/log.txt"
}

sc_swipe() {
  local p d=$((W * 45 / 100)) i; p=$(freept "" -1 "$d" .3); [ "$p" != none ] && [ -n "$p" ] || { fail "swipe: no empty spot on home"; return 1; }
  set -- $p; local x=$1 y=$2
  rec_on
  for i in $(seq 1 "$REPS"); do
    chk swipe$i; swipe "$x" "$y" $((x - d)) "$y" 220 "page swipe to the next page" || break; sleep 1.2
    chk swipe$i-back; swipe $((x - d)) "$y" "$x" "$y" 220 "page swipe back" || break; sleep 1.2
  done
  rec_off swipe
  step swipe "page swipes done ($REPS pairs)"; pass "recorded"
}
sc_launcher() {
  local i p; rec_on
  for i in $(seq 1 "$REPS"); do
    chk launcher$i; p=$(freept "" 0 0 .54); [ "$p" != none ] && [ -n "$p" ] || { fail "launcher: no empty spot"; break; }
    set -- $p; swipe "$1" "$2" "$1" $(($2 - H * 30 / 100)) 250 "up from empty space (the drawer)" || break; sleep 1.5
    [ "$(isopen)" = true ] || note "rep $i: the drawer didn't open"
    back 1.5
  done
  rec_off launcher
  step launcher "launcher opened and shut ($REPS times)"; pass "recorded"
}
sc_shade() {
  local i S=$((H / 100)) X=$((W * 8 / 10)); rec_on
  for i in $(seq 1 "$REPS"); do
    chk shade$i; mdown $X 8 "the status bar (the shade)" || break
    mpath $X 8 $X $((8 + 40 * S)) 14; mup $X $((8 + 40 * S)); sleep 1.5
    back 1.5
  done
  rec_off shade
  step shade "shade pulled down and closed ($REPS times)"; pass "recorded"
}
for s in swipe launcher shade; do
  [ -z "$ONLY" ] || [ "$ONLY" = $s ] || continue
  sc_$s; hemit system.home null
done
meter_back
e2e_finish
