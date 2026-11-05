# lanes: phone
# bf-quiet-phone.sh <secs> <touch irq count>: (on the phone as root, Android side; bf-quiet.sh pushes it) one soak
# sample of <secs> s in ONE adb call: what is in front (mCurrentFocus + topResumedActivity) at its start and end, the
# game's CPU over the sample (utime+stime of every process whose command line names Broforce_beta.exe - FEX's wine64
# running the game, its Proton/reaper parents - in % of one core), the top processes over the same window (top's second
# frame), skin temperature and the policy0/3/7 caps. "touched" (and nothing else) when the touch IRQs move from <count>.
# The pattern is [B]roforce_beta[.]exe: a plain Broforce_beta.exe also matched this script's own `sh -c` command line,
# so a "game" was always found and bf-quiet never started it (2026-11-05 03:02 soak: home in front for 600 s).
S=${1:-60}; I0=${2:-}
irq() { awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}' /proc/interrupts; }
front() { echo "focus $(dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | sed -nE 's#.*/[a-zA-Z0-9_.]*\.([A-Za-z0-9_$]+)\}.*#\1#p; s#.*mCurrentFocus=Window\{[^ ]+ [^ ]+ ([^}/ ]+)\}.*#\1#p' | head -1)"
  echo "resumed $(dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity | sed -nE 's#.*/[a-zA-Z0-9_.]*\.([A-Za-z0-9_$]+) .*#\1#p')"; }
ticks() { local t=0 p r; for p in $(pgrep -f '[B]roforce_beta[.]exe'); do
  r=$(cat /proc/$p/stat 2>/dev/null) || continue; r=${r##*) }; set -- $r; t=$(( t + ${12} + ${13} )); done; echo $t; }
pids() { pgrep -f '[B]roforce_beta[.]exe' | wc -l; }
front | sed 's/^/start /'
n0=$(pids); c0=$(ticks); t0=$(date +%s)
# top's 2 frames take S s; the touch IRQs are looked at once a second beside it.
top -b -n2 -d "$S" -m 12 > /data/local/tmp/powos-bfq-top.txt 2>/dev/null & tp=$!
while kill -0 $tp 2>/dev/null; do
  [ -n "$I0" ] && [ "$(irq)" != "$I0" ] && { kill $tp 2>/dev/null; echo touched; exit 0; }
  sleep 1
done
c1=$(ticks); t1=$(date +%s); n1=$(pids)
awk '/^Tasks:/{f++} f==2&&/^ *[0-9]+ /{printf "top %s%% %s\n", $9, substr($0, index($0,$12), 60)}' /data/local/tmp/powos-bfq-top.txt | head -12
rm -f /data/local/tmp/powos-bfq-top.txt
# CLK_TCK 100: ticks / s = % of one core.
echo "gamecpu $(( (c1 - c0) / ( t1 > t0 ? t1 - t0 : 1 ) )) procs=$n0/$n1"
front | sed 's/^/end /'
for z in /sys/class/thermal/thermal_zone*; do [ "$(cat $z/type)" = skin-msm-therm ] && echo "skin $(cat $z/temp)"; done
P=/sys/devices/system/cpu/cpufreq; echo "caps $(cat $P/policy0/scaling_max_freq) $(cat $P/policy3/scaling_max_freq) $(cat $P/policy7/scaling_max_freq)"
