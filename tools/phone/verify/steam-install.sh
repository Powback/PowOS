#!/bin/bash
# steam-install.sh <appid>...: (Mac side, queue it: queue.sh add <board-task> steam-install.sh <appid>...) Steam's own
# install (steam://install/<appid>) of games the user already owns, in a free window (steam-install-phone.sh): queues
# the downloads and leaves Steam downloading in the background. Never launches a game. Queue the games' checks
# (bf-coldstart.sh app:<id> ...) after it: they wait ("not ready", exit 3) until Steam has finished downloading.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
[ $# -gt 0 ] || { echo "usage: steam-install.sh <appid>..."; exit 2; }
for id in "$@"; do case $id in *[!0-9]*) echo "steam-install.sh: not an appid: $id"; exit 2 ;; esac; done
OUT=${OUT:-$HOME/.cache/powos-verify/steam-install-$(date +%F_%H%M)}; mkdir -p "$OUT"
for f in steam-install-phone.sh bf-lib.sh; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "FAIL setup: can't push $f"; exit 1; }; done
"$A" shell "su -c 'cp /data/local/tmp/powos-steam-install-phone.sh /data/local/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-steam-install-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh && sh /data/powos/powos-run.sh \"bash /var/tmp/powos-steam-install-phone.sh $*\"'" \
  | tr -d '\r' | tee "$OUT/run.txt"
"$A" shell "su -c 'rm -f /data/local/tmp/powos-steam-install-phone.sh /data/local/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-steam-install-phone.sh'"
echo "artefacts: $OUT/run.txt"
grep -q "^RESULT" "$OUT/run.txt" || { grep -q "^user input\|^stopped from outside" "$OUT/run.txt" && exit 3; echo "FAIL run: no RESULT line"; exit 1; }
grep "^RESULT" "$OUT/run.txt" | tail -1
grep -q "^RESULT.*FAIL" "$OUT/run.txt" && exit 1
exit 0
