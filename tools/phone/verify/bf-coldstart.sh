#!/bin/bash
# bf-coldstart.sh [cold|steam|fexcache]...: (Mac side, queue it: queue.sh add <board-task> bf-coldstart.sh) where a
# Broforce launch's time goes: per variant, tap (the drawer's path) -> Steam's launch -> pressure-vessel -> wineserver
# -> the game's exe -> its window -> its first new frame, Steam's state at the tap and the shader/FEX cache sizes
# (bf-coldstart-phone.sh). Default: cold steam fexcache fexcache (~15 min). Closes Steam + the game after. Exit 3 on a
# real touch.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/bf-coldstart-$(date +%F_%H%M)}; mkdir -p "$OUT"
# adb.sh mounts each pushed file's directory into its container: the path must be resolved (no "..": it pushed
# nothing, so the phone ran an old powos-open-task, 2026-10-22).
ot=$(cd "$here/../../../targets/android/session" && pwd)/powos-open-task
"$A" push "$ot" /data/local/tmp/powos-open-task >/dev/null || { echo "FAIL setup: can't push $ot"; exit 1; }
for f in bf-coldstart-phone.sh bf-lib.sh bf-stop.sh bf-cfg.py; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "FAIL setup: can't push $f"; exit 1; }; done
"$A" shell "su -c 'install -m 755 /data/local/tmp/powos-open-task /data/powos/root/usr/local/bin/powos-open-task && cp /data/local/tmp/powos-bf-coldstart-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/local/tmp/powos-bf-cfg.py /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-bf-*.sh /data/powos/root/var/tmp/powos-bf-cfg.py && sh /data/powos/powos-run.sh \"bash /var/tmp/powos-bf-coldstart-phone.sh $*\"'" \
  | tr -d '\r' | tee "$OUT/run.txt"
"$A" shell "su -c 'rm -f /data/local/tmp/powos-open-task /data/local/tmp/powos-bf-coldstart-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/local/tmp/powos-bf-cfg.py /data/powos/root/var/tmp/powos-bf-cfg.py /data/powos/root/var/tmp/powos-bf-coldstart-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-bf-stop.sh'"
echo "artefacts: $OUT/run.txt"
grep -q "^RESULT" "$OUT/run.txt" || { grep -q "^user input\|^stopped from outside" "$OUT/run.txt" && exit 3; echo "FAIL run: no RESULT line"; exit 1; }
grep "^RESULT" "$OUT/run.txt" | tail -1
grep -q "^RESULT.*FAIL" "$OUT/run.txt" && exit 1
exit 0
