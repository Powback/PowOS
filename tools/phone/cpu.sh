#!/bin/bash
# Per-process CPU on the phone over a window: "cpu.sh [seconds=60] [top=15]".
# Prints "<%cpu of one core> <pid> <name>" sorted, then the total (all processes, % of one core; the phone has 8 cores,
# so 800 = everything busy) and the screen state. Read-only: /proc/<pid>/stat utime+stime (HZ=100) at the start and the
# end of the window, as root (every process). Doesn't touch input or the screen; safe while the user uses the phone,
# but an "idle" number is only one at idle>=120 (tools/phone/idle.sh).
secs=${1:-60}
top=${2:-15}
here=$(dirname "$0")
"$here/adb.sh" shell "su -c 'sh -s'" <<EOF
snap() { for d in /proc/[0-9]*; do { read -r l < \$d/stat; } 2>/dev/null || continue; echo "\${d#/proc/} \$l"; done; }
# comm can hold spaces: everything after the last ")" is the numeric tail (utime = field 14, stime = 15 of stat).
ticks() { sed -E 's/^([0-9]+) [0-9]+ \((.*)\) (.*)$/\1 \2|\3/' | awk -F'|' '{ split(\$1, h, " "); pid = h[1]; name = substr(\$1, length(pid) + 2); gsub(/ /, "_", name); split(\$2, t, " "); print pid, t[12] + t[13], name }'; }
snap | ticks > /data/local/tmp/powos-cpu.a
sleep $secs
snap | ticks > /data/local/tmp/powos-cpu.b
awk -v secs=$secs -v top=$top 'NR == FNR { a[\$1] = \$2; next } (\$1 in a) { d = \$2 - a[\$1]; if (d > 0) { tot += d; printf "%.1f %s %s\n", d / secs, \$1, \$3 } } END { printf "%.1f total\n", tot / secs > "/data/local/tmp/powos-cpu.tot" }' /data/local/tmp/powos-cpu.a /data/local/tmp/powos-cpu.b | sort -rn | head -n $top
cat /data/local/tmp/powos-cpu.tot
# cmdline for the names that hide behind a generic comm (python3, sh, app_process)
rm -f /data/local/tmp/powos-cpu.a /data/local/tmp/powos-cpu.b /data/local/tmp/powos-cpu.tot
echo screen=\$(dumpsys power | sed -n 's/.*mWakefulness=//p' | head -1)
EOF
