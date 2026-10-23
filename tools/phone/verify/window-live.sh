#!/bin/bash
# tools/phone/verify/window-live.sh: does a floating window's CONTENT follow the finger, live (system/TaskLeash.kt)?
# Samples where SurfaceFlinger draws the app (the HWC layer table's Disp Frame of Calculator's window - what is on
# the glass, not WM's idea of it) while an injected finger is still down:
#   move:   bar dragged (dx,dy) and held: mid-drag the content is within TOL px of (start + finger), not at the start;
#           after the lift it stays there (no jump back), the task's bounds agree.
#   resize: grip dragged and held: mid-drag the content is wider than before, within 15% of the finger's width.
#   page (--page): a page swipe held halfway beside the window: the content moved sideways with the page.
# Logcat PowosTaskLeash (start latency, frames, how it ended) goes into the log. Steps + shots on the phone as e2e.
#   queue.sh add --close <task> tools/phone/verify/window-live.sh [--page] [--round R]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
PAGE_STAGE=0; ARGS=()
for a in "$@"; do [ "$a" = --page ] && PAGE_STAGE=1 || ARGS+=("$a"); done
. "$here/e2e-lib.sh"
e2e_args ${ARGS[@]+"${ARGS[@]}"}; LAST=2
E2E_APPS='com.oneplus.calculator'
e2e_init live
e2e_setup inner
CALC=com.oneplus.calculator
TOL=${TOL:-40}

# sfframe <layer name part>: "l t r b" where SurfaceFlinger composes it on the ON display (HWC layers, Disp Frame).
sfframe() { sh_ "dumpsys SurfaceFlinger" | awk -v p="$1" '
  /\(active\) HWC layers:/ {on=1; next} /HWC layers:/ {on=0}
  on && want {n=split($0, f, "|"); if (n >= 6) {print f[6]; exit} }
  on && index($0, p) {want=1}' | xargs; }
content() { sfframe "$CALC/"; }
logc() { sh_ "rm -f /data/local/tmp/live.txt; (timeout 250 logcat -T 1 -v time -s PowosTaskLeash PowosWindowDrag PowosWindowResize PowosFreeform RemoteTransitionHandler </dev/null >/data/local/tmp/live.txt 2>&1 &)"; }
near() { local d=$(($1 - $2)); [ ${d#-} -le "$3" ]; }

logc
tap_dock() { local p; p=$(pt "$(dockel "a:$CALC/")"); case $p in none|off|"") return 1 ;; esac; set -- $p; tap "$1" "$2" "Calculator's dock cell"; }
tap_dock || { r=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$CALC\\//.test(a.key))||{}).key||'none'"); hcall apps.launch "['$r']" "()=>'ok'" >/dev/null; }
sleep 2.5; chk calc; CT=$(waitwin $CALC 6)
step calc "Calculator in a window"
[ "$CT" != none ] && [ -n "$CT" ] || { fail "no Calculator window"; e2e_finish; exit 0; }
C0=$(content); note "task $CT $(tbounds "$CT"), content $C0"
[ -n "$C0" ] || { fail "can't read Calculator's layer from SurfaceFlinger (HWC table)"; e2e_finish; exit 0; }

# Move: the bar, held still mid-way.
p=$(barpt "$CT"); if [ -n "$p" ]; then set -- $p; x=$1; y=$2; dx=$(dp 140); dy=$(dp 70)
  [ $((x + dx)) -gt $((W - $(dp 60))) ] && dx=$((-dx)); set -- $C0; L0=$1; T0=$2
  mdown $x $y "the bar" && { mpath $x $y $((x + dx)) $((y + dy)) 8; sleep 0.5
    M=$(content); step move-mid "bar held after ($dx,$dy)"; note "content mid-drag $M (was $C0)"
    set -- $M; if [ $# -ge 4 ]; then
      near "$1" $((L0 + dx)) $TOL && near "$2" $((T0 + dy)) $TOL && pass "mid-drag the content is with the finger: $1,$2 (want $((L0 + dx)),$((T0 + dy)))" ||
        fail "mid-drag the content is at $1,$2 - not with the finger ($((L0 + dx)),$((T0 + dy))); started at $L0,$T0"
    else fail "no content layer mid-drag ($M)"; fi
    mup $((x + dx)) $((y + dy)); sleep 1.2; chk move
    E=$(content); step move-end "bar let go"; note "content after $E, task $(tbounds "$CT")"
    set -- $E; [ $# -ge 4 ] && near "$1" $((L0 + dx)) $TOL && near "$2" $((T0 + dy)) $TOL && pass "after the lift the content stays: $1,$2" || fail "after the lift the content is at ${E:-none} (want $((L0 + dx)),$((T0 + dy)))"
    set -- $(tbounds "$CT") $E; [ $# -ge 8 ] && near "$1" "$5" $TOL && pass "task bounds and content agree ($1 vs $5)" || fail "task bounds ($1 $2 $3 $4) and content ($5 $6 $7 $8) differ"; }
else fail "no bar"; fi

# Resize: the grip, held still mid-way, inwards near an edge.
g=$(wframe "PowOS window grip $CT}"); if [ -n "$g" ]; then set -- $g; x=$((($1 + $3) / 2)); y=$((($2 + $4) / 2)); s=1
  { [ $x -gt $((W - $(dp 160))) ] || [ $y -gt $((H - $(dp 220))) ]; } && s=-1
  C1=$(content); set -- $C1; W0=$(($3 - $1)); dx=$((s * $(dp 120))); dy=$((s * $(dp 80)))
  mdown $x $y "the grip" && { mpath $x $y $((x + dx)) $((y + dy)) 8; sleep 0.9
    M=$(content); step resize-mid "grip held after ($dx,$dy)"; note "content mid-resize $M (was $C1)"
    set -- $M; WM=$(( ${3:-0} - ${1:-0} )); want=$((W0 + dx))
    [ $(( (WM - W0) * s )) -gt 0 ] && near $WM $want $((want * 15 / 100)) && pass "mid-resize the content is $WM px wide (was $W0, finger $want)" ||
      fail "mid-resize the content is $WM px wide (was $W0, finger wants $want)"
    mup $((x + dx)) $((y + dy)); sleep 1.5; chk resize
    E=$(content); step resize-end "grip let go"; note "content after $E, task $(tbounds "$CT")"
    set -- $E; WE=$(( ${3:-0} - ${1:-0} )); near $WE $want $((want * 10 / 100)) && pass "after the lift the content is $WE px wide" || fail "after the lift the content is $WE px wide (want $want)"; }
else fail "no grip"; fi

# Page: a swipe held halfway beside the window; the content goes with the page.
if [ $PAGE_STAGE = 1 ]; then
  set -- $(tbounds "$CT"); if [ $1 -gt $((W - $3)) ]; then d=-1; else d=1; fi
  p=$(freept "$(tbounds "$CT")" $d $((W * 35 / 100)))
  if [ "$p" != none ] && [ -n "$p" ]; then set -- $p; x=$1; y=$2; dx=$((d * W * 20 / 100)); C2=$(content); set -- $C2; L2=$1
    mdown $x $y "beside the window" && { mpath $x $y $((x + dx)) $y 8; sleep 0.5
      M=$(content); step page-mid "page swipe held at $dx px"; note "content mid-swipe $M (was $C2)"
      set -- $M; [ $# -ge 4 ] && near "$1" $((L2 + dx)) $((TOL * 2)) && pass "mid-swipe the window moved with the page: $1 (want $((L2 + dx)))" || fail "mid-swipe the window is at ${1:-none} (page wants $((L2 + dx)), was $L2)"
      mup $x $y; sleep 1.2; chk page; step page-end "let go where it began: the page stays"; }
  else fail "no spot beside the window for a page swipe"; fi
fi

sh_ "cat /data/local/tmp/live.txt" > "$OUT/logcat.txt"
log "logcat: $(wc -l < "$OUT/logcat.txt") lines -> $OUT/logcat.txt"; grep -E "PowosTaskLeash|Found filter" "$OUT/logcat.txt" | tail -12 | tee -a "$OUT/log.txt"
e2e_finish
