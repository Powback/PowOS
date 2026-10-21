#!/bin/bash
# journey.sh [RUNS=A B C] [OUT=~/.cache/powos-verify/<date>]: one verification window, from the Mac.
#   waits ONCE for the phone (idle.sh --wait 120, screen Awake - never polls, never wakes it), holds
#   ~/.cache/powos-verify.lock (ship-apk.sh won't install over it), runs gest.sh per run on the phone, voids the window
#   if com.powos.app restarted, pulls the recordings/screenshots to OUT (under $HOME: Colima shares only that) and
#   deletes them from the phone. Exit 3 = a real touch came (stopped), 4 = phone never free / lock busy.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
RUNS=${RUNS:-A B C}; OUT=${OUT:-$HOME/.cache/powos-verify/$(date +%F_%H%M)}; L=$HOME/.cache/powos-verify.lock
mkdir -p "$OUT"
s=$("$T/idle.sh" --wait 120 ${MAX_WAIT:-3600}) || { echo "phone not free: $s"; exit 4; }
case "$s" in *Awake*) ;; *) echo "screen off ($s): no journey (never wake it)"; exit 4 ;; esac
mkdir "$L" 2>/dev/null || { echo "verify lock busy: $(cat "$L/who" 2>/dev/null)"; exit 4; }
echo "powos-verify journey ($RUNS) $(date +%T)" > "$L/who"; trap 'rm -rf "$L"' EXIT
"$A" push "$here/gest.sh" /data/local/tmp/powos-gest.sh >/dev/null
p0=$("$A" shell pidof com.powos.app | tr -d '\r'); rc=0
for r in $RUNS; do
  echo "== run $r"; "$A" shell "su -c 'sh /data/local/tmp/powos-gest.sh $r'" 2>&1 | grep -v "Broken pipe"
  [ "${PIPESTATUS[0]}" = 3 ] && { echo "user touched - stopped"; rc=3; break; }
done
p1=$("$A" shell pidof com.powos.app | tr -d '\r'); [ "$p0" = "$p1" ] || { echo "com.powos.app restarted ($p0 -> $p1): runs VOID"; rc=5; }
"$A" shell "su -c 'chmod 644 /data/local/tmp/cv/*'" >/dev/null 2>&1
"$A" pull /data/local/tmp/cv/. "$OUT/" >/dev/null && "$A" shell "su -c 'rm -rf /data/local/tmp/cv /data/local/tmp/powos-gest.sh'"
echo "artefacts: $OUT"; exit $rc
