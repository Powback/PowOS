#!/bin/bash
# One idle-cost sample of the phone, screen on, nobody touching it: "idle-sample.sh [seconds=60]".
#   - refuses unless idle>=120 s and the screen is on (tools/phone/idle.sh) - never wakes it, never touches input;
#   - per-process CPU over the window (tools/phone/cpu.sh), the WebView pages' frames/paints/rAF (tools/phone/cdp.sh
#     idle, the first 20 s), and the app's window frames (dumpsys gfxinfo, reset at the start);
#   - appends one summary line to ~/.cache/powos-perf/idle.log (Mac) and prints everything.
# Budget (2026-10-21, the user): ~3% CPU idle on home with the screen on (the PowOS processes together: app, WebView
# renderer, its share of system_server/surfaceflinger aside).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
secs=${1:-60}
s=$("$here/idle.sh")
i=${s#idle=}; i=${i%% *}
if [ "${i:-0}" -lt 120 ] || [[ "$s" != *Awake* ]]; then echo "idle-sample: not now ($s)"; exit 3; fi
fg=$("$here/adb.sh" shell "dumpsys activity activities | grep -m1 topResumedActivity" | sed 's/.* u0 //; s/ .*//')
"$here/adb.sh" shell "dumpsys gfxinfo com.powos.app reset" >/dev/null
"$here/cdp.sh" idle 20 > "${TMPDIR:-/tmp}/powos-idle-cdp.json" 2>&1 &
cdp=$!
cpu=$("$here/cpu.sh" "$secs" 25)
wait $cdp
gfx=$("$here/adb.sh" shell "dumpsys gfxinfo com.powos.app" | grep -E "^\s*(Window:|Total frames rendered)" | paste - - | sed 's/  */ /g')
after=$("$here/idle.sh")
echo "== foreground: $fg"
echo "== CPU over ${secs}s (% of one core)"; echo "$cpu"
echo "== WebView pages (20 s)"; cat "${TMPDIR:-/tmp}/powos-idle-cdp.json"
echo "== app windows' frames over ${secs}s"; echo "$gfx"
echo "== after: $after"
pick() { echo "$cpu" | awk -v n="$1" '$3 ~ n { s += $1 } END { printf "%.1f", s }'; }
mkdir -p ~/.cache/powos-perf
line="$(date '+%F %T') idle=${i}s fg=$fg total=$(echo "$cpu" | awk '/total/{print $1}') app=$(pick '^com.powos.app$') webview=$(pick 'ocessService') system_server=$(pick '^system_server$') sf=$(pick '^surfaceflinger$') wg=$(pick 'reguard') plasma=$(pick '^plasmashell$') kwin=$(pick '^kwin_wayland$') touched_during=$([ "${after#idle=}" != "$after" ] && a=${after#idle=} && [ "${a%% *}" -lt "$i" ] && echo yes || echo no)"
echo "$line" | tee -a ~/.cache/powos-perf/idle.log
