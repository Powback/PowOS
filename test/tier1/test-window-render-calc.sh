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
# 11-26 (f1dfea35, 11-23 d38c773e: the user's Calculator formula held ~130 chars of old checks' residue, unreadable
# after the tap -> false WINDOWS BROKEN): the hidden check runs on its OWN app (PowOS's WindowCheckActivity, a counter
# fresh at 0 each launch + a Tap button, by content description), never a user's. Fixtures: display 76 the check's,
# display 0 home with a decoy counter that must never be read.
W=com.powos.app
ok "wcplan: Tap centre + fresh counter" "$($PY wcplan "$FX/wc-fresh.xml" 76 $W | paste -sd'|' -)" "540 880|0"
$PY wcplan "$FX/wc-no-button.xml" 76 $W >/dev/null; ok "wcplan: no visible Tap button: exit 1" "$?" 1
$PY wcplan "$FX/wc-fresh.xml" 77 $W >/dev/null; ok "wcplan: no app on the display: exit 1" "$?" 1
$PY wcplan "$FX/wc-fresh.xml" 76 $P >/dev/null; ok "wcplan: another package (Calculator) is never read" "$?" 1
$PY wcjudge "$FX/wc-fresh.xml" "$FX/wc-tapped.xml" 76 $W >/dev/null; ok "wcjudge: 0 -> 1 passes" "$?" 0
$PY wcjudge "$FX/wc-fresh.xml" "$FX/wc-fresh.xml" 76 $W >/dev/null; ok "wcjudge: unchanged fails" "$?" 1
$PY wcjudge "$FX/wc-fresh.xml" "$FX/wc-twice.xml" 76 $W >/dev/null; ok "wcjudge: +2 (a double tap) fails" "$?" 1
$PY wcjudge "$FX/wc-fresh.xml" "$FX/calc-full.xml" 76 $W >/dev/null; ok "wcjudge: app gone: unreadable (2)" "$?" 2
ok "wcjudge: judged on its display only (home's decoy 9 ignored)" "$($PY wcjudge "$FX/wc-fresh.xml" "$FX/wc-tapped.xml" 76 $W)" "counter 0 -> 1"
# The shell side: the hidden check judges only its own app - no Calculator, no fixed tap, no pixel judgement.
S=$ROOT/tools/phone/verify/window-render.sh
H=$(sed -n '/^hidden() {/,/^}/p' "$S")
ok "no WR_TAP/WR_CLEAR in the hidden check" "$(echo "$H" | grep -c 'WR_TAP\|WR_CLEAR')" 0
ok "the hidden check uses wcplan + wcjudge, never calc" "$(echo "$H" | grep -c '\$PY wcplan\|\$PY wcjudge') $(echo "$H" | grep -c '\$PY calc')" "2 0"
ok "the hidden check's app is PowOS's WindowCheckActivity" "$(echo "$H" | grep -c '^  local APP=com.powos.app comp=com.powos.app/dev.omalauncher.shell.WindowCheckActivity$')" 1
ok "the hidden check never names the user's Calculator" "$(echo "$H" | grep -v '^ *#' | grep -ci 'calculator')" 0
M=$ROOT/targets/android/app/app/src/main/AndroidManifest.xml
ok "WindowCheckActivity: in the manifest, own process, not exported, no launcher entry" "$(sed -n '/\.shell\.WindowCheckActivity"/,/\/>/p' "$M" | grep -c 'android:process=":windowcheck"\|android:exported="false"\|documentLaunchMode="always"') $(sed -n '/\.shell\.WindowCheckActivity"/,/\/>/p' "$M" | grep -c LAUNCHER)" "3 0"
K=$ROOT/targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/WindowCheckActivity.kt
ok "the activity's descriptions are the ones window-render.py reads" "$(grep -c '"powos-window-check-count"\|"powos-window-check-tap"' "$K") $(grep -c 'desc:powos-window-check-count\|desc:powos-window-check-tap' "$ROOT/tools/phone/verify/window-render.py")" "2 1"
ok "the visible check plans its tap and undoes it" "$(grep -c 'PY calcdisp\|input -d \$VD tap \$ux' "$S")" 2
echo "Results: $pass passed, $fail failed"
[ $fail = 0 ]
