#!/bin/bash
# lanes: phone
# needs: home
# switcher-canvas-dock.sh (board task switcher-drag-dock-open-canvas; host system/CanvasDock.kt, page ui/carddock.ts):
# the switcher's "drag a card up and toward a side" dock into OxygenOS's Open Canvas (com.oplus.pscanvas, the native
# split view), through the same host call the gesture makes (tasks.canvasDock), on the unfolded inner screen:
#   1. tasks.canvas says yes unfolded (unfolds with cmd device_state if folded, reset after)
#   2. Settings + Files started (harmless apps; ones already running are used as they are and never removed)
#   3. Settings docked LEFT beside Files: isInPocketStudio(0) true and getPocketStudioTaskRegion(0) has two regions,
#      Settings' the left one (the no-permission reads, tasks.canvasState)
#   4. MEASURED, not judged: each app's task before vs. in the canvas - "reused" (its state kept, path A is enough) or
#      "new task" (pscanvas started it fresh: path B / com.oplus.permission.safe.WINDOW needed) - and
#      `dumpsys package permission com.oplus.permission.safe.WINDOW` (its protection level), for the HACK's real fix
#   5. The canvas closed (Home, then its task removed), only the tasks this check started removed; inCanvas false.
# Exit 0 PASS, 1 FAIL, 3 not now / touched.
set -uo pipefail
NAME=switcher-canvas-dock; . "$(dirname "$0")/wwc-lib.sh"
S=com.android.settings F=com.coloros.filemanager
MINE_T=""
# tasks.list's id of [pkg]'s task (the newest), or "".
tid() { hcall tasks.list "[]" "l=>(l.find(t=>(t.key||'').includes('$1'))||{}).id??''"; }
canvas_task() { sh_ "dumpsys activity activities" | grep -E "Task\{.*com\.oplus\.pscanvas|Task\{.*pocket" | sed -nE 's/.*Task\{[0-9a-f]+ #([0-9]+).*/\1/p' | head -1; }
wwc_extra() { local c t
  sh_ "input keyevent KEYCODE_HOME" >/dev/null; sleep 1
  c=$(canvas_task)
  if [ -n "$c" ]; then
    r=$(hcall tasks.remove "[$c]" "v=>String(v)"); say "close: canvas task $c removed through home's bridge: $r"
    [ -n "$(canvas_task)" ] && sh_ "cmd activity stack remove $c" >/dev/null && say "close: canvas task $c removed (cmd activity stack remove)"
  fi
  for t in $MINE_T; do hcall tasks.remove "[$t]" "()=>'ok'" >/dev/null; done; MINE_T=""; }

T0=$SECONDS
if [ "${LOCK_HELD:-0}" != 1 ]; then
  "$T/idle.sh" --wait 120 1800 >/dev/null || { echo "SKIP phone busy (not idle 2 min within 30 min)"; exit 3; }; fi
s=$("$T/idle.sh"); case $s in *screen=Awake*) ;; *) echo "SKIP screen not on ($s)"; exit 3 ;; esac
wwc_home || wwc_skip "home's page isn't visible after going home ($(wwc_vis | head -c 60))"

# 1. Open Canvas available (unfolded).
c=$(hcall tasks.canvas "[]" "v=>String(v)")
if [ "$c" != true ]; then
  fold 3; UNFOLDED=1
  for _ in 1 2 3 4 5 6 7 8; do sleep 0.5; c=$(hcall tasks.canvas "[]" "v=>String(v)"); [ "$c" = true ] && break; done
fi
case $c in true) say "canvas: available (unfolded)" ;; *"no such call"*|*"unknown"*) wwc_skip "this APK has no tasks.canvas yet ($c)" ;;
  *) bad "canvas: tasks.canvas says $c on the unfolded screen"; wwc_end "-" ;; esac
say "permission: $(sh_ "dumpsys package permission com.oplus.permission.safe.WINDOW" | grep -iE "protectionLevel|prot=|package=" | head -3 | tr '\n' ' ')"

# 2. Settings + Files with a task each.
for p in $S $F; do
  id=$(tid $p)
  if [ -z "$id" ]; then
    sh_ "monkey -p $p -c android.intent.category.LAUNCHER 1" >/dev/null; sleep 2
    for _ in 1 2 3 4 5 6; do id=$(tid $p); [ -n "$id" ] && break; sleep 0.5; done
    [ -n "$id" ] && MINE_T="$MINE_T $id"
    say "start: $p task ${id:-none} (started by this check)"
  else say "start: $p task $id (already there: used as is, never removed)"; fi
  [ -n "$id" ] || { bad "start: no task for $p"; wwc_end "-"; }
  eval "ID_${p//./_}=$id"
done
SID=$ID_com_android_settings FID=$ID_com_coloros_filemanager
wwc_home || bad "home's page not back in front before the dock"
sh_ "logcat -c" >/dev/null

# 3. Dock Settings left beside Files (the host call the switcher's gesture makes).
r=$(hcall tasks.canvasDock "[$SID,'left',$FID]" "v=>JSON.stringify(v)")
say "dock: tasks.canvasDock($SID left, $FID) = $r"
case $r in *'"ok":true'*) ;; *) bad "dock: refused: $r" ;; esac
st=""; for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 0.5; st=$(sh_ "dumpsys activity activities" | grep -c pscanvas); [ "${st:-0}" -gt 0 ] && break; done
sleep 3   # CanvasDock.measure reads back at 2.5 s
"$T/shot.sh" "$OUT/canvas.png" >/dev/null 2>&1
cs=$(hcall tasks.canvasState "[]" "v=>JSON.stringify(v)")
say "state: $cs"
say "top: $(sh_ "dumpsys activity activities" | grep -m1 topResumedActivity | cut -c1-160)"
say "log: $(sh_ "logcat -d -s PowosCanvasDock OplusSplitScreenManagerService FlexibleWindowManagerService" | grep -iE "PocketStudio|shortcut|dock|pair" | tail -8 | cut -c1-220 | tr '\n' '|')"
v=$(python3 - "$cs" "$SID" "$FID" <<'PY'
import json, sys
try: s = json.loads(sys.argv[1])
except Exception: print("FAIL canvasState unreadable"); sys.exit()
sid, fid = sys.argv[2], sys.argv[3]
reg = s.get("regions") or {}
out = []
if not s.get("inCanvas"): out.append("FAIL isInPocketStudio(0) is false after the dock")
if len(reg) != 2: out.append(f"FAIL {len(reg)} canvas regions, not 2: {reg}")
ld = s.get("lastDock") or {}
print("MEASURE " + str(ld.get("verdict", "no measurement")))
if len(reg) == 2:
    left = min(reg, key=lambda k: reg[k][0])
    # The canvas may hold new task ids (started by intent): Settings is left when its old id is, or else the left
    # region's id is the one Settings has in recents now.
    after = (ld.get("after") or {}).get("com.android.settings")
    if left not in (sid, str(after)): out.append(f"FAIL Settings (task {sid}, now {after}) isn't the left region {left}: {reg}")
print("\n".join(out) or "OK")
PY
)
while IFS= read -r l; do case $l in FAIL*) bad "${l#FAIL }" ;; *) say "$l" ;; esac; done <<<"$v"

# 5. Close it.
wwc_extra
sleep 1
cs=$(hcall tasks.canvasState "[]" "v=>JSON.stringify(v)")
case $cs in *'"inCanvas":true'*) bad "close: still in a canvas after Home + removing its task: $cs" ;; *) say "close: canvas gone" ;; esac
wwc_end "Settings docked left of Files in Open Canvas (regions read back), canvas closed"
