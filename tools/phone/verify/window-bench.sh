#!/bin/bash
# lanes: phone
# tools/phone/verify/window-bench.sh: the window-handling benchmark - every number the user feels as "windows are slow /
# bugged / don't load" (11-07 00:2x: "we really need to benchmark and fix all the window handling", "focus on
# performance atm", "no windows not loading etc"), each with a PASS budget. Runs in the verify queue's idle window:
#   queue.sh add <task> tools/phone/verify/window-bench.sh [--apps "kate dolphin konsole calc settings"] [--no-fold]
#   STRESS_N=20 (default) open/switch/close cycles first - the storm (see 0. below); STRESS_N=0 skips it.
# Linux apps (Kate, Dolphin, Konsole: KWin -> web window) and Android web windows (Calculator, Settings: a virtual
# display mirrored into home's page), on the unfolded home, opened through home's own launch path (state.ts launch,
# what a dock/drawer tap runs). Measured (in-page times are performance.now() in home's page, frame-exact; "drawn" is a
# screencap of the window's body on the glass, window-render.py stats, so its resolution is one shot, ~0.5-1 s):
#   open      launch -> its frame on the page (placeholder)          budget OPEN_FRAME_MS   150
#             launch -> live (the placeholder goes: its first frame) budget Linux 2500 / Android 1500 (LIVE_*_MS)
#             launch -> its body drawn on the glass (not flat)        budget live + DRAWN_SLACK_MS 1500
#   blank     the "not loading" detector: live but its body flat (one colour, no edges) for > BLANK_S (3) s, or never
#             live in LIVE_MAX_S (20) s = FAIL "not loading" (the window log + KWin log lines for it are kept)
#   drag      the bar dragged 1 s (input swipe): home's frames during it - fps >= 55, p95 frame <= 25 ms, and the window
#             moved with the finger (its frame within 10%)
#   resize    the SE grip dragged 1 s: the same frame budget; then the body drawn at its new size <= RESIZE_SETTLE_MS 1500
#   switch    a tap on the lower window's bar -> it is on top: <= SWITCH_MS 100
#   maximise  toggleMaximise (the bar's double tap / button) -> its frame settled: <= MAX_MS 400, drawn again after
#   restore   the same back
#   rotate    the screen turned 90 deg (user_rotation, put back) -> every window's frame settled, live and drawn <= 2500
#   unfold    folded 4 s and unfolded -> every window back live and drawn <= UNFOLD_MS 4000 (--no-fold skips it)
#   five      5 apps launched at once -> all live <= FIVE_MS 8000, all drawn
#   close     a tap on its close button -> its frame gone from the page <= CLOSE_MS 150, from the host <= 1000
# Output: $OUT/bench.tsv (metric, app, value ms|fps, budget, PASS|FAIL), one "BENCH" line each in the log; the window
# log / KWin log / logcat window tags since the start in $OUT. Only what it opened is closed; an app the user already
# runs is left out (noted). Exit: 0 all within budget; 1 a FAIL; 3 the user touched it / not now (re-queued); 5 ENV.
# Parts (11-10): the whole bench is ~2x the queue's 300 s budget, so every queued run timed out without a verdict. As
# `--round R --part K --of 4` it runs as four jobs that each fit, same round folder (e2e-lib's parts):
#   1 storm | 2 open gestures switch close | 3 open rotate fold close | 4 five       (--phases "..." picks any set)
# --of 6 (11-10, use this): 1 storm | 2-3 open gestures, half the apps each | 4 open switch close | 5 open rotate
# fold close | 6 five. Soft budget 210 s, hard stop 275 s (below).
# Each part also keeps its own clock (BENCH_BUDGET_S, 255 s from the start, the restore's time left): a phase that
# would start past it is a FAIL naming it, the storm stops starting cycles at it (FAIL: k of N cycles in budget), and
# three launches in a row that never go live end the storm (FAIL) - 20 s each was what ate the budget on 11-07/08.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APPS="kate dolphin konsole calc settings"; FOLD=1; ARGS=()
while [ $# -gt 0 ]; do case "$1" in --apps) APPS=$2; shift 2 ;; --no-fold) FOLD=0; shift ;; *) ARGS+=("$1"); shift ;; esac; done
. "$here/e2e-lib.sh"
# Every phase published as "-- HH:MM:SS <phase>" (queue.sh's kill_step names the step a timeout hit): 11-08 03:20's
# "FAIL timeout at step: apps: kate konsole calc settings" was only the last log line - the bench was in the storm's
# leak count (S0=$(leakstate)), no app had hung. And each page eval gives up in 20 s, not cdp.ts's 120 s: one call into
# a paused page (home behind a task) spent 40 % of the job's budget.
export CDP_TIMEOUT_S=${CDP_TIMEOUT_S:-20}
eval "e2e_$(declare -f chk)"
chk() { [ "$1" = "${PHASE:-}" ] || { PHASE=$1; echo "-- $(date +%T) $1"; }; e2e_chk "$1"; }
e2e_args ${ARGS[@]+"${ARGS[@]}"}
PHASES=${PHASES:-}
for ((i = 0; i < ${#ARGS[@]}; i++)); do [ "${ARGS[$i]}" = --phases ] && PHASES=${ARGS[$((i + 1))]:-}; done
if [ -z "$PHASES" ]; then
  # Six parts (11-10 p2): at Mac load ~35 one gesture round took 56-76 s, so part 2 of four (open, gestures for every
  # app, switch, close) could not fit; gestures now run in two parts over half the apps each (GHALF).
  if [ "$LAST" = 6 ]; then case $PART in 1) PHASES=storm ;; 2) PHASES="open gestures"; GHALF=1 ;; 3) PHASES="open gestures"; GHALF=2 ;;
    4) PHASES="open switch close" ;; 5) PHASES="open rotate fold close" ;; 6) PHASES=five ;; *) echo "bad --part $PART of 6"; exit 2 ;; esac
  elif [ "$LAST" = 4 ]; then case $PART in 1) PHASES=storm ;; 2) PHASES="open gestures switch close" ;;
    3) PHASES="open rotate fold close" ;; 4) PHASES=five ;; *) echo "bad --part $PART of 4"; exit 2 ;; esac
  else PHASES="storm open gestures switch rotate fold close five"; fi
fi
# The part's clocks, from the script's start: no new item after BENCH_BUDGET_S (soft: a FAIL naming what was not
# started), and a hard stop at BENCH_HARD_S. The end (restore_bench, e2e_finish's restore, end shot, layout check,
# publish) took > 43 s at Mac load ~35 (11-10 p2 part 2: work ended 257 s in, the queue killed it at 300 s), so the soft
# budget leaves 90 s. The hard stop is the backstop for one blocking call that runs long: a watchdog kills the running
# call and the script ends with a FAIL naming the step, the windows it opened closed in one host call - never the
# queue's 300 s kill.
BENCH_BUDGET_S=${BENCH_BUDGET_S:-210}; BENCH_HARD_S=${BENCH_HARD_S:-275}; T0S=$SECONDS; GHALF=${GHALF:-0}
# room <what> <s>: budget left to start one more item of a phase loop that should take <s> s (the last one's length);
# else a FAIL naming it. phase() alone checked only a phase's start, so part 2's five 35-50 s gesture rounds ran past
# the 300 s kill with no verdict (11-10 05:35, "FAIL timeout at step: gestures settings").
room() {
  [ $((SECONDS - T0S + ${2:-0})) -lt "$BENCH_BUDGET_S" ] && return 0
  fail "out of budget: $1 not started, $((SECONDS - T0S)) s in, the last one took ${2:-0} s (BENCH_BUDGET_S $BENCH_BUDGET_S)"; return 1
}
# phase <name>: this part runs it, and there is budget left to start it (else a FAIL naming it, not a kill).
phase() {
  [[ " $PHASES " == *" $1 "* ]] || return 1
  [ $((SECONDS - T0S)) -lt "$BENCH_BUDGET_S" ] && return 0
  fail "out of budget: $1 not started, $((SECONDS - T0S)) s in (BENCH_BUDGET_S $BENCH_BUDGET_S) - a slower bench step before it"; return 1
}
E2E_APPS='com.oneplus.calculator|com.android.settings'
E2E_LINUX='kate dolphin konsole'
e2e_init window-bench
PY="python3 -I $here/window-render.py"
HYPR=/data/powos/root/run/powos-app/hyprland.log
OPEN_FRAME_MS=${OPEN_FRAME_MS:-150}; LIVE_LINUX_MS=${LIVE_LINUX_MS:-2500}; LIVE_ANDROID_MS=${LIVE_ANDROID_MS:-1500}
DRAWN_SLACK_MS=${DRAWN_SLACK_MS:-1500}; BLANK_S=${BLANK_S:-3}; LIVE_MAX_S=${LIVE_MAX_S:-20}
FPS_MIN=${FPS_MIN:-55}; P95_MS=${P95_MS:-25}; RESIZE_SETTLE_MS=${RESIZE_SETTLE_MS:-1500}; SWITCH_MS=${SWITCH_MS:-100}
MAX_MS=${MAX_MS:-400}; ROTATE_MS=${ROTATE_MS:-2500}; UNFOLD_MS=${UNFOLD_MS:-4000}; FIVE_MS=${FIVE_MS:-8000}
CLOSE_MS=${CLOSE_MS:-150}; CLOSE_HOST_MS=${CLOSE_HOST_MS:-1000}
TSV=$OUT/bench.tsv; printf 'metric\tapp\tvalue\tbudget\tverdict\n' > "$TSV"
MINEW=""   # the web windows this bench opened (w-ids)
ROT0=""

# bench <metric> <app> <value> <budget> <le|ge> [unit]: one measured number against its budget.
bench() {
  local v=$3 b=$4 ok=FAIL u=${6:-ms}
  if [ -n "$v" ] && [ "$v" != - ] && awk -v v="$v" -v b="$b" -v o="$5" 'BEGIN{exit !(o=="le" ? v<=b : v>=b)}'; then ok=PASS; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "${v:--}" "$([ "$5" = le ] && echo "<=$b" || echo ">=$b")$u" "$ok" >> "$TSV"
  log "BENCH $1 $2: ${v:--}$u (budget $([ "$5" = le ] && echo "<=" || echo ">=")$b$u) $ok"
  [ $ok = PASS ] && pass "$1 $2: ${v}$u" || fail "$1 $2: ${v:--}$u, budget $([ "$5" = le ] && echo "<=" || echo ">=")$b$u"
}
nowms() { python3 -c 'import time; print(int(time.time()*1000))'; }
WW="Promise.all([importShim('./ui/webwindows.tsx'),importShim('./state.ts')])"

# keyof <app>: home's launch key.
keyof() {
  case $1 in
    kate|dolphin|konsole) echo "l:org.kde.$1" ;;
    calc) hcall apps.list "[]" "l=>(l.find(a=>/^a:com\\.oneplus\\.calculator\\//.test(a.key))||{}).key||'none'" ;;
    settings) hcall apps.list "[]" "l=>(l.find(a=>/^a:com\\.android\\.settings\\//.test(a.key))||{}).key||'none'" ;;
  esac
}
linux() { case $1 in kate|dolphin|konsole) return 0 ;; esac; return 1; }

# open_js <key...>: launches them through home's launch path at once; resolves when each is live (or LIVE_MAX_S):
# {key: {frame, live, id, failed}} in ms from the launch. One whose window from before is still up (one app, one
# window: the launch only raises it) fails at 1.5 s saying so, not 20 s of "never live" (11-08 storm).
open_js() {
  local keys; keys=$(printf "'%s'," "$@")
  ev "$WW.then(([m,s])=>{const K=[${keys%,}],before=new Set(m.webWins.value.map(w=>w.id)),t0=performance.now(),r={};
for(const k of K){r[k]={frame:-1,live:-1,id:null,failed:''};s.launch(k)}
return new Promise(ok=>{const tick=()=>{const t=Math.round(performance.now()-t0);
 for(const k of K){const w=m.webWins.value.filter(w=>String(w.key).startsWith(k)&&!before.has(w.id)).at(-1);if(!w){const o=m.webWins.value.find(w=>String(w.key).startsWith(k)&&before.has(w.id));if(o&&t>1500)r[k].failed='its window '+o.id+' from before is still open: the launch raised it (a close that missed)';continue}const o=r[k];o.id=w.id;
  if(o.frame<0&&document.querySelector('.webwindow[data-wwid=\"'+w.id+'\"]'))o.frame=t;if(o.live<0&&w.live)o.live=t;if(w.failed)o.failed=String(w.failed)}
 if(K.every(k=>r[k].live>=0||r[k].failed)||t>${LIVE_MAX_S}000)return ok(JSON.stringify(r));requestAnimationFrame(tick)};tick()})})"
}
jget() { python3 -c "import json,sys
try: print(json.loads(sys.argv[1])[sys.argv[2]][sys.argv[3]])
except Exception: print('')" "$1" "$2" "$3"; }

# drawn <w-id> <name>: its body on the glass is a picture, not a flat fill (kwin-restart-windows.sh's rule).
drawn() {
  local r st dom col
  r=$(wwbody "$1"); [ -n "$r" ] || { echo "no body on screen"; return 1; }
  "$A" exec-out "screencap | gzip -1" > "$OUT/$2.raw.gz" 2>/dev/null && [ -s "$OUT/$2.raw.gz" ] || { echo "screencap failed"; return 1; }
  # shellcheck disable=SC2086
  st=$($PY stats "$OUT/$2.raw.gz" $r 2>&1)
  dom=$(echo "$st" | sed -n 's/.*dominant=\([0-9.]*\).*/\1/p'); col=$(echo "$st" | sed -n 's/.*colours=\([0-9]*\).*/\1/p')
  echo "$st"
  awk -v d="${dom:-1}" -v c="${col:-0}" 'BEGIN { exit !(d < 0.97 && c >= 4) }' && return 0
  # shellcheck disable=SC2086
  $PY png "$OUT/$2.raw.gz" "$OUT/$2.png" $r "$OUT/$2-body.png" >/dev/null 2>&1; return 1
}
# until_drawn <w-id> <name> <max ms>: ms (Mac clock, from now) until drawn, or "" by max.
until_drawn() {
  local t0 t; t0=$(nowms)
  while :; do
    drawn "$1" "$2" >/dev/null && { echo $(($(nowms) - t0)); return 0; }
    t=$(($(nowms) - t0)); [ $t -gt "$3" ] && return 1
    sleep 0.2
  done
}
# blank_check <w-id> <app>: the "not loading" detector - live and drawn within BLANK_S s, else FAIL with evidence.
blank_check() {
  local live d
  live=$(wwel "$1" "e=>e.querySelector('.webwindow-body.live')?'live':(e.querySelector('.ww-failed,.failed')?'failed':'placeholder')")
  if d=$(until_drawn "$1" "blank-$2" $((BLANK_S * 1000))); then pass "loaded $2 ($1): $live, drawn"; return 0; fi
  fail "NOT LOADING $2 ($1): $live but its body is flat for > ${BLANK_S} s ($(drawn "$1" "blank-$2-last"))"
  log "  shot: $OUT/blank-$2-last.png (body: blank-$2-last-body.png)"
  return 1
}

# fps_js <ms>: home's frames for that long (rAF intervals): "fps p50 p95 max n" - run in the background beside input.
fps_js() {
  ev "new Promise(ok=>{const t=[];const t0=performance.now();const f=n=>{t.push(n);if(n-t0<$1)requestAnimationFrame(f);else{const d=t.slice(1).map((v,i)=>v-t[i]).sort((a,b)=>a-b);const q=p=>d.length?d[Math.min(d.length-1,Math.floor(p*d.length))]:0;ok([Math.round(1000*d.length/(t.at(-1)-t[0])),q(.5).toFixed(1),q(.95).toFixed(1),(d.at(-1)||0).toFixed(1),d.length].join(' '))}};requestAnimationFrame(f)})"
}
# frame_of <w-id>: its frame element's rect, "x y w h" CSS px.
frame_of() { wwel "$1" "e=>{const r=e.getBoundingClientRect();return [r.x,r.y,r.width,r.height].map(Math.round).join(' ')}"; }

# gesture <metric> <w-id> <app> <x0 y0 x1 y1>: an injected 1 s swipe while home's frames are sampled.
gesture() {
  local m=$1 id=$2 app=$3 f0 f1 res fps p95
  f0=$(frame_of "$id")
  fps_js 1600 > "$OUT/fps-$m-$app.txt" &
  local bg=$!; sleep 0.15
  swipe "$4" "$5" "$6" "$7" 1000 "$m $app" || { wait $bg; fail "$m $app: no spot to touch"; return 1; }
  wait $bg; res=$(cat "$OUT/fps-$m-$app.txt"); f1=$(frame_of "$id")
  set -- $res; fps=${1:-}; p95=${3:-}
  log "$m $app: frames '$res' (fps p50 p95 max n), frame $f0 -> $f1"
  bench "$m-fps" "$app" "$fps" "$FPS_MIN" ge fps
  bench "$m-p95" "$app" "$p95" "$P95_MS" le
  echo "$f0|$f1" > "$OUT/frames-$m-$app.txt"
}

RB=0
restore_bench() {
  [ $RB = 1 ] && return 0; RB=1
  local i
  [ "${OCON:-0}" = 1 ] && sh_ "setprop debug.powos.ww_order_check 0"
  for i in $MINEW; do hcall webwindows.close "[${i#w}]" "()=>'ok'" >/dev/null 2>&1; done
  [ -n "$ROT0" ] && { set -- $ROT0; sh_ "settings put system accelerometer_rotation $1; settings put system user_rotation $2"; log "rotation put back ($ROT0)"; ROT0=""; }
  sh_ "tail -n +$((H0 + 1)) $HYPR" > "$OUT/kwin.log" 2>/dev/null
  "$A" exec-out "su -c 'cat /data/data/com.powos.app/files/window-log.1.txt /data/data/com.powos.app/files/window-log.txt 2>/dev/null'" 2>/dev/null |
    awk -v s="$START" '$1" "$2 >= s' > "$OUT/window-log.txt"
  sh_ "logcat -d -v time -s PowosWebWindows:V PowosRenderWatch:V RenderWatch:V WebWindowSource:V" > "$OUT/logcat-windows.txt"
  log "logs: window-log $(wc -l < "$OUT/window-log.txt" | tr -d ' ') lines, kwin $(wc -l < "$OUT/kwin.log" | tr -d ' '), logcat $(wc -l < "$OUT/logcat-windows.txt" | tr -d ' ') -> $OUT"
}

e2e_setup inner
START=$(sh_ "date +\"%m-%d %H:%M:%S\""); H0=$(sh_ "wc -l < $HYPR"); H0=${H0:-0}
trap 'restore_bench; e2e_abort; [ -n "${WDOG:-}" ] && kill "$WDOG" 2>/dev/null' EXIT
# hard_stop: the watchdog's USR1 (after it killed the running call): the FAIL, the windows closed in one call, rotation
# and the lock put back, the steps published - no end screenshot or full restore (those are what ran out of time).
hard_stop() {
  trap - USR1 EXIT
  fail "hard deadline: ${BENCH_HARD_S} s reached in step '${PHASE:-?}' - stopped there; the part's last items are not judged"
  [ -n "$MINEW" ] && CDP_TIMEOUT_S=8 ev "importShim('./bridge.ts').then(b=>Promise.all([$(echo $MINEW | sed 's/w//g; s/ /,/g')].map(i=>b.powos.webwindows.close(i)))).then(()=>'ok')" >/dev/null 2>&1
  [ "${OCON:-0}" = 1 ] && sh_ "setprop debug.powos.ww_order_check 0"
  [ -n "$ROT0" ] && { set -- $ROT0; sh_ "settings put system accelerometer_rotation $1; settings put system user_rotation $2"; }
  publish; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
  echo "FAIL e2e-$JOURNEY round $ROUND part $PART/$LAST: $NPASS passed, $NFAIL failed - hard deadline ${BENCH_HARD_S} s in '${PHASE:-?}' - $UDIR"
  print_fails; exit 1
}
trap hard_stop USR1
# The watchdog: at BENCH_HARD_S from the start, kill the script's running calls with all their descendants (killing
# only a $(...) subshell left its child holding the pipe, so the call never returned; not the watchdog itself),
# then USR1 (bash runs the trap once the foreground call has returned).
( sleep $((BENCH_HARD_S - (SECONDS - T0S))); me=$(exec sh -c 'echo $PPID')
  k=$(pgrep -P $$ | grep -vx "$me"); all=$k; while [ -n "$k" ]; do k=$(for c in $k; do pgrep -P "$c"; done); all="$all $k"; done
  kill $all; kill -USR1 $$ ) >/dev/null 2>&1 &
WDOG=$!
[ "$(hcall webwindows.list "[]" "l=>'ok'")" = ok ] || { echo "ENV: home has no web windows here (folded, off)"; exit 5; }
# "[s]team_app_", not steam_app_: pgrep -f matched the su/sh wrapping its own command line (it carries the pattern), so
# every run SKIPped "a game runs: not now" with no game up (11-07). The bracket keeps the pattern out of that line.
[ -z "$(sh_ "chroot /data/powos/root /usr/bin/pgrep -f \"[s]team_app_\" | head -1")" ] || e2e_skip "a game runs: not now"
log "apk $(sh_ "dumpsys package com.powos.app | grep -m1 versionName"), kwin $(sh_ "chroot /data/powos/root /usr/bin/pacman -Q kwin 2>/dev/null")"

# The apps: one the user already runs is left out (its window could be theirs).
RUN=""; for a in $APPS; do
  if linux "$a" && [ -n "$(us "pgrep -x $a | head -1")" ]; then note "$a: the user's $a runs - left out"; continue; fi
  k=$(keyof "$a"); case $k in ""|none|ERR*) note "$a: no launch key ($k)"; continue ;; esac
  RUN="$RUN $a"; eval "KEY_$a=\$k"
done
[ -n "$RUN" ] || { echo "ENV: no app to bench"; exit 5; }
# Gestures over half the apps (parts 2 and 3 of six): the first half rounded up, or the rest.
if [ "$GHALF" != 0 ]; then set -- $RUN; h=$((($# + 1) / 2))
  if [ "$GHALF" = 1 ]; then RUN=$(echo $RUN | cut -d' ' -f1-$h); else [ $# -gt $h ] && RUN=$(echo $RUN | cut -d' ' -f$((h + 1))-) || RUN=""; fi
  [ -n "$RUN" ] || { echo "ENV: no app left for this half (GHALF $GHALF)"; exit 5; }
fi
log "apps: $RUN"

# 0. THE STORM (the user 11-07: "rapidly opening and closing apps seeing how responsive everything is measuring
# framedrops etc"): STRESS_N cycles at user speed (one per ~STRESS_PACE_S s). Cycle k opens app k (round robin over
# the apps), then taps the bar of the window cycle k-1 opened (switch: it comes on top) and closes it by its close
# button - so one or two windows are up at any time. Per cycle: tap -> frame (first visual response), tap -> live,
# switch, close -> gone; home's frames over the cycle (rAF: dropped frames = missed 16.7 ms vsyncs, janky = > 25 ms,
# p95/p99). Then: leaks (web windows, host windows, ww layers, tasks, PSS before vs after), stuck/blank windows, and
# whether it slows down (last third vs first third of open->live).
STRESS_N=${STRESS_N:-20}; STRESS_PACE_S=${STRESS_PACE_S:-1.5}
STORM_P95_MS=${STORM_P95_MS:-25}; STORM_DROP=${STORM_DROP:-6}; SLOWDOWN=${SLOWDOWN:-1.5}
leakstate() {   # "pagewins hostwins wwlayers tasks pss_kb"
  local pw hw ly tk ps
  pw=$(ev "document.querySelectorAll('.webwindow[data-wwid]').length")
  hw=$(hcall webwindows.list "[]" "l=>String(l.length)")
  ly=$(sh_ "dumpsys SurfaceFlinger --list" | grep -cE "powos-ww-[0-9]+")
  tk=$(tasks | grep -cE "$E2E_APPS")
  ps=$(sh_ "dumpsys meminfo com.powos.app" | awk '/TOTAL PSS:/{print $3; exit} /^ *TOTAL /{print $2; exit}')
  echo "$pw $hw $ly $tk ${ps:-0}"
}
# arm_js <var> <cond> [limit ms]: JS that has the page time the next tap - from its pointerdown (the page's clock) until
# <cond> (an async JS function -> bool) holds, in ms -> window.<var>; "-" when it doesn't hold <limit> (2000) ms after the
# tap, or no tap came in 30 s. The limit counts from the tap, not the arming: under Mac load the hops between arming and
# the tap (offpill's dumpsys, `input tap`'s start) took > 2 s, so every storm close read "-" (11-10 p1: "close - ms"
# in both cycles). A newer arming of the same var ends the older one (no late write into the next measurement).
arm_js() {
  printf '%s' "(()=>{const V='$1',A=(window.__wbArm=window.__wbArm||{}),g=(A[V]=(A[V]||0)+1),C=$2;window[V]=null;let t0=0;const d=e=>{t0=e.timeStamp};document.addEventListener('pointerdown',d,{capture:true,once:true});const t1=performance.now();const end=v=>{document.removeEventListener('pointerdown',d,{capture:true});if(A[V]===g)window[V]=v};(async()=>{for(;;){if(A[V]!==g)return;if(t0&&await C())return end(String(Math.round(performance.now()-t0)));const n=performance.now();if(t0?n-t0>${3:-2000}:n-t1>30000)return end(t0?'- (not within ${3:-2000} ms of the tap)':'- (no tap reached the page in 30 s)');await new Promise(r=>requestAnimationFrame(r))}})();return 'armed'})()"
}
# The page and host conditions arm_js times: its frame gone from the page; gone from the host's list (webwindows.list,
# the bridge from the page - the host's close on the phone's clock, not the Mac's: polled from the Mac each read was a
# CDP hop of 2-8 s at load 35 and the tap's own `input tap` start, so close-host read 1.5-3 s for a close the host
# finished 30 ms after the touch, 11-10 05:38:51.556 -> .594 for calc).
pagegone() { printf '%s' "async()=>!document.querySelector('.webwindow[data-wwid=\"${1#w}\"]')"; }
hostgone() { printf '%s' "async()=>{const b=await importShim('./bridge.ts');const l=await b.powos.webwindows.list();return !l.some(w=>w.id===${1#w})}"; }
ontop() { printf '%s' "async()=>{const [m]=await $WW;const t=m.webWins.value.at(-1);return !!t&&t.id===${1#w}}"; }
# storm_switch <w-id>: a tap on its bar -> ms until it is on top ("-": not on top in 2 s, or no bar on screen).
storm_switch() {
  local p; p=$(barpt "$1"); [ -n "$p" ] || { echo -; return; }
  ev "$(arm_js __wbSw "$(ontop "$1")")" >/dev/null
  set -- $p; sh_ "input tap $1 $2"; storm_read __wbSw
}
# storm_read <var> [max ms]: the page's armed measurement once it resolved - one page call that waits for it (it was up to
# ten polls, each a CDP hop of 2-8 s under Mac load: one storm cycle took 58 s, 11-10 p1).
# A "-" says why on stderr (the job log): no tap reached the page, or the condition never held after it.
storm_read() {
  local v; v=$(ev "new Promise(ok=>{const t=performance.now();const f=()=>{const v=window.$1;if(v!=null)return ok(String(v));if(performance.now()-t>${2:-12000})return ok('- (not resolved in ${2:-12000} ms of reading)');setTimeout(f,25)};f()})")
  case ${v:--} in -*) echo "  $1: ${v:-- (no answer from the page)}" >&2; echo - ;; *) echo "$v" ;; esac
}
# storm_close <w-id>: a tap on its close button -> ms until its frame is gone ("-": no button, closed by the host).
storm_close() {
  local p; p=$(wwpt "$1" .ww-close)
  [ -n "$p" ] || { hcall webwindows.close "[${1#w}]" "()=>'ok'" >/dev/null; echo -; return; }
  ev "$(arm_js __wbCl "$(pagegone "$1")")" >/dev/null
  set -- $p; offpill "$1" "$2" "close" && sh_ "input tap $1 $2"; storm_read __wbCl
}
# storm_cycle <i> <app>: open it, switch to the window the last cycle opened (PREVID) and close that; one storm.part row.
storm_cycle() {
  local i=$1 a=$2 k r id fr lv t sw=- cl=- nm
  eval "k=\$KEY_$a"
  ev "(window.__wbS.m.push(performance.now()),'ok')" >/dev/null
  t=$(nowms); r=$(open_js "$k")
  id=$(jget "$r" "$k" id); fr=$(jget "$r" "$k" frame); lv=$(jget "$r" "$k" live)
  [ -n "$id" ] && [ "$id" != None ] && MINEW="$MINEW w$id" || id=""
  { [ -z "$lv" ] || [ "$lv" -lt 0 ] 2>/dev/null; } && { fail "NOT LOADING storm $i $a: never live ($(jget "$r" "$k" failed))"; lv=-; }
  # "w<id>": barpt takes a web window's id with its w (a bare id went to its uiautomator path: no bar found, every switch
  # "-", so the close tap hit whatever lay over the lower window's button - 11-08 storm).
  if [ -n "$PREVID" ] && [ "$(wwhost "$PREVID" gone)" != true ]; then sw=$(storm_switch "w$PREVID"); cl=$(storm_close "w$PREVID"); fi
  # Pace: one cycle per STRESS_PACE_S s at least (user speed), never faster.
  nm=$(( $(nowms) - t )); awk -v n="$nm" -v p="$STRESS_PACE_S" 'BEGIN{exit !(n < p*1000)}' && sleep "$(awk -v n="$nm" -v p="$STRESS_PACE_S" 'BEGIN{print (p*1000-n)/1000}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$a" "${fr:--}" "$lv" "$sw" "$cl" >> "$OUT/storm.part"
  log "storm $i $a: frame ${fr:--} live $lv switch $sw close $cl ms (prev ${PREVID:-none})"
  PREVID=$id
}
# storm_frames: home's frames per cycle (mark i to mark i+1) joined to storm.part -> storm.tsv; the frame budgets.
storm_frames() {
  local fr n=0 c ap f l s2 c2 cyc FR
  # Frames per cycle: from mark i to mark i+1 (the last to the stop).
  fr=$(ev "(()=>{const S=window.__wbS;S.on=false;const out=[];const m=[...S.m,performance.now()];const all=[];for(let i=0;i+1<m.length;i++){const t=S.t.filter(v=>v>=m[i]&&v<m[i+1]);const d=t.slice(1).map((v,j)=>v-t[j]);all.push(...d);const s=[...d].sort((a,b)=>a-b);const q=p=>s.length?s[Math.min(s.length-1,Math.floor(p*s.length))]:0;out.push([d.reduce((a,v)=>a+Math.max(0,Math.round(v/16.67)-1),0),d.filter(v=>v>25).length,q(.95).toFixed(1),q(.99).toFixed(1),Math.round(1000*d.length/((t.at(-1)-t[0])||1))].join(' '))}const s=all.sort((a,b)=>a-b);const q=p=>s.length?s[Math.min(s.length-1,Math.floor(p*s.length))]:0;out.push(['ALL',all.reduce((a,v)=>a+Math.max(0,Math.round(v/16.67)-1),0),all.filter(v=>v>25).length,q(.95).toFixed(1),q(.99).toFixed(1),s.length].join(' '));return out.join('|')})()")
  IFS='|' read -ra FR <<<"$fr"
  while IFS=$'\t' read -r c ap f l s2 c2; do
    set -- ${FR[$n]:-- - - - -}; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$ap" "$f" "$l" "$s2" "$c2" "$1" "$2" "$3" "$4" "$5" >> "$OUT/storm.tsv"; n=$((n + 1))
  done < "$OUT/storm.part"; rm -f "$OUT/storm.part"
  column -t -s$'\t' "$OUT/storm.tsv" | tee -a "$OUT/log.txt"
  set -- ${FR[${#FR[@]}-1]}; log "storm frames: $*  (ALL dropped janky p95 p99 n)"
  cyc=${#FR[@]}; cyc=$((cyc - 1)); [ $cyc -ge 1 ] || cyc=1
  bench storm-p95 home "$4" "$STORM_P95_MS" le
  bench storm-drop-per-cycle home "$(awk -v d="$2" -v c=$cyc 'BEGIN{printf "%.1f", d/c}')" "$STORM_DROP" le frames
  sh_ "dumpsys gfxinfo com.powos.app" | grep -E "Total frames rendered|Janky frames|(50|90|95|99)th percentile" | head -7 > "$OUT/gfxinfo.txt"; log "gfxinfo (whole app, the storm): $(tr '\n' ';' < "$OUT/gfxinfo.txt")"
}
# storm_trend: per column (frame, live, close) the median and the slowdown (last third / first third), with budgets.
storm_trend() {
  local col nm2 med slow
  for col in 3 4 6; do   # frame, live, close: medians, and the slowdown (last third / first third)
    nm2=$(sed -n 1p "$OUT/storm.tsv" | cut -f$col)
    read -r med slow <<<"$(python3 -c 'import sys
c=int(sys.argv[2]); v=[int(r.split("\t")[c-1]) for r in open(sys.argv[1]).read().splitlines()[1:] if r.split("\t")[c-1].isdigit()]
if not v: print("- -"); raise SystemExit
s=sorted(v); t=max(1,len(v)//3); a=sum(v[:t]); b=sum(v[-t:])
print(s[len(s)//2], "%.2f" % (b/a if a else 1))' "$OUT/storm.tsv" $col)"
    log "storm $nm2: median ${med} ms, last third / first third ${slow}x"
    case $nm2 in frame_ms) bench storm-frame-median all "$med" "$OPEN_FRAME_MS" le ;; live_ms) bench storm-live-median all "$med" "$LIVE_LINUX_MS" le ;; close_ms) bench storm-close-median all "$med" "$CLOSE_MS" le ;; esac
    bench "storm-slowdown-$nm2" all "$slow" "$SLOWDOWN" le x
  done
}
# storm_leaks <before>: what the storm left (leakstate now vs before), each budget 0 but PSS (40 MB).
storm_leaks() {
  local S1 b1 b2 b3 b4 b5
  sleep 3; S1=$(leakstate); log "storm: after (page host layers tasks pss) $S1 (before $1)"
  set -- $1; b1=$1 b2=$2 b3=$3 b4=$4 b5=$5; set -- $S1
  bench leak-page-windows all $(($1 - b1)) 0 le " win"; bench leak-host-windows all $(($2 - b2)) 0 le " win"
  bench leak-ww-layers all $(($3 - b3)) 0 le " layers"; bench leak-tasks all $(($4 - b4)) 0 le " tasks"
  bench leak-pss-mb all $((($5 - b5) / 1024)) 40 le MB
}
storm() {
  local apps=() a i S0
  for a in $RUN; do apps+=("$a"); done
  [ ${#apps[@]} -ge 1 ] || return 0
  local L0=$SECONDS; chk "storm: leaks before"; S0=$(leakstate); log "storm: before (page host layers tasks pss) $S0"
  sh_ "dumpsys gfxinfo com.powos.app reset" >/dev/null
  printf 'cycle\tapp\tframe_ms\tlive_ms\tswitch_ms\tclose_ms\tdrop\tjank\tp95\tp99\tfps\n' > "$OUT/storm.tsv"
  # home's frames through the whole storm, marked per cycle (window.__wbS).
  ev "(()=>{const S=window.__wbS={t:[],m:[],on:true};const f=n=>{S.t.push(n);if(S.on)requestAnimationFrame(f)};requestAnimationFrame(f);return 'on'})()" >/dev/null
  PREVID=""; local dead=0 ran=0 c0 cyc_s=0 after_s
  # Room kept for the storm's own frames/trend/leak reads inside the part's budget: twice what the leak count before
  # took (it is the same reads again, plus the frames and the screenshot), at least 25 s - a fixed 25 s left the after
  # step 70+ s short at Mac load 35 and the part was killed at 300 s with no verdict (11-10 05:13:37). A cycle starts
  # only when it fits, at the last cycle's length.
  after_s=$(( 2 * (SECONDS - L0) + 15 )); [ $after_s -ge 25 ] || after_s=25
  for i in $(seq 1 "$STRESS_N"); do
    [ $((SECONDS - T0S + cyc_s)) -lt $((BENCH_BUDGET_S - after_s)) ] || break
    c0=$SECONDS; chk "storm $i"; a=${apps[$(((i - 1) % ${#apps[@]}))]}; storm_cycle "$i" "$a"; ran=$i; cyc_s=$((SECONDS - c0))
    # A never-live launch costs LIVE_MAX_S; three in a row is the verdict (NOT LOADING), not a reason to time out.
    if tail -1 "$OUT/storm.part" | cut -f4 | grep -qx -- -; then dead=$((dead + 1)); else dead=0; fi
    [ $dead -ge 3 ] && { fail "storm stopped at cycle $i: three launches in a row never went live"; break; }
  done
  [ $dead -ge 3 ] || [ "$ran" -ge "$STRESS_N" ] || fail "storm: $ran of $STRESS_N cycles in the part's ${BENCH_BUDGET_S} s - a cycle took $(( (SECONDS - T0S) / (ran > 0 ? ran : 1) )) s on average (pace ${STRESS_PACE_S} s)"
  [ -n "$PREVID" ] && { hcall webwindows.close "[${PREVID#w}]" "()=>'ok'" >/dev/null; }
  chk "storm: frames, trend, leaks after"; storm_frames; storm_trend; storm_leaks "$S0"
  MINEW=""
  step storm "after $STRESS_N open/switch/close cycles"
}
[ "${STRESS_N:-20}" -gt 0 ] && phase storm && storm

# 1. open, one at a time (cold for Linux: no process yet), and the not-loading detector on each.
IT0=""
phase open && for a in $RUN; do
  IT_S=$((SECONDS - ${IT0:-$SECONDS})); room "open $a" "$IT_S" || break; IT0=$SECONDS
  eval "k=\$KEY_$a"; chk "open $a"
  t0=$(nowms); r=$(open_js "$k"); t1=$(nowms)
  id=$(jget "$r" "$k" id); fr=$(jget "$r" "$k" frame); lv=$(jget "$r" "$k" live); fl=$(jget "$r" "$k" failed)
  log "open $a: $r"
  [ -n "$id" ] && [ "$id" != None ] && { MINEW="$MINEW w$id"; eval "ID_$a=w\$id"; }
  bench open-frame "$a" "$fr" "$OPEN_FRAME_MS" le
  if [ -z "$lv" ] || [ "$lv" -lt 0 ] 2>/dev/null; then
    bench open-live "$a" - "$(linux "$a" && echo $LIVE_LINUX_MS || echo $LIVE_ANDROID_MS)" le
    fail "NOT LOADING $a: never live in ${LIVE_MAX_S} s${fl:+ ($fl)}"; continue
  fi
  bench open-live "$a" "$lv" "$(linux "$a" && echo $LIVE_LINUX_MS || echo $LIVE_ANDROID_MS)" le
  d=$(until_drawn "w$id" "open-$a" 6000) && bench open-drawn "$a" $((t1 - t0 + d)) $((lv + DRAWN_SLACK_MS)) le || blank_check "w$id" "$a"
  step "open-$a" "$a opened as a web window"
done

# 2. drag + resize + maximise/restore on each window, frame-timed.
IT_S=0
phase gestures && for a in $RUN; do
  eval "id=\${ID_$a:-}"; [ -n "$id" ] || continue
  room "gestures $a" "$IT_S" || break; IT0=$SECONDS; chk "gestures $a"
  hcall webwindows.list "[]" "()=>'ok'" >/dev/null
  ev "$WW.then(([m])=>(m.raise(${id#w}),'ok'))" >/dev/null; sleep 0.4
  p=$(barpt "$id"); [ -n "$p" ] && { set -- $p; gesture drag "$id" "$a" "$1" "$2" $(($1 + $(dp 120))) $(($2 + $(dp 60))); sleep 0.6; }
  g=$(wwpt "$id" ".ww-grip-se"); [ -n "$g" ] || g=$(wwpt "$id" "[class*=grip][class*=se]")
  if [ -n "$g" ]; then set -- $g; gesture resize "$id" "$a" "$1" "$2" $(($1 - $(dp 90))) $(($2 - $(dp 70)))
    d=$(until_drawn "$id" "resize-$a" 4000) && bench resize-settle "$a" "$d" "$RESIZE_SETTLE_MS" le || blank_check "$id" "$a"
  else note "resize $a: no SE grip on its frame"; fi
  for dir in maximise restore; do
    ms=$(ev "$WW.then(([m])=>{const id=${id#w},q=()=>{const e=document.querySelector('.webwindow[data-wwid=\"'+id+'\"] .webwindow-body');if(!e)return '';const r=e.getBoundingClientRect();return [r.x,r.y,r.width,r.height].map(Math.round).join(' ')},a=q(),t0=performance.now();m.toggleMaximise(id);
return new Promise(ok=>{let last=a,same=0;const f=()=>{const t=performance.now()-t0,c=q();if(c!==a&&c===last)same++;else same=0;last=c;if(same>=3)return ok(String(Math.round(t-3*16.7)));if(t>3000)return ok('-');requestAnimationFrame(f)};requestAnimationFrame(f)})})")
    bench "$dir" "$a" "$ms" "$MAX_MS" le
    d=$(until_drawn "$id" "$dir-$a" 4000) && log "$dir $a: drawn again ${d} ms after (Mac clock)" || blank_check "$id" "$a"
  done
  step "gestures-$a" "$a dragged, resized, maximised and restored"; IT_S=$((SECONDS - IT0))
done

# 3. switching: a tap on the lower of two windows' bars puts it on top. The host's layer order check (SurfaceFlinger's
# composition against the page's z, WebWindows.orderCheckSoon) is off in daily use (docs/WINDOWS_FIX_PLAN.md 1.1); it
# runs here, after the switch timings, and any "layer order != page order" line it logs is a FAIL.
set -- $RUN; if [ $# -ge 2 ] && phase switch; then
  eval "i1=\${ID_$1:-}; i2=\${ID_$2:-}"
  if [ -n "$i1" ] && [ -n "$i2" ]; then
    OC0=$(sh_ "date +\"%m-%d %H:%M:%S.000\"")
    for pair in "$i1 $i2 $1" "$i2 $i1 $2"; do set -- $pair; chk switch
      ev "$WW.then(([m])=>(m.raise(${2#w}),'ok'))" >/dev/null; sleep 0.5
      p=$(barpt "$1"); [ -n "$p" ] || { note "switch: $1's bar not on screen (under the other)"; continue; }
      ev "$(arm_js __wbSw "$(ontop "$1")" 3000)" >/dev/null
      set -- $p "$1" "$3"; tap "$1" "$2" "the lower window's bar"
      bench switch "$4" "$(storm_read __wbSw)" "$SWITCH_MS" le
    done
    # The order check, once per raise: on, raise each in turn (the check runs 300 ms after the apply), off again.
    sh_ "setprop debug.powos.ww_order_check 1"; OCON=1
    for w in "$i1" "$i2"; do ev "$WW.then(([m])=>(m.raise(${w#w}),'ok'))" >/dev/null; sleep 1.2; done
    sh_ "setprop debug.powos.ww_order_check 0"; OCON=0
    oc=$(sh_ "logcat -d -v time -T \"$OC0\" -s PowosWebWindows:V" | grep -c "layer order != page order")
    log "layer order check over the switch: ${oc:-0} divergence line(s)"
    [ "${oc:-0}" = 0 ] || { sh_ "logcat -d -v time -T \"$OC0\" -s PowosWebWindows:V" | grep "layer order" > "$OUT/layer-order.txt"; bench layer-order all "$oc" 0 le; }
  fi
fi

# 4. rotate 90 deg and back: every window settled, live and drawn.
settle_all() {   # settle_all <metric> <budget>: ms (Mac clock) until every bench window is live and drawn
  local t0 left w; t0=$(nowms)
  while :; do
    left=""; for w in $MINEW; do
      [ "$(wwhost "$w" gone)" = true ] && continue
      [ "$(wwel "$w" "e=>e.querySelector('.webwindow-body.live')?'live':'no'")" = live ] && drawn "$w" "$1-$w" >/dev/null || left="$left $w"
    done
    [ -z "$left" ] && { echo $(($(nowms) - t0)); return 0; }
    [ $(($(nowms) - t0)) -gt $(($2 * 3)) ] && { echo "- (not back:$left)"; return 1; }
    sleep 0.3
  done
}
if phase rotate; then chk rotate
ROT0=$(sh_ "echo \$(settings get system accelerometer_rotation) \$(settings get system user_rotation)")
for rot in 1 0; do
  sh_ "settings put system accelerometer_rotation 0; settings put system user_rotation $rot"; sleep 0.3
  v=$(settle_all "rotate$rot" "$ROTATE_MS"); bench "rotate-$rot" all "${v%% *}" "$ROTATE_MS" le; [ "${v%% *}" = - ] && log "rotate: $v"
done
set -- $ROT0; sh_ "settings put system accelerometer_rotation $1; settings put system user_rotation $2"; ROT0=""
step rotated "rotated and back"
fi

# 5. fold 4 s, unfold: the windows come back.
if [ $FOLD = 1 ] && phase fold; then chk fold
  device_state_set 0; sleep 4; device_state_set 3; sleep 0.3
  v=$(settle_all unfold "$UNFOLD_MS"); bench unfold all "${v%% *}" "$UNFOLD_MS" le; [ "${v%% *}" = - ] && log "unfold: $v"
  # The ids may be new after a fold (Linux windows handed back and adopted again): read them by key.
  for a in $RUN; do eval "k=\$KEY_$a"; n=$(wwids "$k" | tail -1); [ -n "$n" ] && { eval "ID_$a=\$n"; MINEW="$MINEW $n"; }; done
  step unfolded "folded and unfolded"
fi

# 6. close every window by its close button, timed in the page: frame gone from the page, and gone from the host's
# list (both from the tap's pointerdown, on the phone's clock - see hostgone).
IT0=""
phase close && CLOSED=1 && for a in $RUN; do
  eval "id=\${ID_$a:-}"; [ -n "$id" ] || continue
  IT_S=$((SECONDS - ${IT0:-$SECONDS})); room "close $a" "$IT_S" || break; IT0=$SECONDS; chk "close $a"
  ev "$WW.then(([m])=>(m.raise(${id#w}),'ok'))" >/dev/null; sleep 0.4
  p=$(wwpt "$id" .ww-close); [ -n "$p" ] || { note "close $a: no close button on screen"; continue; }
  ev "[$(arm_js __wbCl "$(pagegone "$id")" 3000),$(arm_js __wbHg "$(hostgone "$id")" "$((CLOSE_HOST_MS * 3))")].join()" >/dev/null
  set -- $p; tap "$1" "$2" "$a's close button"
  bench close "$a" "$(storm_read __wbCl)" "$CLOSE_MS" le
  bench close-host "$a" "$(storm_read __wbHg)" "$CLOSE_HOST_MS" le
done
# Only a close phase that ran hands the windows off; otherwise restore_bench closes what this part opened.
[ "${CLOSED:-0}" = 1 ] && { MINEW=""; sleep 1.5; }

# 7. five at once (warm: the Linux apps quit by their close a moment ago may still be ending).
set -- $RUN; if [ $# -ge 2 ] && phase five; then chk five
  keys=(); for a in $RUN; do eval "keys+=(\"\$KEY_$a\")"; done
  t0=$(nowms); r=$(open_js "${keys[@]}"); t1=$(nowms); log "five: $r"
  worst=0; ok=1; for a in $RUN; do eval "k=\$KEY_$a"; id=$(jget "$r" "$k" id); lv=$(jget "$r" "$k" live)
    [ -n "$id" ] && [ "$id" != None ] && { MINEW="$MINEW w$id"; eval "ID_$a=w\$id"; }
    if [ -z "$lv" ] || [ "$lv" -lt 0 ] 2>/dev/null; then ok=0; fail "NOT LOADING $a (five at once): never live"; else [ "$lv" -gt $worst ] && worst=$lv; fi
  done
  bench five-live "${#keys[@]}apps" "$([ $ok = 1 ] && echo $worst || echo -)" "$FIVE_MS" le
  for a in $RUN; do eval "id=\${ID_$a:-}"; [ -n "$id" ] && blank_check "$id" "five-$a"; done
  step five "five windows at once"
fi

restore_bench
log "bench table: $TSV"; column -t -s$'\t' "$TSV" | tee -a "$OUT/log.txt"
e2e_finish
