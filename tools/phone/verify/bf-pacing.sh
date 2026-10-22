#!/bin/bash
# bf-pacing.sh [mode...]: (Mac; queue it: queue.sh add <task> bf-pacing.sh base cap60) Broforce frame pacing + stale
# frames, ~3-4 min of screen per mode. Per mode: dxvk.conf in the game dir (base = none; cap60 = dxgi.maxFrameRate 60;
# fifo = syncInterval 1; nolatency = maxFrameLatency 1), start the game (KWin shows it as its own task),
# wait for its X window (+ its size vs the screen: unity-screen), 45 s settle, then 30 s of SurfaceFlinger present
# times + a 20 s screenrecord (bf-present.sh), and the session log's "Xwayland KGSL" lines. bf-frames.py turns
# that into fps / frame-time percentiles / % at 16.7 ms / dup + stale-back frames; its last line = the board result.
# Restores: dxvk.conf, the game + Steam (bf-stop.sh; Steam restarted -silent if it ran before), the front activity.
# Exit 3 on a real touch (re-queued), 5 when the game doesn't start. Artefacts: OUT (~/.cache/powos-verify/bfp-*).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
[ $# -gt 0 ] || set -- base
OUT=${OUT:-$HOME/.cache/powos-verify/bfp-$(date +%F_%H%M)}; mkdir -p "$OUT"
G=/home/powos/.local/share/Steam/steamapps/common/Broforce; LOG=/data/powos/root/run/powos-app/hyprland.log
irq() { "$A" shell "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts" | tr -d '\r'; }
asuser() { "$A" shell "su -c 'cp /data/local/tmp/powos-$1 /data/powos/root/var/tmp/powos-$1; chmod 644 /data/powos/root/var/tmp/powos-$1; sh /data/powos/powos-run.sh \"sh /var/tmp/powos-$1\"'" 2>&1 | grep -v sysvipc | tr -d '\r'; }
[ -n "$("$A" shell "pgrep -f Broforce_beta.exe" | tr -d '\r')" ] && { echo "game already running (the user plays?) - skip"; exit 3; }
front=$("$A" shell "dumpsys activity activities | grep -m1 topResumedActivity" | sed -nE 's#.* ([a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+) .*#\1#p')
steam_before=$("$A" shell "pgrep -f 'steam -cef'" | tr -d '\r')
fold=$("$A" shell "dumpsys device_state | grep -m1 mCommittedState" | sed -nE "s/.*name='([A-Z_]+)'.*/\1/p")
echo "front=${front:-?} steam_before=${steam_before:+yes} fold=$fold"
for f in bf-start.sh bf-stop.sh bf-window.sh bf-present.sh; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null; done
restore() {
  "$A" shell "su -c 'pkill -f powos-bf-present.sh; pkill -INT screenrecord'" >/dev/null 2>&1
  asuser bf-stop.sh >/dev/null; "$A" shell "su -c 'rm -f /data/powos/root$G/dxvk.conf'"
  [ -n "$steam_before" ] && "$A" shell "su -c 'sh /data/powos/powos-run.sh \"cd /home/powos; setsid -f steam -silent </dev/null >/dev/null 2>&1\"'" >/dev/null 2>&1
  [ -n "$front" ] && "$A" shell "am start -n $front >/dev/null 2>&1"
  "$A" shell "su -c 'rm -rf /data/local/tmp/bfp /data/local/tmp/powos-bf-*.sh /data/powos/root/var/tmp/powos-bf-*.sh'"
}
i0=$(irq); touched() { [ "$(irq)" != "$i0" ]; }
abort() { echo "touch $(date +%T) - abort, restoring"; restore; exit 3; }
nap() { local i; for i in $(seq "$1"); do sleep 5; touched && abort; done; }
for mode in "$@"; do
  case $mode in
    base) conf= ;; cap60) conf='dxgi.maxFrameRate = 60' ;; fifo) conf='dxgi.syncInterval = 1' ;;
    nolatency) conf='dxgi.maxFrameLatency = 1' ;; *) echo "unknown mode $mode"; continue ;;
  esac
  "$A" shell "su -c 'rm -f /data/powos/root$G/dxvk.conf'"
  if [ -n "$conf" ]; then
    printf '%s\n' "$conf" > "$OUT/dxvk-$mode.conf"; "$A" push "$OUT/dxvk-$mode.conf" /data/local/tmp/powos-dxvk.conf >/dev/null
    "$A" shell "su -c 'cp /data/local/tmp/powos-dxvk.conf /data/powos/root$G/dxvk.conf; chmod 644 /data/powos/root$G/dxvk.conf; rm /data/local/tmp/powos-dxvk.conf'"
  fi
  M=$OUT/$mode; mkdir -p "$M"; k0=$("$A" shell "su -c 'grep -c \"Xwayland KGSL\" $LOG'" | tr -d '\r')
  echo "== $mode $(date +%T)"; asuser bf-start.sh >/dev/null
  win=""; for i in $(seq 48); do nap 1; win=$(asuser bf-window.sh | tail -1); case $win in win=[0-9]*) break ;; esac; done
  case $win in win=[0-9]*) ;; *) echo "$mode: no game window in 4 min ($win)"; restore; exit 5 ;; esac
  echo "$mode: window after $((i * 5)) s: $win"; echo "$win" | sed 's/win=//; s/screen=/on /' > "$M/window.txt"
  nap 9  # KWin opens the game as its own Android task (PowosWindowActivity, WindowTasks): nothing to bring forward
  top=$("$A" shell "dumpsys activity activities | grep -m1 topResumedActivity" | sed -nE 's#.*/[a-zA-Z0-9_.]*\.([A-Za-z0-9_$]+) .*#\1#p')
  echo "$mode: in front: $top"; echo "front $top" >> "$M/window.txt"
  "$A" shell "su -c 'rm -rf /data/local/tmp/bfp; nohup sh /data/local/tmp/powos-bf-present.sh 30 \"PowosWindowActivity|SurfaceView|Broforce|steam_app\" /data/local/tmp/bfp >/dev/null 2>&1 &'"
  nap 8
  "$A" shell "su -c 'grep \"Xwayland KGSL\" $LOG | tail -n +$((k0 + 1))'" > "$M/kgsl.txt"
  "$A" pull /data/local/tmp/bfp "$M/" >/dev/null && mv "$M"/bfp/* "$M"/ && rmdir "$M/bfp"
  "$A" shell "su -c 'pkill -f Broforce_beta.exe; rm -rf /data/local/tmp/bfp'"; sleep 8
done
echo "== done $(date +%T)"; restore
python3 "$here/bf-frames.py" "$OUT" "$@"
