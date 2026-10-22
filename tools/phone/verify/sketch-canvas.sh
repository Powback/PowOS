#!/bin/bash
# tools/phone/verify/sketch-canvas.sh: Sketch's infinite canvas on the device (skill: powos-widgets). In one free window:
# opens Sketch, starts a FRESH test drawing from its gallery (the user's own drawings are never drawn on or moved),
# draws one stroke with a real touch, then two-finger pinch and pan (pointer events dispatched on the canvas: `input`
# has no multi-touch) and checks the view zoomed around the pinch centre and panned, nothing painted at rest, the view
# saved in local-sketch's viewport table, kept across a rotation and across closing and reopening Sketch; "fit all"
# shows the whole drawing; a double tap goes to 100% without keeping a dot. Then deletes the test drawing (its view
# goes with it), closes Sketch, puts the rotation settings back; the user's drawings and views are fingerprinted
# before and after (must be unchanged). window.__sketch is read only.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); A=$here/adb.sh
OUT=${OUT:-$HOME/powos-rec/sketch-canvas-$(date +%H%M%S)}; mkdir -p "$OUT"
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
restore() {
  [ -n "${rot0:-}" ] && sh_ settings put system user_rotation "$rot0"
  [ -n "${acc0:-}" ] && sh_ settings put system accelerometer_rotation "$acc0"
  js '(window.__powosApps && window.__powosApps.closeApp(), "closed")' >/dev/null
  echo "restored: user_rotation=$(sh_ settings get system user_rotation) accelerometer_rotation=$(sh_ settings get system accelerometer_rotation)"
}
WL_TRAP='restore'
. "$(dirname "$0")/window-lock.sh"
window_lock sketch-canvas.sh 120
t0=$(sh_ cat /data/local/tmp/powos-lasttouch)
touched() { [ "$(sh_ cat /data/local/tmp/powos-lasttouch)" != "$t0" ] && { echo "ABORT: the user touched the phone"; exit 3; }; return 0; }
rot0=$(sh_ settings get system user_rotation); acc0=$(sh_ settings get system accelerometer_rotation)
mine() { echo "$(sql "SELECT id, key, width, height, updated FROM drawing") $(sql "SELECT * FROM viewport")"; }
before=$(mine); echo "$before" > "$OUT/before.json"
ok=0; bad=0; res() { if [ "$1" = pass ]; then ok=$((ok+1)); else bad=$((bad+1)); fi; echo "$1 $2: $3" | tee -a "$OUT/result.txt"; }
state() { js 'JSON.stringify(window.__sketch || null)'; }
get() { python3 -c 'import json,sys; s=json.loads(sys.argv[1]); print(eval(sys.argv[2], {"s": s, "round": round}))' "$1" "$2" 2>/dev/null; }
# The drawing point at the canvas centre and the scale: "cx cy s".
spot() { python3 -c 'import json,sys; s=json.loads(sys.argv[1]); v=s["view"]; w,h=s["size"]; print(round((w/2-v["ox"])/v["s"],1), round((h/2-v["oy"])/v["s"],1), round(v["s"],4))' "$1" 2>/dev/null; }
# Two fingers on the canvas (css px from its centre): a0 b0 -> a1 b1, as pointer events, one frame's worth of moves.
two() {
  js "(() => { const c = [...document.querySelectorAll('canvas')].sort((a, b) => b.width * b.height - a.width * a.height)[0];
    const r = c.getBoundingClientRect(), mx = r.left + r.width / 2, my = r.top + r.height / 2;
    const ev = (t, id, x, y) => c.dispatchEvent(new PointerEvent(t, { pointerId: id, pointerType: 'touch', isPrimary: id === 901, clientX: mx + x, clientY: my + y, bubbles: true }));
    const [a0x, a0y, b0x, b0y, a1x, a1y, b1x, b1y] = [$1];
    ev('pointerdown', 901, a0x, a0y); ev('pointerdown', 902, b0x, b0y);
    for (let i = 1; i <= 12; i++) { const t = i / 12; ev('pointermove', 901, a0x + (a1x - a0x) * t, a0y + (a1y - a0y) * t); ev('pointermove', 902, b0x + (b1x - b0x) * t, b0y + (b1y - b0y) * t); }
    ev('pointerup', 901, a1x, a1y); ev('pointerup', 902, b1x, b1y); return 'moved'; })()" >/dev/null
  sleep 1
}
# Portrait, home, Sketch open on a fresh drawing.
sh_ settings put system accelerometer_rotation 0; sh_ settings put system user_rotation 0
sh_ input keyevent KEYCODE_HOME; sleep 1.5
js '(window.__powosApps.openApp("local.sketch"), "open")' >/dev/null; sleep 3
js '(document.querySelector("[aria-label=drawings]").click(), "gallery")' >/dev/null; sleep 1
js '(document.querySelector("[aria-label=\"new drawing\"]").click(), "fresh")' >/dev/null; sleep 1
s0=$(state); echo "fresh: $s0" >> "$OUT/states.txt"
key=$(get "$s0" 's["key"]')
[ -n "$key" ] || { res fail open "Sketch didn't open on a fresh drawing ($s0)"; exit 0; }
[ -n "$(js '(document.querySelector("[aria-label=\"fit all\"]") ? "yes" : "")')" ] || { res fail open "no fit-all control: the new UI isn't installed"; exit 0; }
read -r x0 y0 x1 y1 <<<"$(js '(() => { const c = [...document.querySelectorAll("canvas")].sort((a, b) => b.width * b.height - a.width * a.height)[0]; const r = c.getBoundingClientRect(), d = devicePixelRatio; return [r.left + r.width * 0.3, r.top + r.height * 0.35, r.left + r.width * 0.7, r.top + r.height * 0.6].map((v) => Math.round(v * d)).join(" "); })()')"
touched; sh_ input swipe "$x0" "$y0" "$x1" "$y1" 500; sleep 1.5
s1=$(state); echo "drawn: $s1" >> "$OUT/states.txt"
n1=$(get "$s1" 's["strokes"]'); [ "${n1:-0}" -ge 1 ] && res pass draw "$n1 stroke, mode $(get "$s1" 's["mode"]')" || res fail draw "no stroke recorded ($s1)"
dpr=$(js 'String(devicePixelRatio)')
# Pinch 2x around a point left of centre: the drawing point under it stays under it.
read -r sx sy ss <<<"$(spot "$s1")"
touched; two "-90, 0, -10, 0, -130, 0, 30, 0"
s2=$(state); echo "pinched: $s2" >> "$OUT/states.txt"
python3 - "$s1" "$s2" "$dpr" <<'PY' && res pass pinch "zoomed 2x around the pinch centre, mode free" || res fail pinch "see $OUT/states.txt"
import json,sys; a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); d=float(sys.argv[3])
va,vb=a["view"],b["view"]; px=a["size"][0]/2-50*d; py=a["size"][1]/2
pa=((px-va["ox"])/va["s"],(py-va["oy"])/va["s"]); pb=((px-vb["ox"])/vb["s"],(py-vb["oy"])/vb["s"])
sys.exit(0 if b["mode"]=="free" and abs(vb["s"]/va["s"]-2)<0.02 and abs(pa[0]-pb[0])<2 and abs(pa[1]-pb[1])<2 else 1)
PY
# Pan: both fingers 80 css px right, 40 down.
touched; two "-40, 0, 40, 0, 40, 40, 120, 40"
s3=$(state); echo "panned: $s3" >> "$OUT/states.txt"
python3 - "$s2" "$s3" "$dpr" <<'PY' && res pass pan "view moved 80,40 css px at the same zoom" || res fail pan "see $OUT/states.txt"
import json,sys; a=json.loads(sys.argv[1])["view"]; b=json.loads(sys.argv[2])["view"]; d=float(sys.argv[3])
sys.exit(0 if abs(b["s"]-a["s"])<1e-6 and abs(b["ox"]-a["ox"]-80*d)<2 and abs(b["oy"]-a["oy"]-40*d)<2 else 1)
PY
p0=$(get "$s3" 's["paints"]'); sleep 2; p1=$(get "$(state)" 's["paints"]')
[ "$p0" = "$p1" ] && res pass rest "no repaint in 2 s at rest ($p0 paints)" || res fail rest "repainted at rest: $p0 -> $p1"
sleep 1
vrow=$(sql "SELECT cx, cy, zoom, fit FROM viewport WHERE key = '$key'"); echo "viewport: $vrow" >> "$OUT/states.txt"
[ "$(get "$vrow" 'len(s)==1 and s[0][3] is False')" = True ] && res pass saved "view saved for the test drawing ($vrow)" || res fail saved "viewport row: ${vrow:-none}"
# Rotation keeps the centre and zoom.
spot0=$(spot "$s3")
touched; sh_ settings put system user_rotation 1; sleep 3
s4=$(state); echo "landscape: $s4" >> "$OUT/states.txt"; spot1=$(spot "$s4")
sh_ settings put system user_rotation 0; sleep 3
python3 -c 'import sys; a=list(map(float,sys.argv[1].split())); b=list(map(float,sys.argv[2].split())); sys.exit(0 if abs(a[0]-b[0])<2 and abs(a[1]-b[1])<2 and abs(a[2]-b[2])<0.01 else 1)' "$spot0" "$spot1" &&
  res pass rotate "centre and zoom kept in landscape ($spot0 -> $spot1)" || res fail rotate "($spot0 -> $spot1)"
# Close and reopen: the test drawing (the newest) opens at its saved view.
js '(window.__powosApps.closeApp(), "closed")' >/dev/null; sleep 2
js '(window.__powosApps.openApp("local.sketch"), "open")' >/dev/null; sleep 3
s5=$(state); echo "reopened: $s5" >> "$OUT/states.txt"; spot2=$(spot "$s5")
[ "$(get "$s5" 's["key"]')" = "$key" ] && [ "$(get "$s5" 's["mode"]')" = free ] &&
  python3 -c 'import sys; a=list(map(float,sys.argv[1].split())); b=list(map(float,sys.argv[2].split())); sys.exit(0 if abs(a[0]-b[0])<2 and abs(a[1]-b[1])<2 and abs(a[2]-b[2])<0.01 else 1)' "$spot0" "$spot2" &&
  res pass reopen "view back after reopening ($spot2)" || res fail reopen "key $(get "$s5" 's["key"]'), mode $(get "$s5" 's["mode"]'), $spot0 -> $spot2"
# Fit all, then a double tap (two quick taps) to 100%.
js '(document.querySelector("[aria-label=\"fit all\"]").click(), "fit")' >/dev/null; sleep 1
s6=$(state); echo "fit: $s6" >> "$OUT/states.txt"
[ "$(get "$s6" 's["mode"]=="fit" and s["view"]["ox"]+s["extent"]["x0"]*s["view"]["s"]>=-1 and s["view"]["ox"]+s["extent"]["x1"]*s["view"]["s"]<=s["size"][0]+1 and s["view"]["oy"]+s["extent"]["y1"]*s["view"]["s"]<=s["size"][1]+1')" = True ] &&
  res pass "fit all" "whole drawing on screen" || res fail "fit all" "$s6"
js "(() => { const c = [...document.querySelectorAll('canvas')].sort((a, b) => b.width * b.height - a.width * a.height)[0];
  const r = c.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
  const ev = (t, id) => c.dispatchEvent(new PointerEvent(t, { pointerId: id, pointerType: 'touch', isPrimary: true, clientX: x, clientY: y, bubbles: true }));
  ev('pointerdown', 911); ev('pointerup', 911); setTimeout(() => (ev('pointerdown', 912), ev('pointerup', 912)), 80); return 'taps'; })()" >/dev/null
sleep 1.5
s7=$(state); echo "double tap: $s7" >> "$OUT/states.txt"
[ "$(get "$s7" 's["mode"]=="free" and abs(s["view"]["s"]-1)<1e-6')" = True ] && [ "$(get "$s7" 's["strokes"]')" = "$n1" ] &&
  res pass "double tap" "100%, no dot kept ($n1 stroke)" || res fail "double tap" "$s7"
sh_ "screencap -p /data/local/tmp/sk-canvas.png"; "$A" pull /data/local/tmp/sk-canvas.png "$OUT/" >/dev/null 2>&1; sh_ rm -f /data/local/tmp/sk-canvas.png
# Clean up: the test drawing deleted from the gallery (its view with it); the user's drawings and views unchanged.
js "(document.querySelector('[aria-label=drawings]').click(), 'g')" >/dev/null; sleep 1
js "(document.querySelector('[data-drawing=\"$key\"] [aria-label^=delete]').click(), 'del')" >/dev/null; sleep 1.5
after=$(mine); echo "$after" > "$OUT/after.json"
[ "$after" = "$before" ] && res pass "user's drawings" "drawings and views unchanged, test drawing and its view removed" ||
  res fail "user's drawings" "before/after differ: $OUT/before.json $OUT/after.json"
echo "passed $ok, failed $bad; out: $OUT"
[ "$bad" = 0 ] || echo "FAIL sketch-canvas: $bad check(s) failed"
