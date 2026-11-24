#!/usr/bin/env bash
# Text fidelity after motion: Firefox on the Wikipedia page, scroll 10 s (F8), back to the top (F9), wait 2 s, then
# grab sway's output (grim) and compare it to the same state shown locally (no waypipe): PSNR via ffmpeg plus a per-pixel
# diff (count, count off by >16 levels, bounding box). One command: tools/research/remoting/run-fidelity.sh [MODES...] -> results/fidelity.jsonl
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); dc="$here/dc"; res="$here/results"; mkdir -p "$res"
"$dc" up -d comp app >/dev/null 2>&1
shot() { # MODE -> /tmp/fid-MODE.png in comp
  local m=$1 where=app; [ "$m" = local ] && where=comp
  "$dc" exec -T -u u comp comp-start "$m" >/dev/null
  "$dc" exec -T -u u $where app-start "$m" firefox >/dev/null
  sleep 25
  "$dc" exec -T -u u comp sh -c "export WAYLAND_DISPLAY=wayland-1; wtype -k Shift_L -s 150 -k F8; sleep 10.5; wtype -k Shift_L -s 150 -k F9; sleep 2; grim /tmp/fid-$m.png"
  "$dc" exec -T -u u $where app-stop || true
}
modes=${*:-gpu shm video}
shot local
for m in $modes; do
  shot "$m"
  psnr=$("$dc" exec -T comp sh -c "ffmpeg -hide_banner -i /tmp/fid-$m.png -i /tmp/fid-local.png -lavfi psnr -f null - 2>&1 | grep -o 'average:[a-z0-9.]*'")
  diff=$("$dc" exec -T comp python3 - "$m" <<'PY2'
import json, subprocess, sys, numpy as np
rd = lambda f: np.frombuffer(subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                                            capture_output=True).stdout, np.uint8).reshape(1080, 1920, 3).astype(int)
d = np.abs(rd(f"/tmp/fid-{sys.argv[1]}.png") - rd("/tmp/fid-local.png")).max(axis=2)
ys, xs = np.nonzero(d)
print(json.dumps({"px_differing": int(len(ys)), "px_off_by_more_than_16": int((d > 16).sum()), "max_diff": int(d.max()),
                  "bbox": [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())] if len(ys) else None}))
PY2
)
  echo "{\"mode\": \"$m\", \"psnr_vs_local_db\": \"${psnr#average:}\", \"diff\": $diff}" | tee -a "$res/fidelity.jsonl"
done
