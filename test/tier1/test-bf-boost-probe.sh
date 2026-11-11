#!/bin/bash
# bf-coldstart.sh's boost probe (docs/research/game-launch-time.md 11-11 21:30): logcat's main buffer on the phone holds
# ~1 min, so the 21:30 run printed "category: -" although the oplus-hook had answered appType 4 at the tap. The probe
# reads the hook's lines from Vector's module log (since the check began) and prints the clamp after the run. Renders
# the probe's heredoc like bf-coldstart does, against a fake Vector log / cpufreq tree, with no phone.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); V=$ROOT/tools/phone/verify
pass=0 fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: got '$2', want '$3'"; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/lspd" "$T/cpufreq/policy0" "$T/cpufreq/policy7" "$T/state" "$T/bin"
echo 2016000 > "$T/cpufreq/policy0/scaling_max_freq"; echo 2016000 > "$T/cpufreq/policy0/cpuinfo_max_freq"
echo 1363200 > "$T/cpufreq/policy7/scaling_max_freq"; echo 3187200 > "$T/cpufreq/policy7/cpuinfo_max_freq"
cat > "$T/lspd/modules_2026-11-10T01:16:03.749514.log" <<'L'
[ 2026-11-11T21:16:53.259     1000: 30626: 30922 I/VectorLegacyBridge ] PowOS-oplushook: gameClass: com.powos.app appType 4 (steam_app_274190 boosted)
[ 2026-11-11T21:32:51.067     1000: 30626: 30922 I/VectorLegacyBridge ] PowOS-oplushook: gameClass: com.powos.app appType 4 (steam_app_274190 boosted)
[ 2026-11-11T21:32:51.068     1000: 30626: 30626 I/VectorLegacyBridge ] PowOS-oplushook: gameClass: marker steam_app_274190, category evaluated now
[ 2026-11-11T21:32:52.000     1000: 30626: 30626 I/VectorLegacyBridge ] PowOS-oplushook: splitDividerMenu: hooks installed
L
for c in dumpsys ps logcat; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; chmod +x "$T/bin/$c"; done
# The heredoc body as bf-coldstart writes it (unquoted EOF: $since expands, \$ stays), phone paths -> the fakes.
since=$(date -j -f '%F %T' '2026-11-11 21:30:00' +%s 2>/dev/null || date -d '2026-11-11 21:30:00' +%s)
body=$(awk '/^cat > "\$OUT\/boost-probe.sh" <<EOF$/{f=1;next} f&&/^EOF$/{exit} f' "$V/bf-coldstart.sh")
ok "probe heredoc found" "$([ -n "$body" ] && echo yes)" yes
eval "cat > \"\$T/probe.sh\" <<EOF
$body
EOF"
sed -i.bak -e "s#/data/adb/lspd/log#$T/lspd#g" -e "s#/sys/devices/system/cpu/cpufreq#$T/cpufreq#g" \
  -e "s#/data/powos/state/game-boost#$T/state#g" -e "s#date -d @\([0-9]*\) '+%F %T'#echo '2026-11-11 21:30:00'#" "$T/probe.sh"
out=$(PATH="$T/bin:$PATH" sh "$T/probe.sh" 2>&1)
ok "hook lines since the check began" "$(echo "$out" | grep -c '^hooklog .*gameClass')" 2
ok "an older launch's line left out" "$(echo "$out" | grep -c 'T21:16:53')" 0
ok "appType 4 answer kept" "$(echo "$out" | grep -c '^hooklog .*appType 4')" 1
ok "clamp after the run" "$(echo "$out" | grep '^clamp_after')" "clamp_after policy0=2016000/2016000 policy7=1363200/3187200 "
ok "summary counts the hook's answers" "$(grep -c "grep -c 'appType 4'" "$V/bf-coldstart.sh")" 1
echo "test-bf-boost-probe: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
