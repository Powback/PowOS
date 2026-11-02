#!/bin/bash
# lanes: phone
# bf-drawn.sh: (Mac side; queue it: queue.sh add [--close] <board-task> bf-drawn.sh) a game's window task draws each
# game frame ONCE (kwin 0052 = 6.7.5-3.59, board task broforce-games-black-noise-flicker-artifacts-ove): before, one
# commit was composited into every consumer buffer in turn - "window task 11 frames: last 5 s 110 commits, 300 drawn"
# (2026-11-02 21:41, Broforce ~22 game fps under its window task's 60 redraws, black noise over it).
# Steps (one free window): Broforce up (bf-fold-phone.sh start), unfolded portrait, 30 s, then KWin's "window task N
# frames" lines for the game's task from the session log (/run/powos-app/hyprland.log, only lines written during the
# run). PASS: drawn <= commits x 1.15 summed over the run, and commits >= 5 per s (the game draws). The numbers are the
# fps evidence too (commits / 5 = the game's own fps). Exit 3 = user input; 1 = FAIL; the game closed after (if ours).
# NEEDS: the user's "you may launch games for tests" - it starts Broforce.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); P=$here/..; A=$P/adb.sh
APP=${APP:-274190} WIN_NAME=${WIN_NAME:-Broforce} MIN=${KWIN_MIN:-6.7.5-3.59}
case "$APP$WIN_NAME" in *[!A-Za-z0-9_.-]*) echo "APP / WIN_NAME: one word each"; exit 2 ;; esac
OUT=${OUT:-$HOME/.cache/powos-verify/bf-drawn-$(date +%F_%H%M)}; mkdir -p "$OUT"
. "$here/window-lock.sh"; window_lock bf-drawn.sh 120
trap '[ "${WL_LOCK:-}" ] && rm -rf "$WL_LOCK"' EXIT
log() { echo "$(date +%T) $*" | tee -a "$OUT/run.txt"; }
BF_ADB=$A . "$here/bf-lib.sh"
for f in bf-fold-phone.sh bf-stop.sh bf-lib.sh bf-xframes.py; do "$A" push "$here/$f" "/data/local/tmp/powos-$f" >/dev/null || { echo "ENV: can't push $f"; exit 5; }; done
"$A" shell "su -c 'cd /data/local/tmp && cp powos-bf-fold-phone.sh powos-bf-stop.sh powos-bf-lib.sh powos-bf-xframes.py /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-bf-*'"
ph() { "$A" shell "su -c 'sh /data/powos/powos-run.sh \"APP=$APP WIN_NAME=$WIN_NAME bash /var/tmp/powos-bf-fold-phone.sh $*\"'" | tr -d '\r'; }
irq() { "$A" shell "cat /proc/interrupts" | awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}'; }
I0=$(irq); touched() { [ "$(irq)" != "$I0" ] && { log "user input - stopping"; return 0; }; return 1; }
printf 'v=$(pacman -Q kwin | cut -d" " -f2); echo "$v $(vercmp "$v" %s)"\n' "$MIN" > "$OUT/q.sh"
kv=$("$P/root.sh" "$OUT/q.sh" 2>/dev/null | tail -1 | tr -d '\r'); log "kwin $kv (needs >= $MIN)"
[ "${kv##* }" -ge 0 ] 2>/dev/null || { log "FAIL: KWin ${kv%% *} older than $MIN (queue kwin-install.sh $MIN first)"; exit 1; }
LOGF=/run/powos-app/hyprland.log
printf 'wc -l < %s\n' "$LOGF" > "$OUT/n.sh"
n0=$("$P/root.sh" "$OUT/n.sh" 2>/dev/null | tail -1 | tr -d '\r')
touched && exit 3
pill "$WIN_NAME up"
r=$(ph start); echo "$r" >> "$OUT/run.txt"; mine=$([[ $r == *mine=1* ]] && echo 1 || echo 0)
stop() { if [ "$mine" = 1 ]; then log "closed: $("$A" shell "su -c 'sh /data/powos/powos-run.sh \"APP=$APP bash /var/tmp/powos-bf-stop.sh\"'" 2>&1 | tr -d '\r' | tail -1)"
  elif [[ $r == *mine=0* ]]; then log "the user's $WIN_NAME: $(ph refreeze | tail -1)"; fi; }
[[ $r == *"user input"* ]] && { log "user input during the start"; exit 3; }
[[ $r == *FAIL* || $r != *mine=* ]] && { log "FAIL: $WIN_NAME didn't come up: $(echo "$r" | grep -m1 FAIL)"; stop; exit 1; }
"$A" shell cmd device_state state 3 >/dev/null 2>&1; sleep 30
touched && { stop; "$A" shell cmd device_state state reset >/dev/null 2>&1; exit 3; }
"$P/shot.sh" "$OUT/game.png" >/dev/null 2>&1 || true
# The game's task: the last "live ... for \"<name>\"" line of this run; its frames lines after it.
printf 'tail -n +%s %s | grep -a -E "window task [0-9]+ (live|frames)"\n' "$((${n0:-0} + 1))" "$LOGF" > "$OUT/f.sh"
"$P/root.sh" "$OUT/f.sh" 2>/dev/null | tr -d '\r' > "$OUT/frames.txt"
stop; "$A" shell cmd device_state state reset >/dev/null 2>&1
task=$(grep -a "for \"$WIN_NAME\"" "$OUT/frames.txt" | tail -1 | sed -E 's/.*window task ([0-9]+) live.*/\1/')
[ -n "$task" ] || { log "FAIL: no window task went live for $WIN_NAME (frames.txt)"; exit 1; }
res=$(grep -a "window task $task frames" "$OUT/frames.txt" | sed -E 's/.* ([0-9]+) commits, ([0-9]+) drawn.*/\1 \2/' |
  awk '{c += $1; d += $2; n++} END {printf "%d %d %d", c, d, n}')
read -r c d n <<< "$res"
log "task $task: $n x 5 s, $c commits ($(awk -v c="$c" -v n="$n" 'BEGIN {printf "%.1f", n ? c / n / 5 : 0}') game fps), $d drawn"
[ "${n:-0}" -ge 3 ] || { log "FAIL: only ${n:-0} frames lines for task $task"; exit 1; }
awk -v c="$c" -v n="$n" 'BEGIN { exit !(c / n / 5 >= 5) }' || { log "FAIL not-drawing: the game committed < 5 fps"; exit 1; }
awk -v c="$c" -v d="$d" 'BEGIN { exit !(d <= c * 1.15) }' || { log "FAIL redraws: $d drawn for $c commits (each frame drawn more than once)"; exit 1; }
log "PASS: each game frame drawn once ($d drawn / $c commits)"
