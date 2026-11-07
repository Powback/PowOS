#!/bin/bash
# lanes: phone
# game-resize.sh <appid> [window name]: (Mac side; queue it: queue.sh add [--close] <board-task> game-resize.sh <appid>)
# ANY installed Steam game's picture follows its container (board task games-resize-live-to-their-container-portrait-la,
# kwin 0032 = 6.7.5-3.37): the game's X window takes its Android task's shape and size - phone upright -> portrait,
# rotated -> landscape, unfolded -> the inner screen - and the game draws its whole screen, no letterbox/pillarbox.
# bf-resize.sh is this for Broforce (274190). The window: Proton's class steam_app_<appid> (largest visible one), else
# the window named [window name] (default: Steam's name for the game, appmanifest) - bf-fold-phone.sh gamewin.
# Steps (one free window, the user's phone handed over): the game up the way the user starts it (bf-fold-phone.sh
# start: powos-open-task, Steam cold or warm, a frozen one of the user's resumed; GRACE_S=0 - no 130 s wait for the sleep
# grace) -> unfolded (state 3, inner 2268x2440) -> rotated landscape (user_rotation 1) -> folded (state 0, cover
# 2484x1116 landscape) -> cover portrait (user_rotation 0, 1116x2484) -> unfolded again. Each step (board steps G1-G3):
#   G1 the X window's size (xwininfo, bf-fold-phone.sh state geom) IS the screen's (shot.sh) within 1 % per side - the
#      game renders at its container's size, no scaling (an aspect-only match let a half-size window pass);
#   G2 it gets there by itself after the change: polled every ~1 s for SETTLE_S (12) s, the time logged ("settled
#      N s"; Unity maps 314x208 first and goes full screen later), and the window still drawing (xframes count);
#   G3 the game's layer is what SurfaceFlinger composes full screen (bf-onscreen.sh: own task or home's full-screen web
#      window, logged as how=task|web), and no letterbox / pillarbox in the screencap: black bars on BOTH opposite
#      edges, each > 1.5 % of that side and within a third of each other (Proton's fullscreen hack centres a game that
#      renders a smaller / other-shaped mode than its window: Besiege's saved 2268x1600 in a 2268x2440 window). One
#      dark edge alone is the game's art, logged only. BARS=note keeps bars a note (a game whose menu is black-framed).
# Also logged once: the game's own command line's size arguments (unity-screen / unreal's -ResX), from /proc.
# G4 (controller layout per orientation) is pad-fullscreen.sh's.
# Rotation and device state are always put back. Not covered: a floating task's drag-resize (no scripted drag yet).
# Exit 3 = no window / user input. KWIN_MIN default 6.7.5-3.37 (queue kwin-install.sh 6.7.5-3.37 before it).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); P=$here/..; A=$P/adb.sh
APP=${1:-${APP:-}} WIN_NAME=${2:-${WIN_NAME:-}} MIN=${KWIN_MIN:-6.7.5-3.37} NAME=${CHECK_NAME:-game-resize}
case $APP in ""|*[!0-9]*) echo "usage: game-resize.sh <steam appid> [window name]"; exit 2 ;; esac
case "$WIN_NAME" in *[!A-Za-z0-9_.-]*) echo "WIN_NAME: one word (letters, digits, _ . -)"; exit 2 ;; esac
OUT=${OUT:-$HOME/.cache/powos-verify/$NAME-$APP-$(date +%F_%H%M)}; mkdir -p "$OUT"
rot0=$("$A" shell settings get system accelerometer_rotation | tr -d '\r'); urot0=$("$A" shell settings get system user_rotation | tr -d '\r')
restore() { "$A" shell "cmd device_state state reset; settings put system user_rotation ${urot0:-0}; settings put system accelerometer_rotation ${rot0:-1}" >/dev/null 2>&1; }
WL_TRAP='restore'
. "$here/window-lock.sh"; window_lock "$NAME.sh" 120
trap 'restore; [ "${WL_LOCK:-}" ] && rm -rf "$WL_LOCK"' EXIT
log() { echo "$(date +%T) $*" | tee -a "$OUT/run.txt"; }
BF_ADB=$A . "$here/bf-lib.sh"
for f in bf-fold-phone.sh bf-stop.sh bf-lib.sh bf-xframes.py bf-onscreen.sh; do "$A" push "$here/$f" "/data/local/tmp/powos-$f" >/dev/null || { echo "ENV: can't push $f to the phone (a stale /data/local/tmp copy would run instead)"; exit 5; }; done
"$A" shell "su -c 'cd /data/local/tmp && cp powos-bf-fold-phone.sh powos-bf-stop.sh powos-bf-lib.sh powos-bf-xframes.py /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-bf-*'"
ph() { "$A" shell "su -c 'sh /data/powos/powos-run.sh \"APP=$APP WIN_NAME=$WIN_NAME GRACE_S=0 bash /var/tmp/powos-bf-fold-phone.sh $*\"'" | tr -d '\r'; }
irq() { "$A" shell "cat /proc/interrupts" | awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}'; }
I0=$(irq); touched() { [ "$(irq)" != "$I0" ] && { log "user input - stopping"; return 0; }; return 1; }
printf 'v=$(pacman -Q kwin | cut -d" " -f2); echo "$v $(vercmp "$v" %s)"\n' "$MIN" > "$OUT/q.sh"
kv=$("$P/root.sh" "$OUT/q.sh" 2>/dev/null | tail -1 | tr -d '\r'); log "kwin $kv (needs >= $MIN)"
[ "${kv##* }" -ge 0 ] 2>/dev/null || { log "FAIL: KWin ${kv%% *} older than $MIN (queue kwin-install.sh $MIN first)"; exit 1; }

touched && exit 3
pill "${WIN_NAME:-app $APP} up"
r=$(ph start); echo "$r" >> "$OUT/run.txt"; mine=$([[ $r == *mine=1* ]] && echo 1 || echo 0)
stop() { if [ "$mine" = 1 ]; then pill "closing the game"
    log "closed: $("$A" shell "su -c 'sh /data/powos/powos-run.sh \"APP=$APP bash /var/tmp/powos-bf-stop.sh\"'" 2>&1 | tr -d '\r' | tail -1)"
  elif [[ $r == *mine=0* ]]; then log "the user's $WIN_NAME: $(ph refreeze | tail -1)"; fi; }
[[ $r == *"user input"* ]] && { log "user input during the start"; exit 3; }
[[ $r == *FAIL* || $r != *mine=* ]] && { log "FAIL: ${WIN_NAME:-app $APP} didn't come up: $(echo "$r" | grep -m1 FAIL)"; stop; exit 1; }
# Ready: the window drawing before the first probe (a game's own load screen after its window maps - Besiege, 32-bit
# Unity under x86 Proton + FEX, sat on a black 1135x1365 window for minutes), at most READY_S (90) s; logged.
t0=$(date +%s); while [ $(($(date +%s) - t0)) -lt "${READY_S:-90}" ]; do c=$(ph changes 3); [ "${c#changes=}" -ge 3 ] 2>/dev/null && break; touched && { stop; exit 3; }; done
log "ready: $c after $(($(date +%s) - t0)) s; game args: $(ph args | tail -1)"
bars() {  # black rows/columns at each edge of a screencap
  local r c
  r=$(ffmpeg -nostdin -loglevel error -i "$1" -vf "format=gray,scale=1:ih:flags=area" -f rawvideo - 2>/dev/null | od -An -v -tu1 | tr -s ' \n' ' ')
  c=$(ffmpeg -nostdin -loglevel error -i "$1" -vf "format=gray,scale=iw:1:flags=area" -f rawvideo - 2>/dev/null | od -An -v -tu1 | tr -s ' \n' ' ')
  awk -v r="$r" -v c="$c" 'function edge(s, rev,   a, n, i, k) { n = split(s, a, " "); for (k = 0; k < n; k++) {
      i = rev ? n - k : k + 1; if (a[i] > 12) return k }; return n }
    BEGIN { printf "top=%d bottom=%d left=%d right=%d\n", edge(r, 0), edge(r, 1), edge(c, 0), edge(c, 1) }'; }
# boxed "<bars line>" <WxH>: "letterbox-<top>/<bottom>" or "pillarbox-<left>/<right>" when both opposite edges are black
# for > 1.5 % of that side and within a third of each other (a centred smaller picture), else nothing.
boxed() { awk -v s="$1" -v wh="$2" 'BEGIN { split(wh, d, "x"); n = split(s, kv, " "); for (i = 1; i <= n; i++) { split(kv[i], e, "="); b[e[1]] = e[2] + 0 }
    if (d[1] + 0 <= 0 || d[2] + 0 <= 0) exit
    if (pair(b["top"], b["bottom"], d[2])) { printf "letterbox-%d/%d", b["top"], b["bottom"]; exit }
    if (pair(b["left"], b["right"], d[1])) printf "pillarbox-%d/%d", b["left"], b["right"] }
  function pair(a, c, side) { return a * 1000 > side * 15 && c * 1000 > side * 15 && a * 3 >= c * 2 && c * 3 >= a * 2 && a < side / 2 }'; }
fails=0 sizes=
SETTLE_S=${SETTLE_S:-12}
fits() {  # fits <win WxH> <screen WxH>: the same size within 1 % per side (G1: no scaling, not just the same shape)
  awk -v g="$1" -v s="$2" 'BEGIN { split(g, a, "x"); split(s, b, "x"); dw = a[1] - b[1]; dh = a[2] - b[2]
    ok = (b[1] + 0 > 0) && (b[2] + 0 > 0) && (dw * dw * 10000 <= b[1] * b[1]) && (dh * dh * 10000 <= b[2] * b[2]); exit !ok }'; }
probe() {  # probe <label>
  local st g c s wh bad= t0 dt on
  pill "$1: the game's window vs its screen"
  if "$P/shot.sh" "$OUT/$1-0.png" >/dev/null 2>&1; then
    wh=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$OUT/$1-0.png")
  else wh=; fi
  t0=$(date +%s); st=$(ph state); g=$(echo "$st" | grep -o 'geom=[0-9]*x[0-9]*' | cut -d= -f2)
  while [ -n "$wh" ] && ! fits "${g:-0x0}" "$wh" && [ $(($(date +%s) - t0)) -lt "$SETTLE_S" ]; do
    sleep 1; st=$(ph state); g=$(echo "$st" | grep -o 'geom=[0-9]*x[0-9]*' | cut -d= -f2); done
  dt=$(($(date +%s) - t0))
  c=$(ph changes 3)
  on=$("$A" shell sh /data/local/tmp/powos-bf-onscreen.sh | tr -d '\r'); set -- "$1" $on
  if "$P/shot.sh" "$OUT/$1.png" >/dev/null 2>&1; then s=$(bars "$OUT/$1.png"); else s="no screencap"; fi
  box=$(boxed "$s" "$wh")
  log "$1: $st $c screen=${wh:--} settled=${dt}s how=${4:-none} $s"
  sizes+=" $1=${g:--}/${wh:--}"
  [[ $st == *reaper=-* ]] && bad+=" game-gone"
  [ -n "$g" ] && [ -n "$wh" ] || bad+=" no-geometry"
  [ -n "$g" ] && [ -n "$wh" ] && ! fits "$g" "$wh" && bad+=" G1-window-${g}-is-not-the-screen-${wh}-after-${SETTLE_S}s"
  [ "${3:-0}" -ge 1 ] 2>/dev/null || bad+=" G3-no-full-screen-game-layer(${on:-?})"
  [ "${c#changes=}" -ge 3 ] 2>/dev/null || bad+=" not-drawing"
  [ -n "$box" ] && { if [ "${BARS:-verdict}" = note ]; then log "  $1 note: $box (BARS=note)"; else bad+=" G3-$box"; fi; }
  [ -n "$bad" ] && { fails=$((fails + 1)); log "  $1 bad:$bad"; }
  return 0
}
rotate() { "$A" shell "settings put system accelerometer_rotation 0; settings put system user_rotation $1"; sleep 5; }
"$A" shell cmd device_state state 3; rotate 0; touched && { [ "$mine" = 1 ] && stop; exit 3; }
probe unfolded
rotate 1; log "rotated landscape"; probe unfolded-landscape
"$A" shell cmd device_state state 0; sleep 6; log "folded (cover)"; probe folded-landscape
rotate 0; log "cover portrait"; probe folded-portrait
touched && { restore; [ "$mine" = 1 ] && stop; exit 3; }
"$A" shell cmd device_state state 3; sleep 6; log "unfolded again"; probe unfolded-again
restore
stop
"$A" shell "su -c 'rm -f /data/local/tmp/powos-bf-* /data/powos/root/var/tmp/powos-bf-fold-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-bf-xframes.py'"
log "RESULT $NAME $APP: $([ $fails = 0 ] && echo PASS || echo "FAIL ($fails bad steps)") - window sizes:$sizes; artefacts $OUT"
[ $fails = 0 ]
