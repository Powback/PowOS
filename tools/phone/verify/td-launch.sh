#!/bin/bash
# td-launch.sh [arm64|x86]...: (Mac side, queue it: queue.sh add --budget 1500 <board-task> td-launch.sh) Teardown
# (1167630) cold launches with every log on, one per variant = the Proton it runs on (td-launch-phone.sh: arm64 =
# Proton Experimental (ARM64), x86 = Proton Experimental under FEX), default arm64 x86 (~10-20 min). Per variant: the
# stages (tap -> reaper -> pressure-vessel -> wineserver -> teardown.exe -> window -> first frame), Steam's stdout,
# PROTON_LOG, FEX telemetry, a screenshot of the window; closes the game + Steam after and puts Steam's tool mapping
# back (KEEP=<variant> keeps that one). Artefacts ~/.cache/powos-verify/td-launch-<date>/. Exit 3 on a real touch.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/td-launch-$(date +%F_%H%M)}; mkdir -p "$OUT"
for f in td-launch-phone.sh bf-lib.sh bf-stop.sh; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "FAIL setup: can't push $f"; exit 1; }; done
"$A" shell "su -c 'cp /data/local/tmp/powos-td-launch-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-td-launch-phone.sh /data/powos/root/var/tmp/powos-bf-*.sh && sh /data/powos/powos-run.sh \"${KEEP:+KEEP=$KEEP }${LAUNCH_S:+LAUNCH_S=$LAUNCH_S }bash /var/tmp/powos-td-launch-phone.sh $*\"'" \
  | tr -d '\r' | tee "$OUT/run.txt"
"$A" exec-out "su -c 'tar -C /data/powos/root/tmp -cz td-logs 2>/dev/null'" > "$OUT/td-logs.tgz" && tar -C "$OUT" -xzf "$OUT/td-logs.tgz" 2>/dev/null && rm -f "$OUT/td-logs.tgz"
"$A" shell "su -c 'rm -f /data/local/tmp/powos-td-launch-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/powos-td-launch-phone.sh'"
echo "artefacts: $OUT/ (run.txt, td-logs/<variant>/: steam.out, steam-1167630.log, gameprocess, console, fex-telemetry, window.png)"
grep -q "^RESULT" "$OUT/run.txt" || { grep -q "^user input\|^stopped from outside" "$OUT/run.txt" && exit 3; echo "FAIL run: no RESULT line"; exit 1; }
grep "^RESULT" "$OUT/run.txt" | tail -1
grep -q "^RESULT.*FAIL" "$OUT/run.txt" && exit 1
exit 0
