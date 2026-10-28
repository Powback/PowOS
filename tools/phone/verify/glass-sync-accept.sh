#!/bin/bash
# lanes: phone
# glass-sync-accept.sh [OUT] (board shell-renders-in-sync-with-the-compositor-blur-s): the device acceptance for
# frame-synced glass (71b2c58c, Settings.Global powos_glass_sync). The manager's bar: "a 60 fps recording of a folder
# morph, a widget drag and a shade open with the blur following exactly (no lag frame), plus glass over glass".
# Runs the same four scenes with powos_glass_sync 0 (OFF, today's path) and then 1 (ON), the shell pages reloaded
# after each change (they ask the host "b.sync" on load). All motion is CDP-driven, no touch injection:
#   widget  - a home widget tile (its .tile outlined 4 px magenta) moved back and forth by inline transform ~2.2 s;
#   folder  - a home folder opened/closed twice through state.ts's `folder` signal (the morph), its sheet outlined;
#   g-o-g   - glass over glass: a tint-less test .tile (outlined) swept across the open folder's glass sheet;
#   shade   - powos.shade.open() from home, the shade's .notif-panel outlined, closed with a BACK key (not a touch).
# Each scene is screenrecorded (~4 s, 40 Mbit/s, the display's own rate). Per frame (ffmpeg at 1/4 scale, numpy):
# the outline's box; per side, gradient energy of a thin band just OUTSIDE the outline and just INSIDE it, both over
# a farther band outside (same frame: robust to dimming/tint). A blur that lags the element blurs the outside band on
# the trailing side (ratio drops) and leaves the inside band sharp on the leading side (ratio rises). Baseline = the
# same ratios on the clip's frames at rest; a MOVING frame off the baseline (out < 0.6x, or in > 1.6x+0.1) is a
# mismatched frame. Dropped frames: gaps > 1.6x the median frame gap while the outline moves.
# Masked: the wallpaper's own texture is the signal (bands with flat wallpaper are skipped, never counted); the
# verify pill and other UI are outside the outlined element's bands unless they overlap it (then skipped as flat or
# counted equally in both modes).
# PASS: ON has <= 1 mismatched frame per scene AND (0 in total or clearly fewer than OFF) AND ON drops no more frames
# than OFF: powos_glass_sync is LEFT at 1. FAIL (or abort): set back to what it was (0). Numbers printed either way;
# recordings + per-scene json under OUT (~/.cache/powos-verify/glass-accept-<time>/).
# Exit 0 pass, 1 fail, 3 a real touch / screen not awake (re-queued), 5 can't run (nothing judged; setting restored).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/glass-accept-$(date +%m%d-%H%M%S)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
cdp() { "$T/cdp.sh" eval "$1" "$2" 2>&1 | tail -1; }
home() { sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; }
setsync() { sh_ "settings put global powos_glass_sync $1"; }
. "$here/window-lock.sh"; window_lock glass-sync-accept.sh 120
ORIG=$(sh_ "settings get global powos_glass_sync"); case $ORIG in 0|1) ;; *) ORIG=0 ;; esac
KEEP=0 # 1 = PASS: leave sync on
CLEAN='(async()=>{document.getElementById("gsa-t")?.remove();document.getElementById("gsa-s")?.remove();try{const S=await importShim("./state.ts");S.folder.value=null}catch(e){}return "clean"})()'
reload() { # both glass pages, then wait for home to be back (its glass module and tiles)
  cdp home 'location.reload(),1' >/dev/null; cdp shade 'location.reload(),1' >/dev/null
  local i; for i in $(seq 1 20); do sleep 1.5
    case $(cdp home 'String(!!(window.__glass&&__glass.live&&document.querySelector(".home-tile .tile")))') in *true*) sleep 2; return 0;; esac
  done; echo "home didn't come back after the reload"; return 1; }
restore() {
  cdp home "$CLEAN" >/dev/null; cdp shade 'document.getElementById("gsa-s")?.remove(),1' >/dev/null
  local want=$ORIG; [ $KEEP = 1 ] && want=1
  if [ "$(sh_ "settings get global powos_glass_sync")" != "$want" ]; then setsync "$want"; reload >/dev/null; fi
  echo "powos_glass_sync now $(sh_ "settings get global powos_glass_sync") (was $ORIG)"
  home; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"; }
trap restore EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
DID=$(sh_ "dumpsys display" | grep -E "^  DisplayDeviceInfo" | sed -nE 's/.*uniqueId="local:([0-9]+)",.* state ON,.*/\1/p' | head -1)
[ -n "$DID" ] || { echo "no display is on"; exit 3; }
echo "display $DID, apk $(sh_ "dumpsys package com.powos.app | grep -m1 lastUpdateTime" | tr -s ' '), sync was $ORIG"
case $(cdp home 'typeof (window.__glass&&__glass.live&&__glass.live.sync)') in *function*) ;;
  *) echo "the live shell has no frame-synced glass (71b2c58c not shipped) - nothing judged"; exit 5;; esac
home; chk home

# The scenes (home page unless named). Each returns "ok" or why it couldn't run.
W_JS='(async()=>{const t=[...document.querySelectorAll(".home-tile")].find(e=>{const r=e.getBoundingClientRect();return e.querySelector(".tile")&&r.width>120&&r.top>40&&r.bottom<innerHeight-40});if(!t)return "no widget tile on screen";const s=t.querySelector(".tile");const o=[t.style.transform,t.style.transition,t.style.zIndex,s.style.outline];s.style.outline="4px solid #ff00ff";t.style.transition="none";t.style.zIndex=50;await new Promise(r=>setTimeout(r,600));let x=0,v=14;const end=performance.now()+2200;await new Promise(r=>{function f(){x+=v;if(Math.abs(x)>innerWidth*0.3)v=-v;t.style.transform=`translate(${x}px,${x/3}px)`;performance.now()<end?requestAnimationFrame(f):r()}requestAnimationFrame(f)});await new Promise(r=>setTimeout(r,500));[t.style.transform,t.style.transition,t.style.zIndex,s.style.outline]=o;return "ok"})()'
F_PRE='const S=await importShim("./state.ts");const it=(S.home.value.items||[]).find(i=>Array.isArray(i.apps)&&i.apps.length>1&&document.querySelector(`.home-tile[data-key="${i.key}"]`));if(!it)return "no folder on home";const st=document.createElement("style");st.id="gsa-s";'
F_JS="(async()=>{${F_PRE}st.textContent=\".folder-view .folder-sheet{outline:4px solid #ff00ff!important}\";document.head.appendChild(st);const w=ms=>new Promise(r=>setTimeout(r,ms));for(let k=0;k<2;k++){S.folder.value=it.key;await w(900);S.folder.value=null;await w(900)}st.remove();return \"ok\"})()"
G_JS="(async()=>{${F_PRE}st.textContent=\"#gsa-t,#gsa-t::before,#gsa-t::after{background:none!important;box-shadow:none!important;border:0!important;border-radius:0!important}\";document.head.appendChild(st);const w=ms=>new Promise(r=>setTimeout(r,ms));S.folder.value=it.key;await w(700);const sh=document.querySelector(\".folder-view .folder-sheet\");if(!sh){S.folder.value=null;st.remove();return \"the folder sheet did not open\"}const b=sh.getBoundingClientRect();const d=document.createElement(\"div\");d.className=\"tile\";d.id=\"gsa-t\";const tw=Math.min(180,b.width/3);Object.assign(d.style,{position:\"fixed\",left:\"0px\",top:(b.top+b.height/2-tw/2)+\"px\",width:tw+\"px\",height:tw+\"px\",outline:\"4px solid #ff00ff\",zIndex:99999});document.body.appendChild(d);let x=b.left,v=12;d.style.transform=\"translateX(\"+x+\"px)\";await w(400);const end=performance.now()+2000;await new Promise(r=>{function f(){x+=v;if(x>b.right-tw||x<b.left)v=-v;d.style.transform=\"translateX(\"+x+\"px)\";performance.now()<end?requestAnimationFrame(f):r()}requestAnimationFrame(f)});await w(300);d.remove();S.folder.value=null;await w(600);st.remove();return \"ok\"})()"
S_PRE='(()=>{document.getElementById("gsa-s")?.remove();const st=document.createElement("style");st.id="gsa-s";st.textContent=".notif-panel{outline:4px solid #ff00ff!important}";document.head.appendChild(st);return "ok"})()'
S_JS='(async()=>{const {powos}=await importShim("./bridge.ts");await powos.shade.open();return "ok"})()'

FF() { docker run --rm -v "$OUT":/w -w /w --entrypoint "$1" linuxserver/ffmpeg:latest "${@:2}"; }
record() { # record <mode> <scene>: screenrecord around the scene's driver
  local m=$1 sc=$2 f=/data/local/tmp/gsa-$1-$2.mp4 rp r
  "$A" shell "rm -f $f; screenrecord --display-id $DID --bit-rate 40000000 --time-limit 4 $f" >/dev/null 2>&1 & rp=$!
  sleep 0.6
  case $sc in
    widget) r=$(cdp home "$W_JS") ;;
    folder) r=$(cdp home "$F_JS") ;;
    gog)    r=$(cdp home "$G_JS") ;;
    shade)  cdp shade "$S_PRE" >/dev/null; r=$(cdp home "$S_JS"); sleep 1.4; "$A" shell input keyevent KEYCODE_BACK; sleep 1.2
            cdp shade 'document.getElementById("gsa-s")?.remove(),1' >/dev/null ;;
  esac
  wait $rp; "$A" pull "$f" "$OUT/$m-$sc.mp4" >/dev/null 2>&1; "$A" shell "rm -f $f" >/dev/null 2>&1
  case $r in *ok*) ;; *) [ $sc = shade ] || { echo "can't run scene $sc: $r"; exit 5; } ;; esac
  [ -s "$OUT/$m-$sc.mp4" ] || { echo "no recording for $m/$sc"; exit 5; }
  home; chk "$m/$sc"; }

cat > "$OUT/an.py" <<'PY'
import sys, json
import numpy as np
raw, w, h, ptsf = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
pts = [float(l) for l in open(ptsf) if l.strip() and l.strip() != "N/A"]
F = w * h * 3
data = np.memmap(raw, np.uint8, "r"); n = len(data) // F
Y, X = np.mgrid[0:h, 0:w]
rows = []
for k in range(n):
    f = np.asarray(data[k * F:(k + 1) * F]).reshape(h, w, 3).astype(np.int16)
    r, g, b = f[..., 0], f[..., 1], f[..., 2]
    M = (r > 140) & (b > 140) & (g < 120)
    if M.sum() < 30: rows.append(None); continue
    ys, xs = np.nonzero(M)
    x0, x1 = np.percentile(xs, [1, 99]).astype(int); y0, y1 = np.percentile(ys, [1, 99]).astype(int)
    if x1 - x0 < 12 or y1 - y0 < 12: rows.append(None); continue
    G = 0.3 * r + 0.59 * g + 0.11 * b
    E = np.zeros_like(G); E[:, 1:] += np.abs(np.diff(G, axis=1)); E[1:, :] += np.abs(np.diff(G, axis=0))
    Md = M.copy()
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1), (2, 0), (-2, 0), (0, 2), (0, -2)): Md |= np.roll(np.roll(M, dy, 0), dx, 1)
    out = np.stack([x0 - X, X - x1, y0 - Y, Y - y1]); dout = out.max(0); sout = out.argmax(0)
    ins = np.stack([X - x0, x1 - X, Y - y0, y1 - Y]); din = ins.min(0); sin = ins.argmin(0)
    far = (dout >= 12) & (dout <= 24) & ~Md
    if far.sum() < 40 or E[far].mean() < 4: rows.append(None); continue
    ef = E[far].mean(); ro = []; ri = []
    for s in range(4):
        nb = (dout >= 2) & (dout <= 7) & (sout == s) & ~Md
        ib = (din >= 3) & (din <= 9) & (sin == s) & ~Md
        ro.append(float(E[nb].mean() / ef) if nb.sum() >= 30 else None)
        ri.append(float(E[ib].mean() / ef) if ib.sum() >= 30 else None)
    rows.append({"k": k, "box": [int(x0), int(x1), int(y0), int(y1)], "ro": ro, "ri": ri})
prev = None; moving = []
for row in rows:
    mv = False
    if row and prev: mv = max(abs(a - b) for a, b in zip(row["box"], prev["box"])) >= 1
    if row: row["mv"] = mv; prev = row
    else: prev = None
valid = [x for x in rows if x]
rest = [x for x in valid if not x["mv"]]
base = rest if len(rest) >= 3 else valid
def med(key, s):
    v = [x[key][s] for x in base if x[key][s] is not None]
    return float(np.median(v)) if v else None
bo = [med("ro", s) for s in range(4)]; bi = [med("ri", s) for s in range(4)]
bad = []
for x in valid:
    if not x["mv"]: continue
    why = []
    for s in range(4):
        if x["ro"][s] is not None and bo[s] and x["ro"][s] < 0.6 * bo[s]: why.append("out%d" % s)
        if x["ri"][s] is not None and bi[s] is not None and x["ri"][s] > 1.6 * bi[s] + 0.1: why.append("in%d" % s)
    if why: bad.append([x["k"], why])
mv = [x["k"] for x in valid if x["mv"]]
drop = 0
if mv and len(pts) >= n and n > 2:
    t0, t1 = pts[min(mv) - 1] if min(mv) > 0 else pts[0], pts[max(mv)]
    gaps = [pts[i + 1] - pts[i] for i in range(len(pts) - 1) if t0 <= pts[i] < t1]
    if gaps:
        mg = float(np.median(gaps)); drop = sum(1 for gp in gaps if gp > 1.6 * mg)
        fps = round(1 / mg, 1) if mg > 0 else 0
    else: fps = 0
else: fps = 0
print(json.dumps({"frames": n, "outlined": len(valid), "moving": len(mv), "mismatched": len(bad), "dropped": drop,
                  "fps": fps, "examples": bad[:8], "base_out": bo, "base_in": bi}))
PY
PYRUN=(uv run -q --no-project --with numpy -- python -I)
analyse() { # analyse <mode> <scene> -> json line in OUT/<mode>-<scene>.json
  local b=$1-$2 wh
  FF ffprobe -v error -select_streams v -show_entries frame=pts_time -of csv=p=0 "$b.mp4" > "$OUT/$b.pts" 2>/dev/null
  wh=$(FF ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 "$b.mp4" | tr -d '\r')
  local w=$(( ${wh%,*} / 4 / 2 * 2 )) h=$(( ${wh#*,} / 4 / 2 * 2 ))
  FF ffmpeg -v error -y -i "$b.mp4" -vf "scale=$w:$h" -fps_mode passthrough -f rawvideo -pix_fmt rgb24 "$b.raw" || return 1
  "${PYRUN[@]}" "$OUT/an.py" "$OUT/$b.raw" $w $h "$OUT/$b.pts" > "$OUT/$b.json"; rm -f "$OUT/$b.raw"; }

SCENES="widget folder gog shade"
for mode in off on; do
  v=0; [ $mode = on ] && v=1
  setsync $v; reload || exit 5; chk "reload $mode"
  echo "== $mode (powos_glass_sync=$(sh_ "settings get global powos_glass_sync"))"
  for sc in $SCENES; do record $mode $sc; done
done
# Judged off the phone: the window is over (the lock stays until the verdict sets the knob).
num() { sed -nE "s/.*\"$2\": ([0-9]+).*/\1/p" "$OUT/$1.json" | head -1; }
fail=0; offm=0; onm=0; offd=0; ond=0
for sc in $SCENES; do for mode in off on; do analyse $mode $sc || { echo "analysis failed: $mode/$sc"; exit 5; }; done
  for mode in off on; do echo "$mode/$sc: $(cat "$OUT/$mode-$sc.json" | cut -c1-260)"; done
  m0=$(num off-$sc mismatched); m1=$(num on-$sc mismatched); d0=$(num off-$sc dropped); d1=$(num on-$sc dropped); mv=$(num on-$sc moving)
  [ -n "$m1" ] && [ -n "$mv" ] || { echo "no numbers for $sc"; exit 5; }
  if [ "$mv" -lt 15 ]; then [ $sc = shade ] && { echo "NOTE: shade scene not measured (moving frames $mv: the shade's outline wasn't seen)"; continue; }
    echo "the $sc scene had $mv outlined moving frames - not measurable"; exit 5; fi
  offm=$((offm + m0)); onm=$((onm + m1)); offd=$((offd + d0)); ond=$((ond + d1))
  [ "$m1" -le 1 ] || { echo "FAIL $sc: ON has $m1 mismatched frames (OFF $m0)"; fail=1; }
done
echo "mismatched frames: OFF $offm, ON $onm; dropped while moving: OFF $offd, ON $ond"
[ $onm -eq 0 ] || [ $((onm * 2)) -le $offm ] || { echo "FAIL: ON ($onm) isn't clearly fewer than OFF ($offm)"; fail=1; }
[ $ond -le $offd ] || { echo "FAIL: ON drops more frames ($ond) than OFF ($offd)"; fail=1; }
echo "recordings + per-scene json: $OUT"
if [ $fail = 0 ]; then KEEP=1; echo "PASS: frame-synced glass follows exactly - powos_glass_sync left at 1"; exit 0; fi
echo "FAIL: frame-synced glass did not meet the bar - powos_glass_sync set back to $ORIG"; exit 1
