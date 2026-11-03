#!/bin/bash
# lanes: phone
# bf-overlay-watch.sh [secs, default 90]: (Mac) READ-ONLY watch of the user's running game while THEY open overlays
# (volume panel, the PowOS gamepad) - board task broforce-games-black-noise-flicker-artifacts-ove. Starts, stops,
# taps and screencaps nothing (a screencap is itself GPU composition, the very condition being watched).
# User 2026-11-03 18:5x: "it's def flickering black ... seems like it happens when I use an overlay like the volume
# button or the gamepad"; their 18:44 screenshots show the game under a regular grid of black 16x4 blocks / 16-px
# columns every 48 px, in the X window's orientation (KWin's task buffers are pre-rotated 90 deg, so its own render
# would show 4x16): a buffer read while a GPU was still writing it, upstream of KWin's task render.
# Per second: which overlay layers SurfaceFlinger has (VolumeDialog, the PowOS gamepad), the large dma-bufs by last
# writer (/sys/kernel/debug/dma_buf/bufinfo: fresh Xwayland window buffers = churn). Meanwhile Xwayland's copy of the
# game window at 1 fps (bf-xframes grab: XGetImage = glamor's finished copy) and the game layer's present times
# (bf-present.sh). After: checker score per X frame (bf-checker.py --frames) against the overlay timeline, and the
# session log's "Xwayland KGSL:" / "window task N frames" lines written during the watch.
# Reading it: X frames checkered while an overlay is up -> the corruption is in Xwayland's window pixmap (the game ->
# glamor Present copy); X frames clean -> it is after Xwayland (KWin sampling Xwayland's buffer, or SurfaceFlinger).
# Exit 3 = no awake game to watch; artefacts ~/.cache/powos-verify/bfo-<date>/.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
SECS=${1:-90}; case $SECS in *[!0-9]*|"") echo "secs: a number"; exit 2 ;; esac
OUT=${OUT:-$HOME/.cache/powos-verify/bfo-$(date +%F_%H%M)}; mkdir -p "$OUT"
asuser() { local n=$1; shift
  "$A" shell "su -c 'cp /data/local/tmp/powos-$n /data/powos/root/var/tmp/powos-$n; chmod 644 /data/powos/root/var/tmp/powos-$n; sh /data/powos/powos-run.sh \"sh /var/tmp/powos-$n $*\"'" 2>&1 | grep -v sysvipc | tr -d '\r'; }
for f in bf-game.sh bf-present.sh bf-checker-phone.sh bf-lib.sh bf-xframes.py; do
  "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "ENV: can't push $f"; exit 5; }; done
gs=$(asuser bf-game.sh state | tail -1)
[ "$gs" = game=awake ] || { echo "no awake game to watch ($gs) - nothing done"; exit 3; }
"$A" shell "su -c 'cp /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-xframes.py /data/powos/root/var/tmp/; chmod 644 /data/powos/root/var/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-bf-xframes.py'"
L0=$("$A" shell "su -c 'wc -l < /data/powos/root/run/powos-app/hyprland.log'" | tr -dc 0-9)
echo "watching ${SECS}s from $(date +%T) (log line ${L0:-?}); open the volume panel / gamepad as you play"
asuser bf-checker-phone.sh grab "$SECS" /var/tmp/bfo/x >/dev/null
"$A" shell "su -c 'rm -rf /data/local/tmp/bfo-p; nohup sh /data/local/tmp/powos-bf-present.sh $SECS \"PowosWindowActivity|powos-ww-[0-9]+-linux\" /data/local/tmp/bfo-p 0 >/dev/null 2>&1 &'"
# One adb call per second: overlay layers + the big dma-bufs' last writers (count per writer).
PROBE='t=$(date +%T); o=$(dumpsys SurfaceFlinger --list | grep -oiE "VolumeDialog[A-Za-z]*|PowOS gamepad[A-Za-z ]*|Gamepad[A-Za-z]*" | sort -u | tr "\n" ","); b=$(awk "/^[0-9]+\t/{if(s>15000000)print w; s=\$1; w=\"none\"} /Exclusive fence/{w=\$4} END{if(s>15000000)print w}" /sys/kernel/debug/dma_buf/bufinfo | sed -E "s/kgsl-3d0_[0-9]+-//; s/\(.*//" | sort | uniq -c | awk "{printf \"%s=%s \", \$2, \$1}"); echo "$t overlay=${o:-none} bufs: $b"'
printf '%s\n' "$PROBE" > "$OUT/probe.sh"; "$A" push "$OUT/probe.sh" /data/local/tmp/powos-bfo-probe.sh >/dev/null
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "$SECS" ]; do
  "$A" shell "su -c 'sh /data/local/tmp/powos-bfo-probe.sh'" | tr -d '\r' >> "$OUT/timeline.txt"; sleep 0.7
done
sleep 3
"$A" shell "su -c 'cp -r /data/powos/root/var/tmp/bfo/x /data/local/tmp/bfo-x; chmod -R 755 /data/local/tmp/bfo-x /data/local/tmp/bfo-p'"
"$A" pull /data/local/tmp/bfo-x "$OUT/" >/dev/null && mv "$OUT/bfo-x" "$OUT/x"
"$A" pull /data/local/tmp/bfo-p "$OUT/" >/dev/null && mv "$OUT/bfo-p" "$OUT/present"
"$A" shell "su -c 'tail -n +$((${L0:-0} + 1)) /data/powos/root/run/powos-app/hyprland.log'" | tr -d '\r' \
  | grep -aE "Xwayland KGSL|Xwayland glamor|window task [0-9]+ (frames|resized|full screen)|imported buffer" > "$OUT/session.txt"
"$A" shell "su -c 'rm -rf /data/local/tmp/bfo-x /data/local/tmp/bfo-p /data/local/tmp/powos-bfo-probe.sh /data/local/tmp/powos-bf-*.sh /data/local/tmp/powos-bf-xframes.py /data/powos/root/var/tmp/bfo /data/powos/root/var/tmp/powos-bf-*.sh'"
up=$(grep -vc "overlay=none" "$OUT/timeline.txt")
echo "overlay up $up of $(wc -l < "$OUT/timeline.txt") probes; buffer writers: $(awk '{$1=$2=""; print}' "$OUT/timeline.txt" | sort | uniq -c | sort -rn | head -3 | tr -s ' ' | tr '\n' ';')"
uv run --quiet --with numpy python3 "$here/bf-checker.py" --frames "$OUT/x" "$OUT/timeline.txt" | tee "$OUT/result.txt"
echo "session: $(grep -c 'Xwayland KGSL' "$OUT/session.txt") KGSL stat lines, $(grep -c imported "$OUT/session.txt") buffer imports, $(grep -c resized "$OUT/session.txt") task resizes; out=$OUT"
