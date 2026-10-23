#!/bin/bash
# bf-coldstart.sh [app:<appid>] [win:<window title>] [setup tokens] [cold|steam|fexcache]...: (Mac side, queue it:
# queue.sh add <board-task> bf-coldstart.sh) where a Steam game's launch time goes (default Broforce 274190; any
# installed game with app:<id>, e.g. app:1167630 Teardown; its window title defaults to its Steam name): per variant, tap (the drawer's path) -> Steam's launch -> pressure-vessel -> wineserver
# -> the game's exe -> its window -> its first new frame, Steam's state at the tap and the shader/FEX cache sizes
# (bf-coldstart-phone.sh). Default: cold steam fexcache fexcache (~15 min). Closes Steam + the game after. Exit 3 on a
# real touch.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
envs="" args=()
for a in "$@"; do case $a in
  app:[0-9]*) envs="$envs APP=${a#app:}" ;;
  # Base64: a title with spaces ("RimWorld by Ludeon Studios") through su -c and powos-run.sh's quoting.
  win:*) envs="$envs WIN_B64=$(printf %s "${a#win:}" | base64 | tr -d '\n')" ;;
  *) args+=("$a") ;; esac; done
set -- "${args[@]+"${args[@]}"}"
OUT=${OUT:-$HOME/.cache/powos-verify/bf-coldstart-$(date +%F_%H%M)}; mkdir -p "$OUT"
# adb.sh mounts each pushed file's directory into its container: the path must be resolved (no "..": it pushed
# nothing, so the phone ran an old powos-open-task, 2026-10-22).
ot=$(cd "$here/../../../targets/android/session" && pwd)/powos-open-task
"$A" push "$ot" /data/local/tmp/powos-open-task >/dev/null || { echo "FAIL setup: can't push $ot"; exit 1; }
# powos-steam-compat from the repo (the steam package's per-game compat policy; the phone's may be older).
pc=$(cd "$here/../../../targets/android/pkgs/steam" && pwd)/powos-steam-compat
"$A" push "$pc" /data/local/tmp/powos-steam-compat >/dev/null || { echo "FAIL setup: can't push $pc"; exit 1; }
for f in bf-coldstart-phone.sh bf-lib.sh bf-stop.sh; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "FAIL setup: can't push $f"; exit 1; }; done
# The runner's budget kill (TERM) ends only this Mac side: the phone side ran on (2026-10-23 04:31: td-launch-phone kept
# launching Teardown while the next check ran). So the adb run waits in the background and a TERM stops the phone
# side too (its own TERM trap closes what it started).
stop_phone() { "$A" shell "su -c 'pkill -TERM -f powos-bf-coldstart-phone.sh'" >/dev/null 2>&1; kill "$job" 2>/dev/null; exit 3; }
{ "$A" shell "su -c 'install -m 755 /data/local/tmp/powos-open-task /data/powos/root/usr/local/bin/powos-open-task && cp /data/local/tmp/powos-bf-coldstart-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/local/tmp/powos-steam-compat /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-bf-*.sh /data/powos/root/var/tmp/powos-steam-compat && sh /data/powos/powos-run.sh \"env$envs bash /var/tmp/powos-bf-coldstart-phone.sh $*\"'" \
  | sed -l $'s/\r$//' | tee "$OUT/run.txt"; } &
job=$!; trap stop_phone TERM INT HUP; wait "$job"; trap - TERM INT HUP
"$A" shell "su -c 'rm -f /data/local/tmp/powos-open-task /data/local/tmp/powos-bf-coldstart-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/local/tmp/powos-steam-compat /data/powos/root/var/tmp/powos-steam-compat /data/powos/root/var/tmp/powos-bf-coldstart-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-bf-stop.sh'"
echo "artefacts: $OUT/run.txt"
grep -q "^RESULT" "$OUT/run.txt" || { grep -q "^user input\|^stopped from outside\|^not ready" "$OUT/run.txt" && exit 3; echo "FAIL run: no RESULT line"; exit 1; }
grep "^RESULT" "$OUT/run.txt" | tail -1
grep -q "^RESULT.*FAIL" "$OUT/run.txt" && exit 1
exit 0
