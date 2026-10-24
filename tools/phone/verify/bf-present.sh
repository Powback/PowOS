# bf-present.sh <secs> <layer-regex> <outdir> [rec secs, default 20; 0 = none]: (on the phone, root) SurfaceFlinger present times (ns, `--latency`
# column 3) of every layer matching the regex, polled every 0.5 s for <secs> s, and a 20 s screenrecord of the ON
# display (<outdir>/rec.mp4) from 4 s in. Each poll returns the layer's last ~127 frames, so polls overlap: the
# analysis dedupes. <outdir>/layers = the names, <outdir>/L<n>.txt = times, each poll led by "P <vsync period ns>".
# Toybox grep has no "\|" in a basic regex: the old `grep -v "a\|b"` dropped nothing, so the 6 picked were container
# layers (ActivityRecord, the window's) that never carry a buffer - "no presents" read as a compositor fault (03:58).
mkdir -p "$3"; end=$(( $(date +%s) + $1 ))
dumpsys SurfaceFlinger --list | sed -E 's/^RequestedLayerState\{//; s/ parentId=.*//; s/ z=.*//; s/\}$//' | grep -iE "$2" \
  | grep -vE "Gesture Monitor|ActivityRecord|InputSink" | head -6 > "$3/layers"
DID=$(dumpsys display | grep -E "^  DisplayDeviceInfo" | sed -nE 's/.*uniqueId="local:([0-9]+)",.* state ON,.*/\1/p' | head -1)
[ "${4:-20}" -gt 0 ] && ( sleep 4; screenrecord --display-id "$DID" --bit-rate 40000000 --time-limit "${4:-20}" "$3/rec.mp4" ) &
while [ $(date +%s) -lt $end ]; do
  n=0
  while read -r L; do
    n=$((n + 1)); dumpsys SurfaceFlinger --latency "$L" | awk 'NR==1{print "P", $1} NR>1 && $3>0 && $3<9e18 {print $3}' >> "$3/L$n.txt"
  done < "$3/layers"
  sleep 0.5
done
wait; chmod -R 755 "$3"
