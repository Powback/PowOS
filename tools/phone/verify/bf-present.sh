# lanes: phone
# bf-present.sh <secs> <layer-regex> <outdir> [rec secs, default 20; 0 = none]: (on the phone, root) SurfaceFlinger present times (ns, `--latency`
# column 3) of every layer matching the regex, polled every 0.5 s for <secs> s, and a 20 s screenrecord of the ON
# display (<outdir>/rec.mp4) from 4 s in. Each poll returns the layer's last ~127 frames, so polls overlap: the
# analysis dedupes. <outdir>/layers = the names, <outdir>/L<n>.txt = times, each poll led by "P <vsync period ns>".
# Also (games-120, the per-layer rate table): <outdir>/A<n>.txt = the same polls' ACTUAL present times (column 2: when
# the frame reached the panel, so its rate is what the screen showed), and <outdir>/displays.txt = SurfaceFlinger's
# displays (each one's activeMode vsyncRate and displayManagerPolicy render range: the panel's rate under the game),
# and <outdir>/vrr.txt = ColorOS's VRR state (its CVT render-rate cap).
# Toybox grep has no "\|" in a basic regex: the old `grep -v "a\|b"` dropped nothing, so the 6 picked were container
# layers (ActivityRecord, the window's) that never carry a buffer - "no presents" read as a compositor fault (03:58).
mkdir -p "$3"; end=$(( $(date +%s) + $1 ))
# Only layers that can carry the game's buffers, the BLAST SurfaceView (where KWin's window task draws) or home's web
# window buffer ([BBQ] powos-ww-<id>-linux, unfolded) first: on
# 2026-11-05 02:45 the 6 slots went to leftover "animation-leash of starting_reveal" layers of earlier tasks plus
# "Bounds for"/"Background for" containers, the BLAST layer was cut by head -6, and the run read the menu's few
# presents as "no presents" yet still PASSed.
dumpsys SurfaceFlinger --list | sed -E 's/^RequestedLayerState\{//; s/ parentId=.*//; s/ z=.*//; s/\}$//' | grep -iE "$2" \
  | grep -vE "Gesture Monitor|ActivityRecord|InputSink|animation-leash|^Bounds for|^Background for" > "$3/all"
{ grep -E "\(BLAST\)|\[BBQ\] powos-ww-|powos-direct" "$3/all"; grep -vE "\(BLAST\)|\[BBQ\] powos-ww-|powos-direct" "$3/all"; } | head -6 > "$3/layers"; rm -f "$3/all"
DID=$(dumpsys display | grep -E "^  DisplayDeviceInfo" | sed -nE 's/.*uniqueId="local:([0-9]+)",.* state ON,.*/\1/p' | head -1)
[ "${4:-20}" -gt 0 ] && ( sleep 4; screenrecord --display-id "$DID" --bit-rate 40000000 --time-limit "${4:-20}" "$3/rec.mp4" ) &
while [ $(date +%s) -lt $end ]; do
  n=0
  while read -r L; do
    n=$((n + 1)); dumpsys SurfaceFlinger --latency "$L" > "$3/lat"
    awk 'NR==1{print "P", $1} NR>1 && $3>0 && $3<9e18 {print $3}' "$3/lat" >> "$3/L$n.txt"
    awk 'NR>1 && $2>0 && $2<9e18 {print $2}' "$3/lat" >> "$3/A$n.txt"
  done < "$3/layers"
  sleep 0.5
done
rm -f "$3/lat"; dumpsys SurfaceFlinger --displays > "$3/displays.txt" 2>/dev/null
# ColorOS's own render rate under the panel's (OPlus VRR "CVT: CurrentRate [<fps>, <source>]", e.g. 60 from touch idle
# "oti-adfr" while the panel stays 120 Hz: sf-latch-60, 11-06) - bf-layers.py shows it as "render cap".
dumpsys SurfaceFlinger --oplus vrr > "$3/vrr.txt" 2>/dev/null
wait; chmod -R 755 "$3"
