#!/bin/bash
# lanes: emu phone
# shade-panel.sh [OUT] (Mac side; board "shade over-pull moves the whole panel"): the shade's PANEL follows the finger,
# not only what's in it, and the blur covers it. A held finger (motionevents) opens the shade from the status bar,
# pulls further on the control center, folds it back up and pushes the shade shut, while a screen recording runs.
# Held at each step, over CDP: the panel's bottom edge (its frost, the grip) is where the gesture is - partway open it
# is short of the open edge, over-pulled it moved with the notifications (no empty slab under them), partway shut it's
# higher again - and from SurfaceFlinger: the shade window's blur region covers the panel (open and grown). The clip's
# frames go to OUT (frame-*.png; the board task's --image when BOARD_TASK is set). Changes no setting; Back + Home after.
# Exit 1 + "FAIL:" on a miss, 3 on a real touch (restored) or no window.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/shade-panel-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "pkill -INT screenrecord; input keyevent 4; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; }
. "$here/window-lock.sh"; window_lock shade-panel 120 "${MAX_WAIT:-10800}"
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq); FAILS=0
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; "$A" shell input motionevent CANCEL 1 1 >/dev/null 2>&1; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
q() { "$T/cdp.sh" eval shade "$1" 2>/dev/null | tail -1 | tr -d '"\\\r'; }
# The panel (device px): its edge (bottom), grip bottom, top, left, right; what's last in it; --q; v3 shown whole.
P='(()=>{const d=devicePixelRatio,p=document.querySelector(".notif-panel"),r=p.getBoundingClientRect(),g=p.querySelector(".notif-grip")?.getBoundingClientRect();const l=[...document.querySelectorAll(".panel-body.together .notif-items > *")].map(e=>e.getBoundingClientRect().bottom);return [r.bottom,g?g.bottom:0,Math.max(0,r.top),r.left,r.right,l.length?Math.max(...l):0].map(v=>Math.round(v*d)).join(" ")+" "+getComputedStyle(p).getPropertyValue("--q").trim()+" "+!!document.querySelector(".cc3-list.whole")})()'
# The shade window's blur regions from SurfaceFlinger: "radius l t r b" of the largest, or nothing.
blur() { sh_ "dumpsys SurfaceFlinger" | awk '/^  Layer \[/{on=/PowOS shade/} on&&/radius=.*rect=\[/{gsub(/[^0-9 ,.]/," ");print}' |
  awk '{n=split($0,a,/[ ,]+/); k=0; for(i=1;i<=n;i++) if(a[i]!="") v[++k]=a[i]; print v[1], v[k-3], v[k-2], v[k-1], v[k]}' | sort -k5 -n | tail -1; }
covers() { # $1 what, $2 panel line, $3 blur line: the region over the panel's whole rect
  set -- "$1" $2 X $3
  local e=$2 top=$4 l=$5 r=$6 rad=${11:-0} bl=${12:-0} bt=${13:-0} br=${14:-0} bb=${15:-0}
  [ "${rad%%.*}" -gt 0 ] 2>/dev/null || { fail "$1: no blur under the shade (regions: ${*:11})"; return; }
  [ "$bt" -le "$top" ] && [ "$bb" -ge "$((e - 2))" ] && [ "$bl" -le "$((l + 2))" ] && [ "$br" -ge "$((r - 2))" ] &&
    log "$1: blur radius ${rad} over [$bl $bt $br $bb], the panel [$l $top $r $e]" ||
    fail "$1: the blur [$bl $bt $br $bb] doesn't cover the panel [$l $top $r $e]"
}
f() { echo "$1" | awk -v i="$2" '{print $i}'; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
sh_ "cmd statusbar collapse; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
[ "$(q 'fetch(new URL("./ui/ccexpand.ts", location.href)).then(r=>r.text()).then(t=>t.includes("--cc-lift"))')" = true ] ||
  { echo "the panel-follows-the-finger shell isn't live on the phone yet - back on the queue"; exit 3; }
did=$(sh_ "dumpsys display" | sed -nE 's/.*DisplayDeviceInfo.*uniqueId="local:([0-9]+)", ([0-9]+) x ([0-9]+),.* state ON,.*/\1 \2 \3/p' | head -1)
set -- $did; [ $# -ge 3 ] || { echo "no display on"; exit 3; }; DID=$1; W=$2; H=$3
S=$((H / 100)); X=$((W * 8 / 10))
# Phone-side moves for steps FROM..TO of S px each from (X, Y0), down (+1) or up (-1).
steps() { local i; for i in $(seq "$1" "$2"); do echo "input motionevent MOVE $3 $(($4 + $5 * i * S)); sleep 0.03;"; done; }

sh_ "screenrecord --display-id $DID --bit-rate 20000000 --time-limit 40 /data/local/tmp/shade-panel.mp4 >/dev/null 2>&1 &"
sleep 1.2
# 1. Open: a finger down on the status bar, held partway (the edge short of open), then on down and let go.
"$A" shell "input motionevent DOWN $X 8; $(steps 1 3 $X 8 1)" >/dev/null; sleep 0.5; chk open1
p1=$(q "$P"); log "open, 3% down: $p1"
"$A" shell "$(steps 4 6 $X 8 1)" >/dev/null; sleep 0.5; chk open2
p2=$(q "$P"); log "open, 6% down: $p2"
"$A" shell "$(steps 7 40 $X 8 1) input motionevent UP $X $((8 + 40 * S))" >/dev/null; sleep 1.5; chk open
po=$(q "$P"); bo=$(blur); log "open: $po | blur: $bo"
E=$(f "$po" 1)
[ -n "$E" ] && [ "$E" -gt 0 ] 2>/dev/null || { fail "the shade didn't open ($po)"; exit 1; }
for p in "$p1" "$p2"; do
  e=$(f "$p" 1); g=$(f "$p" 2); qq=$(f "$p" 7)
  awk -v q="$qq" 'BEGIN{exit !(q > 0.02 && q < 0.98)}' || { log "(partway probe at q=$qq: not partway, skipped)"; continue; }
  [ "$e" -lt "$((E - (E / 5)))" ] || fail "partway open (q $qq) the panel's edge is at $e of $E: a static slab"
  [ $((e - g)) -ge 0 ] && [ $((e - g)) -le $((E - $(f "$po" 2) + 4)) ] || fail "partway open the grip ($g) isn't at the edge ($e)"
done
[ "$(f "$p1" 1)" -le "$(f "$p2" 1)" ] 2>/dev/null || fail "opening, the edge went up as the finger went down: $(f "$p1" 1) -> $(f "$p2" 1)"
covers "open" "$po" "$bo"

# 2. Over-pull on the control center: held, the edge moved with the notifications; let go, shown whole, still covered.
# Where shade-overpull.sh starts it (the middle, 45% down): never on a slider or a toggle.
Y=$((H * 45 / 100))
"$A" shell "input motionevent DOWN $((W / 2)) $Y; $(steps 1 4 $((W / 2)) $Y 1)" >/dev/null; sleep 0.5; chk over
ph=$(q "$P"); log "over-pull held: $ph"
de=$(( $(f "$ph" 1) - E )); gap0=$(( E - $(f "$po" 6) )); gap1=$(( $(f "$ph" 1) - $(f "$ph" 6) ))
[ "$de" -ge "$((S * 2))" ] || fail "over-pulled $((4 * S)) px, the panel's edge moved only $de px"
[ "$gap1" -le "$((gap0 + 12))" ] || fail "over-pulled, $gap1 px of empty panel under the notifications (open: $gap0)"
"$A" shell "$(steps 5 14 $((W / 2)) $Y 1) input motionevent UP $((W / 2)) $((Y + 14 * S))" >/dev/null; sleep 1.5; chk over2
pw=$(q "$P"); bw=$(blur); log "shown whole: $pw | blur: $bw"
[ "$(f "$pw" 8)" = true ] || fail "let go past the threshold, the rest isn't shown"
covers "shown whole" "$pw" "$bw"

# 3. Fold it back (up at the list's end), then push the shade shut: held partway, the edge higher than open.
# A list taller than the panel scrolls to its end first: up to three pulls up until it folds.
for _ in 1 2 3; do
  EW=$(f "$(q "$P")" 1); YU=$((EW - 6 * S))
  "$A" shell "input motionevent DOWN $((W / 2)) $YU; $(steps 1 12 $((W / 2)) $YU -1) input motionevent UP $((W / 2)) $((YU - 12 * S))" >/dev/null
  sleep 1.5; chk fold
  pf=$(q "$P"); [ "$(f "$pf" 8)" = false ] && break
done
log "folded: $pf"
[ "$(f "$pf" 8)" = false ] || fail "pulled up at the list's end three times, the rest is still shown"
EF=$(f "$pf" 1); YC=$((EF - 6 * S))
"$A" shell "input motionevent DOWN $((W / 2)) $YC; $(steps 1 3 $((W / 2)) $YC -1)" >/dev/null; sleep 0.5; chk close1
pc=$(q "$P"); bc=$(blur); log "closing, held: $pc | blur: $bc"
"$A" shell "$(steps 4 20 $((W / 2)) $YC -1) input motionevent UP $((W / 2)) $((YC - 20 * S))" >/dev/null; sleep 1.5; chk close
pz=$(q "$P"); log "closed: $pz"
qc=$(f "$pc" 7)
if awk -v q="$qc" 'BEGIN{exit !(q > 0.02 && q < 0.98)}'; then
  [ "$(f "$pc" 1)" -lt "$((EF - EF / 10))" ] || fail "partway shut (q $qc) the panel's edge stayed at $(f "$pc" 1) of $EF"
  [ -n "$bc" ] || fail "partway shut the blur is already gone while the panel shows"
else log "(closing probe at q=$qc: not partway)"; fi
awk -v q="$(f "$pz" 7)" 'BEGIN{exit !(q < 0.05)}' || fail "pushed up, the shade didn't shut ($pz)"

sleep 1; sh_ "pkill -INT screenrecord"; sleep 1.5
"$A" pull /data/local/tmp/shade-panel.mp4 "$OUT/clip.mp4" >/dev/null 2>&1; sh_ "rm -f /data/local/tmp/shade-panel.mp4"
if [ -s "$OUT/clip.mp4" ]; then
  ffmpeg -loglevel error -y -i "$OUT/clip.mp4" -vf "fps=12,scale=540:-2" "$OUT/frame-%03d.png"
  n=$(ls "$OUT"/frame-*.png 2>/dev/null | wc -l | tr -d ' '); log "frames: $n in $OUT"
  if [ -n "${BOARD_TASK:-}" ] && [ "$n" -gt 0 ]; then
    imgs=(); for fr in $(ls "$OUT"/frame-*.png | awk -v n="$n" 'NR % int(n / 10 + 1) == 0'); do imgs+=(--image "$fr"); done
    "$T/../../lib/ai/agents/powos-agents-cli" task set "$BOARD_TASK" "${imgs[@]}" >/dev/null 2>&1 || true
  fi
else fail "no recording pulled"; fi

restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
echo "artefacts: $OUT"
[ "$FAILS" = 0 ] && echo "PASS: the panel's edge followed the finger opening, over-pulled and shutting; the blur covered it open and grown" ||
  { echo "FAIL: $FAILS step(s)"; exit 1; }
