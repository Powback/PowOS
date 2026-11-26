#!/bin/bash
# lanes: phone
# needs: home
# switcher-canvas-dock.sh (board task switcher-drag-dock-open-canvas; host system/CanvasDock.kt, page ui/carddock.ts):
# the switcher's split view - drag a card to a screen edge, it docks there, then PICK the other app (ui/canvaspick.tsx) -
# into OxygenOS's Open Canvas (com.oplus.pscanvas, the native split view), done the way the user does it: a REAL drag
# injected on the switcher's card (input motionevent: up first, then to the edge) and a real tap on the picked app, not
# the host call - on the unfolded inner screen. The user, 11-26: "You should be able to drag the window to the right
# side, left side, top or bottom. The app should then dock and you should be able to select the other app".
#   1. tasks.canvas says yes unfolded (unfolds with cmd device_state if folded, reset after); tasks.canvasSides read
#      (Settings, on OxygenOS's split blocklist, must not be in it when it runs)
#   2. Calculator, then Chrome started (both split-capable; apps already running are used as they are, never removed)
#   3. The switcher (KEYCODE_APP_SWITCH), Chrome's card dragged to the screen edge away from its centre: the picker is up
#      and NO canvas yet (never an auto-picked partner); a tap on Calculator in it: Open Canvas comes up - two sides read
#      from dumpsys input's frames, Chrome's on the dragged-to side; the page's and host's lines ([canvas] /
#      PowosCanvasDock) logged
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
# The VISIBLE Open Canvas container's task id. Not any pscanvas task: the 11-26 run's "a canvas opened before the
# pick" was a container left over from an earlier dock (#3510, visible=false, sz=1, older than both apps' tasks).
canvas_task() { sh_ "dumpsys activity activities" | grep -E "^ *\* Task\{.*com\.oplus\.pscanvas.* visible=true" | sed -nE 's/.*Task\{[0-9a-f]+ #([0-9]+).*/\1/p' | sed -n 1p; }
# Every pscanvas container, visible or not (closed before the run: a stale one is where OxygenOS may put the next dock).
canvas_tasks() { sh_ "dumpsys activity activities" | grep -E "^ *\* Task\{.*com\.oplus\.pscanvas" | sed -nE 's/.*Task\{[0-9a-f]+ #([0-9]+).*/\1/p' | sort -u; }
# The page's tasks.canvasDock calls from now on, each with its args and ms since [dock_watch] (the drop/pick evidence).
dock_watch() { ev "(()=>{globalThis.__dockCalls=[];globalThis.__dockT0=Date.now();if(!globalThis.__dockWrapped){globalThis.__dockWrapped=1;import('./bridge.ts').then(m=>{const k=m.powos.tasks,o=k.canvasDock;if(o)k.canvasDock=(...a)=>(globalThis.__dockCalls.push((Date.now()-globalThis.__dockT0)+'ms:'+a.join(',')),o(...a))})}return 'ok'})()" >/dev/null; }
# "none", or each call as "<ms>ms:<id>,<side>,<other>" joined by ";".
dock_calls() { ev "(globalThis.__dockCalls||[]).join(';')||'none'" | tr -d '"'; }
# The keyguard is up (the 11-26 run: the lock screen came up right at the pick - adopt gate keyguard=true - and the
# tap never reached the picker). Not the check's to judge: "not now".
locked() { sh_ "dumpsys window" | grep -qE "mDreamingLockscreen=true|isKeyguardShowing=true|mShowingLockscreen=true"; }
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
# drag_card <task id>: the switcher opened over the front app, that task's card lifted (up 60 CSS px first: a card push,
# not the row's scroll) and carried to the screen edge away from its centre (6 px in: ui/carddock.ts dockSide's edge
# band), then let go. Echoes "left|right x0 y0 x1 y1" (device px), or "none <why>".
drag_card() { local g side x0 y0 x1 y1 ux uy i
  selfinput; sh_ "input keyevent KEYCODE_APP_SWITCH" >/dev/null; sleep 1.5
  g=$(ev "(()=>{const c=document.querySelector('.recents.open .task[data-task=\"$1\"]');if(!c)return 'none no card for task $1 ('+[...document.querySelectorAll('.recents .task')].map(e=>e.dataset.task).join(',')+')';const r=c.getBoundingClientRect(),d=devicePixelRatio,W=innerWidth,x=r.left+r.width/2,y=r.top+r.height/2,left=x>=W/2,tx=left?6:W-6;return [left?'left':'right',x*d,y*d,tx*d,(y-60)*d].map(v=>typeof v==='number'?Math.round(v):v).join(' ')})()" | tr -d '"')
  case $g in left*|right*) ;; *) echo "${g:-none no answer}"; return ;; esac
  read -r side x0 y0 x1 y1 <<<"$g"
  selfinput
  # One shell: DOWN, up 4 steps, sideways 8 steps to the edge (the finger held there a moment: the half lights), UP.
  local cmd="input motionevent DOWN $x0 $y0"
  for i in 1 2 3 4; do uy=$(( y0 + (y1 - y0) * i / 4 )); cmd="$cmd; input motionevent MOVE $x0 $uy"; done
  for i in 1 2 3 4 5 6 7 8; do ux=$(( x0 + (x1 - x0) * i / 8 )); cmd="$cmd; input motionevent MOVE $ux $y1"; done
  sh_ "$cmd; sleep 0.3; input motionevent MOVE $x1 $y1; input motionevent UP $x1 $y1" >/dev/null
  echo "$g"; }
# picker_side: the side the picker docked the dragged app on ("left" / "right" ...), or "" when no picker is up.
picker_side() { ev "document.querySelector('.canvas-pick')?.dataset.side||''" | tr -d '"'; }
# pick_app <task id>: a real tap on that task's cell in the picker. Echoes "x y" (device px) or "none <why>".
pick_app() { local g
  g=$(ev "(()=>{const b=document.querySelector('.canvas-pick-app[data-task=\"$1\"]');if(!b)return 'none no picker cell for task $1 ('+[...document.querySelectorAll('.canvas-pick-app[data-task]')].map(e=>e.dataset.task).join(',')+')';const r=b.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.left+r.width/2)*d)+' '+Math.round((r.top+Math.min(r.height/2,30))*d)})()" | tr -d '"')
  case $g in none*|"") echo "${g:-none no answer}"; return ;; esac
  selfinput; sh_ "input tap $g" >/dev/null
  echo "$g"; }
# The dock's lines (host, page, OxygenOS, the switcher), saved whole to dock-log.txt; [n] of them echoed. Not
# AndroidRuntime: the check's own `content`/`input` calls flooded it and pushed every dock line out (11-26 run).
pagelog() { sh_ "logcat -d" | grep -E "PowosCanvasDock|\[canvas\]|PowosSwitcher|OplusSplitScreenManagerService.*(PocketStudio|PairTask|shortcut|unSupports)|FlexibleWindowManagerService.*(PocketStudio|hortcut)|FATAL EXCEPTION|ANR in" | grep -v "getPocketStudioTaskRegion" > "$OUT/dock-log.txt"
  tail -"${1:-10}" "$OUT/dock-log.txt" | cut -c1-230; }

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
# A canvas left from an earlier dock closed first (OxygenOS reuses its container; it also showed as a card).
for c in $(canvas_tasks); do r=$(hcall tasks.remove "[$c]" "v=>String(v)"); say "setup: stale canvas task $c removed: $r"; done
sh_ "logcat -c" >/dev/null
sh_ "input keyevent KEYCODE_WAKEUP" >/dev/null
dock_watch; sleep 1

# 3. The real drag on Chrome's card (the switcher opened over Chrome): docked, the picker up, no canvas till the pick.
g=$(drag_card "$CID"); say "drag: chrome's card $g"
case $g in none*) bad "drag: $g"; wwc_end "-" ;; esac
SIDE=${g%% *}
sleep 1
ps=$(picker_side); say "picker: docked ${ps:-none}"
[ "$ps" = "$SIDE" ] || bad "picker: let go at the $SIDE edge, the picker says '${ps:-no picker}'"
"$T/shot.sh" "$OUT/picker.png" >/dev/null 2>&1
calls=$(dock_calls); say "picker: tasks.canvasDock calls before the pick: $calls"
case $calls in none) ;; *) bad "picker: tasks.canvasDock called on the drop, before any pick: $calls" ;; esac
[ -n "$(canvas_task)" ] && bad "picker: a visible canvas opened before the pick (an auto-picked partner)"
locked && { pagelog 6 >/dev/null; wwc_skip "the lock screen came up before the pick"; }
p=$(pick_app "$KID"); say "pick: calculator at $p"
case $p in none*) bad "pick: $p"; wwc_end "-" ;; esac
sleep 1
calls=$(dock_calls); say "pick: tasks.canvasDock calls after the tap: $calls"
case $calls in *":$CID,$SIDE,$KID"*) ;; *) bad "pick: the tap on Calculator didn't call tasks.canvasDock($CID, $SIDE, $KID): $calls (picker now: $(picker_side))" ;; esac
locked && say "pick: the lock screen is up after the tap (see dock-log.txt)"
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
sh_ "dumpsys input" > "$OUT/input.txt" 2>/dev/null
# Each app's frame ON THE SCREEN: input's window list (InputDispatcher's frames are display space, from SurfaceFlinger).
# Not dumpsys window: Open Canvas places its sides by their surfaces, so WM's frames and task bounds are each side's
# own size at 0,0 (11-25 run: Calculator and Chrome both [0,0][1123,2440] while the shot showed Calculator left,
# Chrome right - the check's misread, not a missing split). dumpsys window only when input has no frame for an app.
frames=$(python3 - "$OUT/input.txt" "$OUT/windows.txt" "$C" "$K" <<'PY2'
import re, sys
inp = open(sys.argv[1], errors="replace").read()
win = open(sys.argv[2], errors="replace").read()
out, src = {}, {}
for line in inp.splitlines():
    for pkg in sys.argv[3:]:
        if pkg in out or not re.search(r"name='[0-9a-f]+ " + re.escape(pkg) + "/", line): continue
        if re.search(r"visible=false|NOT_VISIBLE", line): continue
        m = re.search(r"frame=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", line)
        if m and int(m.group(3)) > int(m.group(1)): out[pkg] = [int(v) for v in m.groups()]; src[pkg] = "input"
for blk in re.split(r"\n\s*Window #\d+ ", win)[1:]:
    head = blk.split("\n", 1)[0]
    for pkg in sys.argv[3:]:
        if pkg + "/" in head and pkg not in out and "isVisible=true" in blk.replace("mViewVisibility=0x0", "isVisible=true"):
            m = re.search(r"(?:mFrame|frame)=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", blk)
            if m: out[pkg] = [int(v) for v in m.groups()]; src[pkg] = "window"
print(";".join(f"{k}={','.join(map(str, v))}" for k, v in out.items()) + " " + ",".join(f"{k.rsplit('.',1)[-1]}:{v}" for k, v in src.items()))
PY2
)
fsrc=${frames##* } frames=${frames% *}
say "frames: ${frames:-none read} (from $fsrc: input = on screen, window = WM's own, unplaced)"
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
    if c[:2] == k[:2]:
        out.append(f"FAIL sides unreadable: Chrome and Calculator both at {c[:2]} ({c} / {k}) - see input.txt, windows.txt, canvas.png")
        c = None
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
  # Every note the switcher shows from here on, caught as it mounts: it lives 2.4 s (recents-note animation), and the
  # 11-25 run read the DOM once ~20 s after the drag (a slow page eval + the shot) - '' whatever had been shown.
  ev "(()=>{globalThis.__dockNotes=[];globalThis.__dockNoteObs?.disconnect();const o=new MutationObserver(()=>{for(const e of document.querySelectorAll('.recents-note')){const t=e.textContent||'';if(t&&!__dockNotes.includes(t))__dockNotes.push(t)}});o.observe(document.body,{childList:true,subtree:true,characterData:true});globalThis.__dockNoteObs=o;return 'ok'})()" >/dev/null
  g=$(drag_card "$SID")
  # The switcher's list can lag a fresh launch by a beat (11-26: Settings 3531 not yet a card): once more.
  case $g in none*) sh_ "input keyevent KEYCODE_BACK" >/dev/null; sleep 2; g=$(drag_card "$SID") ;; esac
  say "drag: settings' card $g"
  sleep 3
  n=$(ev "(()=>{const n=(globalThis.__dockNotes||[]).join(' | ');globalThis.__dockNoteObs?.disconnect();return n})()" | tr -d '"')
  "$T/shot.sh" "$OUT/settings-note.png" >/dev/null 2>&1
  say "note: $n"
  case $n in *"can't be used in split view"*) ;; *) bad "settings: no \"can't be used in split view\" note after the drag (note: '$n')" ;; esac
  sleep 2; [ -n "$(canvas_task)" ] && bad "settings: a canvas opened for Settings"
  while IFS= read -r l; do say "log: $l"; done < <(pagelog 4)
  sh_ "input keyevent KEYCODE_HOME" >/dev/null
fi
wwc_end "Chrome's card dragged to the ${SIDE:-?} edge docked, Calculator picked: Open Canvas with both (sides read back); Settings refused with a note"
