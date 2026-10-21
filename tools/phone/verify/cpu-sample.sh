# cpu-sample.sh <secs>: (on the phone, root) CPU % of one core for com.powos.app, its WebView renderer and the PowOS session tree, plus touch IRQs during the window (non-zero = not an idle sample)
D=${1:-150}
APP=$(pidof com.powos.app); WV=$(ps -A -o pid,args | awk '/webview:sandboxed_process/ && !/awk/{print $1}')
kids() { for c in $(cat /proc/$1/task/*/children 2>/dev/null); do echo $c; kids $c; done; }
ROOTS=$(ps -A -o pid,args | awk '/powos-session.sh/ && !/awk/{print $1}')
SESS=$( (for r in $ROOTS; do echo $r; kids $r; done; ps -A -o pid,uid | awk '$2==10359{print $1}') | sort -un | grep -vx "$APP")
tk() { set -- $(sed 's/.*) //' /proc/$1/stat 2>/dev/null); echo $(( ${12:-0} + ${13:-0} )); }
snap() { for p in $APP $WV $SESS; do echo "$p $(tk $p)"; done; }
irq() { awk '/touch-0/{for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i; else break} END{print s}' /proc/interrupts; }
i0=$(irq); snap > /data/local/tmp/cv-cpu-a.txt; t0=$(cut -d' ' -f1 /proc/uptime); c0=$(head -1 /proc/stat)
sleep $D
snap > /data/local/tmp/cv-cpu-b.txt; t1=$(cut -d' ' -f1 /proc/uptime); c1=$(head -1 /proc/stat); i1=$(irq)
W=$(echo "$t1 $t0" | awk '{print $1-$2}')
echo "window=${W}s touch_irqs_during=$((i1-i0)) focus=$(dumpsys window | grep -m1 mCurrentFocus | sed 's/.*u0 //;s/}//') app=$APP webview=$(echo $WV) session_procs=$(echo $SESS | wc -w)"
echo "$c0
$c1" | awk 'NR==1{for(i=2;i<=NF;i++)a+=$i; ai=$5+$6} NR==2{for(i=2;i<=NF;i++)b+=$i; bi=$6+$5; printf "whole phone busy: %.1f%% of one core (8 cores)\n", ((b-a)-(bi-ai))/(b-a)*800}'
awk -v W=$W -v app="$APP" -v wv=" $(echo $WV) " -v sess=" $(echo $SESS) " 'NR==FNR{a[$1]=$2;next} ($1 in a){d=$2-a[$1]; if(d<0)d=0; if($1==app)A+=d; else if(index(wv," "$1" "))V+=d; else if(index(sess," "$1" "))S+=d; if(d>0)print "P", $1, d}
 END{printf "com.powos.app: %.2f%%  webview renderer: %.2f%%  PowOS session: %.2f%%  (of one core)\n", A/W, V/W, S/W}' /data/local/tmp/cv-cpu-a.txt /data/local/tmp/cv-cpu-b.txt > /data/local/tmp/cv-cpu-r.txt
grep -v ^P /data/local/tmp/cv-cpu-r.txt
grep ^P /data/local/tmp/cv-cpu-r.txt | sort -k3 -nr | head -10 | while read x p t; do echo "  $p $(cat /proc/$p/comm 2>/dev/null) $(awk -v t=$t -v W=$W 'BEGIN{printf "%.2f%%", t/W}')"; done
