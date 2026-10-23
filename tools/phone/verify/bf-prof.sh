# bf-prof.sh <secs> <outdir>: (on the phone, root; bf-pacing.sh runs it beside bf-present.sh) where a running game's
# time goes, read-only: <outdir>/prof.txt =
#   thread  <%cpu> <pid> <tid> <process>/<thread> cpu=<last cpu>   the 25 busiest threads over <secs> (any process)
#   cluster policy<N> cpus=<list> cur=<avg MHz> cap=<min scaling_max MHz> hw=<cpuinfo_max MHz>   1 s samples
#   gpu busy=<avg %> clk=<avg MHz> max=<max_gpuclk MHz> thermal_pwrlevel=<max> throttling=<last>
#   temp <zone> <max C>                                   the 4 hottest thermal zones
#   cgroup <pid> <comm> <cpuset line> allowed=<cpus>      for each process with a thread above 20%
# A cap below hw = someone (thermal, the vendor's performance HAL) limits that cluster while the game runs.
s=${1:-30} out=${2:-/data/local/tmp/bfprof}; mkdir -p "$out"; f=$out/prof.txt; : > "$f"
snap() { for t in /proc/[0-9]*/task/[0-9]*; do read -r l < "$t/stat" 2>/dev/null && echo "${t#/proc/} $l"; done 2>/dev/null; }
snap > "$out/s1"; K=/sys/class/kgsl/kgsl-3d0; P=/sys/devices/system/cpu/cpufreq
i=0; : > "$out/samples"
while [ $i -lt "$s" ]; do
  i=$((i + 1))
  for c in $P/policy*; do echo "C ${c##*/} $(cat "$c/scaling_cur_freq") $(cat "$c/scaling_max_freq")"; done >> "$out/samples"
  echo "G $(cat $K/gpu_busy_percentage | tr -dc 0-9) $(cat $K/gpuclk) $(cat $K/thermal_pwrlevel) $(cat $K/throttling)" >> "$out/samples"
  for z in /sys/class/thermal/thermal_zone*; do t=$(cat "$z/temp" 2>/dev/null) && [ "${t:-0}" -gt 1000 ] && echo "T $(cat "$z/type") $t"; done >> "$out/samples"
  sleep 1
done
snap > "$out/s2"
awk -v s="$s" 'function v(l,  r, a) { r = substr(l, index(l, ") ") + 2); split(r, a, " "); return a[12] + a[13] }
  function lc(l,  r, a) { r = substr(l, index(l, ") ") + 2); split(r, a, " "); return a[37] }
  function cm(l) { return substr(l, index(l, "(") + 1, index(l, ") ") - index(l, "(") - 1) }
  NR == FNR { b[$1] = v($0); n[$1] = cm($0); next }
  { split($1, k, "/"); if (k[1] == k[3]) pn[k[1]] = cm($0); if ($1 in b) { d[$1] = v($0) - b[$1]; L[$1] = lc($0); T[$1] = cm($0) } }
  END { for (t in d) if (d[t] > 0) { split(t, k, "/"); printf "thread %5.1f %s %s %s/%s cpu=%s\n", d[t] / s, k[1], k[3], pn[k[1]], T[t], L[t] } }' \
  "$out/s1" "$out/s2" | sort -k2 -rn | head -25 >> "$f"
awk '$1 == "C" { n[$2]++; c[$2] += $3; if (!($2 in m) || $4 < m[$2]) m[$2] = $4 }
  END { for (p in n) printf "%s %d %d\n", p, c[p] / n[p] / 1000, m[p] / 1000 }' "$out/samples" | sort | while read -r p cur cap; do
  echo "cluster $p cpus=$(tr ' ' , < $P/$p/related_cpus | sed 's/,$//') cur=$cur cap=$cap hw=$(( $(cat $P/$p/cpuinfo_max_freq) / 1000 ))"; done >> "$f"
awk -v mx="$(( $(cat $K/max_gpuclk) / 1000000 ))" '$1 == "G" { n++; b += $2; c += $3; if ($4 > tp) tp = $4; th = $5 }
  END { if (n) printf "gpu busy=%d clk=%d max=%d thermal_pwrlevel=%d throttling=%s\n", b / n, c / n / 1000000, mx, tp, th }' "$out/samples" >> "$f"
awk '$1 == "T" { if ($3 > m[$2]) m[$2] = $3 } END { for (z in m) printf "temp %s %.1f\n", z, m[z] / 1000 }' "$out/samples" | sort -k3 -rn | head -4 >> "$f"
for p in $(awk '$1 == "thread" && $2 > 20 {print $3}' "$f" | sort -u); do
  echo "cgroup $p $(cat /proc/$p/comm 2>/dev/null) $(grep -m1 ':cpuset:' /proc/$p/cgroup 2>/dev/null) allowed=$(awk '/Cpus_allowed_list/ {print $2}' /proc/$p/status 2>/dev/null)"
done >> "$f"
rm -f "$out/s1" "$out/s2"; chmod -R 755 "$out"
