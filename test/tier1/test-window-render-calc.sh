#!/bin/bash
# window-render.sh --hidden (the ship gate's window check): where it taps Calculator and how it judges the tap.
# 11-11 ea2933b3 false "WINDOWS BROKEN": a fixed tap at 0.14,0.69 of the 1080x1500 display (151,1035) hit the scientific
# layout's "log" key, the formula already held a long "(log(log(...cos(log(log(" of earlier checks, the appended text
# was off-screen and the pixel diff of the number area read 0.0005. Now the key comes from the accessibility dump
# (window-render.py calc) and the effect is the formula's text (calcjudge). The fixtures are `uiautomator dump
# --windows` dumps of that state, rebuilt from the run's tap.png geometry (the run saved no dump): display 127 the
# check's, display 0 a user's own Calculator at other bounds that must never be picked.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); PY="python3 -I $ROOT/tools/phone/verify/window-render.py"
FX=$ROOT/test/tier1/fixtures/window-render; P=com.oneplus.calculator
pass=0 fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: got '$2', want '$3'"; fi; }

plan=$($PY calc "$FX/calc-scrolled.xml" 127 $P); rc=$?
ok "scrolled: plan exit" "$rc" 0
ok "scrolled: the 7 key by its bounds, not 151,1035 (log); delete key" "$(echo "$plan" | head -1)" "digit_7 537 876 781 728"
ok "scrolled: formula text read whole" "$(echo "$plan" | sed -n 2p)" '"(log(log(log(log(log(log(log(cos(log(log(log(log(log(log(cos(log(log("'
ok "display 0's Calculator (the user's) is never the plan" "$($PY calc "$FX/calc-scrolled.xml" 0 $P | head -1)" "digit_7 837 1476 1081 1328"
ok "long number (digit limit): + instead of 7" "$($PY calc "$FX/calc-long-number.xml" 127 $P | head -1 | cut -d' ' -f1)" op_add
$PY calc "$FX/calc-other-display.xml" 127 $P >/dev/null; ok "no Calculator on the display: exit 1" "$?" 1
$PY calc "$FX/missing.xml" 127 $P >/dev/null 2>&1; ok "no dump: exit 1" "$?" 1
$PY calcjudge "$FX/calc-scrolled.xml" "$FX/calc-scrolled-tapped.xml" 127 $P changed >/dev/null; ok "an off-screen appended 7 counts" "$?" 0
$PY calcjudge "$FX/calc-scrolled.xml" "$FX/calc-scrolled.xml" 127 $P changed >/dev/null; ok "an unchanged formula fails" "$?" 1
$PY calcjudge "$FX/calc-scrolled.xml" "$FX/calc-scrolled.xml" 127 $P same >/dev/null; ok "undo: same" "$?" 0
$PY calcjudge "$FX/calc-scrolled.xml" "$FX/calc-scrolled-tapped.xml" 0 $P changed >/dev/null; ok "judged on its display only" "$?" 1
$PY calcjudge "$FX/calc-scrolled.xml" "$FX/calc-other-display.xml" 127 $P changed >/dev/null; ok "app gone: unreadable (2)" "$?" 2
# The shell side: no fixed-fraction tap or pixel judgement left in the hidden check.
S=$ROOT/tools/phone/verify/window-render.sh
ok "no WR_TAP/WR_CLEAR in the hidden check" "$(sed -n '/^hidden() {/,/^}/p' "$S" | grep -c 'WR_TAP\|WR_CLEAR')" 0
ok "the hidden check uses calc + calcjudge" "$(sed -n '/^hidden() {/,/^}/p' "$S" | grep -c '\$PY calc')" 3
echo "Results: $pass passed, $fail failed"
[ $fail = 0 ]
