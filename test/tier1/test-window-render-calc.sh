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
pass=0 fail=0; TMPF=$(mktemp); trap 'rm -f "$TMPF"' EXIT
ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: got '$2', want '$3'"; fi; }

plan=$($PY calc "$FX/calc-scrolled.xml" 127 $P); rc=$?
ok "scrolled: plan exit" "$rc" 0
ok "scrolled: ends in '(' with a visible ( key: delete judged, ( typed back" "$(echo "$plan" | head -1)" "del 781 728 lparen 293 1319"
ok "scrolled: formula text read whole" "$(echo "$plan" | sed -n 2p)" '"(log(log(log(log(log(log(log(cos(log(log(log(log(log(log(cos(log(log("'
ok "display 0's Calculator (the user's) is never the plan" "$($PY calc "$FX/calc-scrolled.xml" 0 $P | head -1)" "del 1081 1328 digit_2 959 1771"
ok "long number: delete judged, its last digit typed back" "$($PY calc "$FX/calc-long-number.xml" 127 $P | head -1)" "del 781 728 digit_1 537 1171"
# 11-11 21:28 (real dump, display 154): the formula full of old checks' leftovers ("c" = cos(, "L" = log( in the OnePlus
# build's text) at the app's max length - a 7 changed nothing (false WINDOWS BROKEN). The delete always changes it.
ok "full formula ending in 7: delete judged, 7 typed back" "$($PY calc "$FX/calc-full.xml" 154 $P | head -1)" "del 665 909 digit_7 153 1033"
$PY calcjudge "$FX/calc-full.xml" "$FX/calc-full-deleted.xml" 154 $P changed >/dev/null; ok "full formula: the delete counts" "$?" 0
$PY calcjudge "$FX/calc-full.xml" "$FX/calc-full.xml" 154 $P changed >/dev/null; ok "full formula: unchanged fails" "$?" 1
ok "calcdisp: the app's display and size" "$($PY calcdisp "$FX/calc-full.xml" $P)" "154 1080 1500"
# No key for the last char ("L" = log( has no key in the basic layout) or an empty formula: 7, undone by delete.
sed 's/text="\([^"]*\)7" resource-id="com.oneplus.calculator:id\/formula"/text="\1L" resource-id="com.oneplus.calculator:id\/formula"/' "$FX/calc-full.xml" > "$TMPF"
ok "last char without a key: 7, undone by delete" "$($PY calc "$TMPF" 154 $P | head -1)" "digit_7 153 1033 del 665 909"
sed 's/text="[^"]*" resource-id="com.oneplus.calculator:id\/formula"/text="" resource-id="com.oneplus.calculator:id\/formula"/' "$FX/calc-full.xml" > "$TMPF"
ok "empty formula: 7, undone by delete" "$($PY calc "$TMPF" 154 $P | head -1)" "digit_7 153 1033 del 665 909"
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
ok "a full formula is NOT JUDGED, never a FAIL, in the hidden check" "$(sed -n '/^hidden() {/,/^}/p' "$S" | grep -c 'NOT JUDGED (\$APP.s formula full')" 1
ok "the visible check plans its tap and undoes it" "$(grep -c 'PY calcdisp\|input -d \$VD tap \$ux' "$S")" 2
echo "Results: $pass passed, $fail failed"
[ $fail = 0 ]
