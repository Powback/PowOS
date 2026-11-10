# linux-cold-open-phone.sh APP_ID EXE EXEC TAG (Android sh, root; pushed and run by linux-cold-open.sh): one cold open of
# a Linux app as its own task, started exactly the way the PowOS app's drawer starts it (RootedGuest.rootCommand ->
# powos-run.sh -> powos-open-task), every stage stamped on the phone's own clock (ms since the launch call):
#   exec   the app's process start (/proc/<pid>/stat starttime, so not the poll's resolution)
#   task   KWin exported its first window as a task ("new window ... ( "<id>" ) opened as a task")
#   live   that task's buffer is live in KWin ("window task N live ... for "<caption>"": the first frame reaches the host)
#   status powos-open-task printed "task" (the caller's status line)
# plus which ksycoca6 cache the launch (re)built, if any - the in-process kbuildsycoca of 11-10 04:38 (docs/research/
# linux-app-cold-start.md). Prints key=value lines; never touches a running instance (exit 3 when EXE already runs).
ID=$1 EXE=$2 EXEC=$3 TAG=$4
R=/data/powos/root; H=$R/run/powos-app/hyprland.log; C=$R/home/powos/.cache; O=/data/local/tmp/powos-cold-$TAG.out
now() { echo $(( $(date +%s%N) / 1000000 )); }
[ -z "$(pidof "$EXE")" ] || { echo "running=1"; exit 3; }
L=$(tr '\0' '\n' < /proc/$(pidof kwin_wayland | cut -d' ' -f1)/environ 2>/dev/null | sed -n 's/^LANG=//p')
syc0=$(cd $C && for f in ksycoca6_*; do echo "$(stat -c %Y "$f") $f"; done)
k0=$(grep -a -c . $H)
T0=$(now)
WAYLAND_DISPLAY=wayland-0 LANG="${L:-C.UTF-8}" sh /data/powos/powos-run.sh \
  "powos-open-task --app-id '$ID' -- '$EXEC'" > $O 2>&1 &
pid="" task="" live="" status="" cap=""
while [ $(( $(now) - T0 )) -lt 30000 ]; do
  [ -n "$pid" ] || pid=$(pidof "$EXE" | cut -d' ' -f1)
  if [ -z "$task" ]; then
    l=$(tail -n +$((k0 + 1)) $H | grep -a -m1 "( \"$ID\" ) opened as a task")
    [ -n "$l" ] && { task=$(( $(now) - T0 )); cap=$(echo "$l" | sed -n 's/.*new window "\(.*\)" ( ".*/\1/p'); }
  fi
  [ -n "$task" ] && [ -z "$live" ] && tail -n +$((k0 + 1)) $H | grep -a -q "window task [0-9]* live, .* for \"$cap\"" && live=$(( $(now) - T0 ))
  [ -z "$status" ] && grep -q '^powos-open-task: task' $O && status=$(( $(now) - T0 ))
  [ -n "$live" ] && [ -n "$status" ] && break
  sleep 0.05
done
exec_ms=-
if [ -n "$pid" ] && [ -r /proc/$pid/stat ]; then
  st=$(sed 's/.*) //' /proc/$pid/stat | cut -d' ' -f20); bt=$(sed -n 's/^btime //p' /proc/stat); hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  exec_ms=$(( (bt * 1000 + st * 1000 / hz) - T0 ))
fi
syc1=$(cd $C && for f in ksycoca6_*; do echo "$(stat -c %Y "$f") $f"; done)
echo "exec=$exec_ms"; echo "task=${task:--}"; echo "live=${live:--}"; echo "status=${status:--}"; echo "pid=${pid:--}"
echo "sycoca_rebuilt=$(echo "$syc1" | grep -vxF "$syc0" | cut -d' ' -f2 | tr '\n' ' ')"
echo "caption=$cap"
grep -a '^powos-open-task: timing' $O | tail -1 | sed 's/^powos-open-task: timing/helper=/'
