#!/bin/bash
# lanes: emu phone
# tools/phone/verify/sketch-rotate.sh: Sketch (local.sketch) keeps a drawing across rotation (skill: powos-widgets). In
# one free window: opens Sketch on home, starts a FRESH test drawing from its gallery (the user's own drawings are never
# drawn on), draws one long stroke down to the bottom of the portrait canvas with real touches, rotates to landscape
# and back (user_rotation, auto-rotate off) and checks each time that the canvas was resized, every stroke is still
# drawn and the whole drawing fits on screen (window.__sketch, read only), and that the stroke is in the app's database.
# Then deletes the test drawing from the gallery, closes Sketch and puts the rotation settings back; the user's
# drawings are counted and fingerprinted before and after (must be unchanged).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); A=$here/adb.sh
OUT=${OUT:-$HOME/powos-rec/sketch-rotate-$(date +%H%M%S)}; mkdir -p "$OUT"
sh_() { "$A" shell "$@" | tr -d '\r'; }
# A value from home's page (read, or a click in this free window), decoded: a string as itself, anything else as JSON.
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
window_lock sketch-rotate.sh 120
t0=$(sh_ cat /data/local/tmp/powos-lasttouch)
touched() { [ "$(sh_ cat /data/local/tmp/powos-lasttouch)" != "$t0" ] && { echo "ABORT: the user touched the phone"; exit 3; }; return 0; }
rot0=$(sh_ settings get system user_rotation); acc0=$(sh_ settings get system accelerometer_rotation)
before=$(sql "SELECT id, key, width, height, updated FROM drawing"); echo "$before" > "$OUT/before.json"
ok=0; bad=0; res() { if [ "$1" = pass ]; then ok=$((ok+1)); else bad=$((bad+1)); fi; echo "$1 $2: $3" | tee -a "$OUT/result.txt"; }
. "$(dirname "$0")/sketch-lib.sh"
state() { js 'JSON.stringify(window.__sketch || null)'; }
fits() { # <state json>: canvas WxH, strokes, and the whole extent on the canvas
  python3 -c 'import json,sys; s=json.loads(sys.argv[1]); v=s["view"]; r=s["extent"]; w,h=s["size"]
ok=v["ox"]+r["x0"]*v["s"]>=-1 and v["oy"]+r["y0"]*v["s"]>=-1 and v["ox"]+r["x1"]*v["s"]<=w+1 and v["oy"]+r["y1"]*v["s"]<=h+1
print(w, h, s["strokes"], "fits" if ok else "CROPPED", round(v["s"],3))' "$1" 2>/dev/null || echo "? ? 0 unreadable"
}
# Portrait, home, Sketch open on a fresh drawing.
sh_ settings put system accelerometer_rotation 0; sh_ settings put system user_rotation 0
sketch_fresh || exit 1
# One long stroke with real touches, from the top third to the canvas's bottom (screen px = css px x dpr).
read -r x0 y0 x1 y1 <<<"$(js '(() => { const c = [...document.querySelectorAll("canvas")].sort((a, b) => b.width * b.height - a.width * a.height)[0]; const r = c.getBoundingClientRect(), d = devicePixelRatio; return [r.left + r.width * 0.3, r.top + r.height * 0.3, r.left + r.width * 0.7, r.top + r.height * 0.86].map((v) => Math.round(v * d)).join(" "); })()')"
touched; sh_ input swipe "$x0" "$y0" "$x1" "$y1" 600; sleep 1.5
s1=$(state); echo "drawn: $s1" >> "$OUT/states.txt"; alive "$s1" "drawn"; read -r w1 h1 n1 f1 _ <<<"$(fits "$s1")"
[ "${n1:-0}" -ge 1 ] && res pass draw "${n1} stroke on ${w1}x${h1}" || res fail draw "no stroke recorded (swipe $x0,$y0 -> $x1,$y1; $s1)"
sh_ "screencap -p /data/local/tmp/sk-portrait.png"; "$A" pull /data/local/tmp/sk-portrait.png "$OUT/" >/dev/null 2>&1
# Landscape.
touched; sh_ settings put system user_rotation 1; sleep 3
s2=$(state); echo "landscape: $s2" >> "$OUT/states.txt"; alive "$s2" "landscape"; read -r w2 h2 n2 f2 k2 <<<"$(fits "$s2")"
sh_ "screencap -p /data/local/tmp/sk-landscape.png"; "$A" pull /data/local/tmp/sk-landscape.png "$OUT/" >/dev/null 2>&1
[ "$w2" != "$w1" ] && [ "$n2" = "$n1" ] && [ "$f2" = fits ] && res pass landscape "${w2}x${h2}, ${n2} stroke(s), whole drawing on screen (scale $k2)" ||
  res fail landscape "${w2}x${h2} (was ${w1}x${h1}), ${n2}/${n1} strokes, $f2"
# Back to portrait.
touched; sh_ settings put system user_rotation 0; sleep 3
s3=$(state); echo "portrait: $s3" >> "$OUT/states.txt"; alive "$s3" "portrait"; read -r w3 h3 n3 f3 k3 <<<"$(fits "$s3")"
[ "$w3" = "$w1" ] && [ "$n3" = "$n1" ] && [ "$f3" = fits ] && res pass "portrait again" "${w3}x${h3}, ${n3} stroke(s), scale $k3" ||
  res fail "portrait again" "${w3}x${h3}, ${n3}/${n1} strokes, $f3"
# In the database (so a restart keeps it).
id=$(sql "SELECT id FROM drawing WHERE key = '$key'" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0][0] if r else "")' 2>/dev/null)
cnt=$( [ -n "$id" ] && sql "SELECT id FROM stroke WHERE drawing = $id" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)
[ "${cnt:-0}" -ge 1 ] && res pass saved "test drawing $id has $cnt stroke(s) in local-sketch" || res fail saved "test drawing ${id:-missing}: ${cnt:-0} strokes in the database"
# Clean up: the test drawing deleted from the gallery, then checked gone; the user's drawings unchanged.
echo "cleanup: $(drop)" >> "$OUT/states.txt"
after=$(sql "SELECT id, key, width, height, updated FROM drawing"); echo "$after" > "$OUT/after.json"
[ "$after" = "$before" ] && res pass "user's drawings" "unchanged, test drawing removed" || res fail "user's drawings" "before/after differ: $OUT/before.json $OUT/after.json"
sh_ rm -f /data/local/tmp/sk-portrait.png /data/local/tmp/sk-landscape.png
echo "passed $ok, failed $bad; out: $OUT"
[ "$bad" = 0 ] || echo "FAIL sketch-rotate: $bad check(s) failed"
