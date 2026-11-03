P=$(for d in /proc/[0-9]*; do c=$(tr '\0' ' ' < $d/cmdline 2>/dev/null); case "$c" in *FEX*Broforce*|*FEX*wine*i386*Broforce*) echo ${d#/proc/} $(cat $d/task/*/stat 2>/dev/null | wc -l);; esac; done | sort -k2 -n | tail -1 | cut -d' ' -f1)
echo game_pid=$P; [ -z "$P" ] && { echo NOGAME; exit 0; }
tr '\0' ' ' < /proc/$P/cmdline | cut -c1-300; echo
grep -E "Cpus_allowed_list" /proc/$P/status
snapt() { for t in /proc/$P/task/*; do s=$(cat $t/stat 2>/dev/null) || continue; r=${s##*) }; set -- $r; echo "${t##*/} $(( ${12} + ${13} )) ${37} $(cat $t/comm | tr ' ' _)"; done; }
snapcpu() { head -9 /proc/stat; }
gpu() { K=/sys/class/kgsl/kgsl-3d0; echo "busy=$(cat $K/gpu_busy_percentage 2>/dev/null) clk=$(cat $K/gpuclk 2>/dev/null) devfreq=$(cat $K/devfreq/cur_freq 2>/dev/null) max=$(cat $K/max_gpuclk 2>/dev/null) pwr=$(cat $K/max_pwrlevel $K/min_pwrlevel $K/thermal_pwrlevel 2>/dev/null|tr '\n' ,) temp=$(cat $K/temp 2>/dev/null)"; }
echo "== static"; K=/sys/class/kgsl/kgsl-3d0; echo avail=$(cat $K/gpu_available_frequencies 2>/dev/null); echo gov=$(cat $K/devfreq/governor 2>/dev/null) dfmax=$(cat $K/devfreq/max_freq) dfmin=$(cat $K/devfreq/min_freq)
for p in /sys/devices/system/cpu/cpufreq/policy*; do echo "${p##*/} cpus=$(cat $p/related_cpus) gov=$(cat $p/scaling_governor) cur=$(cat $p/scaling_cur_freq) max=$(cat $p/scaling_max_freq) hwmax=$(cat $p/cpuinfo_max_freq)"; done
snapt > /data/local/tmp/bft.a; snapcpu > /data/local/tmp/bfc.a
echo "== gpu samples (1/s for 30 s) + cpu cur freqs"
for i in $(seq 1 30); do echo "$(gpu) cpu=$(for p in /sys/devices/system/cpu/cpufreq/policy*; do printf '%s ' $(($(cat $p/scaling_cur_freq)/1000)); done)"; sleep 1; done
snapt > /data/local/tmp/bft.b; snapcpu > /data/local/tmp/bfc.b
echo "== per-thread %core over 30 s (tid pct lastcpu comm)"
awk 'NR==FNR{a[$1]=$2;next} ($1 in a){d=$2-a[$1]; if(d>3) printf "%d %.0f%% cpu%s %s\n",$1,d/0.30,$3,$4}' /data/local/tmp/bft.a /data/local/tmp/bft.b | sort -k2 -rn | head -20
echo "== per-cpu busy over 30 s"
paste /data/local/tmp/bfc.a /data/local/tmp/bfc.b | awk '{n=NF/2; ta=0;tb=0; for(i=2;i<=n;i++){ta+=$i;tb+=$(i+n)} ia=$5+$6; ib=$(5+n)+$(6+n); printf "%s %.0f%%\n",$1,100*(1-(ib-ia)/(tb-ta))}'
echo "== affinity of hot threads"; for t in /proc/$P/task/*; do grep -q Cpus_allowed_list $t/status && echo "$(cat $t/comm) $(grep Cpus_allowed_list $t/status|awk '{print $2}')"; done | sort | uniq -c | sort -rn | head
cat /proc/$P/cpuset 2>/dev/null; cat /proc/$P/cgroup | head -5
echo "== thermal"; for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/type); case "$t" in *skin*|*gpu*|*cpu-1-*|*xo*|*sys-therm*|battery) echo "$t $(cat $z/temp)";; esac; done | head -30
for c in /sys/class/thermal/cooling_device*; do t=$(cat $c/type); case "$t" in *gpu*|*cpu*|thermal-cpufreq*|*devfreq*) echo "cool $t $(cat $c/cur_state)/$(cat $c/max_state)";; esac; done | head -20
rm -f /data/local/tmp/bf[tc].[ab]
