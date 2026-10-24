#!/bin/bash
# lanes: emu phone
# tools/phone/verify/sketch-zoom.sh [board-task]: Sketch's infinite zoom on the device (skill: powos-shell). In one free
# window: opens Sketch on a FRESH test drawing (the user's own drawings are never drawn on or moved), draws one red line
# across the centre with a real touch, pinches in to 50x (pointer events dispatched on the canvas: `input` has no
# multi-touch) and checks the line is re-rendered crisp (its edge ~1 px wide, not a scaled raster's blur), then pinches
# out to the 0.02x limit and checks the background fills the whole viewport (no edge, no paper). Screencaps of both
# ("zoom-in", "zoom-out") go onto the board task as review images. Then deletes the test drawing, closes Sketch; the
# user's drawings and views are fingerprinted before and after (must be unchanged). window.__sketch is read only.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); A=$here/adb.sh; ROOT=$(cd "$here/../.." && pwd)
TASK=${1:-sketch-infinite-canvas-pinch-zoom-two-finger-pan}
OUT=${OUT:-$HOME/powos-rec/sketch-zoom-$(date +%H%M%S)}; mkdir -p "$OUT"
sh_() { "$A" shell "$@" | tr -d '\r'; }
js() {
  "$here/cdp.sh" eval "" "$1" 2>/dev/null | tail -1 |
    python3 -c 'import json,sys; v=json.loads(sys.stdin.read() or "null"); print(v if isinstance(v,str) else json.dumps(v))' 2>/dev/null
}
sql() { # <query> -> JSON rows, through root inside PowOS
  local f; f=$(mktemp "$HOME/.cache/sketch-sql.XXXX")
  printf 'curl -s -X POST --data-binary %q http://127.0.0.1:3410/v1/database/local-sketch/sql\n' "$1" > "$f"
  "$here/root.sh" "$f" 2>/dev/null | grep '^\[' | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[0]["rows"]))' 2>/dev/null
  rm -f "$f"
}
restore() { js '(window.__powosApps && window.__powosApps.closeApp(), "closed")' >/dev/null; }
WL_TRAP='restore'
. "$(dirname "$0")/window-lock.sh"
window_lock sketch-zoom.sh 120
t0=$(sh_ cat /data/local/tmp/powos-lasttouch)
touched() { [ "$(sh_ cat /data/local/tmp/powos-lasttouch)" != "$t0" ] && { echo "ABORT: the user touched the phone"; exit 3; }; return 0; }
mine() { echo "$(sql "SELECT id, key, width, height, updated FROM drawing") $(sql "SELECT * FROM viewport") $(sql "SELECT uid, hidden FROM stroke")"; }
before=$(mine); echo "$before" > "$OUT/before.json"
ok=0; bad=0; res() { if [ "$1" = pass ]; then ok=$((ok+1)); else bad=$((bad+1)); fi; echo "$1 $2: $3" | tee -a "$OUT/result.txt"; }
. "$(dirname "$0")/sketch-lib.sh"
state() { js 'JSON.stringify(window.__sketch || null)'; }
get() { python3 -c 'import json,sys; s=json.loads(sys.argv[1]); print(eval(sys.argv[2], {"s": s, "round": round}))' "$1" "$2" 2>/dev/null; }
CANVAS='[...document.querySelectorAll("canvas")].sort((a, b) => b.width * b.height - a.width * a.height)[0]'
# A pinch about the canvas centre: the fingers' half-distance r0 -> r1 css px (r1 / r0 = the zoom factor).
pinch() {
  js "(() => { const c = $CANVAS, r = c.getBoundingClientRect(), mx = r.left + r.width / 2, my = r.top + r.height / 2;
    const ev = (t, id, x) => c.dispatchEvent(new PointerEvent(t, { pointerId: id, pointerType: 'touch', isPrimary: id === 901, clientX: mx + x, clientY: my, bubbles: true }));
    const [r0, r1] = [$1, $2];
    ev('pointerdown', 901, -r0); ev('pointerdown', 902, r0);
    for (let i = 1; i <= 12; i++) { const d = r0 + (r1 - r0) * i / 12; ev('pointermove', 901, -d); ev('pointermove', 902, d); }
    ev('pointerup', 901, -r1); ev('pointerup', 902, r1); return 'pinched'; })()" >/dev/null
  sleep 1
}
# The canvas's centre column: edge px (part-way between the darkest and brightest red) and solid px.
COLUMN="(() => { const c = $CANVAS, d = c.getContext('2d').getImageData(c.width >> 1, 0, 1, c.height).data;
  let lo = 255, hi = 0; for (let i = 0; i < d.length; i += 4) (lo = Math.min(lo, d[i])), (hi = Math.max(hi, d[i]));
  let mid = 0, on = 0; for (let i = 0; i < d.length; i += 4) { const t = (d[i] - lo) / (hi - lo || 1); if (t > 0.1 && t < 0.9) mid++; if (t >= 0.9) on++; }
  return JSON.stringify({ mid, on, lo, hi }); })()"
# Samples across the whole canvas that aren't the background.
NOTBG="(() => { const c = $CANVAS, d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data; let n = 0, bad = 0;
  for (let i = 0; i < d.length; i += 4 * 97) { n++; if (Math.abs(d[i] - 18) > 2 || Math.abs(d[i + 1] - 18) > 2 || Math.abs(d[i + 2] - 22) > 2) bad++; }
  return JSON.stringify({ n, bad, transform: c.style.transform, page: getComputedStyle(c.parentElement).backgroundColor }); })()"
sketch_fresh || exit 1
js '(document.querySelector("[aria-label=\"color #ff5c5c\"]").click(), "red")' >/dev/null; sleep 0.5
read -r x0 y x1 <<<"$(js "(() => { const c = $CANVAS, r = c.getBoundingClientRect(), d = devicePixelRatio; return [r.left + r.width * 0.3, r.top + r.height / 2, r.left + r.width * 0.7].map((v) => Math.round(v * d)).join(' '); })()")"
touched; sh_ input swipe "$x0" "$y" "$x1" "$y" 500; sleep 1.5
s1=$(state); echo "drawn: $s1" >> "$OUT/states.txt"; alive "$s1" "drawn"
[ "$(get "$s1" 's["strokes"]')" = 1 ] && res pass draw "1 red line, scale $(get "$s1" 'round(s["view"]["s"],3)')" || { res fail draw "no stroke ($s1)"; }
# In: 10x then 5x about the centre (the line runs through it).
touched; pinch 20 200; pinch 40 200
s2=$(state); echo "zoomed in: $s2" >> "$OUT/states.txt"; alive "$s2" "zoomed in"; c2=$(js "$COLUMN"); echo "column: $c2" >> "$OUT/states.txt"
"$here/shot.sh" "$OUT/sketch-zoom-in.png" >/dev/null 2>&1
python3 - "$s1" "$s2" "$c2" <<'PY' && res pass "zoom in" "50x and crisp: $c2" || res fail "zoom in" "$(get "$s2" 'round(s["view"]["s"],2)') x, column $c2"
import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); c=json.loads(sys.argv[3])
r=b["view"]["s"]/a["view"]["s"]
sys.exit(0 if abs(r-50)<0.5 and c["hi"]>200 and c["on"]>100 and c["mid"]<=4 else 1)
PY
# Out: to the 0.02x limit; the background covers every pixel but the (now tiny) line.
touched; for i in 1 2 3 4; do pinch 200 20; done
s3=$(state); echo "zoomed out: $s3" >> "$OUT/states.txt"; alive "$s3" "zoomed out"; b3=$(js "$NOTBG"); echo "background: $b3" >> "$OUT/states.txt"
"$here/shot.sh" "$OUT/sketch-zoom-out.png" >/dev/null 2>&1
python3 - "$s3" "$b3" <<'PY' && res pass "zoom out" "0.02x, background over the whole viewport ($b3)" || res fail "zoom out" "scale $(get "$s3" 's["view"]["s"]'), $b3"
import json,sys; s=json.loads(sys.argv[1]); b=json.loads(sys.argv[2])
sys.exit(0 if abs(s["view"]["s"]-0.02)<1e-4 and b["bad"]<=2 and b["transform"]=="" and b["page"]=="rgb(18, 18, 22)" else 1)
PY
# Clean up: the test drawing deleted (its view with it); the user's drawings, strokes and views unchanged.
echo "cleanup: $(drop)" >> "$OUT/states.txt"
restore
after=$(mine); echo "$after" > "$OUT/after.json"
[ "$after" = "$before" ] && res pass "user's drawings" "drawings, strokes and views unchanged, test drawing removed" ||
  res fail "user's drawings" "before/after differ: $OUT/before.json $OUT/after.json"
imgs=()
for f in sketch-zoom-in.png sketch-zoom-out.png; do
  [ -f "$OUT/$f" ] && "$here/review-image.sh" "$OUT/$f" >/dev/null && imgs+=(--image "/home/powos/design-qa/$f")
done
[ ${#imgs[@]} -gt 0 ] && python3 "$ROOT/lib/ai/agents/powos-agents-cli" task set "$TASK" "${imgs[@]}" >/dev/null 2>&1
echo "passed $ok, failed $bad; out: $OUT"
[ "$bad" = 0 ] || echo "FAIL sketch-zoom: $bad check(s) failed"
