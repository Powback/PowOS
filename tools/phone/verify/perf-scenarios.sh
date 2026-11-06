#!/bin/bash
# tools/phone/verify/perf-scenarios.sh: the perf task's own three interactions measured on the phone with the shell's
# recorder (fpsmeter.tsx: the status bar's meter, one recording per scenario) - home's page swipes, the launcher
# (drawer) opened and shut, the shade pulled down and pushed away. Each scenario: the meter clicked over CDP (no touch:
# a DOM click on the bar's own page), the gesture N times by injected input (e2e-lib.sh: aborts when the user touches
# the phone), the meter clicked again, the new perf-*.json pulled to $OUT/<scenario>.json and its summary printed
# (fps p50/p5, frames over 33 ms, long tasks, native stalls, top renders). Runs only after the user has left the phone
# for PERF_IDLE_S (default 600 s). Each recording is marked a check's (window.__perfSource = "verify" with the start
# click): saved as always, but filed as no PowOS AI ask and no coordinator mail (f428; a user's own tap still files both).
# shade-scroll (S8'): the shade opened by the bridge's shade.open, its notification list (.notif-list) scrolled down
# and up REPS times, the shade put away by shade_shut. The meter's fps is home's frames (the shade is its own page, the
# meter takes only its renders), so the shade page's own rAF deltas are recorded beside it and gated: FAIL when their
# fps p5 < 55 or any frame > 33 ms, or when the list didn't scroll (too few notifications to measure).
#   perf-scenarios.sh [--round R] [--only swipe|launcher|shade|shade-scroll] [--reps N]
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
# The user's finger away >= PERF_IDLE_S (600) by the touch panels' IRQs (idle.sh); e2e's own gate (dumpsys power's
# activity, moved by app wakes too) keeps its usual 120 s - asking 600 of it skipped a free window (act 461, idle 629).
PERF_IDLE_S=${PERF_IDLE_S:-600}
s=$("$T/idle.sh"); i=${s#idle=}; i=${i%% *}
[ "${i:-0}" -ge "$PERF_IDLE_S" ] || { echo "SKIP: user touched the phone ${i:-?} s ago (need $PERF_IDLE_S): $s"; exit 3; }
ONLY=; REPS=3; ARGS=()
while [ $# -gt 0 ]; do case "$1" in --only) ONLY=$2; shift 2 ;; --reps) REPS=$2; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
e2e_args "${ARGS[@]}"
e2e_init perf-scenarios
PDIRF=/data/data/com.powos.app/files/run/powos-ai-shared
newest() { sh_ "ls -t $PDIRF 2>/dev/null | grep -m1 '^perf-'"; }
METER0=
meter_back() { [ -n "$METER0" ] && ev "importShim('./bridge.ts').then(b=>b.powos.store.set('perf.meter',$METER0)).then(()=>'ok')" >/dev/null; METER0=; }
e2e_setup
METER0=$(ev 'importShim("./bridge.ts").then(b=>b.powos.store.get("perf.meter")).then(v=>JSON.stringify(v??null))')
case $METER0 in null|\{*) ;; *) METER0= ;; esac
log "perf.meter at start: ${METER0:-unreadable}"

# rec_on / rec_off <scenario>: the meter's record button, clicked on the status bar's page.
rec_on() { BEFORE=$(newest); ev "(window.__perfSource='verify',document.querySelector('.fps-meter').click(),'ok')" statusbar >/dev/null; sleep 0.8; }
rec_off() {
  ev "(document.querySelector('.fps-meter').click(),'ok')" statusbar >/dev/null
  local f= i; for i in $(seq 1 20); do sleep 1; f=$(newest); [ -n "$f" ] && [ "$f" != "$BEFORE" ] && break; f=; done
  [ -n "$f" ] || { fail "$1: no new perf trace after the stop"; return 1; }
  sh_ "cat $PDIRF/$f" > "$OUT/$1.json"
  log "$1: $f -> $OUT/$1.json"
  python3 "$here/perf-summary.py" "$1" "$OUT/$1.json" | tee -a "$OUT/log.txt"
}

sc_swipe() {
  local p d=$((W * 45 / 100)) i; p=$(freept "" -1 "$d" .3); [ "$p" != none ] && [ -n "$p" ] || { fail "swipe: no empty spot on home"; return 1; }
  set -- $p; local x=$1 y=$2
  rec_on
  for i in $(seq 1 "$REPS"); do
    chk swipe$i; swipe "$x" "$y" $((x - d)) "$y" 220 "page swipe to the next page" || break; sleep 1.2
    chk swipe$i-back; swipe $((x - d)) "$y" "$x" "$y" 220 "page swipe back" || break; sleep 1.2
  done
  rec_off swipe
  step swipe "page swipes done ($REPS pairs)"; pass "recorded"
}
sc_launcher() {
  local i p; rec_on
  for i in $(seq 1 "$REPS"); do
    chk launcher$i; p=$(freept "" 0 0 .54); [ "$p" != none ] && [ -n "$p" ] || { fail "launcher: no empty spot"; break; }
    set -- $p; swipe "$1" "$2" "$1" $(($2 - H * 30 / 100)) 250 "up from empty space (the drawer)" || break; sleep 1.5
    [ "$(isopen)" = true ] || note "rep $i: the drawer didn't open"
    back 1.5
  done
  rec_off launcher
  step launcher "launcher opened and shut ($REPS times)"; pass "recorded"
}
sc_shade() {
  local i S=$((H / 100)) X=$((W * 8 / 10)); rec_on
  for i in $(seq 1 "$REPS"); do
    chk shade$i; mdown $X 8 "the status bar (the shade)" || break
    mpath $X 8 $X $((8 + 40 * S)) 14; mup $X $((8 + 40 * S)); sleep 1.5
    back 1.5
  done
  rec_off shade
  step shade "shade pulled down and closed ($REPS times)"; pass "recorded"
}
# The shade page's frames: rAF deltas and the list's scroll range, from ss_on to ss_off (a JSON line).
SS_ON='(()=>{const l=document.querySelector(".notif-list");const r=window.__ssRec={dt:[],last:0,on:true,lo:l?l.scrollTop:-1,hi:l?l.scrollTop:-1};const f=t=>{if(!r.on)return;if(r.last)r.dt.push(Math.round((t-r.last)*10)/10);r.last=t;requestAnimationFrame(f)};requestAnimationFrame(f);if(l)l.addEventListener("scroll",()=>{r.lo=Math.min(r.lo,l.scrollTop);r.hi=Math.max(r.hi,l.scrollTop)},{passive:true});return "ok"})()'
SS_OFF='(()=>{const r=window.__ssRec;if(!r)return "{}";r.on=false;return JSON.stringify({dt:r.dt,lo:r.lo,hi:r.hi})})()'
# The check's own test notifications (the phone's own shade often has too few to scroll), SILENT: the queue runs in
# idle windows, often at night - no sound, no vibration, no banner. `cmd notification post` can't do that (the shell's
# channel is IMPORTANCE_DEFAULT and it has no importance flag), so they go in as PowOS's own Plasma mirror would post
# a low-urgency Linux notification: a {"op":"notify","urgency":0} file in the app's run/plasma/out (PlasmaBridge.kt's
# FileObserver) -> its "plasma-quiet-v1" channel, IMPORTANCE_LOW (listed in the shade, never peeks or sounds; PowOS's
# own banner needs HIGH). Plasma itself isn't involved. Read first: that channel at importance 1..2, else a SKIP
# (nothing posted). SS_N of them, two per made-up Linux app ("PowOS check A".."), so each app is its own row with two
# cards; ids SS_ID0+i (far above Plasma's own counter, never a real one's). Removed again at the end - also on an
# abort (the EXIT trap) - by {"op":"close"} files (PlasmaBridge cancels its own tag+id); only keys "|plasma|<our id>|"
# are ever touched, the user's notifications never.
SS_N=${SS_N:-14}
SS_ID0=2000000000
SS_RUN=/data/data/com.powos.app/files/run/plasma/out
SS_KEYS="l=>JSON.stringify((l&&l.items||[]).map(n=>n.key).filter(k=>{const p=k.split('|');return p[1]==='com.powos.app'&&p[3]==='plasma'&&+p[2]>$SS_ID0&&+p[2]<=$SS_ID0+$SS_N}))"
ss_mine() { hcall notifications.list "[]" "$SS_KEYS"; }
# ss_files <op>: one root script writing an op file per test id, as the session's bridge does (.name, renamed in).
ss_files() {
  local i c=$((SS_N / 2 + SS_N % 2)) L=ABCDEFGHIJKLMNOPQRSTUVWXYZ
  { echo "set -e; d=$SS_RUN; [ -d \$d ]"
    for i in $(seq 1 "$SS_N"); do
      local id=$((SS_ID0 + i)) f="ss-$(date +%s)-$i.json" j=$(( (i - 1) % c ))
      if [ "$1" = notify ]; then
        printf 'printf %%s %q > $d/.%s\n' "{\"op\":\"notify\",\"id\":$id,\"app\":\"PowOS check ${L:$j:1}\",\"title\":\"shade-scroll test $i of $SS_N\",\"text\":\"posted by the scroll check, removed after it\",\"urgency\":0,\"time\":$(date +%s)}" "$f"
      else
        printf 'printf %%s %q > $d/.%s\n' "{\"op\":\"close\",\"id\":$id}" "$f"
      fi
      printf 'chmod 644 $d/.%s; mv $d/.%s $d/%s\n' "$f" "$f" "$f"
    done
    echo "echo wrote"; } | ash
}
ss_seed() {
  local i n imp
  imp=$(sh_ "dumpsys notification" | grep -m1 "mId=.plasma-quiet-v1" | grep -oE "mImportance=-?[0-9]+" | cut -d= -f2)
  case ${imp:-x} in 1|2) ;; *) e2e_skip "shade-scroll: no silent channel for test notifications (plasma-quiet-v1 importance '${imp:-missing}', want 1..2) - nothing posted" ;; esac
  trap 'rc=$?; ss_unseed; (exit $rc); e2e_abort' EXIT
  [ "$(ss_files notify)" = wrote ] || { fail "shade-scroll: couldn't write the test notifications to $SS_RUN"; return 1; }
  for i in $(seq 1 10); do sleep 1; n=$(ss_mine | python3 -c 'import json,sys
try: print(len(json.loads(sys.stdin.read())))
except Exception: print(0)'); [ "$n" -ge "$SS_N" ] && break; done
  log "shade-scroll: posted $SS_N silent test notifications (plasma-quiet-v1, importance $imp), $n in the shade's list"
}
ss_unseed() {
  local left i
  for i in 1 2 3; do
    [ "$(ss_mine)" = "[]" ] && break
    ss_files close >/dev/null; sleep 1.5
  done
  left=$(ss_mine)
  [ "$left" = "[]" ] && log "shade-scroll: test notifications removed" || note "shade-scroll: test notifications still listed after the clean-up: $left"
  trap 'e2e_abort' EXIT
}
sc_shade_scroll() {
  ss_seed
  sc_shade_scroll_run; local rc=$?
  ss_unseed
  return $rc
}
sc_shade_scroll_run() {
  local i o ox=0 oy=0 g x t b
  hcall shade.open "[]" "()=>'ok'" >/dev/null; sleep 1.5
  [ "$(shadeup)" = up ] || { fail "shade-scroll: the shade didn't open (shade.open)"; return 1; }
  o=$(wframe "PowOS shade"); [ -n "$o" ] && { set -- $o; ox=$1; oy=$2; }
  g=$(ev "(()=>{const l=document.querySelector('.notif-list');if(!l)return 'none';const r=l.getBoundingClientRect(),d=devicePixelRatio;return [Math.round((r.x+r.width/2)*d+$ox),Math.round((r.y+r.height*.3)*d+$oy),Math.round((r.y+r.height*.7)*d+$oy),l.scrollHeight-l.clientHeight,l.children.length].join(' ')})()" shade)
  log "shade-scroll: list (x y30 y70 scrollable-px rows) $g"
  set -- $g; [ $# -ge 5 ] || { fail "shade-scroll: no notification list in the shade ($g)"; shade_shut "shade-scroll"; return 1; }
  x=$1 t=$2 b=$3
  [ "$4" -gt 0 ] 2>/dev/null || { fail "shade-scroll: the notification list can't scroll ($4 px over, $5 rows) - too few notifications to measure"; shade_shut "shade-scroll"; return 1; }
  rec_on; ev "$SS_ON" shade >/dev/null
  for i in $(seq 1 "$REPS"); do
    # Bottom-aligned: it opens at its foot, so the finger goes down first (older ones), then up again.
    chk shadescroll$i; swipe "$x" "$t" "$x" "$b" 300 "the notification list scrolled (finger down)" || break; sleep 1
    chk shadescroll$i-back; swipe "$x" "$b" "$x" "$t" 300 "the notification list scrolled back (finger up)" || break; sleep 1
  done
  ev "$SS_OFF" shade > "$OUT/shade-scroll-raf.json"
  rec_off shade-scroll
  shade_shut "shade-scroll"
  step shade-scroll "notification list scrolled down and up ($REPS times)"
  local r; r=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1])); dt=[x for x in d.get("dt",[]) if x>0]
if len(dt)<10: print("BAD only %d shade frames recorded" % len(dt)); sys.exit()
fps=sorted(1000/x for x in dt); p5=fps[int(len(fps)*.05)]; p50=fps[len(fps)//2]; mx=max(dt); n=sum(1 for x in dt if x>33)
ok=p5>=55 and n==0 and d.get("hi",0)>d.get("lo",0)
print("%s shade page: %d frames, fps p50 %.1f p5 %.1f, longest %.1f ms, %d over 33 ms, list scrolled %s..%s px" % ("OK" if ok else "BAD",len(dt),p50,p5,mx,n,d.get("lo"),d.get("hi")))' "$OUT/shade-scroll-raf.json")
  log "$r"
  case $r in OK*) pass "${r#OK }" ;; *) fail "${r#BAD } (want p5 >= 55 fps, no frame > 33 ms, the list scrolled)" ;; esac
}
for s in swipe launcher shade shade-scroll; do
  [ -z "$ONLY" ] || [ "$ONLY" = $s ] || continue
  "sc_${s//-/_}"; hemit system.home null
done
meter_back
e2e_finish
