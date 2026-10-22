#!/bin/bash
# owed-checks.sh [MAX_WAIT_S]: one AWAKE_ONLY free window for the batch of owed on-device checks (verify/owed.sh):
# one idle.sh --wait (never polls, never wakes), the verify lock, the Lights tile's position read over CDP (read only),
# the run, the screencaps pulled to OUT (~/.cache/powos-verify/owed-<time>) and put in design-qa on the phone, each
# attached to its owner's board task. Exit 3: the user touched - stopped; 4: no window.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; ROOT=$(cd "$T/../.." && pwd)
OUT=${OUT:-$HOME/.cache/powos-verify/owed-$(date +%m%d-%H%M)}; L=$HOME/.cache/powos-verify.lock; mkdir -p "$OUT"
s=$(AWAKE_ONLY=1 "$T/idle.sh" --wait 120 "${1:-10800}") || { echo "no free window: $s"; exit 4; }
mkdir "$L" 2>/dev/null || { echo "verify lock busy: $(cat "$L/who" 2>/dev/null)"; exit 4; }
echo "powos-verify: owed screen checks $(date +%T), ~30 s" > "$L/who"; trap 'rm -rf "$L"' EXIT
# The Lights room's name on home's first page, in device pixels (read only).
pos=$("$T/cdp.sh" eval home 'JSON.stringify((()=>{const e=[...document.querySelectorAll(".island-face *")].find(n=>n.children.length==0&&/room/i.test(n.textContent));if(!e)return [0,0];const r=e.getBoundingClientRect();if(r.y<0||r.y>innerHeight)return [0,0];return [Math.round((r.x+Math.min(r.width,60)/2)*devicePixelRatio),Math.round((r.y+r.height/2)*devicePixelRatio)]})())' 2>/dev/null | tr -dc '0-9,' | tr ',' ' ')
echo "lights at: ${pos:-none}"
"$A" push "$here/owed.sh" /data/local/tmp/powos-owed.sh >/dev/null
"$A" shell "su -c 'sh /data/local/tmp/powos-owed.sh ${pos:-0 0}'"; rc=$?
"$A" shell "su -c 'chmod 644 /data/local/tmp/cv/owed-*'" >/dev/null 2>&1
"$A" pull /data/local/tmp/cv/. "$OUT/" >/dev/null 2>&1; "$A" shell "su -c 'rm -rf /data/local/tmp/cv /data/local/tmp/powos-owed.sh'"
B="python3 $ROOT/lib/ai/agents/powos-agents-cli"
attach() { # task file...
  local t=$1; shift
  for f in "$@"; do [ -f "$OUT/$f" ] || continue; "$T/review-image.sh" "$OUT/$f" >/dev/null && $B task set "$t" --image "/home/powos/design-qa/$f" >/dev/null && echo "attached $f -> $t"; done
}
attach merged-widgets-misaligned-ragged-edges-unfolded $(cd "$OUT" && ls owed-home-* 2>/dev/null)
attach lights-long-press-popup-with-all-sliders $(cd "$OUT" && ls owed-lights-* 2>/dev/null)
attach frost-v2-one-glass-for-powos-ai-and-the-control $(cd "$OUT" && ls owed-cc-* owed-ai-* 2>/dev/null)
echo "artefacts: $OUT"; exit $rc
