#!/bin/bash
# tools/phone/verify/window-rec.sh: screen recordings of a floating window's bar drag and grip resize (the
# window-core review: content follows live, no flicker or ghost, no white/empty area), with where SurfaceFlinger draws
# the app (HWC Disp Frame) mid-gesture and after, logcat PowosTaskLeash & co, and touches into the window after each
# gesture (InputDispatcher's touch state: does the app's window get the finger). Optional stages:
#   --app calc|kate  Calculator (Android, default) or Kate (a Linux window, PowosWindowActivity)
#   --off            the same with the live leash off (settings put global powos_live_leash 0; put back after)
#   --pages          page-swipe frame times (gfxinfo of com.powos.app) without and with the window open
# Recordings: ~/.cache/powos-verify/window-core/<MMDD-HHMM>-<app>[-off]-{drag,resize,pages}.mp4 (+ logcat, log).
#   queue.sh add --budget 300 <task> tools/phone/verify/window-rec.sh --app kate [--off] [--pages]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APP=calc; OFF=0; PAGES=0; ARGS=()
while [ $# -gt 0 ]; do case $1 in --app) APP=$2; shift 2 ;; --off) OFF=1; shift ;; --pages) PAGES=1; shift ;; *) ARGS+=("$1"); shift ;; esac; done
. "$here/e2e-lib.sh"
e2e_args ${ARGS[@]+"${ARGS[@]}"}; LAST=2
E2E_APPS='com.oneplus.calculator|PowosWindowActivity'; E2E_LINUX='kate'
TAG=$APP$([ $OFF = 1 ] && echo -off)
e2e_init "rec-$TAG"
e2e_setup inner
RD=$HOME/.cache/powos-verify/window-core; mkdir -p "$RD"; STAMP=$(date +%m%d-%H%M); PRE=$RD/$STAMP-$TAG
TOL=${TOL:-40}
LEASH0=$(sh_ "settings get global powos_live_leash")
restore_leash() { if [ "$LEASH0" = null ] || [ -z "$LEASH0" ]; then sh_ "settings delete global powos_live_leash" >/dev/null; else sh_ "settings put global powos_live_leash $LEASH0" >/dev/null; fi; }
trap 'rc=$?; sh_ "pkill -INT screenrecord" >/dev/null 2>&1; restore_leash; (exit $rc); e2e_abort' EXIT
[ $OFF = 1 ] && sh_ "settings put global powos_live_leash 0"
note "live leash setting: was ${LEASH0:-unset}, now $(sh_ "settings get global powos_live_leash")"
DID=$(sh_ "dumpsys display" | grep -E "^  DisplayDeviceInfo" | sed -nE 's/.*uniqueId="local:([0-9]+)",.* state ON,.*/\1/p' | head -1)

case $APP in
  calc) KEY=a:com.oneplus.calculator/; LAYER=com.oneplus.calculator/; WKEY=com.oneplus.calculator ;;
  kate) KEY=l:org.kde.kate; LAYER=PowosWindowActivity; WKEY=l:org.kde.kate ;;
  *) echo "unknown --app $APP"; exit 2 ;;
esac

sfframe() { sh_ "dumpsys SurfaceFlinger" | awk -v p="$1" '
  /\(active\) HWC layers:/ {on=1; next} /HWC layers:/ {on=0}
  on && want {n=split($0, f, "|"); if (n >= 6) {print f[6]; exit} }
  on && index($0, p) {want=1}' | xargs; }
content() { sfframe "$LAYER"; }
near() { local d=$(($1 - $2)); [ ${d#-} -le "$3" ]; }
logc() { sh_ "rm -f /data/local/tmp/rec.txt; (timeout 280 logcat -T 1 -v time -s PowosTaskLeash PowosWindowDrag PowosWindowResize PowosWindowFrames PowosWindowFrame PowosFreeform WindowTasks RemoteTransitionHandler ShellTransitions </dev/null >/data/local/tmp/rec.txt 2>&1 &)"; }
rec() { sh_ "rm -f /data/local/tmp/wc-$1.mp4; (screenrecord --display-id $DID --bit-rate 20000000 --time-limit ${2:-12} /data/local/tmp/wc-$1.mp4 </dev/null >/dev/null 2>&1 &)"; sleep 1.2; }
recstop() { sleep 0.6; sh_ "pkill -INT screenrecord"; sleep 1.5; "$A" pull "/data/local/tmp/wc-$1.mp4" "$PRE-$1.mp4" >/dev/null 2>&1 && log "recording: $PRE-$1.mp4 ($(du -k "$PRE-$1.mp4" | cut -f1) KB)" || fail "no recording for $1"; sh_ "rm -f /data/local/tmp/wc-$1.mp4"; }
touched() { sh_ "dumpsys input" | sed -n '/TouchStatesByDisplay/,/CursorStatesByDisplay/p' | grep -oE "name='[^']*'|pilferingPointerIds=[^,]*" | tr '\n' ' ' | cut -c1-600; }
# A tap inside the window's content (a third down, a quarter in): which windows the finger went to.
intap() { local b w=$2; b=$(tbounds "$1"); [ -n "$b" ] || return; set -- $b; local x=$(($1 + ($3 - $1) / 4)) y=$(($2 + ($4 - $2) / 3))
  mdown $x $y "inside the window" || return; local t; t=$(touched); mup $x $y
  case $t in *PowosWindowActivity*|*calculator*|*Calculator*) pass "[$w] a tap inside goes to the app: $t" ;; *) fail "[$w] a tap inside did NOT reach the app's window: $t" ;; esac; sleep 0.6; }
gfx() { sh_ "dumpsys gfxinfo com.powos.app" | grep -m6 -E "Total frames rendered|Janky frames|50th percentile|90th percentile|99th percentile|Number Missed Vsync" | xargs; }
pagelag() { local p x y to d=1
  p=$(freept "$(win "$WKEY" bounds 2>/dev/null)" $d $((W * 35 / 100))); [ "$p" = none ] || [ -z "$p" ] && { d=-1; p=$(freept "$(win "$WKEY" bounds 2>/dev/null)" $d $((W * 35 / 100))); }
  [ "$p" != none ] && [ -n "$p" ] || { fail "[$1] no spot for a page swipe"; return; }
  set -- $p "$1"; x=$1; y=$2; to=$((x + d * W * 35 / 100))
  logc; sh_ "dumpsys gfxinfo com.powos.app reset >/dev/null"; rec "pages-$3" 10
  swipe $x $y $to $y 250 "pages ($3)"; sleep 1.2; hemit system.home null; sleep 0.8; chk "pages-$3"
  swipe $x $y $to $y 250 "pages again ($3)"; sleep 1.2; hemit system.home null; sleep 0.8; chk "pages-$3"
  # The refresh rate while a finger moves the page (a slow swipe, sampled half way): the display mode, and the votes
  # that cap it (an app window's request caps the whole display).
  offpill $x $y "slow page swipe" && note "[$3] mid-swipe refresh: $(sh_ "(input swipe $x $y $to $y 1200 &); sleep 0.6; dumpsys SurfaceFlinger | grep -m1 -E \"activeMode=\" | grep -oE \"vsyncRate=[0-9.]+\"; dumpsys SurfaceFlinger | grep -m2 -E \"PrimaryRefreshRates|AppRequestRefreshRates\"; dumpsys display | grep -E \"PRIORITY_APP_REQUEST|PRIORITY_.*TOUCH|PRIORITY_.*IDLE|mActiveRenderFrameRate\"; sleep 0.8" | tr -s " " | tr "\n" ";")"
  sleep 0.8; hemit system.home null; sleep 0.8; chk "pages-$3"
  recstop "pages-$3"; note "[$3] page swipes, home's frames: $(gfx)"
  sh_ "cat /data/local/tmp/rec.txt" > "$PRE-pages-$3-logcat.txt"
  note "[$3] window events during the swipes: $(grep -cE 'PowosWindowFrame' "$PRE-pages-$3-logcat.txt") PowosWindowFrame(s) lines, $(grep -c 'windows (' "$PRE-pages-$3-logcat.txt") refreshes"; }

[ $PAGES = 1 ] && pagelag nowin
logc
r=$(hcall apps.launch "['$(hcall apps.list "[]" "l=>(l.find(a=>a.key.startsWith('$KEY'))||{}).key||'none'")']" "()=>'ok'")
CT=$(waitwin "$WKEY" 40); sleep 2; chk open
step open "$APP in a window ($r)"
[ "$CT" != none ] && [ -n "$CT" ] || { fail "no $APP window"; e2e_finish; exit 0; }
C0=$(content); note "task $CT $(tbounds "$CT"), content $C0"
intap "$CT" before
[ $PAGES = 1 ] && pagelag win

# Move: out, part way back, held, let go.
p=$(barpt "$CT"); if [ -n "$p" ]; then set -- $p; x=$1; y=$2; dx=$(dp 160); dy=$(dp 80)
  [ $((x + dx)) -gt $((W - $(dp 80))) ] && dx=$((-dx)); [ $((y + dy)) -gt $((H - $(dp 300))) ] && dy=$((-dy))
  set -- ${C0:-0 0 0 0}; L0=$1; T0=$2
  rec drag 14
  mdown $x $y "the bar" && { mpath $x $y $((x + dx)) $((y + dy)) 24; mpath $((x + dx)) $((y + dy)) $((x + dx * 3 / 4)) $((y + dy * 3 / 4)) 8; sleep 0.4
    M=$(content); dx=$((dx * 3 / 4)); dy=$((dy * 3 / 4)); note "content mid-drag $M (was $C0)"
    set -- $M; [ $# -ge 4 ] && near "$1" $((L0 + dx)) $TOL && near "$2" $((T0 + dy)) $TOL && pass "mid-drag the content is with the finger: $1,$2" || fail "mid-drag the content is at ${M:-none}, the finger wants $((L0 + dx)),$((T0 + dy))"
    mup $((x + dx)) $((y + dy)); sleep 1.5; chk move; recstop drag
    E=$(content); step moved "bar let go"; note "content after $E, task $(tbounds "$CT")"
    set -- $E; [ $# -ge 4 ] && near "$1" $((L0 + dx)) $TOL && near "$2" $((T0 + dy)) $TOL && pass "after the lift the content stays: $1,$2" || fail "after the lift the content is at ${E:-none} (want $((L0 + dx)),$((T0 + dy)))"
    set -- $(tbounds "$CT") $E; [ $# -ge 8 ] && near "$1" "$5" $TOL && near "$2" "$6" $TOL && pass "task bounds and content agree" || fail "task bounds ($1 $2 $3 $4) and content (${5:-} ${6:-}) differ"; }
  intap "$CT" "after the drag"
else fail "no bar"; fi

# Resize: the grip out (or in near an edge), held, let go.
g=$(wframe "PowOS window grip $CT}"); if [ -n "$g" ]; then set -- $g; x=$((($1 + $3) / 2)); y=$((($2 + $4) / 2)); s=1
  { [ $x -gt $((W - $(dp 200))) ] || [ $y -gt $((H - $(dp 260))) ]; } && s=-1
  C1=$(content); set -- ${C1:-0 0 0 0}; W0=$(($3 - $1)); H0=$(($4 - $2)); dx=$((s * $(dp 150))); dy=$((s * $(dp 100)))
  rec resize 14
  mdown $x $y "the grip" && { mpath $x $y $((x + dx)) $((y + dy)) 24; sleep 0.9
    M=$(content); note "content mid-resize $M (was $C1)"; set -- ${M:-0 0 0 0}; WM=$(($3 - $1))
    [ $(( (WM - W0) * s )) -gt 0 ] && near $WM $((W0 + dx)) $(((W0 + dx) * 15 / 100)) && pass "mid-resize the content is $WM px wide (was $W0, finger $((W0 + dx)))" || fail "mid-resize the content is $WM px wide (was $W0, finger wants $((W0 + dx)))"
    mup $((x + dx)) $((y + dy)); sleep 2; chk resize; recstop resize
    E=$(content); step resized "grip let go"; set -- ${E:-0 0 0 0}; WE=$(($3 - $1)); HE=$(($4 - $2))
    set -- $(tbounds "$CT"); TW=$(($3 - $1)); TH=$(($4 - $2)); note "content after $E (${WE}x$HE), task $* (${TW}x$TH)"
    near $WE $TW 8 && near $HE $TH $((TH / 20 + 8)) && pass "after the lift the content fills the task (${WE}x$HE vs ${TW}x$TH)" || fail "after the lift the content (${WE}x$HE) doesn't fill the task (${TW}x$TH)"
    near $TW $((W0 + dx)) $(((W0 + dx) / 10)) && pass "the task took the new width ($TW)" || fail "the task is $TW wide (want $((W0 + dx)))"; }
  intap "$CT" "after the resize"
else fail "no grip"; fi

sh_ "cat /data/local/tmp/rec.txt" > "$PRE-logcat.txt"; cp "$OUT/log.txt" "$PRE-log.txt" 2>/dev/null
log "logcat: $(wc -l < "$PRE-logcat.txt") lines -> $PRE-logcat.txt"; grep -E "PowosTaskLeash|PowosWindowResize|Found filter" "$PRE-logcat.txt" | tail -14 | tee -a "$OUT/log.txt"
e2e_finish
cp "$OUT/log.txt" "$PRE-log.txt" 2>/dev/null; true
