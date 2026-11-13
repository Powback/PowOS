#!/bin/bash
# test-perf-trace-fields.sh: perf-trace-fields.py (perf-scenarios.sh --only trace, board task
# perf-traces-the-user-sends-must-show-what-react) passes a recording that carries react-scan's data - renders by
# count/time, slow commits with duration + components, home's frame verdicts, the commit list - and names each field
# a recording lacks (an old trace: no slowCommits; a meter without the render scan: renders a string).
set -uo pipefail
s=$(cd "$(dirname "$0")/../.." && pwd)/tools/phone/verify/perf-trace-fields.py
T=$(mktemp -d "${TMPDIR:-/tmp}/ptf.XXXXXX"); trap 'rm -rf "$T"' EXIT
fails=0
good='{"summary":{"renders":{"renders":42,"commits":7,"byCount":["Icon 12r 0n 1.2ms"],"byTime":["Pager 3r 0n 9.1ms"],
 "slowCommits":["12.4ms at +3051ms: Pager x1 Icon x12"]},"home":{"preRollMs":8000,"longFrames":[{"verdict":"js"}]}},
 "renders":{"commitList":[{"t":3051,"ms":12.4,"names":{"Pager":1,"Icon":12}}]}}'
case_() {  # case_ <name> <want rc> <json> [<want text>]
  printf '%s\n' "$3" > "$T/p.json"; out=$(python3 -I "$s" "$T/p.json"); rc=$?
  if [ "$rc" = "$2" ] && { [ -z "${4:-}" ] || grep -q -- "$4" <<<"$out"; }; then echo "PASS $1"
  else echo "FAIL $1: rc $rc (want $2), out: $out"; fails=$((fails + 1)); fi; }
case_ complete 0 "$good"
case_ no-slow-commits 1 "${good/\"slowCommits\":\[\"12.4ms at +3051ms: Pager x1 Icon x12\"\]/\"slowCommits\":[]}" "MISSING summary.renders.slowCommits"
case_ renders-string 1 '{"summary":{"renders":"no renders section","home":{"preRollMs":0,"longFrames":[]}}}' "isn't a section"
case_ no-commit-list 1 "${good/\"commitList\":\[*\]/\"commitList\":[]}" "MISSING renders.commitList"
case_ no-verdicts 1 "${good/\"preRollMs\":8000,/}" "MISSING summary.home"
exit $fails
