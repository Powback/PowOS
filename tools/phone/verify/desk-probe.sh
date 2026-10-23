#!/bin/bash
# tools/phone/verify/desk-probe.sh: evidence for E2E round 2's floating-window failures (2026-10-23), run twice - with
# SystemUI's caption overlay (com.android.shell:PowosNoCaption, system/OemCaption.kt) on, then off (the bisect), the
# overlay on again at the end. Per pass, on a Calculator window: the bar drag (where the task, the app's own window
# and PowOS's bar end up), a grip resize, a swipe in the top band of the app's content (does it drag the window?), a
# page swipe beside the window (does home see the touch, does inWindow refuse it, does the page turn) and the close
# button; pass 1 also Dolphin's close button. Steps + screenshots: /home/powos/design-qa/e2e-probe/<round>/.
#   queue.sh add --budget 600 <task> tools/phone/verify/desk-probe.sh [--round R]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
e2e_args "$@"; LAST=2   # one part; LAST != PART: no mail to the manager
E2E_APPS='com.oneplus.calculator|PowosWindowActivity'
E2E_LINUX='dolphin'
e2e_init probe
e2e_setup inner
CALC=com.oneplus.calculator
OVL=com.android.shell:PowosNoCaption
# The overlay on again whatever ends the run (a touch, the budget).
trap 'rc=$?; sh_ "cmd overlay enable $OVL" >/dev/null; (exit $rc); e2e_abort' EXIT

dock_tap() { local p; p=$(pt "$(dockel "$1")"); case $p in none|off|"") fail "no dock cell for $2 ($p)"; return 1 ;; esac
  set -- $p "$2"; tap "$1" "$2" "$3's dock cell"; }
# The app's own window frame (its content), as WM has it: "l t r b".
appframe() { sh_ "dumpsys window windows" | awk '/^ *Window #/{f=(index($0,"com.android.calculator2.Calculator}")>0)} f' | grep -oE ' frame=\[-?[0-9]+,-?[0-9]+\]\[-?[0-9]+,-?[0-9]+\]' | head -1 | tr -c '0-9\n-' ' ' | xargs; }
where() { note "task $(tbounds "$1") | app window $(appframe) | bar $(wframe "PowOS window bar $1}") | grip $(wframe "PowOS window grip $1}") | list $(win $CALC bounds)"; }
# Home's touches, recorded (passive, capture) - what reached the page.
ev "window.__pt||(window.__pt=[],addEventListener('touchstart',e=>__pt.push('s'+Math.round(e.touches[0].clientX*devicePixelRatio)+','+Math.round(e.touches[0].clientY*devicePixelRatio)),{capture:true,passive:true}),addEventListener('touchend',()=>__pt.push('e'),{capture:true,passive:true}),addEventListener('touchcancel',()=>__pt.push('c'),{capture:true,passive:true}));'ok'" >/dev/null
touches() { ev "JSON.stringify((window.__pt||[]).splice(0))"; }
# The windows a finger that is down right now went to (InputDispatcher's touch state): who takes a touch, who pilfered it.
touched() { sh_ "dumpsys input" | sed -n '/TouchStatesByDisplay/,/CursorStatesByDisplay/p' | head -40 | tr -s ' ' | tr '\n' ' ' | cut -c1-1500; }
# A tap as DOWN, the touch state, UP (a tap all the same: no move between).
dtap() { mdown "$1" "$2" "$3" || return 1; log "tap $3 at $1,$2 (down, touch state, up)"; note "touch on $3: $(touched)"; mup "$1" "$2"; }
inwin() { ev "importShim('./ui/desktops.ts').then(m=>String(m.inWindow($1/devicePixelRatio,$2/devicePixelRatio)))"; }
logc() { sh_ "rm -f /data/local/tmp/probe-$1.txt; (timeout 200 logcat -T 1 -v time -s PowosWindowFrames PowosWindowFrame PowosWindowResize PowosFreeform PowosOemCaption WindowTasks PowosTasks com.powos.app:W </dev/null >/data/local/tmp/probe-$1.txt 2>&1 &)"; }
# + SystemUI's warnings and errors (WM Shell's window decoration lives there: a caption 0 dp high may throw).
logc_sys() { ash <<EOF2
rm -f /data/local/tmp/probe-sys-$1.txt; (timeout 200 logcat -T 1 -v time --pid=\$(pidof com.android.systemui) '*:W' </dev/null >/data/local/tmp/probe-sys-$1.txt 2>&1 &)
EOF2
}
pulllog() { sh_ "cat /data/local/tmp/probe-$1.txt" > "$OUT/logcat-$1.txt"; sh_ "cat /data/local/tmp/probe-sys-$1.txt" > "$OUT/logcat-sys-$1.txt"
  log "logcat ($1): $(wc -l < "$OUT/logcat-$1.txt") lines, SystemUI W/E $(wc -l < "$OUT/logcat-sys-$1.txt") -> $OUT/logcat-*$1.txt"
  grep -iE "exception|decor|caption" "$OUT/logcat-sys-$1.txt" | head -8; }

pass_() { # <tag>
  local tag=$1 CT b0 b1 p x y dx=$(dp 120) dy=$(dp 60)
  logc "$tag"; logc_sys "$tag"; touches >/dev/null
  note "[$tag] overlay: $(sh_ "cmd overlay list com.android.systemui" | grep Powos | xargs)"
  dock_tap "a:$CALC/" Calculator || return; sleep 2.5; chk calc; CT=$(waitwin $CALC 6)
  step "$tag-calc" "[$tag] Calculator from the dock"; where "$CT"
  [ "$CT" != none ] || { fail "[$tag] no Calculator window"; return; }
  # A: the bar drag.
  b0=$(tbounds "$CT"); p=$(barpt "$CT")
  if [ -n "$p" ]; then set -- $p; x=$1; y=$2
    mdown $x $y "the bar" && { mpath $x $y $((x + dx)) $((y + dy)) 6; sleep 0.3; mup $((x + dx)) $((y + dy)); sleep 1.5; chk drag
      step "$tag-dragged" "[$tag] dragged by the bar ($dx,$dy)"; where "$CT"; b1=$(tbounds "$CT")
      [ "$b1" != "$b0" ] && pass "[$tag] the bar moved it: $b0 -> $b1" || fail "[$tag] the bar drag didn't move it ($b0)"
      set -- $(tbounds "$CT") $(appframe)
      [ $# -ge 8 ] && [ "$1" = "$5" ] && [ "$2" -le "$6" ] && pass "[$tag] the app's window is in its task ($1 vs $5)" || fail "[$tag] the app's window ($5 $6 $7 $8) is not in its task ($1 $2 $3 $4)"; }
  else fail "[$tag] no bar"; fi
  # B: the grip, towards the side with room.
  local g; g=$(wframe "PowOS window grip $CT}")
  if [ -n "$g" ]; then set -- $g; x=$((($1 + $3) / 2)); y=$((($2 + $4) / 2)); local s=1; { [ $x -gt $((W - $(dp 140))) ] || [ $y -gt $((H - $(dp 200))) ]; } && s=-1   # inwards near an edge
    b0=$(tbounds "$CT"); mdown $x $y "the grip" && { note "[$tag] touch on the grip: $(touched)"; mpath $x $y $((x + s * $(dp 100))) $((y + s * $(dp 60))) 6; sleep 0.8
      step "$tag-resizing" "[$tag] the grip, finger down"; where "$CT"
      mup $((x + s * $(dp 100))) $((y + s * $(dp 60))); sleep 1.5; chk grip
      step "$tag-resized" "[$tag] the grip let go"; where "$CT"; b1=$(tbounds "$CT")
      [ "$b1" != "$b0" ] && pass "[$tag] the grip resized it: $b0 -> $b1" || fail "[$tag] the grip didn't resize it ($b0)"
      set -- $(tbounds "$CT") $(appframe)
      [ $# -ge 8 ] && [ "$1" = "$5" ] && pass "[$tag] after the resize the app's window is in its task" || fail "[$tag] after the resize the app's window ($5 $6 $7 $8) is not in its task ($1 $2 $3 $4)"; }
  else fail "[$tag] no grip"; fi
  # C: a swipe in the top band of the app's content (where SystemUI's caption was).
  set -- $(tbounds "$CT"); b0="$*"; x=$((($1 + $3) / 2)); y=$(($2 + $(dp 40))); local to=$((x - $(dp 120)))
  mdown $x $y "the app's top band" && { note "[$tag] touch in the band: $(touched)"; mpath $x $y $to $y 6; mup $to $y; sleep 1.5; chk band
    step "$tag-band" "[$tag] a sideways swipe in the app's top band (y = top + 40 dp)"; where "$CT"; b1=$(tbounds "$CT")
    [ "$b1" = "$b0" ] && pass "[$tag] the window stayed put" || fail "[$tag] a swipe INSIDE the app moved the window: $b0 -> $b1"; }
  # D: a page swipe beside it, as long as fits.
  local pg0 d; pg0=$(hpage); set -- $(tbounds "$CT"); if [ $1 -gt $((W - $3)) ]; then d=-1; else d=1; fi
  p=$(freept "$(tbounds "$CT")" $d $((W * 35 / 100)))
  if [ "$p" != none ] && [ -n "$p" ]; then set -- $p; x=$1; y=$2; to=$((x + d * W * 35 / 100)); [ $to -lt 20 ] && to=20; [ $to -gt $((W - 20)) ] && to=$((W - 20))
    note "[$tag] inWindow($x,$y)=$(inwin $x $y), list $(hcall windows.list "[]" "l=>JSON.stringify(l.map(w=>[w.id,w.minimised,w.away,w.bounds]))")"
    touches >/dev/null; swipe $x $y $to $y 250 "beside the window" && { sleep 1.5; chk page
      step "$tag-page" "[$tag] a swipe beside the window ($x -> $to)"; note "[$tag] home's touches: $(touches)"
      [ "$(hpage)" != "$pg0" ] && pass "[$tag] the page turned ($pg0 -> $(hpage))" || fail "[$tag] the page stayed $pg0 ($((to - x)) px swipe)"
      [ "$(hpage)" != "$pg0" ] && { hemit system.home null; sleep 1; } ; }
  else fail "[$tag] no spot beside the window"; fi
  # E: the close button.
  p=$(closebtn "$CT"); if [ -n "$p" ]; then set -- $p; dtap $1 $2 "Calculator's close button"; sleep 2; chk close
    step "$tag-closed" "[$tag] Calculator's close button"
    [ -z "$(tasks | grep "^$CT ")" ] && pass "[$tag] closed" || fail "[$tag] task $CT still there after its close button"
  else fail "[$tag] no close button"; fi
  pulllog "$tag"
}

pass_ on
# Dolphin's close button (a Linux window), once.
logc dolphin; logc_sys dolphin
dock_tap l:org.kde.dolphin Dolphin && { DT=$(waitwin l:org.kde.dolphin 30); chk dolphin; sleep 2
  step dolphin "Dolphin from the dock"; note "dolphin task $DT $(tbounds "$DT") bar $(wframe "PowOS window bar $DT}")"
  p=$(closebtn "$DT"); [ -n "$p" ] && { set -- $p; dtap $1 $2 "Dolphin's close button"; sleep 3; chk dclose
    step dolphin-closed "Dolphin's close button"
    [ -z "$(tasks | grep "^$DT ")" ] && pass "Dolphin closed" || fail "Dolphin's task $DT still there"
    note "dolphin process: $(us 'pgrep -x dolphin || echo none' | xargs)"; }; }
pulllog dolphin

sh_ "cmd overlay disable $OVL"; sleep 3
pass_ off
sh_ "cmd overlay enable $OVL"; sleep 2
note "overlay at the end: $(sh_ "cmd overlay list com.android.systemui" | grep Powos | xargs)"
e2e_finish
