#!/bin/bash
# lanes: phone
# capture-visible.sh: a screen capture of PowOS home shows home, not black. 11-09: every capture of home on the
# OnePlus (screenrecord, e2e screenshots) was black but the status bar - a stopped Linux window task's leash, shown
# uncropped by TaskSurfaces' fold release, put WM Shell's black task colour over the whole cover screen (SF: Task=<n>
# SOLID_COLOR over the display). It blinded every screenshot-based check.
# Read-only: no taps, no keys. Captures the display that is ON (the cover folded, the inner unfolded), only while
# home (HomeShell) is the top resumed activity; leaves out the status and navigation bars; FAIL when under 1 % of the
# rest is lit (capture-visible-judge.py) and names any SOLID_COLOR layer covering the display.
# Exit 0 PASS, 1 FAIL, 3 not now (screen off, home not in front).
set -uo pipefail
NAME=capture-visible
T=$(cd "$(dirname "$0")/.." && pwd)
A="$T/adb.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/$NAME-$(date +%m%d-%H%M%S)}; mkdir -p "$OUT"
say() { echo "$*" | tee -a "$OUT/log.txt"; }
tag=/data/local/tmp/powos-capvis-$$
# The phone side, one shell: state, display pick, captures, the display's HWC layers.
read -r -d '' ON_PHONE <<EOF
w=\$(dumpsys power | sed -n "s/.*mWakefulness=//p" | head -1)
[ "\$w" = Awake ] || { echo "NOTNOW screen \$w"; exit 0; }
top=\$(dumpsys activity activities | grep -m1 topResumedActivity)
case "\$top" in *HomeShell*) ;; *) echo "NOTNOW home not in front: \$top"; exit 0 ;; esac
id=\$(dumpsys display | grep -E "^  DisplayDeviceInfo" | sed -nE 's/.*uniqueId="local:([0-9]+)",.* state ON,.*/\1/p' | head -1)
[ -n "\$id" ] || { echo "NOTNOW no display on"; exit 0; }
screencap -d \$id > $tag.raw
screencap -d \$id -p $tag.png
dumpsys SurfaceFlinger | awk -v id="\$id" '\$0 ~ "^Display " id " .*HWC layers" {on=1} on && /^(Virtual Display|Window Infos)/ {exit} on' > $tag.sf
chmod 644 $tag.raw $tag.png $tag.sf
echo "SHOT \$id"
EOF
res=$("$A" shell "if command -v su >/dev/null 2>&1; then exec su -c 'sh -s'; else exec sh -s; fi" <<<"$ON_PHONE" 2>&1 | tr -d '\r')
case "$res" in *NOTNOW*) say "SKIP ${res#*NOTNOW }"; exit 3 ;; esac
grep -q '^SHOT' <<<"$res" || { say "SKIP adb: $res"; exit 3; }
id=$(sed -n 's/^SHOT //p' <<<"$res" | head -1)
for x in raw png sf; do "$A" pull "$tag.$x" "$OUT/" >/dev/null 2>&1; done
"$A" shell "if command -v su >/dev/null 2>&1; then su -c 'rm -f $tag.*'; else rm -f $tag.*; fi" >/dev/null 2>&1
b=$(basename "$tag")
[ -s "$OUT/$b.raw" ] || { say "SKIP capture not pulled"; exit 3; }
mv "$OUT/$b.png" "$OUT/home.png" 2>/dev/null
v=$(python3 -I "$T/verify/capture-visible-judge.py" "$OUT/$b.raw" "$OUT/$b.sf"); rc=$?
rm -f "$OUT/$b.raw"
say "display $id: $v"
case $rc in
  0) say "PASS capture-visible: home capture lit ($(head -1 <<<"$v"), $OUT/home.png)"; exit 0 ;;
  1) say "FAIL capture-visible: home capture near-black ($(tr '\n' ' ' <<<"$v")) - $OUT/home.png"; exit 1 ;;
  *) say "SKIP judge: $v"; exit 3 ;;
esac
