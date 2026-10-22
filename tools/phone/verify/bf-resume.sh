#!/bin/bash
# bf-resume.sh: (Mac side, queue it: queue.sh add <board-task> bf-resume.sh) Broforce's instant start - a game kept
# alive and frozen with Steam out of sight (units/phone/steam.json "games": "pause", docs/UNIFIED-SLEEP.md), resumed
# by its launch. Measures cold start vs thawed start (the launch command -> the game's window focused -> its first new
# frame), Steam's tree's CPU while frozen, the compositor/X server answering while it is frozen, and Steam's
# connection log after the thaw. ~7 min. A Broforce already running (the user's) is used as it is and left running;
# one this check started is closed after (bf-stop.sh). Exit 3 on a real touch (the queue retries in the next window).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/bf-resume-$(date +%F_%H%M)}; mkdir -p "$OUT"
# adb.sh mounts each pushed file's directory into its container: the path must be resolved (no "..": it pushed
# nothing, so the phone ran an old powos-open-task, 2026-10-22).
ot=$(cd "$here/../../../targets/android/session" && pwd)/powos-open-task
"$A" push "$ot" /data/local/tmp/powos-open-task >/dev/null || { echo "FAIL setup: can't push $ot"; exit 1; }
for f in bf-resume-phone.sh bf-lib.sh bf-stop.sh; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "FAIL setup: can't push $f"; exit 1; }; done
"$A" shell "su -c 'install -m 755 /data/local/tmp/powos-open-task /data/powos/root/usr/local/bin/powos-open-task && cp /data/local/tmp/powos-bf-resume-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-bf-*.sh && sh /data/powos/powos-run.sh \"bash /var/tmp/powos-bf-resume-phone.sh\"'" \
  | tr -d '\r' | tee "$OUT/run.txt"
"$A" shell "su -c 'rm -f /data/local/tmp/powos-open-task /data/local/tmp/powos-bf-resume-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/powos-bf-resume-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-bf-stop.sh'"
echo "artefacts: $OUT/run.txt"
grep -q "^RESULT" "$OUT/run.txt" || { grep -q "^user input\|^stopped from outside" "$OUT/run.txt" && exit 3; echo "FAIL run: no RESULT line"; exit 1; }
grep "^RESULT" "$OUT/run.txt" | tail -1
grep -q "^RESULT.*FAIL" "$OUT/run.txt" && exit 1
exit 0
