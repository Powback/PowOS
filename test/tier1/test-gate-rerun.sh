#!/bin/bash
# shell/dev/gate-rerun.sh: the shell gate's rerun policy, over fake scene results (no browser, no docker). A scene that
# failed in the full run and passes alone twice is FLAKY (not a FAIL, one ledger row); one that fails alone even once
# is a FAIL (and isn't rerun again); a scene's GATE_ONLY names just it (+ its -launcher page); a run with more failed
# scenes than GATE_RERUN_MAX reruns none; gate.sh wires it in with GATE_RERUN=0 as the off switch.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/shell/dev/gate-rerun.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GATE_FLAKE_LEDGER=$T/flakes.jsonl
pass=0 failn=0
ok() { if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; failn=$((failn+1)); fi; }

# The fake browser run: $T/plan/<scene> holds that scene's alone results in order ("pass fail ..."); each call takes
# the next one, prints what gate.mjs would and logs the call.
gate_rerun_run() {
  local re=$1 out=$2 s r rest
  for s in "$T"/plan/*; do
    s=${s##*/}
    printf '%s' "$s" | grep -qE "$re" || continue
    echo "$s" >> "$T/calls"
    read -r r rest < "$T/plan/$s"; echo "$rest" > "$T/plan/$s"
    if [ "$r" = pass ]; then echo "ok   $s (812 ms)" > "$out"; return 0; fi
    echo "FAIL $s: still broken alone" > "$out"; return 1
  done
  echo "gate: no scene matched" > "$out"; return 0   # matched nothing: rc 0 but no ok line -> not a pass
}
scenario() {   # full-log FAIL lines as "scene" args, plans set by plan()
  rm -rf "$T/plan" "$T/calls" "$T/work" "$GATE_FLAKE_LEDGER"; mkdir -p "$T/plan" "$T/work"
  : > "$T/full.log"; : > "$T/calls"
  local s; for s in "$@"; do echo "FAIL $s: x was 3, want 4" >> "$T/full.log"; done
  echo "ok   home (900 ms)" >> "$T/full.log"
}
plan() { echo "${*:2}" > "$T/plan/$1"; }
run() { gate_rerun "$T/full.log" "$T/work" > "$T/out" 2>&1; echo $?; }

scenario term-scroll; plan term-scroll pass pass
ok "fail in full + pass alone twice: gate passes" '[ "$(run)" = 0 ]'
ok "  reported FLAKY (passed alone 2/2)" 'grep -q "term-scroll FLAKY (passed alone 2/2)" "$T/out"'
ok "  in flaky.txt" '[ "$(cat "$T/work/flaky.txt")" = term-scroll ]'
ok "  rerun exactly twice" '[ "$(grep -c . "$T/calls")" = 2 ]'
ok "  one ledger row: scene, failure text, reruns" 'python3 -c "import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; assert len(r)==1 and r[0][\"scene\"]==\"term-scroll\" and \"x was 3\" in r[0][\"failure\"] and r[0][\"reruns\"]==[\"pass\",\"pass\"] and r[0][\"date\"]" "$GATE_FLAKE_LEDGER"'

scenario desktops; plan desktops fail pass
ok "fail alone on the first rerun: gate fails" '[ "$(run)" = 1 ]'
ok "  not rerun a second time" '[ "$(grep -c . "$T/calls")" = 1 ]'
ok "  no flaky, no ledger row" '[ ! -s "$T/work/flaky.txt" ] && [ ! -s "$GATE_FLAKE_LEDGER" ]'
ok "  the alone failure is printed" 'grep -q "desktops FAIL (failed alone on rerun 1" "$T/out" && grep -q "alone: FAIL desktops: still broken alone" "$T/out"'

scenario one-bar-unfolded; plan one-bar-unfolded pass fail
ok "pass alone once then fail: gate fails" '[ "$(run)" = 1 ] && [ ! -s "$T/work/flaky.txt" ]'

scenario a-scene b-scene; plan a-scene pass pass; plan b-scene fail
ok "one flaky + one real fail: gate fails, only the flaky one in flaky.txt" '[ "$(run)" = 1 ] && [ "$(cat "$T/work/flaky.txt")" = a-scene ]'

scenario lone; : # no plan: the rerun matches nothing, prints no ok
ok "a rerun that ran nothing (rc 0, no ok line) is not a pass" '[ "$(run)" = 1 ]'

scenario s1 s2 s3; plan s1 pass pass; plan s2 pass pass; plan s3 pass pass
ok "more failed scenes than GATE_RERUN_MAX: none rerun, gate fails" '[ "$(GATE_RERUN_MAX=2 run)" = 1 ] && [ ! -s "$T/calls" ]'

ok "GATE_ONLY of a scene: itself and its -launcher page, regex-escaped" '
  re=$(gr_scene_re "app local.lights pills")
  printf "app local.lights pills\n" | grep -qE "$re" && printf "app local.lights pills-launcher\n" | grep -qE "$re" &&
  ! printf "app localXlights pills\n" | grep -qE "$re" && ! printf "app local.lights pills2\n" | grep -qE "$re" &&
  re=$(gr_scene_re "launcher-search-pull") && ! printf "x-launcher-search-pull\n" | grep -qE "$re"'
ok "verdict: N passes = flaky, any fail = fail" '[ "$(gr_verdict 2 pass pass)" = flaky ] && [ "$(gr_verdict 2 pass)" = fail ] && [ "$(gr_verdict 2 pass fail)" = fail ] && [ "$(gr_verdict 2 fail)" = fail ]'
ok "gate.sh sources it, GATE_RERUN=0 skips it, summary says N flaky" '
  G=$ROOT/shell/dev/gate.sh
  grep -q "dev/gate-rerun.sh" "$G" && grep -q "\"\${GATE_RERUN:-2}\" != 0" "$G" && grep -q "flaky\${flaky:+" "$G"'
echo "Results: $pass passed, $failn failed"
[ $failn = 0 ]
