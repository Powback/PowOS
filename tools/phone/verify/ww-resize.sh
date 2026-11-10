#!/bin/bash
# lanes: phone
# needs: kwin
# tools/phone/verify/ww-resize.sh [OUT]: N4 of docs/WEB_WINDOWS.md "Native-glued windows" - a web window resizes with
# no perf drop and no rendering issue (the user, 11-07: "I should be able to resize it flawlessly with no perf drop and
# no rendering issues ever"). For Kate, Dolphin (Linux, KWin's buffers) and Calculator (Android, its VirtualDisplay):
# each opened through home's launch path, then an EDGE drag (right edge, 300 px in and back) and a CORNER drag (bottom
# right, 300x200 px in and back), each at user speed (input swipe, 700 ms a way), measured twice:
#   stats pass  shell     home's frames on the display over each way (SurfaceFlinger --latency of home's buffer layer):
#                         presented frames and MISSED vsyncs (a gap of k periods under 100 ms = k-1 missed) - the
#                         budget is 0; gfxinfo's janky frames and p90/p99 over the gesture (informative)
#               content   the window's own frames on the display (its buffer layer: powos-ww-<id>-linux, or the app's
#                         window on its display): presented, max gap ms
#               kwin      KWin's "window task N frames: ... C commits, D drawn" (0057) lines over the gesture: commits ~=
#                         drawn, a commit KWin never drew is a lost content frame; its "resized: N commits, configure->
#                         commit median" (0018): how long the app takes to draw at a new size (Linux only)
#               buffers   the host's "resize: R relayouts for S steps" (RS1) and "outgrew its buffers" (a consumer
#                         restart = new buffers), the consumer's "pacing" (Andromarchy) lines
#   record pass screenrecord over the same gesture; every frame's part of the body that stays inside the window through
#               the whole drag compared to the frame before the drag: a BLANK frame (that part uniform or black where
#               it showed content) - the budget is 0
# Facts per app/gesture in OUT/summary.txt. FAIL: a missed shell vsync while the finger moves, a blank frame, a
# commit KWin never drew, or a closed Linux window's layer still in SurfaceFlinger 3 s after its close. Needs the phone unfolded and idle (the runner's window); a full-screen window (a game left
# running) skips the run (exit 3, re-queued) - never touched.
#   per frame   each way of the stats pass under perfetto (SF frame timeline, gfx/view atrace, sched) -> OUT/<app>-<g>-<way>
#               .pftrace, read by resize-trace.py: every home surface frame's jank type (App Deadline Missed = the shell
#               late; SurfaceFlinger CPU/GPU = composition; Buffer Stuffing; Display HAL), SF's display frames (GPU-
#               composited count), SF/RenderEngine/home slices >= 4 ms and CPU per process over the drag, one "verdict"
#               (the layer that owns the misses) and a per-frame CSV. From the --latency data alone, each missed vsync is
#               "late" (home's buffer not GPU-done 2 ms before it: the shell's layout/paint/render) or "held" (it was ready,
#               the display showed it later: downstream of the shell - SF, a transaction, the display).
#   WWR_APPS="kate dolphin calc" (default) | any subset;  WWR_REC=0 skips the record pass;  WWR_TRACE=0 no perfetto
#   WWR_DEADLINE_S (default 250): a gesture that can't finish by then isn't started ("FAIL budget: ... not measured")
#               and the page calls answer at once past it, so a FAIL lands with its clean-up inside the queue's 300 s
#               (11-10 01:09: kate alone took ~280 s - ~95 s a gesture with its traces and recording - then the
#               runner's kill; the default three apps never fit). Queue one app per job: WWR_APPS=kate.
#   load        any other process busy for over half the drag (CPU over the drag, from the trace) is named on the
#               FAIL line: 11-10 every kate drag ran beside a Broforce left running (1.0-2.5 cores and its GPU work).
# Exit: 0 PASS; 1 FAIL; 3 not now (a real touch, busy, folded, a game up); 5 can't run.
set -uo pipefail
# WWR_HERE: the tools/phone/verify to use when this file runs from a copy outside a checkout (a check queued before
# its commit ships: the copy runs against the verify checkout's libraries, and waits for no APK ship).
here=${WWR_HERE:-$(cd "$(dirname "$0")" && pwd)}; T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/ww-resize-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
APPS=${WWR_APPS:-"kate dolphin calc"}
REC=${WWR_REC:-1}
TRACE=${WWR_TRACE:-1}
# WWR_DIAGNOSTIC_ONLY=1: no timed/recording passes; WWR_GESTURES=corner for one short capture.
DIAG_ONLY=${WWR_DIAGNOSTIC_ONLY:-0}
GESTURES=${WWR_GESTURES:-"edge corner"}
[ "$DIAG_ONLY" = 1 ] && { TRACE=0; REC=0; }
CALC=${TEST_APP:-com.oneplus.calculator}
sh_() { "$A" shell "su -c '$*'" </dev/null 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
rs() { printf '%s\n' "$1" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '\''/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}'\'' /proc/interrupts"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
fail=0
bad() { log "FAIL $*"; fail=1; }
# The steps' deadline (ww-lib.sh's WW_DEADLINE: page calls answer "ERR deadline" past it); a gesture costs ~GEST_S.
WW_DEADLINE=${WWR_DEADLINE_S:-250}
export CDP_TIMEOUT_S=${CDP_TIMEOUT_S:-20}
# 11-10: was 60 + 30 (two pushes and two pulls a gesture, attribution after the KWin wait); now ~25 + 10 - the
# "time:" line each gesture logs is the measure to set this from.
GEST_S=$(( 40 + 10 * REC ))
[ "$DIAG_ONLY" = 1 ] && GEST_S=20
. "$here/ww-lib.sh"
plaunch() { ev "importShim('./state.ts').then(m=>m.launch('$1')).then(()=>'ok',e=>'ERR '+e)"; }
MINE=""
# restore: every exit path (EXIT trap; the watchdog's hard stop and a TERM/INT end through it). 11-10 08:40-08:56: the
# queue's 300 s kill skipped it - 2 host windows, 5 ww layers and a task left, and window-bench p3's leak checks failed.
# The windows: those it opened ($MINE) and any window of its apps' keys that wasn't up before it started ($BEFORE0) - a
# launch whose window came after the poll gave up is closed too - in ONE page call with a short CDP clock.
BEFORE0=""; KEYS=""
restore() {
  local w ids
  [ "${RESTORED:-0}" = 1 ] && return 0; RESTORED=1
  WW_DEADLINE=$((SECONDS + 40))   # the clean-up's own calls, past the steps' deadline
  [ -n "${WDOG:-}" ] && kill "$WDOG" 2>/dev/null
  ids=$(for w in $MINE; do echo "${w#w}"; done; [ -n "$KEYS" ] && for k in $KEYS; do comm -13 <(echo "$BEFORE0") <(CDP_TIMEOUT_S=8 wwids "$k") | sed 's/^w//'; done)
  ids=$(echo $ids | tr ' ' '\n' | sort -u | grep . | paste -sd, -)
  [ -n "$ids" ] && CDP_TIMEOUT_S=8 ev "importShim('./bridge.ts').then(b=>Promise.all([$ids].map(i=>b.powos.webwindows.close(i)))).then(()=>'ok',e=>'ERR '+e)" >/dev/null 2>&1
  MINE=""
  case " $APPS " in *" kate "*) [ "${KATE_MINE:-0}" = 1 ] && us "pkill -x kate" ;; esac
  case " $APPS " in *" dolphin "*) [ "${DOLPHIN_MINE:-0}" = 1 ] && us "pkill -x dolphin" ;; esac
  [ "${CALC_MINE:-0}" = 1 ] && sh_ "am force-stop $CALC"
  [ -n "${LOGPID:-}" ] && kill "$LOGPID" 2>/dev/null
  if [ "${OVERRIDES_SAVED:-0}" = 1 ]; then
    sh_ "setprop debug.powos.ww_drag_round \"$PREV_DR\""
    [ "$(sh_ "getprop debug.powos.ww_drag_round")" = "$PREV_DR" ] || bad "restore corner property"
    r=$(CDP_TIMEOUT_S=8 ev "globalThis.__wwResizeProbe?.stop();$RESTORE_GLASS;typeof globalThis.__glassDragOff+':'+String(globalThis.__glassDragOff)")
    [ "$r" = "$PREV_GP" ] || bad "restore glass override: $r (wanted $PREV_GP)"
  fi
  true
}
. "$here/window-lock.sh"
window_lock ww-resize.sh 120
log "time: window lock after ${SECONDS} s"   # 11-10 calc job: 207 s gone before its first gesture, nothing said where
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
trap 'exit 1' TERM INT
# The hard stop (window-bench's watchdog): at WWR_HARD_S (275) from the start, kill the running call with all its
# descendants, then USR1: a FAIL naming the step, and exit through the EXIT trap's restore - never the queue's 300 s
# kill. 11-10 08:41:45: a bare `wait` (for the attribution) also waited for the logcat reader, forever; the 250 s
# deadline is checked only between steps, so nothing ended it.
STEP=setup
hard_stop() { trap - USR1; bad "hard deadline: ${WWR_HARD_S:-275} s reached in step '$STEP' - stopped, windows closed"; exit 1; }
trap hard_stop USR1
( sleep $(( ${WWR_HARD_S:-275} - SECONDS )); me=$(exec sh -c 'echo $PPID')
  k=$(pgrep -P $$ | grep -vx "$me"); all=$k; while [ -n "$k" ]; do k=$(for c in $k; do pgrep -P "$c"; done); all="$all $k"; done
  kill $all; kill -USR1 $$ ) >/dev/null 2>&1 &
WDOG=$!
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { log "STOP: a real touch at $1 - restoring"; exit 3; }; }

read -r screen < <("$T/idle.sh")
case "$screen" in *screen=Awake*) ;; *) log "SKIP screen not on ($screen)"; exit 3 ;; esac
sh_ "dumpsys device_state" | awk '/mCommittedState=.*OPENED/{f=1} END{exit !f}' || { log "SKIP folded (needs the inner screen)"; exit 3; }
# Home first (a check before this one may have left another app in front: home's page then didn't answer, 11-07).
sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME" >/dev/null
for i in $(seq 1 10); do
  full=$(hcall webwindows.list "[]" "l=>'ok '+l.filter(w=>w.state==='full').map(w=>w.key).join(' ')")
  case $full in ok*) break ;; esac; sleep 2
done
case $full in ok*) full=${full#ok} full=${full# } ;; *) log "SKIP home's bridge: $full"; exit 3 ;; esac
[ -z "$full" ] || { log "SKIP a full-screen window is up ($full: a game left running) - not touched"; exit 3; }
# RJ2 A/B (nativeglass.ts dragPause): WWR_GLASS_PAUSE=0 keeps home's blur regions through the drag, as before it.
GP=${WWR_GLASS_PAUSE:-1}; DR=${WWR_DRAG_ROUND:-0}
case "$GP:$DR" in 0:0|0:1|1:0|1:1) ;; *) bad "invalid resize switches"; exit 1 ;; esac
PREV_DR=$(sh_ "getprop debug.powos.ww_drag_round") || { bad "cannot read corner property"; exit 1; }
case "$PREV_DR" in ''|0|1) ;; *) bad "unexpected previous corner override: $PREV_DR"; exit 1 ;; esac
PREV_GP=$(ev "typeof globalThis.__glassDragOff+':'+String(globalThis.__glassDragOff)")
case "$PREV_GP" in
  undefined:undefined) RESTORE_GLASS='delete globalThis.__glassDragOff' ;;
  boolean:true) RESTORE_GLASS='globalThis.__glassDragOff=true' ;;
  boolean:false) RESTORE_GLASS='globalThis.__glassDragOff=false' ;;
  *) bad "cannot save glass override: $PREV_GP"; exit 1 ;;
esac
OVERRIDES_SAVED=1
want=$([ "$GP" = 0 ] && echo true || echo false)
effective_gp=$(ev "globalThis.__glassDragOff=$want;String(globalThis.__glassDragOff)")
sh_ "setprop debug.powos.ww_drag_round $DR" || { bad "setprop failed"; exit 1; }
effective_dr=$(sh_ "getprop debug.powos.ww_drag_round")
printf 'requested round=%s pause=%s; effective property=%s glassDragOff=%s; previous property=%s glass=%s\n' "$DR" "$GP" "$effective_dr" "$effective_gp" "$PREV_DR" "$PREV_GP" | tee "$OUT/settings.txt"
[ "$effective_dr" = "$DR" ] && [ "$effective_gp" = "$want" ] || { bad "switch readback mismatch (inconclusive A/B)"; exit 1; }
sleep 1
"$A" shell "logcat -v time -s PowosWebWindows:I Andromarchy:I PowosShell:I" > "$OUT/logcat.txt" 2>/dev/null &
LOGPID=$!

# The SurfaceFlinger layer named <regex> (its name as --latency takes it, "name#id"), the newest one.
layer() { sh_ "dumpsys SurfaceFlinger --list" | sed -nE 's|^RequestedLayerState[{]('"$1"'[^{}]*#[0-9]+)( parentId.*)?[}]$|\1|p' | tail -1; }
# frames <file of --latency output>: "<presented> <missed vsyncs> <longest gap in motion, ms> <late> <held>" (late/held:
# each missed vsync, home's buffer not yet GPU-done 2 ms before it / done and waiting) - gaps over 100 ms are
# idle (nothing changed on screen, no frame needed), neither missed nor a hitch. (11-08: the old third field was the
# longest gap of all, idle ones too - "max 884 ms", "max 1251 ms" read as ~1 s hitches; they were the swipe's
# start/end with nothing to draw.)
frames() { python3 - "$1" <<'PY'
import sys
L=[l.split() for l in open(sys.argv[1]) if l.strip()]
if not L: print("0 0 0 0 0"); sys.exit()
p=int(L[0][0]) or 8333333
# rows: (queued/desired, presented, GPU-done), in present order
a=sorted((tuple(map(int,r)) for r in L[1:] if len(r)==3 and 0<int(r[1])<(1<<62)),key=lambda r:r[1])
miss=0; mx=0; late=0; held=0
for x,y in zip(a,a[1:]):
    g=y[1]-x[1]
    if g<100e6:
        k=max(0,round(g/p)-1); miss+=k; mx=max(mx,g)
        for j in range(1,k+1):
            if y[2] < x[1]+j*p-2e6: held+=1
            else: late+=1
print(len(a), miss, round(mx/1e6,1), late, held)
PY
}
# The window under test alone where its zones are: at the work area's bottom right (its east and south-east zones off
# every other window - 11-08 16:52, Steam's window covered Kate's, Dolphin's and Calculator's east zones: RZ7 passed
# each press on to Steam (raised it, then resized STEAM from its bottom edge in "kate corner"), so every stats line
# measured another window or none). "ok" or why not.
wwclear() { ev "importShim('./ui/webwindows.tsx').then(m=>{const a=m.workArea(),W=Math.round((a.right-a.left)*0.5),H=Math.round((a.bottom-a.top)*0.5);m.placeWindow(${1#w},{x:a.right-W-56,y:a.bottom-H-64,w:W,h:H});return 'ok'},e=>'ERR '+e)"; }
# wwhit <w-id> <selector> <x> <y>: "ok" when a press at x,y (device px) is that window's zone as RZ7 decides it: the
# top element is in the zone and no other window's frame is under it; else what takes the press.
wwhit() { wwel "$1" "e=>{const d=devicePixelRatio,x=$3/d,y=$4/d,z=e.querySelector('$2'),l=document.elementsFromPoint(x,y);if(!z||!l.length)return 'nothing at '+x+','+y;if(!z.contains(l[0]))return 'top is '+l[0].tagName+'.'+String(l[0].className).split(' ')[0];const u=l.find(el=>!e.contains(el)),o=u&&u.closest('.webwindow[data-wwid]');return o?'window w'+o.dataset.wwid+' under it (RZ7 passes the press on)':'ok'}"; }
# kwin_since <line count>: KWin's frame lines after that many lines of its log.
KLOG=/run/powos-app/hyprland.log
klines() { rs "wc -l < $KLOG" | tail -1; }
kwin_since() { rs "tail -n +$(( $1 + 1 )) $KLOG | grep -aE 'window task .* (frames|resized):'"; }

# perfetto around one way (window-rec.sh's sources, the SF frame timeline among them); trace_off pulls it to $1.
TCFG=$OUT/trace.cfg
printf '%s\n' 'buffers { size_kb: 32768 fill_policy: RING_BUFFER }' 'buffers { size_kb: 4096 fill_policy: DISCARD }' \
  'data_sources { config { name: "linux.ftrace" ftrace_config { ftrace_events: "sched/sched_switch" ftrace_events: "sched/sched_wakeup" ftrace_events: "power/cpu_frequency" atrace_categories: "gfx" atrace_categories: "view" atrace_categories: "webview" atrace_categories: "input" atrace_apps: "com.powos.app" } } }' \
  'data_sources { config { name: "android.surfaceflinger.frametimeline" } }' \
  'data_sources { config { name: "track_event" track_event_config { enabled_categories: "cc" enabled_categories: "viz" enabled_categories: "gpu" enabled_categories: "blink" enabled_categories: "skia" enabled_categories: "benchmark" enabled_categories: "disabled-by-default-cc.debug" disabled_categories: "*" } } }' \
  'data_sources { config { name: "linux.process_stats" target_buffer: 1 process_stats_config { scan_all_processes_on_start: true } } }' \
  'duration_ms: 10000' > "$TCFG"
# 11-10 speed (a gesture took ~90 s): the config goes to the phone ONCE, through adb shell's stdin (an adb.sh push is a
# throwaway container, ~6 s each, two a gesture); the trace comes back gzip'd over exec-out (a pull was ~6 s of
# container plus 7-9 MB at ~2 MB/s; gzip -1 makes it ~1/3), and the stop waits for perfetto to exit, not 1.2 s.
# track_event: WebView's own Chromium slices (cc raster, viz draw, blink paint) - the "webview" atrace category gave
# none inside WebViewFunctor::drawGl (11-10 0639 trace: 0 descendants), so which work drawGl waits on was unnamed.
cfg_sent=0
trace_on() { [ "$TRACE" = 1 ] || return 0
  [ "$cfg_sent" = 1 ] || { "$A" shell "su -c 'cat > /data/local/tmp/wwr-trace.cfg'" < "$TCFG" >/dev/null 2>&1; cfg_sent=1; }
  sh_ "rm -f /data/misc/perfetto-traces/wwr.pftrace; perfetto --txt -c /data/local/tmp/wwr-trace.cfg -o /data/misc/perfetto-traces/wwr.pftrace --background" >/dev/null; sleep 0.4; }
trace_off() { [ "$TRACE" = 1 ] || return 0
  sh_ "pkill -INT -f wwr.pftrace; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do pgrep -f wwr.pftrace >/dev/null || break; sleep 0.1; done"
  "$A" exec-out "su -c 'gzip -1 -c /data/misc/perfetto-traces/wwr.pftrace; rm -f /data/misc/perfetto-traces/wwr.pftrace'" 2>/dev/null | gunzip > "$1" 2>/dev/null
  [ -s "$1" ] || rm -f "$1"; }
# attrib <tag>: resize-trace.py's lines for that way's trace (verdict first), the CSV beside it.
attrib() { [ -s "$OUT/$1.pftrace" ] || { echo "verdict: no trace"; return; }
  uvx -q --with perfetto python3 "$here/resize-trace.py" "$OUT/$1.pftrace" "$OUT/$1-frames.csv" 2>&1 | tail -8; }

# One way of a drag: from $1,$2 to $3,$4, the shell's and the content's layers' frames on the display.
way() {
  local x1=$1 y1=$2 x2=$3 y2=$4 tag=$5
  sh_ "dumpsys SurfaceFlinger --latency-clear \"$HL\"; dumpsys SurfaceFlinger --latency-clear \"$CL\""
  trace_on
  sh_ "input swipe $x1 $y1 $x2 $y2 700"
  trace_off "$OUT/$tag.pftrace"
  sh_ "dumpsys SurfaceFlinger --latency \"$HL\"" > "$OUT/$tag-home.lat"
  sh_ "dumpsys SurfaceFlinger --latency \"$CL\"" > "$OUT/$tag-content.lat"
}

# cpu_load <app> <tag>: the processes outside the shell's own pipeline busy for over half of either way's drag
# (resize-trace.py's "CPU over the drag (D ms): name ms, ..." lines in summary.txt), "name N ms of D ms; ..." or "".
cpu_load() { grep -h "^$2 .* trace: CPU over the drag" "$OUT/summary.txt" 2>/dev/null | python3 -c '
import re, sys
own = re.compile(r"com\.powos\.app|surfaceflinger|webview|system_server|app_process|logd|kwin|Xwayland|perfetto|traced|"
                 r"composer|allocator|android\.hardware|" + re.escape(sys.argv[1]), re.I)
out = []
for l in sys.stdin:
    m = re.search(r"CPU over the drag \((\d+) ms\): (.*)", l)
    if not m: continue
    d = int(m.group(1))
    for part in m.group(2).split(", "):
        name, _, ms = part.rpartition(" ")
        if ms.isdigit() and int(ms) * 2 > d and not own.search(name): out.append(f"{name} {ms} ms of {d} ms")
print("; ".join(dict.fromkeys(out)))' "$1"; }

# diag_device_cmd <token> <x1 y1 x2 y2>: the one device command string (adb shell -> su -c), so the offline test
# runs exactly what the phone gets. Watcher matches the quote-free <token>_ACTIVE marker (11-10 22:59/23:03: 159 and
# 146 active JSON records, yet no match - the JSON-quoted pattern never fired on the device shell).
diag_device_cmd() {
  local token=$1 x1=$2 y1=$3 x2=$4 y2=$5 first_match
  first_match=$(cat "$here/resize-first-match.sh")
  printf '%s' "su -c '$first_match
    ( resize_first_match \"$token\" &&
    { sleep 0.15; echo WWR_BEGIN \$(date +%s%3N); echo WWR_PROP \$(getprop debug.powos.ww_drag_round);
      echo WWR_SF_BEGIN; dumpsys SurfaceFlinger; echo WWR_SF_END;
      echo WWR_PROP \$(getprop debug.powos.ww_drag_round); echo WWR_END \$(date +%s%3N); } || echo WWR_ERROR no-confirmed-resize ) &
    watcher=\$!; sleep 0.2; input swipe $x1 $y1 $x2 $y2 3000; wait \${watcher}; sleep 0.3
    logcat -d -v raw -s PowosShell:I | grep \"$token\"
    '"
}
# Separate slow diagnostic replay: device-side log observer waits for confirmed page resize,
# captures SF with device wall timestamps, then validator requires the SAME resize around the entire dump.
# No host sleep guesses; no screenrecord/perfetto during this diagnostic. Never performance evidence.
diagnostic() {
  local tag=$1 x1=$2 y1=$3 x2=$4 y2=$5 token js result
  chk "$tag before diagnostic"
  # Recheck after installing the observer too: transport latency or prior passes may move the zone.
  hit=$(wwhit "$id" "$zone" "$x1" "$y1")
  [ "$hit" = ok ] || { bad "$tag INCONCLUSIVE: unsafe diagnostic zone: $hit"; return; }
  token="WWR_${n}_${SECONDS}_$$"
  js=$(sed "s/TOKEN/\"$token\"/;s/WINDOW_ID/$n/" "$here/resize-state.js")
  [ "$(ev "$js")" = ok ] || { bad "$tag INCONCLUSIVE: cannot install resize observer"; return; }
  hit=$(wwhit "$id" "$zone" "$x1" "$y1")
  [ "$hit" = ok ] || { ev "globalThis.__wwResizeProbe?.stop();'ok'" >/dev/null; bad "$tag INCONCLUSIVE: zone changed: $hit"; return; }
  DIAGNOSTICS=$(( ${DIAGNOSTICS:-0} + 1 ))
  # A bounded device-side watcher, already listening before input starts. The token is unique;
  # logcat's backlog cannot satisfy this job. Timeout and missing/bracketing state fail closed.
  "$A" shell "$(diag_device_cmd "$token" "$x1" "$y1" "$x2" "$y2")" </dev/null > "$OUT/$tag-diagnostic.txt" 2> "$OUT/$tag-diagnostic.stderr"
  # Never blindly swipe back from an arithmetic endpoint; snap/min-size may put another window there.
  chk "$tag after diagnostic"
  ev "globalThis.__wwResizeProbe?.stop();'ok'" >/dev/null
  result=$(python3 "$here/resize-state.py" "$OUT/$tag-diagnostic.txt" "$token" "$n" "$DR" "$GP")
  local rc=$?
  echo "$result" | tee -a "$OUT/summary.txt"
  [ "$rc" = 0 ] || bad "$tag $result"
}

# record <x1 y1 x2 y2> <tag> <sample l t r b, device px>: the gesture under screenrecord, blank frames counted.
record() {
  local x1=$1 y1=$2 x2=$3 y2=$4 tag=$5 sl=$6 st=$7 sr=$8 sb=$9
  sh_ "rm -f /data/local/tmp/wwr.mp4"
  # 8 Mbit/s (was 30): the check reads a 96 px wide gray crop; the file comes back over exec-out, not a pull (11-10).
  "$A" shell "su -c 'screenrecord --bit-rate 8000000 --time-limit 3 /data/local/tmp/wwr.mp4'" >/dev/null 2>&1 &
  local rp=$!
  sleep 0.6
  # Recording has no composition probe: it changes SF's outputs, and is not the measured gesture.
  sh_ "input swipe $x1 $y1 $x2 $y2 700; sleep 0.25; input swipe $x2 $y2 $x1 $y1 700"
  wait "$rp"
  "$A" exec-out "su -c 'cat /data/local/tmp/wwr.mp4; rm -f /data/local/tmp/wwr.mp4'" > "$OUT/$tag.mp4" 2>/dev/null
  [ -s "$OUT/$tag.mp4" ] || { echo "no recording"; return; }
  python3 - "$OUT/$tag.mp4" "$sl" "$st" "$sr" "$sb" "$SW" <<'PY'
import subprocess, sys, json
f, l, t, r, b, sw = sys.argv[1], *map(int, sys.argv[2:])
pr = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                                "-of", "json", f], capture_output=True, text=True).stdout or "{}")
vw = pr.get("streams", [{}])[0].get("width", 0)
if not vw: print("no video"); sys.exit()
k = vw / sw
cl, ct, cw, ch = int(l * k), int(t * k), max(8, int((r - l) * k)), max(8, int((b - t) * k))
W = 96; H = max(8, int(ch * W / cw))
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-vf", f"crop={cw}:{ch}:{cl}:{ct},scale={W}:{H},format=gray",
                      "-fps_mode", "passthrough", "-f", "rawvideo", "-"], capture_output=True)
err = raw.stderr.decode(errors="replace").strip().splitlines(); raw = raw.stdout
n = W * H; fr = [raw[i:i + n] for i in range(0, len(raw) - n + 1, n)]
# Its reason with it (11-10: ffmpeg 9 had dropped -vsync - "no frames" on every run, nothing said why).
if not fr: print(f"no frames: crop {cw}x{ch}+{cl}+{ct} of {vw}x{pr['streams'][0].get('height', '?')}: " + (err[-1][:160] if err else "ffmpeg gave no output")); sys.exit()
ref = fr[0]
def stats(px):
    m = sum(px) / n; sd = (sum((v - m) ** 2 for v in px) / n) ** .5
    return m, sd, sum(1 for v in px if v < 10) / n
rm, rsd, rblack = stats(ref)
blank = changed = 0; worst = 0.0
for i, px in enumerate(fr[1:], 1):
    m, sd, black = stats(px)
    diff = sum(1 for a, c in zip(px, ref) if abs(a - c) > 48) / n
    worst = max(worst, diff)
    if diff > 0.25: changed += 1
    if (diff > 0.5 and sd < 6 and rsd >= 6) or (black > 0.5 and rblack < 0.2): blank += 1
print(f"{len(fr)} frames, {blank} blank, {changed} changed >25%, worst diff {worst*100:.0f}%")
PY
}

cat "$OUT/settings.txt" > "$OUT/summary.txt"
SW=$(sh_ "wm size" | grep -oE '[0-9]+x[0-9]+' | tail -1 | cut -dx -f1)
for app in $APPS; do
  [ $((SECONDS + 20 + GEST_S)) -gt "$WW_DEADLINE" ] && { bad "budget: $app not measured - ${SECONDS}s in, the deadline is ${WW_DEADLINE}s (queue one app a job: WWR_APPS=$app)"; continue; }
  case $app in
    kate) key=l:org.kde.kate; [ "$(us 'pgrep -xc kate' | tail -1)" = 0 ] && KATE_MINE=1 ;;
    dolphin) key=l:org.kde.dolphin; [ "$(us 'pgrep -xc dolphin' | tail -1)" = 0 ] && DOLPHIN_MINE=1 ;;
    calc) key=$(ev "importShim('./state.ts').then(m=>(m.apps.value.find(a=>String(a.key).startsWith('a:$CALC'))||{}).key||'')")
      [ -n "$key" ] || { log "SKIP calc: no drawer key for $CALC"; continue; }
      [ -z "$(sh_ "pidof $CALC")" ] && CALC_MINE=1 ;;
    *) log "unknown app $app"; continue ;;
  esac
  before=$(wwids); [ "${B0SET:-0}" = 1 ] || { BEFORE0=$before; B0SET=1; }; KEYS="$KEYS $key"; STEP="$app open"
  r=$(plaunch "$key"); [ "$r" = ok ] || { bad "$app: launch $key: $r"; continue; }
  id=$(wwnew 30 "$before" | tail -1)
  [ -n "$id" ] || id=$(hcall webwindows.list "[]" "l=>(l.find(w=>w.key==='$key'&&w.state==='floating')||{id:''}).id" | sed 's/^/w/')
  [ "$id" != w ] && [ -n "$id" ] || { bad "$app: no web window within 30 s"; continue; }
  case " $before " in *" $id "*) log "SKIP $app: $id already belongs to user; not moved or resized"; continue ;; *) MINE="$MINE $id" ;; esac
  for i in $(seq 1 15); do [ "$(wwel "$id" "e=>e.querySelector('.webwindow-body.live')?'live':'no'")" = live ] && break; sleep 1; done
  sleep 2; chk "$app open"
  n=${id#w}
  HL=$(layer 'com\.powos\.app/andro\.marchy\.HomeShell')
  case $app in calc) CL=$(layer "${CALC//./\\.}/") ;; *) CL=$(layer "\\[BBQ\\] powos-ww-$n-linux") ;; esac
  c=$(wwclear "$id"); [ "$c" = ok ] || { bad "$app: placing $id clear of the others: $c"; continue; }
  sleep 1
  setup_s=$SECONDS
  log "== $app: window $id ($key), home layer '$HL', content layer '$CL', body $(wwbody "$id")"
  for g in $GESTURES; do
    case $g in edge) zone=.ww-edge-e; dx=-300; dy=0 ;; corner) zone=.ww-edge-se; dx=-300; dy=-200 ;; *) bad "unknown gesture $g"; continue ;; esac
    if [ $((SECONDS + GEST_S)) -gt "$WW_DEADLINE" ]; then
      bad "budget: $app $g not measured - ${SECONDS}s in, a gesture takes ~${GEST_S}s, the deadline is ${WW_DEADLINE}s (queue one app a job: WWR_APPS=$app)"
      continue
    fi
    read -r px py <<<"$(wwpt "$id" "$zone")"
    [ -n "${py:-}" ] || { bad "$app $g: no $zone on screen"; continue; }
    hit=$(wwhit "$id" "$zone" "$px" "$py")
    [ "$hit" = ok ] || { log "SKIP $app $g: no safe resize zone: $hit; other windows untouched"; continue; }
    if [ "$DIAG_ONLY" = 1 ]; then
      diagnostic "$app-$g" "$px" "$py" $((px + dx)) $((py + dy))
      chk "$app $g diagnostic"
      continue
    fi
    read -r bl bt br bb <<<"$(wwbody "$id")"
    k0=$(klines); g0=$SECONDS; STEP="$app $g"
    sh_ "dumpsys gfxinfo com.powos.app reset" >/dev/null
    way "$px" "$py" $((px + dx)) $((py + dy)) "$app-$g-in"
    sleep 0.25
    # The way back from where the zone IS now (a snap to a tile size or a min size moves it off the finger's end).
    read -r b2l b2t b2r b2b <<<"$(wwbody "$id")"
    read -r qx qy <<<"$(wwpt "$id" "$zone")"
    way "${qx:-$((px + dx))}" "${qy:-$((py + dy))}" "$px" "$py" "$app-$g-out"
    # The drag resized THIS window: its body's size followed the finger at least half its way.
    ow=$(( (br - bl) - (${b2r:-$br} - ${b2l:-$bl}) )); oh=$(( (bb - bt) - (${b2b:-$bb} - ${b2t:-$bt}) ))
    [ $((ow * 2)) -ge $((-dx)) ] && [ $((oh * 2)) -ge $((-dy)) ] || bad "$app $g: the drag didn't resize it (body $bl $bt $br $bb -> ${b2l:-?} ${b2t:-?} ${b2r:-?} ${b2b:-?})"
    # The traces' attribution runs on the Mac while KWin's next frame line comes (11-10: it ran after the wait, serially).
    gend=$SECONDS
    ap=""; for w_ in in out; do attrib "$app-$g-$w_" > "$OUT/.attrib-$w_" & ap="$ap $!"; done
    # KWin writes its frame line every 5 s: one covering the gesture's end is out by then.
    wait_s=$([ "$app" = calc ] && echo 1.5 || echo 5.2); sleep "$(python3 -c "import sys; print(max(0.0, float(sys.argv[1]) - (int(sys.argv[2]) - int(sys.argv[3]))))" "$wait_s" "$SECONDS" "$gend")"; chk "$app $g"
    gfx=$(sh_ "dumpsys gfxinfo com.powos.app")
    jank=$(echo "$gfx" | grep -m1 'Janky frames:' | sed -E 's/.*Janky frames: ([0-9]+) \(([0-9.]+)%\).*/\1 (\2%)/')
    p90=$(echo "$gfx" | grep -m1 '90th percentile' | grep -oE '[0-9]+ms'); p99=$(echo "$gfx" | grep -m1 '99th percentile' | grep -oE '[0-9]+ms')
    read -r hi mi xi li di <<<"$(frames "$OUT/$app-$g-in-home.lat")"; read -r ho mo xo lo do_ <<<"$(frames "$OUT/$app-$g-out-home.lat")"
    read -r ci _ cxi <<<"$(frames "$OUT/$app-$g-in-content.lat")"; read -r co _ cxo <<<"$(frames "$OUT/$app-$g-out-content.lat")"
    kl=$(kwin_since "$k0"); kr=$(echo "$kl" | grep -oE 'resized: .*' | tail -2 | tr '\n' ';')
    kw=$(echo "$kl" | sed -nE 's/.*frames: last 5 s ([0-9]+) commits, ([0-9]+) drawn.*/\1 \2/p' | awk '{c+=$1; d+=$2} END{print c+0, d+0}')
    hostl=$(grep -aE "window $n: (resize:|body outgrew)" "$OUT/logcat.txt" | tail -2 | sed -E 's/.*(window [0-9]+: )/\1/' | tr '\n' ';')
    line="$app $g: shell in $hi frames $mi missed ($li late, $di held; longest ${xi} ms), out $ho frames $mo missed ($lo late, $do_ held; longest ${xo} ms); gfxinfo janky ${jank:-?} p90 ${p90:-?} p99 ${p99:-?} | content in $ci frames (max gap ${cxi} ms), out $co (max gap ${cxo} ms) | kwin commits/drawn $kw, ${kr:-no resize line} | host $hostl"
    log "$line"; echo "$line" >> "$OUT/summary.txt"
    wait $ap   # these two only: a bare wait also waits for the logcat reader (forever, 11-10 08:41)
    for w_ in in out; do cat "$OUT/.attrib-$w_" | sed "s/^/$app $g $w_ trace: /" | tee -a "$OUT/summary.txt" >> "$OUT/log.txt"; done
    grep -h "^$app $g .* trace: verdict" "$OUT/summary.txt" | sed 's/^/  /'
    load=$(cpu_load "$app" "$app $g")
    [ $((mi + mo)) -gt 0 ] && bad "$app $g: $((mi + mo)) missed shell vsyncs while the finger moved (want 0)${load:+ - load: $load}"
    [ "$app" != calc ] && read -r kc kd <<<"$kw" && [ "${kc:-0}" -gt 0 ] && [ $((kc - kd)) -gt $((kc / 20 + 1)) ] && bad "$app $g: KWin drew $kd of $kc commits"
    if [ "$REC" = 1 ] && [ $((SECONDS + 30)) -gt "$WW_DEADLINE" ]; then
      bad "budget: $app $g record pass not run - ${SECONDS}s in, the deadline is ${WW_DEADLINE}s"
    elif [ "$REC" = 1 ]; then
      sleep 0.5
      read -r px py <<<"$(wwpt "$id" "$zone")"; read -r bl bt br bb <<<"$(wwbody "$id")"
      # The part of the body inside the window through the whole drag (it shrinks by dx, dy first), inset 24 px.
      rec=$(record "$px" "$py" $((px + dx)) $((py + dy)) "$app-$g" $((bl + 24)) $((bt + 24)) $((br + dx - 24)) $((bb + dy - 24)))
      log "$app $g record: $rec"; echo "$app $g record: $rec" >> "$OUT/summary.txt"
      case $rec in *" 0 blank"*) ;; *blank*) bad "$app $g: blank frames in the window ($rec)" ;; esac
      chk "$app $g record"
    fi
    if [ $((SECONDS + 15)) -gt "$WW_DEADLINE" ]; then
      bad "$app $g INCONCLUSIVE: no diagnostic budget"; continue
    fi
    read -r px py <<<"$(wwpt "$id" "$zone")"
    [ -n "${px:-}" ] && [ -n "${py:-}" ] || { bad "$app $g INCONCLUSIVE: missing zone"; continue; }
    diagnostic "$app-$g" "$px" "$py" $((px + dx)) $((py + dy))
    chk "$app $g diagnostic"
    # The step's own time (11-10: ~90 s a gesture - two adb.sh pushes, two 7-9 MB pulls, the attribution after the
    # wait; the user's bar is a few seconds a step): the drag's two ways, and the whole gesture with its record pass.
    log "time: $app $g ways $((gend - g0)) s, gesture $((SECONDS - g0)) s (setup before the first: ${setup_s:-?} s)"
  done
done
# Closed windows leave no layer behind: each Linux window's content ("powos-ww-N-linux") and its BLAST queue
# ("[BBQ] powos-ww-N-linux") are gone from SurfaceFlinger 3 s after its close (11-07: a consumer stop wedged on its
# event thread kept "[BBQ] powos-ww-1-linux" alive for good, one per closed game window).
[ "${DIAGNOSTICS:-0}" -gt 0 ] || bad "INCONCLUSIVE: no safe diagnostic captured"
LIN=""
for w in $MINE; do case $(wwhost "$w" key) in l:*) LIN="$LIN ${w#w}" ;; esac; done
for w in $MINE; do hcall webwindows.close "[${w#w}]" "v=>String(v)" >/dev/null; done
MINE=""
if [ -n "$LIN" ]; then
  sleep 3
  layers=$(sh_ "dumpsys SurfaceFlinger --list")
  for n in $LIN; do
    left=$(echo "$layers" | grep -cE "powos-ww-$n-linux#")
    log "closed Linux window w$n: $left of its layers left in SurfaceFlinger"
    [ "$left" = 0 ] || bad "closed Linux window w$n: $left layers left ($(echo "$layers" | grep -E "powos-ww-$n-linux#" | tr '\n' ' '))"
  done
fi
grep -aE "consumer stop still blocked" "$OUT/logcat.txt" | sed 's/^/stop: /' | tee -a "$OUT/summary.txt"
grep -aE "pacing:" "$OUT/logcat.txt" | tail -4 | sed 's/^/consumer: /' | tee -a "$OUT/summary.txt"
restore
log "summary: $OUT/summary.txt"
[ "$fail" = 0 ] && log PASS
exit "$fail"
