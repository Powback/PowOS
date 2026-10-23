#!/bin/bash
# tools/phone/verify/window-max.sh <calc|kate|video> [--round R]: a floating window's maximise / restore and an app's
# OWN full screen on the unfolded home (WindowFrames.maximise, FreeformTasks; KWin patch for Linux windows), with a
# screen recording of each stage for review (~/.cache/powos-verify/window-max/<round>/<stage>.mp4).
#   calc:  Calculator from home: the bar's maximise -> the window fills the area under the status bar and above home's
#          bottom bar, its content at that size (SurfaceFlinger draws the app's layer over the task's whole bounds, its
#          buffer not scaled); restore -> EXACTLY the bounds before; a double tap on the bar does the same.
#   kate:  Kate (a Linux window): the same maximise / restore; then Kate's own full screen (Ctrl+Shift+F): the task covers
#          the whole screen (no PowOS bar, home and its dock not shown); Ctrl+Shift+F again: back floating at its bounds.
#   video: a page in Chrome (window-max-video.html, served on the phone's 127.0.0.1) whose video asks for full screen on a
#          tap: the task covers the whole screen, no bar, no dock; Back leaves it: floating at its bounds again.
# Only what it opened is closed (e2e-lib: Calculator/Chrome tasks it started, Kate if it started it; a stage whose app
# was already running is skipped - the user's). Queue each stage: queue.sh add [--close] <task> <this> <stage>.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
STAGE=${1:-calc}; shift || true
case $STAGE in calc|kate|video) ;; *) echo "stage: calc | kate | video"; exit 2 ;; esac
. "$here/e2e-lib.sh"
e2e_args "$@"
e2e_init "max-$STAGE"
e2e_setup inner
REC=$HOME/.cache/powos-verify/window-max/$ROUND; mkdir -p "$REC"
DID=$(sh_ "dumpsys display" | grep -E "^  DisplayDeviceInfo" | sed -nE 's/.*uniqueId="local:([0-9]+)",.* state ON,.*/\1/p' | head -1)
trap 'sh_ "pkill -INT screenrecord" >/dev/null 2>&1; e2e_abort' EXIT
TOL=${TOL:-3}

# --- measuring ---------------------------------------------------------------------------------------------------
# sfrow <layer name part>: "dl dt dr db cl ct cr cb" - where SurfaceFlinger composes the layer on the ON display (HWC
# Disp Frame) and the part of its buffer it shows (Source Crop): equal sizes = the app drew at the window's size.
sfrow() { sh_ "dumpsys SurfaceFlinger" | awk -v p="$1" '
  /\(active\) HWC layers:/ {on=1; next} /HWC layers:/ {on=0}
  on && want {n=split($0, f, "|"); if (n >= 7) {print f[6], f[7]; exit} }
  on && index($0, p) {want=1}' | tr -c '0-9.\n-' ' ' | xargs; }
mode() { sh_ "dumpsys activity activities" | grep -E "^ *\* Task\{.* #$1 " | grep -oE "mode=[a-z-]+" | head -1 | cut -d= -f2; }
near() { local d=$(($1 - $2)); [ ${d#-} -le "$3" ]; }
# eqrect "a b c d" "e f g h" tol
eqrect() { set -- $1 $2 "$3"; [ $# -ge 9 ] && near "$1" "$5" "$9" && near "$2" "$6" "$9" && near "$3" "$7" "$9" && near "$4" "$8" "$9"; }
# The status bar's bottom (its window's frame) and home's bottom bar top (the page), device px.
SB=$(sh_ "dumpsys window windows" | awk '/^ *Window #/{f=(index($0," StatusBar}")>0)} f' | grep -oE ' frame=\[-?[0-9]+,-?[0-9]+\]\[-?[0-9]+,-?[0-9]+\]' | head -1 | tr -c '0-9\n-' ' ' | awk '{print $4}')
BARTOP=$(ev 'Math.round(Math.min(...[...document.querySelectorAll(".home > .bar, .home > .dock, .home > .bottom-bar")].map(e=>e.getBoundingClientRect()).filter(r=>r.height>0).map(r=>r.top))*devicePixelRatio)' | tr -dc '0-9')
log "status bar to ${SB:-?} px, home's bottom bar at ${BARTOP:-?} px, display $DID"
# what <task> <layer>: one line of facts for the log (mode, task bounds, content row, bar frame).
what() { echo "mode=$(mode "$1") task=[$(tbounds "$1")] content=[$(sfrow "$2")] bar=[$(wframe "PowOS window bar $1}")]"; }
# dumps <name> <task>: the raw facts behind a state, for the record.
dumps() { ash <<EOF > "$OUT/$1.txt"
dumpsys activity activities | awk '/\* Task\{.* #$2 /{f=1} f&&/\* Task\{/&&!/#$2 /{f=0} f' | head -40
echo ---; dumpsys window | grep -E "statusBars|navigationBars|mTopIsFullscreen|mForceShowSystemBars|mFocusedApp" | head -24
echo ---; dumpsys window windows | grep -E "Window #|isVisible|mHasSurface" | grep -B1 -E "isVisible=true" | grep -E "Window #" | head -30
EOF
}

# --- recording ---------------------------------------------------------------------------------------------------
rec_start() { sh_ "rm -f /data/local/tmp/wmax-$1.mp4; (screenrecord --display-id $DID --bit-rate 16000000 --time-limit ${2:-60} /data/local/tmp/wmax-$1.mp4 </dev/null >/dev/null 2>&1 &)"; sleep 1; }
rec_stop() { sh_ "pkill -INT screenrecord"; sleep 2; "$A" exec-out "su -c 'cat /data/local/tmp/wmax-$1.mp4'" > "$REC/$1.mp4" 2>/dev/null; sh_ "rm -f /data/local/tmp/wmax-$1.mp4"
  log "recording: $REC/$1.mp4 ($(wc -c < "$REC/$1.mp4" | tr -d ' ') bytes)"; }
logc() { sh_ "rm -f /data/local/tmp/wmax.log; (timeout 200 logcat -T 1 -v time -s PowosWindowFrames PowosWindowFrame PowosFreeform PowosTaskLeash WindowTasks PowosWindowActivity </dev/null >/data/local/tmp/wmax.log 2>&1 &)"; }
logc_get() { sh_ "cat /data/local/tmp/wmax.log" > "$OUT/logcat.txt"; us "tail -n 60 /run/powos-app/hyprland.log 2>/dev/null | grep -iE 'window task|full|resiz|size' | tail -30" > "$OUT/kwin.txt"; }

# --- maximise / restore ------------------------------------------------------------------------------------------
maxbtn() { local b; b=$(wframe "PowOS window bar $1}"); [ -n "$b" ] || return 0; set -- $b; echo "$(($3 - $(dp 55))) $((($2 + $4) / 2))"; }
# maxcheck <task> <layer> <label>: maximise from the bar's button, then restore; then a double tap on the bar.
maxcheck() {
  local id=$1 lay=$2 app=$3 b0 b1 b2 c p r
  b0=$(tbounds "$id"); note "$app before: $(what "$id" "$lay")"
  p=$(maxbtn "$id"); [ -n "$p" ] || { fail "$app: no title bar to maximise from"; return; }
  set -- $p; tap "$1" "$2" "$app's maximise" || return; sleep 0.35
  note "$app 0.35 s after maximise: $(what "$id" "$lay")"
  sleep 1.4; chk maximise
  step "$app-max" "$app maximised from its title bar"; dumps "$app-max" "$id"
  b1=$(tbounds "$id"); c=$(sfrow "$lay"); note "$app maximised: $(what "$id" "$lay")"
  set -- $b1
  [ $# -ge 4 ] && [ "$1" -le "$TOL" ] && [ "$3" -ge $((W - TOL)) ] && [ "$2" -ge "${SB:-0}" ] && [ "$4" -le "${BARTOP:-$H}" ] && [ "$4" -ge $((${BARTOP:-$H} - $(dp 40))) ] &&
    pass "$app maximised fills the area: [$b1] (status bar to ${SB:-?}, home's bar at ${BARTOP:-?})" || fail "$app maximised to [$b1], want 0..$W wide, under ${SB:-?}, just above ${BARTOP:-?}"
  r=$(wframe "PowOS window bar $id}"); set -- $r
  [ $# -ge 4 ] && [ "$2" -ge "${SB:-0}" ] && pass "$app's title bar stays under the status bar ($r)" || fail "$app's title bar [$r] covers the status bar (to ${SB:-?})"
  set -- $c; if [ $# -ge 8 ]; then
    eqrect "$1 $2 $3 $4" "$b1" 4 && near $(($3 - $1)) $(($7 - $5)) 4 && near $(($4 - $2)) $(($8 - $6)) 4 &&
      pass "$app's content drawn at the maximised size ([$c])" || fail "$app's content [$c] isn't the maximised window [$b1] (stale or scaled)"
  else fail "$app: no content layer ($c)"; fi
  p=$(maxbtn "$id"); set -- $p; tap "$1" "$2" "$app's restore" || return; sleep 0.35
  note "$app 0.35 s after restore: $(what "$id" "$lay")"
  sleep 1.4; chk restore
  step "$app-restored" "$app restored from its title bar"
  b2=$(tbounds "$id"); c=$(sfrow "$lay"); note "$app restored: $(what "$id" "$lay")"
  [ "$b2" = "$b0" ] && pass "$app restored to exactly its bounds before ([$b2])" || fail "$app restored to [$b2], was [$b0]"
  set -- $c; [ $# -ge 8 ] && eqrect "$1 $2 $3 $4" "$b2" 4 && near $(($3 - $1)) $(($7 - $5)) 4 && pass "$app's content back at its size ([$c])" || fail "$app's content [$c] after restore, window [$b2]"
  # A double tap on the bar (the desktop convention): maximised, again: back.
  p=$(barpt "$id"); [ -n "$p" ] || return; set -- $p
  log "double tap $app's bar at $1,$2"; offpill "$1" "$2" "bar" || return
  sh_ "input tap $1 $2; input tap $1 $2"; sleep 1.6; chk dtap
  b1=$(tbounds "$id"); step "$app-dtap" "$app's bar double-tapped"
  set -- $b1; [ $# -ge 4 ] && [ "$3" -ge $((W - TOL)) ] && [ "$1" -le "$TOL" ] && pass "$app: a double tap on the bar maximises ([$b1])" || fail "$app: a double tap on the bar left it at [$b1]"
  p=$(barpt "$id"); set -- $p; sh_ "input tap $1 $2; input tap $1 $2"; sleep 1.6; chk dtap2
  b2=$(tbounds "$id"); [ "$b2" = "$b0" ] && pass "$app: a second double tap restores exactly ([$b2])" || fail "$app: after the second double tap [$b2], was [$b0]"
}

# --- an app's own full screen ------------------------------------------------------------------------------------
# fscheck <task> <layer> <label> <enter cmd> <leave cmd>: the app asks for full screen, then leaves it.
fscheck() {
  local id=$1 lay=$2 app=$3 b0 b1 b2 m r hv
  b0=$(tbounds "$id"); note "$app before full screen: $(what "$id" "$lay")"
  eval "$4"; sleep 0.5; note "$app 0.5 s after asking for full screen: $(what "$id" "$lay")"; sleep 1.8; chk fullscreen
  step "$app-fullscreen" "$app asked for full screen"; dumps "$app-fullscreen" "$id"
  b1=$(tbounds "$id"); m=$(mode "$id"); r=$(wframe "PowOS window bar $id}"); hv=$(tvis "$HOMET")
  note "$app full screen: $(what "$id" "$lay") home visible=$hv"
  set -- $b1; [ $# -ge 4 ] && [ "$1" -le 0 ] && [ "$2" -le 0 ] && [ "$3" -ge "$W" ] && [ "$4" -ge "$H" ] && pass "$app full screen covers the whole screen ([$b1], $m)" || fail "$app full screen: [$b1] mode $m, want 0 0 $W $H"
  [ -z "$r" ] && pass "$app full screen has no PowOS title bar" || fail "$app full screen still has a title bar [$r]"
  [ "$hv" = false ] && pass "home (and its dock) out of sight under $app" || fail "home visible=$hv under $app's full screen"
  set -- $(sfrow "$lay"); [ $# -ge 8 ] && [ $(($3 - $1)) -ge $((W - 4)) ] && pass "$app's content at full-screen size ($*)" || fail "$app's content [$*] isn't full screen"
  eval "$5"; sleep 0.5; note "$app 0.5 s after leaving full screen: $(what "$id" "$lay")"; sleep 1.8; chk leave
  step "$app-left-fullscreen" "$app left full screen"
  b2=$(tbounds "$id"); m=$(mode "$id"); note "$app after full screen: $(what "$id" "$lay")"
  [ "$m" = freeform ] && [ "$b2" = "$b0" ] && pass "$app floats again at exactly its bounds before ([$b2])" || fail "$app after full screen: [$b2] mode $m, was [$b0] freeform"
  [ -n "$(wframe "PowOS window bar $id}")" ] && pass "$app's title bar is back" || fail "$app has no title bar after full screen"
}

HOMET=$(tasks | awk '/HomeShell/{print $1; exit}')
logc
case $STAGE in
calc)
  CALC=com.oneplus.calculator
  grep -q " $CALC" <<<"$TASKS0" && { note "Calculator was already open (the user's): the stage skipped"; e2e_finish; exit 0; }
  rec_start calc 70
  r=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$CALC\\//.test(a.key))||{}).key||'none'"); hcall apps.launch "['$r']" "()=>'ok'" >/dev/null
  sleep 2.5; chk calc; CT=$(waitwin $CALC 6)
  step calc "Calculator in a window"
  if [ "$CT" != none ] && [ -n "$CT" ]; then maxcheck "$CT" "$CALC/" calc; else fail "no Calculator window"; fi
  rec_stop calc ;;
kate)
  grep -qx kate <<<"$LIN0" && { note "Kate was already running (the user's): the stage skipped"; e2e_finish; exit 0; }
  rec_start kate 110
  hcall apps.launch "['l:org.kde.kate']" "()=>'ok'" >/dev/null
  KT=$(waitwin l:org.kde.kate 15); chk kate
  step kate "Kate in a window"
  if [ "$KT" != none ] && [ -n "$KT" ]; then
    KL="SurfaceView[com.powos.app/andro.marchy.PowosWindowActivity"
    maxcheck "$KT" "$KL" kate
    set -- $(tbounds "$KT"); tap $((($1 + $3) / 2)) $((($2 + $4) / 2)) "Kate's text (its focus)"; sleep 0.6
    fscheck "$KT" "$KL" kate "sh_ 'input keycombination KEYCODE_CTRL_LEFT KEYCODE_SHIFT_LEFT KEYCODE_F'" "sh_ 'input keycombination KEYCODE_CTRL_LEFT KEYCODE_SHIFT_LEFT KEYCODE_F'"
  else fail "no Kate window"; fi
  rec_stop kate ;;
video)
  CH=com.android.chrome
  grep -q " $CH" <<<"$TASKS0" && { note "Chrome was already open (the user's): the stage skipped"; e2e_finish; exit 0; }
  "$A" push "$here/window-max-video.html" /data/local/tmp/wmax-fs.html >/dev/null 2>&1
  sh_ "mkdir -p /data/powos/root/tmp/wmax; cp /data/local/tmp/wmax-fs.html /data/powos/root/tmp/wmax/fs.html; chmod -R a+rX /data/powos/root/tmp/wmax"
  us "cd /tmp/wmax && setsid -f timeout 240 python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1; sleep 1; echo served"
  rec_start video 80
  r=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$CH\\//.test(a.key))||{}).key||'none'"); hcall apps.launch "['$r']" "()=>'ok'" >/dev/null
  VT=$(waitwin $CH 8); chk chrome
  sh_ "am start -a android.intent.action.VIEW -d http://127.0.0.1:8765/fs.html -p $CH >/dev/null"; sleep 3.5; chk page
  step video "the video page in Chrome's window"
  if [ "$VT" != none ] && [ -n "$VT" ]; then
    set -- $(tbounds "$VT"); CX=$((($1 + $3) / 2)); CY=$((($2 + $4) * 3 / 5))
    fscheck "$VT" "$CH/" video "tap $CX $CY 'the video (asks for full screen)'" "back 0.2"
    back 1.2
  else fail "no Chrome window"; fi
  us "pkill -f 'http.server 8765'; rm -rf /tmp/wmax; true" >/dev/null
  rec_stop video ;;
esac
logc_get
grep -E "maximis|full screen|now a window|PowosFreeform" "$OUT/logcat.txt" | tail -12 | tee -a "$OUT/log.txt"
log "facts: $OUT (dumps, logcat.txt, kwin.txt); recordings: $REC"
e2e_finish
