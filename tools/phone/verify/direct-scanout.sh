#!/bin/bash
# lanes: phone
# direct-scanout.sh: (Mac) step 1 of docs/research/window-task-direct-scanout.md - does the QTI mapper + HWC take a
# gralloc buffer cloned from a template AHardwareBuffer with a foreign dma-buf fd (Broforce's layout: 1116x2484 XR24
# linear, pitch 4608, a system dma-heap buffer) shown on a child ASurfaceControl? Builds direct-scanout/ (NDK + the
# android builder image), pushes it, runs it as root under app_process twice (the clone's size field = the dma-buf's
# real size, then = the template's), ~12 s of a full-screen test pattern on the active display each, and judges
# (direct-scanout/analyze.py): import ok, the clone layer DEVICE-composed shown + flipping, screencap = the pattern
# pixel for pixel, CPU-lock read-back = the pattern, release fences arrive. Board task broforce-fps-low-cpu-bound-under-fex.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"; S=$here/direct-scanout
OUT=${OUT:-$HOME/.cache/powos-verify/direct-scanout-$(date +%F_%H%M)}; mkdir -p "$OUT"
"$S/build.sh" "$OUT/bin" >"$OUT/build.log" 2>&1 || { tail -5 "$OUT/build.log"; echo "ENV: build failed"; exit 5; }
P=/data/local/tmp/powos-ds
"$A" shell "su -c 'mkdir -p $P && chmod 777 $P'" >/dev/null
"$A" push "$OUT/bin/libdstest.so" "$OUT/bin/dstest.dex" "$S/ds-phone.sh" $P/ >/dev/null || { echo "ENV: push failed"; exit 5; }
"$A" shell "su -c 'dumpsys SurfaceFlinger'" | tr -d '\r' > "$OUT/sf-before.txt"
DID=$(awk '/\(active\) HWC layers/{print $2; exit}' "$OUT/sf-before.txt")
LS=$(awk -v d="$DID" '$1=="Display" && $2==d && /physical/{p=1; next} p && /layerStack=/{sub(/.*layerStack=/,""); sub(/[^0-9].*/,""); print; exit}' "$OUT/sf-before.txt")
[ -n "$DID" ] && [ -n "$LS" ] || { echo "ENV: no active display / layer stack in dumpsys SurfaceFlinger"; exit 5; }
echo "active display $DID layerStack $LS; app $("$A" shell "dumpsys package com.powos.app | grep -m1 versionName" | tr -d '\r ')"
for mode in fit keep; do
  "$A" shell "su -c 'sh $P/ds-phone.sh $P $LS $DID $mode size=$mode hold=4 flip=3'" >/dev/null 2>&1
  for f in log logcat.txt sf-shown.txt sf-flip.txt shown.raw shown.png end.raw; do "$A" pull "$P/$mode.$f" "$OUT/" >/dev/null 2>&1; done
done
"$A" shell "su -c 'rm -rf $P'" >/dev/null 2>&1
echo "evidence: $OUT (screencap $OUT/fit.shown.png)"
python3 "$here/direct-scanout/analyze.py" "$OUT" fit keep; rc=$?
[ $rc = 0 ] && echo "PASS direct-scanout step 1: cloned gralloc buffer imported, DEVICE-composed, pixel-exact" ||
  echo "FAIL direct-scanout step 1 (see the FAIL lines above)"
exit $rc
