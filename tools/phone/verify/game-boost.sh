#!/bin/bash
# lanes: phone
# game-boost.sh [secs]: (Mac; run it WHILE THE USER PLAYS a game - it never starts one) whether the game CPU boost
# (targets/android/app/.../shell/GameBoost.kt + assets/game-boost.sh; board broforce-games-black-noise-flicker-
# artifacts-ove, docs/research/broforce-fps.md) is on the game in front, and the fps it gives. Read-only: /proc, sysfs,
# the boost's own status and log, KWin's session log. Over <secs> (default 20):
#   boost    the holder's game, its main thread, the policies' min/max/cur vs hw max, the uclamp group, saved originals
#   main     the main thread's affinity, cpu group and where it ran (10 Hz samples) and its share of one core
#   clocks   each policy's cur freq, averaged over the samples
#   fps      KWin's "window task N frames: last 5 s C commits, D drawn (F fps)" lines written during the run (commits / 5
#            = the game's own fps)
# PASS: a holder boosts a game, every boosted policy's max == its hw max (under a userspace thermal controller -
# OxygenOS' horae - its cap kept: min == max, no "set back by someone else" fights), the main thread is pinned to one cpu and ran
# there in >= 90 % of the samples. The fps lines are the evidence (>= 45 fps = docs/research/broforce-fps.md's goal).
# The vendor's game class (under a thermal controller; needs the oplus-hook module with scope com.oplus.battery):
# "boost vendor_game <app id> since <epoch>" set, and the vendor's last ThermalControllHandler evaluation after that
# epoch ("vendor_thermal ... appType=4 ... configItemName=category_4", measured 11-03 without: appType=-1
# ... configItemName=common_config) classes com.powos.app as a game - FAIL if it
# still says appType=-1 / common_config; none since (no temperature gear change yet) is only a note. With appType 4
# the cap lifts: at gear <= 4 the boosted policies' max is the hw max again (category_4: no cpu level until gear 5).
# Exit 3: no game boosted now (nothing to check - the user isn't playing, or the app isn't the new one); 1 FAIL.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A=$here/../adb.sh
SECS=${1:-20}
case "$SECS" in *[!0-9]*|"") echo "secs: a number"; exit 2 ;; esac
OUT=${OUT:-$HOME/.cache/powos-verify/game-boost-$(date +%F_%H%M%S)}; mkdir -p "$OUT"
cat > "$OUT/probe.sh" <<EOF
F=/data/user/0/com.powos.app/files; S=/data/powos/state/game-boost; P=/sys/devices/system/cpu/cpufreq
LOGF=\$F/run/hyprland.log
[ -f \$F/game-boost.sh ] || { echo "NOSCRIPT"; exit 0; }
sh \$F/game-boost.sh status | sed 's/^/boost /'
m=\$(cat \$S/main 2>/dev/null)
[ -n "\$m" ] && [ -d /proc/\$m ] || { echo "NOMAIN"; exit 0; }
echo "main tid \$m comm \$(cat /proc/\$m/comm) \$(taskset -p \$m | sed 's/.*: /mask /') cg \$(sed -n 's/^[0-9]*:cpu://p' /proc/\$m/cgroup)"
n0=\$(wc -l < \$LOGF 2>/dev/null || echo 0)
r=\$(cat /proc/\$m/stat); r=\${r##*) }; set -- \$r; t0=\$(( \${12} + \${13} ))
i=0; end=\$(( \$(date +%s) + $SECS ))
while [ \$(date +%s) -lt \$end ]; do
  r=\$(cat /proc/\$m/stat 2>/dev/null) || break; r=\${r##*) }; set -- \$r; echo "main_on cpu\${37}"
  [ \$((i % 10)) = 0 ] && for p in \$P/policy*; do echo "clock \${p##*/} \$(cat \$p/scaling_cur_freq)"; done
  i=\$((i + 1)); sleep 0.1
done
r=\$(cat /proc/\$m/stat 2>/dev/null); r=\${r##*) }; set -- \$r; echo "main_busy \$(( (\${12} + \${13} - t0) / $SECS ))"
tail -n +\$((n0 + 1)) \$LOGF 2>/dev/null | grep 'window task .* frames:' | sed 's/^/fps /'
logcat -d -b all -v epoch 2>/dev/null | grep 'Battery *: ThermalControllHandler: tempLevel' | tail -n 1 |
  sed 's/^ *\([0-9]*\)[.0-9]* .*tempLevel=/vendor_thermal at \1 tempLevel=/; s/, *envTempType.*full=/ full=/'
EOF
"$A" push "$OUT/probe.sh" /data/local/tmp/powos-game-boost-probe.sh > /dev/null || { echo "ENV: can't push the probe"; exit 5; }
perl -e "alarm $((SECS + 60)); exec @ARGV" "$A" shell "su -c 'sh /data/local/tmp/powos-game-boost-probe.sh; rm -f /data/local/tmp/powos-game-boost-probe.sh'" |
  tr -d '\r' > "$OUT/raw.txt"
R=$OUT/raw.txt
grep -q '^NOSCRIPT' "$R" && { echo "NOT RUN: no game-boost.sh on the phone (the PowOS app predates the boost)"; exit 3; }
grep -q '^boost holder none' "$R" && { echo "NOT RUN: no game boosted now (play a game, then run this)"; grep '^boost ' "$R"; exit 3; }
grep '^boost ' "$R" | sed 's/^boost //' | tee "$OUT/report.txt"
grep -q '^NOMAIN' "$R" && { echo "FAIL: a holder runs but no main thread is pinned yet" | tee -a "$OUT/report.txt"; exit 1; }
grep '^main tid' "$R" | tee -a "$OUT/report.txt"
awk '$1 == "main_on" { n++; c[$2]++ } END { for (k in c) printf "main ran on %s %d%%\n", k, 100 * c[k] / n }' "$R" | sort -k5 -rn | tee -a "$OUT/report.txt"
awk '$1 == "main_busy" { printf "main busy %d%% of one core\n", $2 }' "$R" | tee -a "$OUT/report.txt"
awk '$1 == "clock" { n[$2]++; s[$2] += $3 } END { for (p in n) printf "clock %s avg %d MHz\n", p, s[p] / n[p] / 1000 }' "$R" | sort | tee -a "$OUT/report.txt"
grep '^fps ' "$R" | sed 's/^fps //' | tail -n 8 | tee -a "$OUT/report.txt"
grep '^vendor_thermal ' "$R" | tee -a "$OUT/report.txt"
fail=0
# Every boosted policy (those with a saved original) at its hw max - or, under a userspace thermal controller ("boost
# thermal <comm>": OxygenOS' horae), at that controller's cap: min == max (the boost holds the min up to it, never
# raises the max past it).
thermal=$(awk '$1 == "boost" && $2 == "thermal" { print $3 }' "$R")
for p in $(grep -o 'policy[0-9]* [0-9]* [0-9]*;' <<< "$(grep '^boost saved' "$R")" | awk '{print $1}'); do
  if [ -n "$thermal" ]; then
    grep -q "^boost policy $p min \([0-9]*\) max \1 " "$R" || { echo "FAIL: $p min not held at $thermal's cap"; fail=1; }
  else
    grep -q "^boost policy $p min [0-9]* max \([0-9]*\) hw \1 " "$R" || { echo "FAIL: $p not at its hw max"; fail=1; }
  fi
done
awk '/^boost .*: boost \(policies/ { f = 0 } /^boost .*set back to .* by someone else/ { f = 1 } END { exit !f }' "$R" && [ -n "$thermal" ] && { echo "FAIL: the boost still fights $thermal's cap"; fail=1; }
# The vendor's game class: an evaluation since it went on must class com.powos.app as a game (appType 4).
vg=$(awk '$1 == "boost" && $2 == "vendor_game" && $3 != "null" && $3 != "" { print $5 }' "$R")
if [ -n "$thermal" ] && [ -n "$vg" ] && [ "$vg" != - ]; then
  at=$(awk '$1 == "vendor_thermal" { print $3 }' "$R")
  if [ -n "$at" ] && [ "$at" -ge "$vg" ]; then
    grep -q '^vendor_thermal .*appType=4 ' "$R" ||
      { echo "FAIL: the vendor still classes com.powos.app as $(grep -o 'configItemName=[a-z_0-9]*' "$R" | tail -n 1) (oplus-hook scope com.oplus.battery?)"; fail=1; }
  else
    echo "note: no vendor thermal evaluation since the game class went on (next temperature gear change)" | tee -a "$OUT/report.txt"
  fi
elif [ -n "$thermal" ]; then
  echo "FAIL: boosted under $thermal but no vendor game class set"; fail=1
fi
mask=$(awk '/^main tid/ { for (i = 1; i <= NF; i++) if ($i == "mask") print $(i + 1) }' "$R")
case "$mask" in 1|2|4|8|10|20|40|80|100|200|400|800) ;; *) echo "FAIL: main thread mask $mask is not one cpu"; fail=1 ;; esac
top=$(awk '/^main ran on/ { print $5 + 0; exit }' "$OUT/report.txt"); top=${top:-0}
[ "$top" -ge 90 ] || { echo "FAIL: main thread on its cpu only $top% of the samples"; fail=1; }
[ $fail = 0 ] && echo "PASS: boosted (report $OUT/report.txt)" || echo "(report $OUT/report.txt)"
exit $fail
