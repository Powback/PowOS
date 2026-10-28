#!/bin/bash
# lanes: phone
# bf-resize.sh: (Mac side; queue it: queue.sh add [--close] <board-task> bf-resize.sh) a full-screen game's window
# follows its container (board task games-resize-live-to-their-container-portrait-la, kwin 0032 = 6.7.5-3.37): the
# game's X window takes its Android task's shape and size - phone upright -> portrait, rotated -> landscape, unfolded
# -> the inner screen - instead of keeping its launch size letterboxed (0017; the user saw Broforce at 496x1104
# portrait in a 2484x1116 landscape task, touches beside it "outside its input region").
# Steps (one free window, the user's phone handed over): Broforce up (bf-fold-phone.sh start: open-task, a frozen one
# of the user's resumed) -> unfolded (state 3) -> rotated landscape (user_rotation 1) -> folded (state 0, cover,
# landscape) -> cover portrait (user_rotation 0) -> unfolded again. Each step: the X window's aspect (xwininfo, bf-fold-
# phone.sh state geom) matches the screen's (shot.sh: the full-screen task fills it) within 4% = "resized"; the window
# still drawing (xframes count) = the game follows; screencap edge bars (a note: dark art reads as bars too).
# Rotation and device state are always put back. Not covered: a floating task's drag-resize (no scripted drag yet).
# Exit 3 = no window / user input. KWIN_MIN default 6.7.5-3.37 (queue kwin-install.sh 6.7.5-3.37 before it).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); P=$here/..; A=$P/adb.sh
APP=${APP:-274190} WIN_NAME=${WIN_NAME:-Broforce} MIN=${KWIN_MIN:-6.7.5-3.37}
case "$APP$WIN_NAME" in *[!A-Za-z0-9_.-]*) echo "APP / WIN_NAME: one word each"; exit 2 ;; esac
OUT=${OUT:-$HOME/.cache/powos-verify/bf-resize-$(date +%F_%H%M)}; mkdir -p "$OUT"
rot0=$("$A" shell settings get system accelerometer_rotation | tr -d '\r'); urot0=$("$A" shell settings get system user_rotation | tr -d '\r')
restore() { "$A" shell "cmd device_state state reset; settings put system user_rotation ${urot0:-0}; settings put system accelerometer_rotation ${rot0:-1}" >/dev/null 2>&1; }
WL_TRAP='restore'
. "$here/window-lock.sh"; window_lock bf-resize.sh 120
trap 'restore; [ "${WL_LOCK:-}" ] && rm -rf "$WL_LOCK"' EXIT
log() { echo "$(date +%T) $*" | tee -a "$OUT/run.txt"; }
BF_ADB=$A . "$here/bf-lib.sh"
for f in bf-fold-phone.sh bf-stop.sh bf-lib.sh bf-xframes.py; do "$A" push "$here/$f" "/data/local/tmp/powos-$f" >/dev/null; done
"$A" shell "su -c 'cd /data/local/tmp && cp powos-bf-fold-phone.sh powos-bf-stop.sh powos-bf-lib.sh powos-bf-xframes.py /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-bf-*'"
ph() { "$A" shell "su -c 'sh /data/powos/powos-run.sh \"APP=$APP WIN_NAME=$WIN_NAME bash /var/tmp/powos-bf-fold-phone.sh $*\"'" | tr -d '\r'; }
irq() { "$A" shell "cat /proc/interrupts" | awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}'; }
I0=$(irq); touched() { [ "$(irq)" != "$I0" ] && { log "user input - stopping"; return 0; }; return 1; }
printf 'v=$(pacman -Q kwin | cut -d" " -f2); echo "$v $(vercmp "$v" %s)"\n' "$MIN" > "$OUT/q.sh"
kv=$("$P/root.sh" "$OUT/q.sh" 2>/dev/null | tail -1 | tr -d '\r'); log "kwin $kv (needs >= $MIN)"
[ "${kv##* }" -ge 0 ] 2>/dev/null || { log "FAIL: KWin ${kv%% *} older than $MIN (queue kwin-install.sh $MIN first)"; exit 1; }

touched && exit 3
pill "$WIN_NAME up"
r=$(ph start); echo "$r" >> "$OUT/run.txt"; mine=$([[ $r == *mine=1* ]] && echo 1 || echo 0)
stop() { if [ "$mine" = 1 ]; then pill "closing the game"
    log "closed: $("$A" shell "su -c 'sh /data/powos/powos-run.sh \"APP=$APP bash /var/tmp/powos-bf-stop.sh\"'" 2>&1 | tr -d '\r' | tail -1)"
  elif [[ $r == *mine=0* ]]; then log "the user's $WIN_NAME: $(ph refreeze | tail -1)"; fi; }
[[ $r == *"user input"* ]] && { log "user input during the start"; exit 3; }
[[ $r == *FAIL* || $r != *mine=* ]] && { log "FAIL: $WIN_NAME didn't come up: $(echo "$r" | grep -m1 FAIL)"; stop; exit 1; }
bars() {  # black rows/columns at each edge of a screencap
  local r c
  r=$(ffmpeg -nostdin -loglevel error -i "$1" -vf "format=gray,scale=1:ih:flags=area" -f rawvideo - 2>/dev/null | od -An -v -tu1 | tr -s ' \n' ' ')
  c=$(ffmpeg -nostdin -loglevel error -i "$1" -vf "format=gray,scale=iw:1:flags=area" -f rawvideo - 2>/dev/null | od -An -v -tu1 | tr -s ' \n' ' ')
  awk -v r="$r" -v c="$c" 'function edge(s, rev,   a, n, i, k) { n = split(s, a, " "); for (k = 0; k < n; k++) {
      i = rev ? n - k : k + 1; if (a[i] > 12) return k }; return n }
    BEGIN { printf "top=%d bottom=%d left=%d right=%d\n", edge(r, 0), edge(r, 1), edge(c, 0), edge(c, 1) }'; }
fails=0 sizes=
probe() {  # probe <label>
  local st g c s wh bad=
  pill "$1: the game's window vs its screen"
  st=$(ph state); c=$(ph changes 3)
  g=$(echo "$st" | grep -o 'geom=[0-9]*x[0-9]*' | cut -d= -f2)
  if "$P/shot.sh" "$OUT/$1.png" >/dev/null 2>&1; then
    wh=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$OUT/$1.png"); s=$(bars "$OUT/$1.png")
  else wh=; s="no screencap"; fi
  log "$1: $st $c screen=${wh:--} $s"
  sizes+=" $1=${g:--}"
  [[ $st == *reaper=-* ]] && bad+=" game-gone"
  [ -n "$g" ] && [ -n "$wh" ] || bad+=" no-geometry"
  if [ -n "$g" ] && [ -n "$wh" ]; then
    awk -v g="$g" -v s="$wh" 'BEGIN { split(g, a, "x"); split(s, b, "x"); d = (a[1] / a[2]) / (b[1] / b[2]); exit !(d > 0.96 && d < 1.04) }' \
      || bad+=" window-${g}-not-the-screen's-shape-${wh}"
  fi
  [ "${c#changes=}" -ge 3 ] 2>/dev/null || bad+=" not-drawing"
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
log "RESULT bf-resize: $([ $fails = 0 ] && echo PASS || echo "FAIL ($fails bad steps)") - window sizes:$sizes; artefacts $OUT"
[ $fails = 0 ]
