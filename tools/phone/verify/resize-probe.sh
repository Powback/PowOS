#!/bin/bash
# tools/phone/verify/resize-probe.sh: where a floating window's touches go right after a grip resize, and why (window-
# scroll.sh FAIL 2026-10-23: after a resize the finger went to home or the window under it, not the app). For each app
# (Calculator, Chrome; Kate for its frame lookup): launched in a window, then the grip dragged out (bigger) and back
# (smaller); at 0.5, 2 and 5 s after each lift the facts: the task's bounds (am stack list), the app's and the frame's
# input windows (dumpsys input: frame, touchable region), the app window's frame in WM, and a DOWN/UP probe at four
# spots inside the new bounds (which window the finger goes to). Logcat (PowosTaskLeash, PowosWindowResize,
# PowosWindowFrame(s), ShellTransitions) is kept for the run. --leash 0 runs it with the old path
# (settings global powos_live_leash 0, put back after). Facts only: FAIL lines where a probe misses the app.
#   queue.sh add <task> tools/phone/verify/resize-probe.sh [--apps "calc chrome kate"] [--leash 0|1]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APPS="calc chrome kate"; LEASH=""; ARGS=()
while [ $# -gt 0 ]; do case $1 in --apps) APPS=$2; shift 2 ;; --leash) LEASH=$2; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
. "$here/e2e-lib.sh"
e2e_args ${ARGS[@]+"${ARGS[@]}"}
E2E_APPS='com.oneplus.calculator|PowosWindowActivity|com.android.chrome'; E2E_LINUX='kate'
e2e_init resize-probe
e2e_setup inner

LEASH0=$(sh_ "settings get global powos_live_leash")
[ -n "$LEASH" ] && { sh_ "settings put global powos_live_leash $LEASH"; log "powos_live_leash $LEASH (was $LEASH0)"; }
putback() { [ -n "$LEASH" ] && { [ "$LEASH0" = null ] && sh_ "settings delete global powos_live_leash" || sh_ "settings put global powos_live_leash $LEASH0"; } >/dev/null; }
TAGS="PowosTaskLeash PowosWindowResize PowosWindowFrame PowosWindowFrames PowosWindowDrag PowosFreeform ShellTransitions RemoteTransitionHandler"
trap 'putback; e2e_abort' EXIT

touched() { sh_ "dumpsys input" | sed -n '/TouchStatesByDisplay/,/CursorStatesByDisplay/p' | grep -oE "name='[^']*'" | sed -E "s/name='[0-9a-f]+ ?/'/" | tr '\n' ' ' | cut -c1-300; }
# facts <task> <pat> <what>: bounds, the input windows of the app + its frame + home, the app window's WM frame.
facts() {
  log "== $3: task $(tbounds "$1")"
  sh_ "dumpsys input" | grep "frame=" | grep -E "name=[0-9a-f]+ ($2|PowOS window (bar|grip) $1\}|com.powos.app/andro.marchy.Home)" | awk '!seen[$0]++' \
    | sed -E "s/.*name=[0-9a-f]+ ([^,]*), .*(inputConfig=[^,]*), .*(frame=\[[^]]*\]\[[^]]*\]), .*(touchableRegion=.*), ownerPid.*/  input: \1 \2 \3 \4/" | head -8 | tee -a "$OUT/log.txt"
  sh_ "dumpsys SurfaceFlinger" | grep -E "Task=$1#|$2" | grep -vE "^ *\+|Composition|HWC" | awk '!seen[$0]++' | head -6 | cut -c1-260 | sed 's/^/  sf: /' | tee -a "$OUT/log.txt"
  sh_ "dumpsys window" | grep -iE "collecting|playing|mSyncEngine|activeSync|Transition\{" | head -6 | cut -c1-200 | sed 's/^/  tr: /' | tee -a "$OUT/log.txt"
  sh_ "dumpsys window windows" | awk -v p="$2" '/^ *Window #/{f=(index($0,p)>0); if(f) print "  wm: " $0} f && /(mFrame=| frame=|Requested w=|isDragResizing|mDragResizing|Surface: shown)/{print "     " $0}' | head -12 | tee -a "$OUT/log.txt"
}
# probes <task> <pat> <what>: a DOWN/UP at four spots inside the task's bounds.
probes() {
  local b t id=$1 pat=$2 what=$3 sx sy sn; b=$(tbounds "$id"); [ -n "$b" ] || { fail "[$what] no bounds for task $id"; return; }; set -- $b
  local m=$(dp 30) cx=$((($1 + $3) / 2)) cy=$((($2 + $4) / 2)) s
  for s in "$(($1 + m)) $(($2 + m)) top-left" "$cx $cy middle" "$(($3 - m)) $(($4 - m)) bottom-right" "$cx $(($4 - m)) bottom-middle"; do
    read -r sx sy sn <<<"$s"
    mdown "$sx" "$sy" "[$what] $sn" || continue; t=$(touched)
    [ -n "$t" ] || log "  touch state: $(sh_ "dumpsys input" | sed -n '/TouchStatesByDisplay/,/CursorStatesByDisplay/p' | head -6 | tr '\n' ' ' | cut -c1-400)"
    mup "$sx" "$sy"; sleep 0.3
    case $t in *"$pat"*) pass "[$what] $sn ($sx,$sy): the finger goes to the app ($t)" ;; *) fail "[$what] $sn ($sx,$sy): NOT the app's: $t" ;; esac
  done; chk probes; }
# gripdrag <task> <dx> <dy>: its grip dragged by (dx, dy) px, the lift's time.
gripdrag() { local g x y; g=$(wframe "PowOS window grip $1}"); [ -n "$g" ] || { fail "no grip for task $1 (frames: $(frames))"; return 1; }; set -- $g "$2" "$3"
  x=$((($1 + $3) / 2)); y=$((($2 + $4) / 2))
  mdown $x $y "the grip" && { mpath $x $y $((x + $5)) $((y + $6)) 10; mup $((x + $5)) $((y + $6)); chk resize; }; }
frames() { sh_ "dumpsys window windows" | grep -oE "Window #[0-9]+ Window\{[0-9a-f]+ u0 PowOS window [a-z]+ [0-9]+\}" | sed -E 's/.*PowOS window //' | tr '\n' ',' ; }
lc() { sh_ "logcat -d -v time -s $TAGS" | tail -${1:-25} | cut -c1-300 | sed 's/^/  log: /' | tee -a "$OUT/log.txt"; }
after() { sleep 0.5; facts "$1" "$2" "$3 +0.5s"; sleep 1.5; facts "$1" "$2" "$3 +2s"; sleep 3; facts "$1" "$2" "$3 +5s"; lc 30; probes "$1" "$2" "$3"; }

for app in $APPS; do
  case $app in
    calc) KEY=a:com.oneplus.calculator/; WKEY=com.oneplus.calculator; PAT=com.oneplus.calculator ;;
    chrome) KEY=a:com.android.chrome/; WKEY=com.android.chrome; PAT=com.android.chrome ;;
    kate) KEY=l:org.kde.kate; WKEY=l:org.kde.kate; PAT=PowosWindowActivity ;;
    *) fail "unknown app $app"; continue ;;
  esac
  k=$(hcall apps.list "[]" "l=>(l.find(a=>a.key.startsWith('$KEY'))||{}).key||'none'")
  [ "$k" != none ] || { fail "$app isn't installed ($k)"; continue; }
  hcall apps.launch "['$k']" "()=>'ok'" >/dev/null; CT=$(waitwin "$WKEY" 40); sleep 2; chk "$app"
  [ "$CT" != none ] && [ -n "$CT" ] || { fail "no $app window"; continue; }
  step "$app" "$app in a window (task $CT)"
  log "windows.list: $(hcall windows.list "[]" "l=>l.map(w=>w.id+':'+(w.app||w.pkg)+'@'+(w.bounds||[]).join(',')+(w.minimised?' min':'')+(w.away?' away':'')).join(' ')")"
  log "frames: $(frames) | bar $CT: $(wframe "PowOS window bar $CT}") | grip: $(wframe "PowOS window grip $CT}")"
  log "tasks: $(sh_ "am stack list" | grep -E "taskId=[0-9]+:" | grep "visible=true" | sed -E 's/.*taskId=([0-9]+): ([^ ]+) bounds=([^ ]+).*/\1 \2 \3/' | tr '\n' ';')"
  facts "$CT" "$PAT" "$app fresh"
  if [ $app = kate ]; then
    # window-scroll's flicks (its 02 step found no bar for Kate after them): the frames and tasks after each.
    set -- $(tbounds "$CT"); x=$((($1 + $3) / 2)); h=$(($4 - $2)); d=$(dp 220); [ $d -gt $((h * 2 / 3)) ] && d=$((h * 2 / 3))
    for f in "$(($2 + $(dp 24))) $d top-down" "$(($2 + h / 2 - d / 2)) $d middle-down" "$(($2 + h / 2 + d / 2)) -$d middle-up" "$(($4 - $(dp 24))) -$d bottom-up"; do
      set -- $f; swipe $x $1 $x $(($1 + $2)) 120 "kate $3" || continue; sleep 1.2; chk kate
      log "after $3: frames $(frames) | tasks $(sh_ "am stack list" | grep -E "taskId=[0-9]+:" | grep "visible=true" | sed -E 's/.*taskId=([0-9]+): ([^ ]+) bounds=([^ ]+).*/\1 \2 \3/' | tr '\n' ';')"
    done
    log "windows.list: $(hcall windows.list "[]" "l=>l.map(w=>w.id+':'+(w.app||w.pkg)+'@'+(w.bounds||[]).join(',')+(w.minimised?' min':'')+(w.away?' away':'')).join(' ')")"
    wframe "PowOS window bar $CT}" | grep -q . && pass "kate's bar is there after the flicks" || fail "kate's bar is gone after the flicks"
    continue
  fi
  set -- $(tbounds "$CT"); RX=$(dp 140); RY=$(dp 90)
  [ $(($3 + RX)) -gt $((W - $(dp 40))) ] && RX=$((-RX)); [ $(($4 + RY)) -gt $((H - $(dp 220))) ] && RY=$((-RY))
  log "resize by $RX,$RY"
  gripdrag "$CT" $RX $RY && after "$CT" "$PAT" "$app resized $RX,$RY"
  step "$app-resized" "$app after the resize"
  gripdrag "$CT" $((-RX)) $((-RY)) && after "$CT" "$PAT" "$app back"
  sh_ "am stack remove $CT"; sleep 1
done
putback
e2e_finish
