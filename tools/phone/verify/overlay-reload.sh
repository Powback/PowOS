#!/bin/bash
# tools/phone/verify/overlay-reload.sh: a shell push never leaves an overlay (the shade) opening onto a reloading page
# (skill: powos-gestures). In one free window, under the verify lock: home in front, a shell file landed in the override
# folder (unchanged: the APK's own copy, so only the reload happens), then at once a pull down on home - the shade must come up showing its
# page (screencap mid-pull), and the log must show the hidden pages reloaded by their hosts (PowosOverlay "reloading
# the hidden page" / "reloaded and ready"), not on the pull.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); A=$here/adb.sh; root=$(cd "$here/../.." && pwd)
OUT=${OUT:-$HOME/powos-rec/overlay-reload-$(date +%H%M%S)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock; n=0
until mkdir "$L" 2>/dev/null; do
  [ $n -ge 120 ] && { echo "overlay-reload.sh: verify lock busy for an hour"; exit 4; }
  n=$((n + 1)); sleep 30
done
echo "overlay-reload.sh $(date +%T) (pid $$)" > "$L/who"; trap 'rm -rf "$L"' EXIT
s=$(AWAKE_ONLY=1 "$here/idle.sh" --wait 120 "${WAIT_S:-7200}") || { echo "no free window: $s"; exit 3; }
echo "$s"
"$A" shell input keyevent KEYCODE_HOME; sleep 1.5
read -r W H < <("$A" shell "dumpsys window displays | grep -m1 -o 'cur=[0-9]*x[0-9]*'" | tr -d '\r' | sed 's/cur=\([0-9]*\)x\([0-9]*\)/\1 \2/')
"$A" shell logcat -c
# A shell file "changed" exactly as a push lands one: the installed APK's own copy (origin's, which the APK was built
# from: no change in what runs) written into the override folder - every page's hot reload fires. Removed after.
F=/data/data/com.powos.app/files/shell/ui/quicktools.tsx
"$A" push "$root/shell/ui/quicktools.tsx" /data/local/tmp/ovr-qt.tsx >/dev/null
own=$("$A" shell "su -c 'stat -c %u:%g /data/data/com.powos.app/files'" | tr -d '\r')
"$A" shell "su -c 'mkdir -p ${F%/*} && cp /data/local/tmp/ovr-qt.tsx $F && chown -R $own ${F%/*} && rm /data/local/tmp/ovr-qt.tsx'"
# The pull at once, while the hidden pages reload: slow, so the window is up mid-pull for the screencap.
"$A" shell "input motionevent DOWN $((W/2)) $((H*30/100)); for i in 1 2 3 4 5 6 7 8; do input motionevent MOVE $((W/2)) \$(($((H*30/100)) + i*$((H*3/100)))); sleep 0.1; done; sleep 0.8; screencap -p /data/local/tmp/ovr.png; input motionevent UP $((W/2)) $((H*54/100)); sleep 1.5; screencap -p /data/local/tmp/ovr-open.png"
for f in ovr ovr-open; do "$A" pull /data/local/tmp/$f.png "$OUT/" >/dev/null 2>&1; "$A" shell rm -f /data/local/tmp/$f.png; done
"$A" shell "logcat -d -v time | grep -E 'PowosOverlay|PowosShade|HotReload|ShellHost.*changed' | tail -20" | tee "$OUT/log.txt"
"$A" shell "dumpsys window windows | grep -E 'Window #.*PowOS shade' -A20 | grep -m1 mViewVisibility"
"$A" shell input swipe $((W/2)) $((H*80/100)) $((W/2)) $((H*15/100)) 250
sleep 2; "$A" shell "su -c 'rm -f $F; rmdir ${F%/*} 2>/dev/null'"
echo "out: $OUT (ovr.png mid-pull, ovr-open.png let go)"
