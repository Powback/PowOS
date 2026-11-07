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
# Facts per app/gesture in OUT/summary.txt. FAIL: a missed shell vsync while the finger moves, a blank frame, or a
# commit KWin never drew. Needs the phone unfolded and idle (the runner's window); a full-screen window (a game left
# running) skips the run (exit 3, re-queued) - never touched.
#   WWR_APPS="kate dolphin calc" (default) | any subset;  WWR_REC=0 skips the record pass
# Exit: 0 PASS; 1 FAIL; 3 not now (a real touch, busy, folded, a game up); 5 can't run.
set -uo pipefail
# WWR_HERE: the tools/phone/verify to use when this file runs from a copy outside a checkout (a check queued before
# its commit ships: the copy runs against the verify checkout's libraries, and waits for no APK ship).
here=${WWR_HERE:-$(cd "$(dirname "$0")" && pwd)}; T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/ww-resize-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
APPS=${WWR_APPS:-"kate dolphin calc"}
REC=${WWR_REC:-1}
CALC=${TEST_APP:-com.oneplus.calculator}
sh_() { "$A" shell "su -c '$*'" </dev/null 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
rs() { printf '%s\n' "$1" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
fail=0
bad() { log "FAIL $*"; fail=1; }
. "$here/ww-lib.sh"
plaunch() { ev "importShim('./state.ts').then(m=>m.launch('$1')).then(()=>'ok',e=>'ERR '+e)"; }
MINE=""
restore() {
  local w
  for w in $MINE; do hcall webwindows.close "[${w#w}]" "v=>String(v)" >/dev/null; done
  case " $APPS " in *" kate "*) [ "${KATE_MINE:-0}" = 1 ] && us "pkill -x kate" ;; esac
  case " $APPS " in *" dolphin "*) [ "${DOLPHIN_MINE:-0}" = 1 ] && us "pkill -x dolphin" ;; esac
  [ "${CALC_MINE:-0}" = 1 ] && sh_ "am force-stop $CALC"
  [ -n "${LOGPID:-}" ] && kill "$LOGPID" 2>/dev/null
  true
}
. "$here/window-lock.sh"
window_lock ww-resize.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { log "STOP: a real touch at $1 - restoring"; exit 3; }; }

read -r screen < <("$T/idle.sh")
case "$screen" in *screen=Awake*) ;; *) log "SKIP screen not on ($screen)"; exit 3 ;; esac
sh_ "dumpsys device_state" | grep -q "mCommittedState=.*OPENED" || { log "SKIP folded (needs the inner screen)"; exit 3; }
# Home first (a check before this one may have left another app in front: home's page then didn't answer, 11-07).
sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME" >/dev/null
for i in $(seq 1 10); do
  full=$(hcall webwindows.list "[]" "l=>'ok '+l.filter(w=>w.state==='full').map(w=>w.key).join(' ')")
  case $full in ok*) break ;; esac; sleep 2
done
case $full in ok*) full=${full#ok} full=${full# } ;; *) log "SKIP home's bridge: $full"; exit 3 ;; esac
[ -z "$full" ] || { log "SKIP a full-screen window is up ($full: a game left running) - not touched"; exit 3; }
sleep 1
"$A" shell "logcat -v time -s PowosWebWindows:I Andromarchy:I PowosShell:I" > "$OUT/logcat.txt" 2>/dev/null &
LOGPID=$!

# The SurfaceFlinger layer named <regex> (its name as --latency takes it, "name#id"), the newest one.
layer() { sh_ "dumpsys SurfaceFlinger --list" | sed -nE 's|^RequestedLayerState[{]('"$1"'[^{}]*#[0-9]+)( parentId.*)?[}]$|\1|p' | tail -1; }
# frames <file of --latency output>: "<presented> <missed vsyncs> <max gap ms>" (gaps over 100 ms: idle, not missed).
frames() { python3 - "$1" <<'PY'
import sys
L=[l.split() for l in open(sys.argv[1]) if l.strip()]
if not L: print("0 0 0"); sys.exit()
p=int(L[0][0]) or 8333333
a=sorted(int(r[1]) for r in L[1:] if len(r)==3 and 0<int(r[1])<(1<<62))
miss=0; mx=0
for x,y in zip(a,a[1:]):
    g=y-x; mx=max(mx,g)
    if g<100e6: miss+=max(0,round(g/p)-1)
print(len(a), miss, round(mx/1e6,1))
PY
}
# kwin_since <line count>: KWin's frame lines after that many lines of its log.
KLOG=/run/powos-app/hyprland.log
klines() { rs "wc -l < $KLOG" | tail -1; }
kwin_since() { rs "tail -n +$(( $1 + 1 )) $KLOG | grep -aE 'window task .* (frames|resized):'"; }

# One way of a drag: from $1,$2 to $3,$4, the shell's and the content's layers' frames on the display.
way() {
  local x1=$1 y1=$2 x2=$3 y2=$4 tag=$5
  sh_ "dumpsys SurfaceFlinger --latency-clear \"$HL\"; dumpsys SurfaceFlinger --latency-clear \"$CL\""
  sh_ "input swipe $x1 $y1 $x2 $y2 700"
  sh_ "dumpsys SurfaceFlinger --latency \"$HL\"" > "$OUT/$tag-home.lat"
  sh_ "dumpsys SurfaceFlinger --latency \"$CL\"" > "$OUT/$tag-content.lat"
}

# record <x1 y1 x2 y2> <tag> <sample l t r b, device px>: the gesture under screenrecord, blank frames counted.
record() {
  local x1=$1 y1=$2 x2=$3 y2=$4 tag=$5 sl=$6 st=$7 sr=$8 sb=$9
  sh_ "rm -f /data/local/tmp/wwr.mp4"
  "$A" shell "su -c 'screenrecord --bit-rate 30000000 --time-limit 4 /data/local/tmp/wwr.mp4'" >/dev/null 2>&1 &
  local rp=$!
  sleep 0.8
  sh_ "input swipe $x1 $y1 $x2 $y2 700"; sleep 0.25; sh_ "input swipe $x2 $y2 $x1 $y1 700"
  wait "$rp"; sleep 0.5
  sh_ "chmod 644 /data/local/tmp/wwr.mp4"
  "$A" pull /data/local/tmp/wwr.mp4 "$OUT/$tag.mp4" >/dev/null 2>&1 || { echo "no recording"; return; }
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
                      "-vsync", "passthrough", "-f", "rawvideo", "-"], capture_output=True).stdout
n = W * H; fr = [raw[i:i + n] for i in range(0, len(raw) - n + 1, n)]
if not fr: print("no frames"); sys.exit()
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

: > "$OUT/summary.txt"
SW=$(sh_ "wm size" | grep -oE '[0-9]+x[0-9]+' | tail -1 | cut -dx -f1)
for app in $APPS; do
  case $app in
    kate) key=l:org.kde.kate; [ "$(us 'pgrep -xc kate' | tail -1)" = 0 ] && KATE_MINE=1 ;;
    dolphin) key=l:org.kde.dolphin; [ "$(us 'pgrep -xc dolphin' | tail -1)" = 0 ] && DOLPHIN_MINE=1 ;;
    calc) key=$(ev "importShim('./state.ts').then(m=>(m.apps.value.find(a=>String(a.key).startsWith('a:$CALC'))||{}).key||'')")
      [ -n "$key" ] || { log "SKIP calc: no drawer key for $CALC"; continue; }
      [ -z "$(sh_ "pidof $CALC")" ] && CALC_MINE=1 ;;
    *) log "unknown app $app"; continue ;;
  esac
  before=$(wwids)
  r=$(plaunch "$key"); [ "$r" = ok ] || { bad "$app: launch $key: $r"; continue; }
  id=$(wwnew 30 "$before" | tail -1)
  [ -n "$id" ] || id=$(hcall webwindows.list "[]" "l=>(l.find(w=>w.key==='$key'&&w.state==='floating')||{id:''}).id" | sed 's/^/w/')
  [ "$id" != w ] && [ -n "$id" ] || { bad "$app: no web window within 30 s"; continue; }
  case " $before " in *" $id "*) ;; *) MINE="$MINE $id" ;; esac
  for i in $(seq 1 15); do [ "$(wwel "$id" "e=>e.querySelector('.webwindow-body.live')?'live':'no'")" = live ] && break; sleep 1; done
  sleep 2; chk "$app open"
  n=${id#w}
  HL=$(layer 'com\.powos\.app/andro\.marchy\.HomeShell')
  case $app in calc) CL=$(layer "${CALC//./\\.}/") ;; *) CL=$(layer "\\[BBQ\\] powos-ww-$n-linux") ;; esac
  log "== $app: window $id ($key), home layer '$HL', content layer '$CL', body $(wwbody "$id")"
  for g in edge corner; do
    case $g in edge) zone=.ww-edge-e; dx=-300; dy=0 ;; corner) zone=.ww-edge-se; dx=-300; dy=-200 ;; esac
    read -r px py <<<"$(wwpt "$id" "$zone")"
    [ -n "${py:-}" ] || { bad "$app $g: no $zone on screen"; continue; }
    read -r bl bt br bb <<<"$(wwbody "$id")"
    k0=$(klines)
    sh_ "dumpsys gfxinfo com.powos.app reset" >/dev/null
    way "$px" "$py" $((px + dx)) $((py + dy)) "$app-$g-in"
    sleep 0.25
    way $((px + dx)) $((py + dy)) "$px" "$py" "$app-$g-out"
    # KWin writes its frame line every 5 s: one covering the gesture's end is out by then.
    [ "$app" = calc ] && sleep 1.5 || sleep 5.2; chk "$app $g"
    gfx=$(sh_ "dumpsys gfxinfo com.powos.app")
    jank=$(echo "$gfx" | grep -m1 'Janky frames:' | sed -E 's/.*Janky frames: ([0-9]+) \(([0-9.]+)%\).*/\1 (\2%)/')
    p90=$(echo "$gfx" | grep -m1 '90th percentile' | grep -oE '[0-9]+ms'); p99=$(echo "$gfx" | grep -m1 '99th percentile' | grep -oE '[0-9]+ms')
    read -r hi mi xi <<<"$(frames "$OUT/$app-$g-in-home.lat")"; read -r ho mo xo <<<"$(frames "$OUT/$app-$g-out-home.lat")"
    read -r ci _ cxi <<<"$(frames "$OUT/$app-$g-in-content.lat")"; read -r co _ cxo <<<"$(frames "$OUT/$app-$g-out-content.lat")"
    kl=$(kwin_since "$k0"); kr=$(echo "$kl" | grep -oE 'resized: .*' | tail -2 | tr '\n' ';')
    kw=$(echo "$kl" | sed -nE 's/.*frames: last 5 s ([0-9]+) commits, ([0-9]+) drawn.*/\1 \2/p' | awk '{c+=$1; d+=$2} END{print c+0, d+0}')
    hostl=$(grep -aE "window $n: (resize:|body outgrew)" "$OUT/logcat.txt" | tail -2 | sed -E 's/.*(window [0-9]+: )/\1/' | tr '\n' ';')
    line="$app $g: shell in $hi frames $mi missed (max ${xi} ms), out $ho frames $mo missed (max ${xo} ms); gfxinfo janky ${jank:-?} p90 ${p90:-?} p99 ${p99:-?} | content in $ci frames (max gap ${cxi} ms), out $co (max gap ${cxo} ms) | kwin commits/drawn $kw, ${kr:-no resize line} | host $hostl"
    log "$line"; echo "$line" >> "$OUT/summary.txt"
    [ $((mi + mo)) -gt 0 ] && bad "$app $g: $((mi + mo)) missed shell vsyncs while the finger moved (want 0)"
    [ "$app" != calc ] && read -r kc kd <<<"$kw" && [ "${kc:-0}" -gt 0 ] && [ $((kc - kd)) -gt $((kc / 20 + 1)) ] && bad "$app $g: KWin drew $kd of $kc commits"
    if [ "$REC" = 1 ]; then
      sleep 0.5
      read -r px py <<<"$(wwpt "$id" "$zone")"; read -r bl bt br bb <<<"$(wwbody "$id")"
      # The part of the body inside the window through the whole drag (it shrinks by dx, dy first), inset 24 px.
      rec=$(record "$px" "$py" $((px + dx)) $((py + dy)) "$app-$g" $((bl + 24)) $((bt + 24)) $((br + dx - 24)) $((bb + dy - 24)))
      log "$app $g record: $rec"; echo "$app $g record: $rec" >> "$OUT/summary.txt"
      case $rec in *" 0 blank"*) ;; *blank*) bad "$app $g: blank frames in the window ($rec)" ;; esac
      sleep 1; chk "$app $g record"
    fi
  done
done
grep -aE "pacing:" "$OUT/logcat.txt" | tail -4 | sed 's/^/consumer: /' | tee -a "$OUT/summary.txt"
log "summary: $OUT/summary.txt"
[ "$fail" = 0 ] && log PASS
exit "$fail"
