#!/bin/bash
# lanes: phone
# steam-pipe-probe.sh: (Mac side, queue it) runs steam-pipe-probe-phone.sh: what Steam's forwarder writes into steam.pipe and
# whether the running ARM64 client takes a hand-written / replayed line (header of the phone script). Exit 3 on a touch.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/steam-pipe-probe-$(date +%F_%H%M)}; mkdir -p "$OUT"
ot=$(cd "$here/../../../targets/android/session" && pwd)/powos-open-task
"$A" push "$ot" /data/local/tmp/powos-open-task >/dev/null || { echo "FAIL setup: can't push $ot"; exit 1; }
for f in steam-pipe-probe-phone.sh bf-lib.sh bf-stop.sh; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "FAIL setup: can't push $f"; exit 1; }; done
"$A" shell "su -c 'install -m 755 /data/local/tmp/powos-open-task /data/powos/root/usr/local/bin/powos-open-task && cp /data/local/tmp/powos-steam-pipe-probe-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-bf-*.sh && sh /data/powos/powos-run.sh \"bash /var/tmp/powos-steam-pipe-probe-phone.sh\"'" \
  | sed -l $'s/\r$//' | tee "$OUT/run.txt"
"$A" shell "su -c 'rm -f /data/local/tmp/powos-open-task /data/local/tmp/powos-steam-pipe-probe-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/powos-steam-pipe-probe-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-bf-stop.sh'"
echo "artefacts: $OUT/run.txt"
grep -q "^RESULT" "$OUT/run.txt" || { grep -q "^user input\|^stopped from outside" "$OUT/run.txt" && exit 3; echo "FAIL run: no RESULT line"; exit 1; }
grep "^RESULT" "$OUT/run.txt" | tail -1
grep -q "^RESULT.*FAIL" "$OUT/run.txt" && exit 1
exit 0
