#!/bin/bash
# lanes: phone
# pad-slide.sh (board on-screen-game-controls-slide-a-finger-between-b; b6980d5b SlideButtons): ONE injected finger on the
# on-screen controls: lands on B, slides to the B/Y border, back onto B, onto Y, onto B, off every button, onto B, lifts.
# A new press is logged by powos-padd only after a release, so PASS = its log says exactly "B Y Y B B": the border
# holds both (no new B on the way back), sliding onto a button presses it and off it releases it. B/Y, never A (Enter
# in Steam's desktop config) into whatever has focus. No game. Overlay state restored. `--geom <l t r b> <wm density>`
# (prefs XML on stdin) only prints the points: the fixture. Exit 0 PASS, 1 FAIL, 3 no window/touched, 5 SKIP.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$here/../../.." && pwd)
GEOM=$(cat <<'PY'
import json,math,re,sys,xml.etree.ElementTree as ET
src=open(sys.argv[1]).read(); l,t,r,b=map(int,sys.argv[2].split()); dpi=int(re.findall(r"\d+",sys.argv[3])[-1])
lay=json.loads("".join(re.findall(r'"((?:[^"\\]|\\.)*)"',src.split("DEFAULT_LAYOUT =")[1].split(";")[0])).replace('\\"','"'))
try: lay=json.loads(next(e.text for e in ET.fromstring(sys.stdin.read()).iter("string") if e.get("name")=="layout"))
except Exception: pass
W,H=r-l,b-t; slop=4/25.4*dpi; C={}
for m in lay["modules"]:
    if m["type"]=="button" and m.get("mode")!="toggle":
        x0,y0,x1,y1=m["zone"]; C[m.get("output")]=((x0+x1)/2*W,(y0+y1)/2*H,min((x1-x0)*W,(y1-y0)*H)/2)
if "b" not in C or "y" not in C: sys.exit("SKIP: the saved layout has no plain B and Y buttons")
(bx,by,br),(yx,yy,yr)=C["b"],C["y"]; d=math.dist((bx,by),(yx,yy)); g=d-br-yr; f=(br+g/2)/d
mid=(bx+(yx-bx)*f,by+(yy-by)*f) if g<1.6*slop else None
far=lambda p:all(math.dist(p,(c[0],c[1]))>c[2]+slop+20 for c in C.values())
e=next((p for p in [(.97*W,.97*H),(.6*W,.95*H),(.5*W,.6*H),(.3*W,.05*H)] if far(p)),None)
if not e: sys.exit("SKIP: no spot clear of every button")
P=lambda p:"%d %d"%(l+p[0],t+p[1]); s=[(bx,by)]+([mid,(bx,by)] if mid else [])+[(yx,yy),(bx,by),e,(bx,by)]
print(";".join(map(P,s))+"|"+("B Y Y B B" if mid else "B Y B B"))
PY
)
geom() { python3 -c "$GEOM" "$ROOT/targets/android/app/engine/src/main/java/andro/marchy/GamepadOverlay.java" "$@"; }
[ "${1:-}" = --geom ] && { geom "$2" "$3"; exit; }
. "$here/e2e-lib.sh"; OUT=$HOME/.cache/powos-verify/pad-slide-$(date +%m%d-%H%M); mkdir -p "$OUT"
. "$here/window-lock.sh"; window_lock pad-slide 120; e2e_touchwatch >/dev/null 2>&1; I0=$(irq)
was=$(hcall pad.state '[]' 'v=>String(v)'); case $was in true|false) ;; *) echo "FAIL: controller state: $was"; exit 1 ;; esac
trap 'hcall pad.overlay "[$was]" "v=>String(v)" >/dev/null; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
[ "$(hcall pad.overlay '[true]' 'v=>String(v)')" = true ] || { echo "FAIL: controller does not enable"; exit 1; }; sleep 1
fr=$(sh_ 'dumpsys window windows' | awk '/^ *Window #/{f=(index($0,"PowOS controller")>0)} f' | grep -oE ' frame=\[[0-9,]+\]\[[0-9,]+\]' | head -1 | tr -c '0-9\n' ' ')
[ -n "$(echo $fr)" ] || { echo "FAIL: controller enabled but has no window"; exit 1; }
g=$(sh_ 'cat /data/data/com.powos.app/shared_prefs/powos_gamepad.xml' | geom "$fr" "$(sh_ 'wm density')" 2>&1) || { case $g in SKIP:*) echo "$g"; exit 5 ;; esac; echo "FAIL: geometry: $g"; exit 1; }
n=$(us 'wc -l < /run/powos-app/powos-padd.log'); [[ "$n" =~ ^[0-9]+$ ]] || { echo "SKIP: ENV: no powos-padd log ($n)"; exit 5; }
IFS=';' read -ra P <<<"${g%|*}"; c="input motionevent DOWN ${P[0]}"; for p in "${P[@]:1}"; do c+="; sleep 0.35; input motionevent MOVE $p"; done
sh_ "$(self_input_for 20)$c; sleep 0.35; input motionevent UP ${P[${#P[@]}-1]}"; sleep 1
[ "$(irq)" = "$I0" ] || { echo "the user touched the phone during the slide - again later"; exit 3; }
got=$(us "tail -n +$((n + 1)) /run/powos-app/powos-padd.log" | sed -n 's/.*powos-padd: pressed //p' | tr '\n' ' ' | xargs)
echo "pad-slide: path ${g%|*}; padd presses '$got', want '${g#*|}'"
[ "$got" = "${g#*|}" ] || { echo "FAIL: one finger sliding B/Y gave presses '$got', not '${g#*|}'"; exit 1; }
echo "PASS: a finger slides between buttons - the B/Y border holds both, onto a button presses it, off releases it"
