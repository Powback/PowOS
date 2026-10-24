#!/bin/bash
# lanes: phone
# bf-pacing.sh [mode...]: (Mac; queue it: queue.sh add <task> bf-pacing.sh base cap60) Broforce frame pacing + stale
# frames, ~3-4 min of screen per mode. Per mode: dxvk.conf in the game dir (base = none; cap60 = dxgi.maxFrameRate 60;
# fifo = syncInterval 1; nolatency = maxFrameLatency 1; env:K=V[,K=V] = those in the game's environment through
# ~/.config/powos/proton-settings.json, e.g. env:PROTON_USE_XALIA=0), start the game (KWin shows it as its own task),
# wait for its X window (+ its size vs the screen: unity-screen), 45 s settle, then 30 s of SurfaceFlinger present
# times + a 20 s screenrecord (bf-present.sh), the same 30 s of per-thread CPU, cluster clocks and caps, GPU busy and
# clock, temperatures (bf-prof.sh: "prof <mode>" lines), and the session log's "Xwayland KGSL" lines. bf-frames.py turns
# that into fps / frame-time percentiles / % at 16.7 ms / dup + stale-back frames; its last line = the board result.
# Restores: dxvk.conf, the game + Steam (bf-stop.sh; Steam restarted -silent if it ran before), the front activity.
# Exit 3 on a real touch (re-queued), 5 when the game doesn't start. Artefacts: OUT (~/.cache/powos-verify/bfp-*).
# Valid only with the game ON SCREEN: a display ON, its task (PowosWindowActivity) in front and that task's SurfaceView
# layer there, before and after the 30 s - else "INVALID: ..." and exit 3 (the next window). The 03:58 run of
# 2026-10-24 measured a game with no task surface (no SurfaceView layer, nothing resumed, no screen recording: the
# screen was off): KWin draws a window task only while its surface exists, so no frame callbacks and 2 commits/s.
# Fits its 300 s budget (one mode per job): every wait is ONE phone-side call (bf-nap.sh, bf-window.sh wait) instead of
# an adb call per 5 s (~2.5 s each through adb.sh: the 45 s settle took 68 s), the scripts go in one push, and the game
# window is waited for only while the rest still fits (WIN_S; else "FAIL no game window" instead of a budget kill).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
[ $# -gt 0 ] || set -- base
BF_ADB=$A . "$here/bf-lib.sh"   # pill <step>: the status pill's sub-step
OUT=${OUT:-$HOME/.cache/powos-verify/bfp-$(date +%F_%H%M)}; mkdir -p "$OUT"
APP=${APP:-274190} WIN_NAME=${WIN_NAME:-}  # any Steam game; default the test case. WIN_NAME (one word) only when its
# window isn't titled like Steam's name for it (bf-window.sh reads that name from the appmanifest).
case "$APP$WIN_NAME" in *[!A-Za-z0-9_.-]*) echo "APP / WIN_NAME: one word each"; exit 2 ;; esac
NAME=${WIN_NAME:-app $APP}
PS=/data/powos/root/home/powos/.config/powos/proton-settings.json
settings() {  # settings <K=V,K=V | empty>: the game's extra environment for this mode (none = file removed)
  "$A" shell "su -c 'rm -f $PS'"; [ -n "$1" ] || return 0
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(dict(kv.split("=", 1) for kv in sys.stdin.read().split(","))))' > "$OUT/settings.json"
  "$A" push "$OUT/settings.json" /data/local/tmp/powos-settings.json >/dev/null
  "$A" shell "su -c 'd=\$(dirname $PS); mkdir -p \$d; cp /data/local/tmp/powos-settings.json $PS; chown \$(stat -c %u:%g \$d) $PS; chmod 644 $PS; rm /data/local/tmp/powos-settings.json'"; }
LOG=/data/powos/root/run/powos-app/hyprland.log
T0=$(date +%s) BUDGET_S=${BUDGET_S:-300}
# After the window: settle 45 + measure 30 + collecting ~25 + restore ~25 + comparing ~25 s, and a margin.
AFTER_WIN_S=${AFTER_WIN_S:-165}
irq() { "$A" shell "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts" | tr -d '\r'; }
asuser() { local n=$1; shift
  "$A" shell "su -c 'cp /data/local/tmp/powos-$n /data/powos/root/var/tmp/powos-$n; chmod 644 /data/powos/root/var/tmp/powos-$n; sh /data/powos/powos-run.sh \"APP=$APP WIN_NAME=$WIN_NAME sh /var/tmp/powos-$n $*\"'" 2>&1 | grep -v sysvipc | tr -d '\r'; }
pill "checking the phone (a game already up? Steam?)"
# Every phone-side script in ONE push (each adb.sh call is a docker run over the VPN, ~2-3 s).
st=$OUT/push; mkdir -p "$st"; for f in bf-start.sh bf-stop.sh bf-window.sh bf-present.sh bf-prof.sh bf-game.sh bf-nap.sh; do
  cp "$here/$f" "$st/powos-$f"; done
"$A" push "$st"/powos-bf-*.sh /data/local/tmp/ >/dev/null || { echo "can't push the check's scripts"; exit 5; }
gs=$(asuser bf-game.sh state | tail -1); users=0
G=$(asuser bf-game.sh dir | tail -1); [ -n "$G" ] || { echo "app $APP isn't installed (no Steam appmanifest)"; exit 5; }
case $gs in
  game=awake) echo "the user's $NAME is up and awake (they play it?) - skip"; exit 3 ;;
  game=frozen) users=1; echo "the user's $NAME, left frozen: measured as it is (base only), frozen again after"
    [ "$*" = base ] || echo "modes other than base need a fresh start: skipped (${*})"; set -- base ;;
esac
ph=$("$A" shell "dumpsys activity activities | grep -m1 topResumedActivity; echo; echo steam=\$(pgrep -f 'steam -cef' | head -1); dumpsys device_state | grep -m1 mCommittedState" | tr -d '\r')
front=$(echo "$ph" | grep -m1 topResumedActivity | sed -nE 's#.* ([a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+) .*#\1#p')
steam_before=$(echo "$ph" | sed -n 's/^steam=//p')
fold=$(echo "$ph" | sed -nE "s/.*mCommittedState.*name='([A-Z_]+)'.*/\1/p")
echo "front=${front:-?} steam_before=${steam_before:+yes} fold=$fold"
restore() {
  pill "closing the game, putting Steam back"
  "$A" shell "su -c 'pkill -f powos-bf-present.sh; pkill -f powos-bf-prof.sh; pkill -INT screenrecord'" >/dev/null 2>&1
  settings ''
  if [ $users = 1 ]; then echo "the user's $NAME: $(asuser bf-game.sh freeze | tail -1)"; else asuser bf-stop.sh >/dev/null; fi
  "$A" shell "su -c 'rm -f /data/powos/root$G/dxvk.conf'"
  [ -n "$steam_before" ] && "$A" shell "su -c 'sh /data/powos/powos-run.sh \"cd /home/powos; setsid -f steam -silent </dev/null >/dev/null 2>&1\"'" >/dev/null 2>&1
  "$A" shell "${front:+am start -n $front >/dev/null 2>&1; }su -c 'rm -rf /data/local/tmp/bfp /data/local/tmp/bfprof /data/local/tmp/powos-bf-*.sh /data/powos/root/var/tmp/powos-bf-*.sh'"
}
i0=$(irq); touched() { [ "$(irq)" != "$i0" ]; }
abort() { echo "touch $(date +%T) - abort, restoring"; restore; exit 3; }
# nap <secs>: one phone-side wait that returns early on a touch (bf-nap.sh).
nap() { case $("$A" shell "sh /data/local/tmp/powos-bf-nap.sh $1 $i0" | tr -d '\r') in *touched*) abort ;; esac; }
# onscreen: the game's task really on the screen - a display ON, PowosWindowActivity resumed, its SurfaceView layer
# there (KWin draws a window task only into that surface) - or why not.
onscreen() { local r on top sv
  r=$("$A" shell "dumpsys display | grep -cE '^  DisplayDeviceInfo.* state ON,'; dumpsys activity activities | grep -m1 topResumedActivity; echo; dumpsys SurfaceFlinger --list | grep -cF 'SurfaceView[com.powos.app/andro.marchy.PowosWindowActivity]'" | tr -d '\r')
  on=$(echo "$r" | sed -n 1p); top=$(echo "$r" | grep -m1 topResumedActivity | sed -nE 's#.*/[a-zA-Z0-9_.]*\.([A-Za-z0-9_$]+) .*#\1#p')
  sv=$(echo "$r" | tail -1); WHY="displays on=${on:-?}, in front=${top:-none}, task surfaces=${sv:-?}"; TOP=$top
  [ "${on:-0}" -ge 1 ] && [ "$top" = PowosWindowActivity ] && [ "${sv:-0}" -ge 1 ]; }
invalid() { echo "INVALID: $NAME wasn't on the screen $1 ($WHY) - frames of a game nobody sees say nothing"; restore; exit 3; }
mi=0
for mode in "$@"; do
  mi=$((mi + 1)); lbl="$mode $mi/$#"
  case $mode in
    base) conf= ;; cap60) conf='dxgi.maxFrameRate = 60' ;; fifo) conf='dxgi.syncInterval = 1' ;;
    nolatency) conf='dxgi.maxFrameLatency = 1' ;; env:*=*) conf= ;; *) echo "unknown mode $mode"; continue ;;
  esac
  case $mode in env:*) settings "${mode#env:}" ;; *) settings '' ;; esac
  "$A" shell "su -c 'rm -f /data/powos/root$G/dxvk.conf'"
  if [ -n "$conf" ]; then
    printf '%s\n' "$conf" > "$OUT/dxvk-$mode.conf"; "$A" push "$OUT/dxvk-$mode.conf" /data/local/tmp/powos-dxvk.conf >/dev/null
    "$A" shell "su -c 'cp /data/local/tmp/powos-dxvk.conf /data/powos/root$G/dxvk.conf; chmod 644 /data/powos/root$G/dxvk.conf; rm /data/local/tmp/powos-dxvk.conf'"
  fi
  M=$OUT/$mode; mkdir -p "$M"; l0=$("$A" shell "su -c 'wc -l < $LOG'" | tr -d '\r ')
  echo "== $mode $(date +%T)"
  if [ -n "$("$A" shell "pgrep -f 'steam -cef'" | tr -d '\r')" ]; then pill "$lbl: launching $NAME"; else pill "$lbl: starting Steam + $NAME"; fi
  asuser bf-start.sh >/dev/null
  pill "$lbl: waiting for the game window"
  # The window, waited for only while the rest of this mode still fits the budget (WIN_S overrides).
  w0=$(date +%s); left=${WIN_S:-$(( T0 + BUDGET_S - AFTER_WIN_S - w0 ))}; [ "$left" -ge 20 ] || left=20
  win=$(asuser bf-window.sh wait "$left" "$i0" | tail -1)
  case $win in touched) abort ;; win=[0-9]*) ;; *) echo "FAIL no game window: $NAME showed none in $left s ($win)"; restore; exit 5 ;; esac
  echo "$mode: window after $(( $(date +%s) - w0 )) s: $win"; echo "$win" | sed 's/win=//; s/screen=/on /' > "$M/window.txt"
  pill "$lbl: game up - settling 45 s"
  nap 45  # KWin opens the game as its own Android task (PowosWindowActivity, WindowTasks): nothing to bring forward
  onscreen; ok=$?; top=$TOP
  # Unity maps a 314x208 window first and goes full screen later: the size that counts is the one after the settle.
  win2=$(asuser bf-window.sh | tail -1); echo "$mode: after the settle: $win2"
  echo "$win2" | sed 's/win=/settled /; s/screen=/on /' >> "$M/window.txt"
  echo "$mode: in front: $top ($WHY)"; echo "front $top" >> "$M/window.txt"
  [ $ok = 0 ] || invalid "after the settle"
  "$A" shell "su -c 'rm -rf /data/local/tmp/bfp /data/local/tmp/bfprof; nohup sh /data/local/tmp/powos-bf-present.sh 30 \"PowosWindowActivity|SurfaceView|steam_app${WIN_NAME:+|$WIN_NAME}\" /data/local/tmp/bfp >/dev/null 2>&1 &
    nohup sh /data/local/tmp/powos-bf-prof.sh 30 /data/local/tmp/bfprof >/dev/null 2>&1 &'"
  pill "$lbl: measuring frames (30 s)"; nap 30
  onscreen || invalid "during the measurement"
  pill "$lbl: collecting the numbers"
  # bf-present (its screen recording) and bf-prof finished, at most 30 s more; then the session log's Xwayland KGSL and
  # KWin window-task lines of this mode, and prof.txt - one call.
  "$A" shell "su -c 'mkdir -p /data/local/tmp/bfp; for i in \$(seq 30); do [ -f /data/local/tmp/bfprof/done ] && ! pgrep -f powos-bf-present.sh >/dev/null && break; sleep 1; done
    tail -n +$((l0 + 1)) $LOG | grep -E \"Xwayland KGSL|window task\" > /data/local/tmp/bfp/log.txt; cp /data/local/tmp/bfprof/prof.txt /data/local/tmp/bfp/ 2>/dev/null; chmod -R 755 /data/local/tmp/bfp'" >/dev/null
  "$A" pull /data/local/tmp/bfp "$M/" >/dev/null && mv "$M"/bfp/* "$M"/ && rmdir "$M/bfp"
  grep "Xwayland KGSL" "$M/log.txt" > "$M/kgsl.txt"; grep "window task" "$M/log.txt" > "$M/kwin.txt"; rm -f "$M/log.txt"
  sed "s/^/kwin $mode: /" "$M/kwin.txt" | tail -5; sed "s/^/prof $mode: /" "$M/prof.txt" 2>/dev/null
  "$A" shell "su -c 'rm -rf /data/local/tmp/bfp /data/local/tmp/bfprof'"
  # The next mode needs a fresh start (its dxvk.conf); the last one is closed (or frozen again) by restore.
  [ $mi -lt $# ] && { pill "$lbl: closing the game"; asuser bf-stop.sh >/dev/null; }
done
echo "== done $(date +%T)"; restore
pill "comparing $(echo "$*" | sed 's/ / vs /g')"
# uv runs it with its own numpy (the script's inline deps, uv's cache): nothing installed into the Mac's python.
uv run --quiet --script "$here/bf-frames.py" "$OUT" "$@"
