#!/bin/bash
# lanes: phone
# needs: home
# switcher-canvas-dock.sh (board task switcher-drag-dock-open-canvas; host system/CanvasDock.kt, page ui/carddock.ts):
# the switcher's "drag a card up and toward a side" dock into OxygenOS's Open Canvas (com.oplus.pscanvas, the native
# split view), done the way the user does it - a REAL drag injected on the switcher's card (input swipe), not the host
# call - on the unfolded inner screen. The user, 11-23: "it does play like a click when i activate the switcher and drag
# the app to one of the sides, but it doesnt activate splitview for it".
#   1. tasks.canvas says yes unfolded (unfolds with cmd device_state if folded, reset after); tasks.canvasSides read
#      (Settings, on OxygenOS's split blocklist, must not be in it when it runs)
#   2. Calculator, then Chrome started (both split-capable; apps already running are used as they are, never removed)
#   3. The switcher (KEYCODE_APP_SWITCH), Chrome's card dragged up and toward the side away from its centre: Open Canvas
#      comes up - isInPocketStudio(0) true, two regions (tasks.canvasState), Chrome's on the dragged-to side; the page's
#      and host's lines ([canvas] / PowosCanvasDock) logged
#      and PowOS never adopts the canvas into a web window (window-log "com.oplus.pscanvas) was full screen")
#   4. MEASURED, not judged: each app's task before vs. in the canvas ("reused" / "new task", CanvasDock.measure)
#   5. The canvas closed (Home, then its task removed); Settings' card dragged the same way: no canvas, and the note
#      "Settings can't be used in split view" on screen (never silent)
# Exit 0 PASS, 1 FAIL, 3 not now / touched.
set -uo pipefail
NAME=switcher-canvas-dock; . "$(dirname "$0")/wwc-lib.sh"
C=com.android.chrome K=com.oneplus.calculator S=com.android.settings
MINE_T=""
# tasks.list's id of [pkg]'s task (the newest), or "". "None" answers "-": hcall takes an empty answer for a failed
# hop and retries it 4 times into "ERR no answer (empty)" - the 11-24 run's "bridge stopped answering" for Calculator
# and Settings was that (neither had a task yet; the ERR text then went on as the task id). Anything not a number: "".
tid() { local v; v=$(hcall tasks.list "[]" "l=>(l.find(t=>(t.key||'').includes('$1'))||{}).id??'-'")
  case $v in [0-9]*) echo "$v" ;; -) ;; *) echo "tid $1: $v" >&2 ;; esac; }
canvas_task() { sh_ "dumpsys activity activities" | grep -E "Task\{.*com\.oplus\.pscanvas" | sed -nE 's/.*Task\{[0-9a-f]+ #([0-9]+).*/\1/p' | sed -n 1p; }
close_canvas() { local c r
  sh_ "input keyevent KEYCODE_HOME" >/dev/null; sleep 1
  c=$(canvas_task)
  [ -n "$c" ] || return 0
  r=$(hcall tasks.remove "[$c]" "v=>String(v)"); say "close: canvas task $c removed through home's bridge: $r"
  [ -n "$(canvas_task)" ] && sh_ "cmd activity stack remove $c" >/dev/null && say "close: canvas task $c removed (cmd activity stack remove)"; }
wwc_extra() { close_canvas
  for t in $MINE_T; do hcall tasks.remove "[$t]" "()=>'ok'" >/dev/null; done; MINE_T=""; }
# start <pkg>: its task (started now if it has none: then removed at the end); echoes the id.
start() { local id; id=$(tid "$1")
  sh_ "monkey -p $1 -c android.intent.category.LAUNCHER 1" >/dev/null; sleep 2
  if [ -z "$id" ]; then
    for _ in 1 2 3 4 5 6; do id=$(tid "$1"); [ -n "$id" ] && break; sleep 0.5; done
    [ -n "$id" ] && MINE_T="$MINE_T $id"; fi
  echo "$id"; }
# The injected drag is the tools' own input (window-lock.sh's powos-selfinput), not the user's touch.
selfinput() { sh_ "echo \$(( \$(date +%s) + 8 )) > /data/local/tmp/powos-selfinput"; }
# drag_card <task id>: the switcher opened over the front app, that task's card dragged up and toward the side away
# from its centre (a straight swipe: up-dominant at the first 10 px, diagonal enough, ending in the outer 20 % of the
# screen - ui/carddock.ts dockSide). Echoes "left|right x0 y0 x1 y1" (device px), or "none <why>".
drag_card() { local g side x0 y0 x1 y1
  selfinput; sh_ "input keyevent KEYCODE_APP_SWITCH" >/dev/null; sleep 1.5
  g=$(ev "(()=>{const c=document.querySelector('.recents.open .task[data-task=\"$1\"]');if(!c)return 'none no card for task $1 ('+[...document.querySelectorAll('.recents .task')].map(e=>e.dataset.task).join(',')+')';const r=c.getBoundingClientRect(),d=devicePixelRatio,W=innerWidth,x=r.left+r.width/2,y=r.top+r.height/2,left=x>=W/2,tx=left?W*0.2:W*0.8,dx=tx-x,dy=-Math.min(y-20,Math.max(1.3*Math.abs(dx),r.height*0.35));return [left?'left':'right',x*d,y*d,tx*d,(y+dy)*d].map(v=>typeof v==='number'?Math.round(v):v).join(' ')})()" | tr -d '"')
  case $g in left*|right*) ;; *) echo "${g:-none no answer}"; return ;; esac
  read -r side x0 y0 x1 y1 <<<"$g"
  selfinput; sh_ "input swipe $x0 $y0 $x1 $y1 700" >/dev/null
  echo "$g"; }
pagelog() { sh_ "logcat -d" | grep -E "PowosCanvasDock|\[canvas\]|OplusSplitScreenManagerService.*(PocketStudio|PairTask|shortcut|unSupports)|FlexibleWindowManagerService.*(PocketStudio|hortcut)|AndroidRuntime|ANR in" | grep -v "getPocketStudioTaskRegion" | tail -"${1:-10}" | cut -c1-230; }

wwc_start
# 1. Open Canvas available (unfolded: wwc_start unfolds).
c=$(hcall tasks.canvas "[]" "v=>String(v)")
case $c in true) say "canvas: available (unfolded)" ;; *"no such call"*|*"unknown"*) wwc_skip "this APK has no tasks.canvas yet ($c)" ;;
  *) bad "canvas: tasks.canvas says $c on the unfolded screen"; wwc_end "-" ;; esac

# 2. Calculator, then Chrome (Chrome the newest: its partner is Calculator).
KID=$(start $K); say "start: calculator task ${KID:-none}"
CID=$(start $C); say "start: chrome task ${CID:-none}"
[ -n "$KID" ] && [ -n "$CID" ] || { bad "start: no task for Calculator ($KID) or Chrome ($CID)"; wwc_end "-"; }
sides=$(hcall tasks.canvasSides "[]" "v=>JSON.stringify(v)")
say "sides: tasks.canvasSides = $sides"
case $sides in *"no such call"*|*"unknown"*) bad "sides: this APK has no tasks.canvasSides ($sides)" ;;
  *"$CID"*) ;; *) bad "sides: Chrome's task $CID isn't a side ($sides)" ;; esac
SID=$(tid $S)
[ -n "$SID" ] && case $sides in *"$SID"*) bad "sides: Settings (task $SID, OxygenOS's split blocklist) is in $sides" ;; esac
sh_ "logcat -c" >/dev/null

# 3. The real drag on Chrome's card (the switcher opened over Chrome).
g=$(drag_card "$CID"); say "drag: chrome's card $g"
case $g in none*) bad "drag: $g"; wwc_end "-" ;; esac
SIDE=${g%% *}
for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 0.5; [ -n "$(canvas_task)" ] && break; done
sleep 3   # CanvasDock.measure reads back at 2.5 s
"$T/shot.sh" "$OUT/canvas.png" >/dev/null 2>&1
cs=$(hcall tasks.canvasState "[]" "v=>JSON.stringify(v)")
say "state: $cs"
# The regions come from the shell's dumps, not tasks.canvasState: FlexibleWindowManager.getPocketStudioTaskRegion
# needs com.oplus.permission.safe.WINDOW (OplusActivityTaskManagerServiceEnhance), so the app's read always throws
# (11-24 log: InvocationTargetException) and its "regions" is {} even with a canvas up. Dumps kept for the next round.
sh_ "dumpsys activity activities" > "$OUT/activities.txt" 2>/dev/null
sh_ "dumpsys window windows" > "$OUT/windows.txt" 2>/dev/null
sh_ "dumpsys activity containers" > "$OUT/containers.txt" 2>/dev/null
frames=$(python3 - "$OUT/windows.txt" "$C" "$K" <<'PY2'
import re, sys
txt = open(sys.argv[1], errors="replace").read()
out = {}
for blk in re.split(r"\n\s*Window #\d+ ", txt)[1:]:
    head = blk.split("\n", 1)[0]
    for pkg in sys.argv[2:]:
        if pkg + "/" in head and pkg not in out and "isVisible=true" in blk.replace("mViewVisibility=0x0", "isVisible=true"):
            m = re.search(r"(?:mFrame|frame)=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", blk)
            if m: out[pkg] = [int(v) for v in m.groups()]
print(";".join(f"{k}={','.join(map(str, v))}" for k, v in out.items()))
PY2
)
say "frames: ${frames:-none read} (dumpsys window, visible app windows)"
say "top: $(sh_ "dumpsys activity activities" | grep -m1 topResumedActivity | cut -c1-160)"
while IFS= read -r l; do say "log: $l"; done < <(pagelog 12)
# 11-23 "it's like hiding the app": PowOS's window adopt took Open Canvas's container into a web window (off the screen).
adopted=$(sh_ "tail -n 60 /data/data/com.powos.app/files/window-log.txt" | grep -E "com\.oplus\.pscanvas\) was full screen" | tail -1)
[ -n "$adopted" ] && bad "adopt: PowOS took Open Canvas into a window: $adopted"
v=$(python3 - "$cs" "$CID" "$SIDE" "$frames" "$(canvas_task)" <<'PY'
import json, sys
try: s = json.loads(sys.argv[1])
except Exception: print("FAIL canvasState unreadable"); sys.exit()
cid, side, frames, container = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
reg = s.get("regions") or {}
out = []
if not s.get("inCanvas"): out.append("FAIL isInPocketStudio(0) is false after the drag")
if not container: out.append("FAIL no com.oplus.pscanvas container task after the drag")
ld = s.get("lastDock") or {}
print("MEASURE " + str(ld.get("verdict", "no measurement")))
fr = dict((k, [int(x) for x in v.split(",")]) for k, v in (p.split("=") for p in frames.split(";") if "=" in p))
c, k = fr.get("com.android.chrome"), fr.get("com.oneplus.calculator")
if c and k:
    ok = c[0] < k[0] if side == "left" else c[0] > k[0]
    if c[2] - c[0] >= 1.5 * (k[2] - k[0]) or k[2] - k[0] >= 1.5 * (c[2] - c[0]): print(f"MEASURE uneven sides: Chrome {c}, Calculator {k}")
    if ok: print(f"OK Chrome is on the {side} (frame {c}), Calculator beside it ({k})")
    else: out.append(f"FAIL Chrome (frame {c}) isn't on the {side} of Calculator ({k})")
elif s.get("inCanvas"): out.append(f"FAIL canvas up but not both apps' windows read from dumpsys window: {fr}")
if len(reg) == 2:
    want = (min if side == "left" else max)(reg, key=lambda k: reg[k][0])
    after = (ld.get("after") or {}).get("com.android.chrome")
    if want not in (cid, str(after)): out.append(f"FAIL Chrome (task {cid}, now {after}) isn't the {side} region {want}: {reg}")
    else: print(f"OK Chrome is the {side} region ({want}): {reg}")
print("\n".join(out) or "OK")
PY
)
while IFS= read -r l; do case $l in FAIL*) bad "${l#FAIL }" ;; *) say "$l" ;; esac; done <<<"$v"

# 5. Close it; then Settings (blocklisted) dragged: no canvas, a note.
close_canvas; sleep 1
cs=$(hcall tasks.canvasState "[]" "v=>JSON.stringify(v)")
case $cs in *'"inCanvas":true'*) bad "close: still in a canvas after Home + removing its task: $cs" ;; *) say "close: canvas gone" ;; esac
SID=$(start $S); say "start: settings task ${SID:-none}"
if [ -n "$SID" ]; then
  g=$(drag_card "$SID"); say "drag: settings' card $g"
  sleep 0.4
  n=$(ev "document.querySelector('.recents-note')?.textContent??''" | tr -d '"')
  "$T/shot.sh" "$OUT/settings-note.png" >/dev/null 2>&1
  say "note: $n"
  case $n in *"can't be used in split view"*) ;; *) bad "settings: no \"can't be used in split view\" note after the drag (note: '$n')" ;; esac
  sleep 2; [ -n "$(canvas_task)" ] && bad "settings: a canvas opened for Settings"
  while IFS= read -r l; do say "log: $l"; done < <(pagelog 4)
  sh_ "input keyevent KEYCODE_HOME" >/dev/null
fi
wwc_end "Chrome's card dragged ${SIDE:-?} docked into Open Canvas beside Calculator (regions read back); Settings refused with a note"
