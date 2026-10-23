#!/bin/bash
# bf-launchpaths.sh: (Mac side, queue it: queue.sh add <board-task> bf-launchpaths.sh) a running, frozen Broforce
# brought back by the Android launch paths - powos-open-task as the drawer runs it (--app-id <.desktop id>) and as the
# games widget runs it (Runtime.launch: --app-id steam_app_<appid>): each must resume (thaw Steam + the game) and show
# the game's window as its own task ("powos-open-task: task") in seconds, no cold Proton start. Installs this
# checkout's session/powos-open-task first (as rooted.sh deploy does). ~3 min with Broforce running, ~6 cold. A
# Broforce already running is left running; one this check started is closed after. Exit 3 on a real touch.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/bf-launchpaths-$(date +%F_%H%M)}; mkdir -p "$OUT"
# adb.sh mounts each pushed file's directory into its container: the path must be resolved (no "..": it pushed
# nothing, so the phone ran an old powos-open-task, 2026-10-22).
ot=$(cd "$here/../../../targets/android/session" && pwd)/powos-open-task
"$A" push "$ot" /data/local/tmp/powos-open-task >/dev/null || { echo "FAIL setup: can't push $ot"; exit 1; }
for f in bf-launchpaths-phone.sh bf-lib.sh bf-stop.sh; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "FAIL setup: can't push $f"; exit 1; }; done
"$A" shell "su -c 'install -m 755 /data/local/tmp/powos-open-task /data/powos/root/usr/local/bin/powos-open-task && cp /data/local/tmp/powos-bf-launchpaths-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-bf-*.sh && sh /data/powos/powos-run.sh \"bash /var/tmp/powos-bf-launchpaths-phone.sh\"'" \
  | sed -l $'s/\r$//' | tee "$OUT/run.txt"
"$A" shell "su -c 'rm -f /data/local/tmp/powos-open-task /data/local/tmp/powos-bf-launchpaths-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/powos-bf-launchpaths-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-bf-stop.sh'"
echo "artefacts: $OUT/run.txt"
grep -q "^RESULT" "$OUT/run.txt" || { grep -q "^user input\|^stopped from outside" "$OUT/run.txt" && exit 3; echo "FAIL run: no RESULT line"; exit 1; }
grep "^RESULT" "$OUT/run.txt" | tail -1
grep -q "^RESULT.*FAIL" "$OUT/run.txt" && exit 1
exit 0
