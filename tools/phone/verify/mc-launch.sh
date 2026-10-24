#!/bin/bash
# lanes: phone
# mc-launch.sh [base|zink|glthread|zink-glthread]...: (Mac side; queue it: queue.sh add <board-task> mc-launch.sh ...)
# Minecraft (the PowStation pack, powos-minecraft + Prism Launcher) launched the drawer's way on the phone, once per
# GL variant (mc-launch-phone.sh: default base): STAGES (tap -> Prism -> Java -> NeoForge's window -> title screen),
# title-screen fps, RSS / GC, a frame of the window, then closed. A test Prism root with an offline profile - the
# user's own Prism data is never touched; a Minecraft the user runs = skipped (exit 3). The first run of a fresh test
# root also downloads Minecraft + runs NeoForge's install (LAUNCH_S=600 for that one; a warm launch is the number).
# Artefacts ~/.cache/powos-verify/mc-launch-<date>/<variant>/ (latest.log, prism.log, gc.log, hud/, h000.png).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/mc-launch-$(date +%F_%H%M)}; mkdir -p "$OUT"
for f in mc-launch-phone.sh bf-lib.sh; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "FAIL setup: can't push $f"; exit 1; }; done
"$A" shell "su -c 'cp /data/local/tmp/powos-mc-launch-phone.sh /data/local/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-mc-launch-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh && sh /data/powos/powos-run.sh \"${LAUNCH_S:+LAUNCH_S=$LAUNCH_S }${FPS_S:+FPS_S=$FPS_S }bash /var/tmp/powos-mc-launch-phone.sh $*\"'" \
  | tr -d '\r' | tee "$OUT/run.txt"
"$A" exec-out "su -c 'tar -C /data/powos/root/tmp -cz mc-logs 2>/dev/null'" > "$OUT/mc-logs.tgz" && tar -C "$OUT" -xzf "$OUT/mc-logs.tgz" 2>/dev/null && rm -f "$OUT/mc-logs.tgz"
"$A" shell "su -c 'rm -f /data/local/tmp/powos-mc-launch-phone.sh /data/local/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-mc-launch-phone.sh'"
echo "artefacts: $OUT/ (run.txt, mc-logs/<variant>/)"
grep -q "^RESULT" "$OUT/run.txt" || { grep -q "^user input\|^stopped from outside\|skipped$" "$OUT/run.txt" && exit 3; echo "FAIL run: no RESULT line"; exit 1; }
grep -q "^RESULT.*FAIL" "$OUT/run.txt" && exit 1
exit 0
