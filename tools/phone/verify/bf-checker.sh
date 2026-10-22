#!/bin/bash
# bf-checker.sh [variant...]: (Mac; queue it: queue.sh add <task> bf-checker.sh) bisect Broforce's black checkerboard
# on the loading + menu screens over render variants, ~4 min of screen each. Variants (bf-checker-phone.sh set):
# base, TU_DEBUG = noubwc | sysmem | flushall | nolrz (Proton user_settings.py), dxvk.conf = nomsaa (d3d11.disableMsaa)
# | zeromem (dxvk.zeroMappedMemory) | zerowg (d3d11.zeroInitWorkgroupMemory) | relaxed (d3d11.relaxedBarriers).
# Per variant: cold start (game killed between variants, Steam kept), from the game window on 75 s of Xwayland's copy
# (x11grab 1 fps), a screencap every ~10 s (shot.sh) and the menu's SurfaceFlinger presents from 45 s (fps), then the
# DXVK + Unity logs. bf-checker.py scores the black checker per frame; its last line = the board result (which variant
# removes it, fps each). Restores user_settings.py, dxvk.conf, the game + Steam, the front activity.
# Exit 3 on a real touch (re-queued), 5 when the game doesn't start. Artefacts: OUT (~/.cache/powos-verify/bfc-*).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
[ $# -gt 0 ] || set -- base noubwc sysmem nomsaa zeromem flushall nolrz zerowg relaxed
OUT=${OUT:-$HOME/.cache/powos-verify/bfc-$(date +%F_%H%M)}; mkdir -p "$OUT"
irq() { "$A" shell "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts" | tr -d '\r'; }
asuser() { local n=$1; shift
  "$A" shell "su -c 'cp /data/local/tmp/powos-$n /data/powos/root/var/tmp/powos-$n; chmod 644 /data/powos/root/var/tmp/powos-$n; sh /data/powos/powos-run.sh \"sh /var/tmp/powos-$n $*\"'" 2>&1 | grep -v sysvipc | tr -d '\r'; }
[ -n "$("$A" shell "pgrep -f Broforce_beta.exe" | tr -d '\r')" ] && { echo "game already running (the user plays?) - skip"; exit 3; }
front=$("$A" shell "dumpsys activity activities | grep -m1 topResumedActivity" | sed -nE 's#.* ([a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+) .*#\1#p')
steam_before=$("$A" shell "pgrep -f 'steam -cef'" | tr -d '\r')
fold=$("$A" shell "dumpsys device_state | grep -m1 mCommittedState" | sed -nE "s/.*name='([A-Z_]+)'.*/\1/p")
echo "front=${front:-?} steam_before=${steam_before:+yes} fold=$fold out=$OUT"
for f in bf-start.sh bf-stop.sh bf-window.sh bf-present.sh bf-checker-phone.sh; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null; done
restore() {
  "$A" shell "su -c 'pkill -f powos-bf-present.sh; pkill -f \"powos-bf-checker-phone.sh grabloop\"'" >/dev/null 2>&1
  asuser bf-checker-phone.sh clean >/dev/null; asuser bf-stop.sh >/dev/null
  [ -n "$steam_before" ] && "$A" shell "su -c 'sh /data/powos/powos-run.sh \"cd /home/powos; setsid -f steam -silent </dev/null >/dev/null 2>&1\"'" >/dev/null 2>&1
  [ -n "$front" ] && "$A" shell "am start -n $front >/dev/null 2>&1"
  "$A" shell "su -c 'rm -rf /data/local/tmp/bfp /data/local/tmp/bfc-* /data/local/tmp/powos-bf-*.sh /data/powos/root/var/tmp/powos-bf-*.sh /data/powos/root/var/tmp/bfc'"
}
i0=$(irq); touched() { [ "$(irq)" != "$i0" ]; }
abort() { echo "touch $(date +%T) - abort, restoring"; restore; exit 3; }
nap() { local i; for i in $(seq "$1"); do sleep 5; touched && abort; done; }
done_v=()
for v in "$@"; do
  M=$OUT/$v; mkdir -p "$M"
  echo "== $v $(date +%T): $(asuser bf-checker-phone.sh set "$v" | tail -1)"
  asuser bf-start.sh >/dev/null
  win=""; for i in $(seq 48); do nap 1; win=$(asuser bf-window.sh | tail -1); case $win in win=[0-9]*) break ;; esac; done
  case $win in win=[0-9]*) ;; *) echo "$v: no game window in 4 min ($win)"; restore; exit 5 ;; esac
  echo "$v: window after $((i * 5)) s: $win"; echo "$win" > "$M/window.txt"
  asuser bf-checker-phone.sh grab 80 /var/tmp/bfc/$v >/dev/null; t0=$(date +%s); n=0
  while [ $(( $(date +%s) - t0 )) -lt 92 ]; do
    el=$(( $(date +%s) - t0 ))
    if [ "$el" -ge $((n * 10 + 3)) ]; then
      n=$((n + 1)); "$here/../shot.sh" "$M/s$(printf %02d $n).png" >/dev/null 2>>"$M/shot.err"
    fi
    if [ "$el" -ge 45 ] && [ -z "${pres:-}" ]; then pres=1
      "$A" shell "su -c 'rm -rf /data/local/tmp/bfp; nohup sh /data/local/tmp/powos-bf-present.sh 25 \"PowosWindowActivity|SurfaceView|Broforce|steam_app\" /data/local/tmp/bfp 0 >/dev/null 2>&1 &'"
    fi
    touched && abort; sleep 2
  done; unset pres
  asuser bf-checker-phone.sh logs /var/tmp/bfc/$v | tail -1
  "$A" shell "su -c 'cp -r /data/powos/root/var/tmp/bfc/$v /data/local/tmp/bfc-$v; chmod -R 755 /data/local/tmp/bfc-$v /data/local/tmp/bfp'"
  "$A" pull /data/local/tmp/bfc-$v "$M/" >/dev/null && mv "$M/bfc-$v"/* "$M"/ && rmdir "$M/bfc-$v"
  "$A" pull /data/local/tmp/bfp "$M/" >/dev/null && mv "$M"/bfp/* "$M"/ && rmdir "$M/bfp"
  echo "$v: $(ls "$M" | grep -c '^h') X frames, $(ls "$M" | grep -c '^s.*png') shots; grab: $(tail -2 "$M/grab.log" | tr '\n' ' ')"
  "$A" shell "su -c 'pkill -f Broforce_beta.exe; rm -rf /data/local/tmp/bfp /data/local/tmp/bfc-$v /data/powos/root/var/tmp/bfc/$v'"; sleep 8
  done_v+=("$v")
done
echo "== done $(date +%T)"; restore
python3 "$here/bf-checker.py" "$OUT" "${done_v[@]}"
