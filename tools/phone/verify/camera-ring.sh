#!/bin/bash
# lanes: phone
# camera-ring.sh (board camera-ring-hugs-the-hole; shell ui/chrome.tsx RecordingRing, host CameraHole.kt): 11-25 "the
# camera ring is too big compared to the camera size". On each screen of the foldable (now, then the other one forced
# with cmd device_state, always reset), PowOS's own held dictation lights the ring; its rect is read over CDP
# (statusbar, read-only) and compared with the phone's REAL hole: the OEM's declared one (OPlus
# ro.oplus.display.*screenhole.position, display px) - else the cutout's bounding rect from dumpsys display, printed only.
# Pass: centred on the hole within 1 CSS px, inner edge = hole radius + 2 px gap (+-1), stroke 1.5-3 px.
# Exit 0 PASS, 1 FAIL, 3 no free window, 5 SKIP (no OEM hole to compare with).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A=$T/adb.sh
OUT=${OUT:-$HOME/.cache/powos-verify/camera-ring-$(date +%m%d-%H%M%S)}; mkdir -p "$OUT"
sh_() { "$A" shell "$*" 2>/dev/null | tr -d '\r'; }
DICT=; FORCED=
# shellcheck disable=SC2034  # read by window-lock.sh's trap (WL_TRAP is eval'd there, DICT/FORCED inside it)
WL_TRAP='[ -z "$DICT" ] || "$T/cdp.sh" eval home "importShim(\"./bridge.ts\").then(b=>b.powos.speech.cancel()).then(()=>\"ok\")" >/dev/null 2>&1; [ -z "$FORCED" ] || { sh_ "cmd device_state state reset"; echo "device state reset: $(sh_ cmd device_state print-state)"; }'
. "$here/window-lock.sh"
window_lock camera-ring.sh 120
# The OEM's holes (display px, natural orientation): "l,t:r,b" each.
holes=$(sh_ "getprop ro.oplus.display.screenhole.positon; getprop ro.oplus.display.screenhole.position; getprop ro.oplus.display.secondary.screenhole.position" | grep -E '^[0-9]+,[0-9]+:[0-9]+,[0-9]+$' | sort -u | tr '\n' ' ')
echo "OEM holes: ${holes:-none}; cutouts: $(sh_ "dumpsys display" | grep -o 'boundingRect={[^}]*}' | sort -u | tr '\n' ' ')"
RING_JS='new Promise(res=>{const end=Date.now()+5000,g=()=>{const r=document.querySelector(".status-rec-ring");if(r){for(const a of r.getAnimations())a.finish();const b=r.getBoundingClientRect(),c=getComputedStyle(r);res(JSON.stringify({x:b.x,y:b.y,w:b.width,h:b.height,stroke:parseFloat(c.borderTopWidth),dpr:devicePixelRatio,iw:innerWidth}))}else if(Date.now()>end)res(document.querySelector(".status-rec-dot")?"dot":"none");else setTimeout(g,200)};g()})'
fails=(); checked=0
one() { # $1 label: read the ring on the screen shown now and compare it with the OEM hole nearest its centre
  local label=$1 cur ring verdict
  cur=$(sh_ "dumpsys window displays" | grep -m1 -o 'cur=[0-9]*x[0-9]*')
  ring=$("$T/cdp.sh" eval statusbar "$RING_JS" 2>&1 | tail -1 | sed 's/^"//; s/"$//; s/\\"/"/g')
  "$T/shot.sh" "$OUT/$label.png" >/dev/null 2>&1 || true
  echo "$label ($cur, rotation $(sh_ "dumpsys input" | grep -m1 -o 'SurfaceOrientation: [0-9]')): ring $ring"
  case $ring in '{'*) ;; *) fails+=("$label: no ring while dictating ($ring)"); return ;; esac
  verdict=$(RING="$ring" HOLES="$holes" python3 - <<'PY'
import json, os
r = json.loads(os.environ["RING"]); d = r["dpr"]
holes = [tuple(int(v) for v in h.replace(":", ",").split(",")) for h in os.environ["HOLES"].split()]
cx, cy = (r["x"] + r["w"] / 2) * d, (r["y"] + r["h"] / 2) * d
if not holes:
    print("SKIP no OEM hole; ring %.1fx%.1f css at %.1f,%.1f px" % (r["w"], r["h"], cx, cy)); raise SystemExit
l, t, rr, b = min(holes, key=lambda h: ((h[0] + h[2]) / 2 - cx) ** 2 + ((h[1] + h[3]) / 2 - cy) ** 2)
hx, hy, hr = (l + rr) / 2, (t + b) / 2, (rr - l) / 2 / d
inner = r["w"] / 2 - r["stroke"]
why = []
if abs(hx - cx) > d or abs(hy - cy) > d: why.append("centre %.1f,%.1f px, hole's %.1f,%.1f" % (cx, cy, hx, hy))
if abs(inner - (hr + 2)) > 1: why.append("inner radius %.2f css, want hole %.2f + 2" % (inner, hr))
if not 1.5 <= r["stroke"] <= 3: why.append("stroke %.2f" % r["stroke"])
print(("FAIL " + "; ".join(why)) if why else "OK hole %d,%d:%d,%d (r %.2f css) ring r %.2f css stroke %.1f" % (l, t, rr, b, hr, r["w"] / 2, r["stroke"]))
PY
)
  echo "  $verdict"
  case $verdict in OK*) checked=$((checked + 1)) ;; SKIP*) ;; *) fails+=("$label: ${verdict#FAIL }") ;; esac
}
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1
# shellcheck disable=SC2034  # read by window-lock.sh's trap (WL_TRAP is eval'd there, DICT/FORCED inside it)
DICT=1
"$T/cdp.sh" eval home 'importShim("./bridge.ts").then(b=>b.powos.speech.start(true)).then(()=>"ok",e=>"ERR "+e)' 2>&1 | tail -1
sleep 2
now=$(sh_ cmd device_state print-state)
one "state-$now"
# The other screen (fold/unfold): forced, the ring must follow to that screen's hole.
case $now in 3) to=0 ;; 0) to=3 ;; *) to= ;; esac
if [ -n "$to" ]; then
  # shellcheck disable=SC2034  # read by window-lock.sh's trap (WL_TRAP is eval'd there, DICT/FORCED inside it)
  FORCED=1; sh_ "cmd device_state state $to"; sleep 4
  one "state-$to"
fi
echo "shots: $OUT"
if [ ${#fails[@]} -gt 0 ]; then printf 'FAIL camera-ring: %s\n' "${fails[*]}"; exit 1; fi
[ "$checked" -gt 0 ] || { echo "SKIP camera-ring: no OEM hole to compare with (ring rects above)"; exit 5; }
echo "PASS camera-ring: the ring hugs the real hole on $checked screen(s) (centre +-1 css px, gap 2 +-1, stroke 1.5-3)"
exit 0
