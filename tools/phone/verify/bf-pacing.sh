#!/bin/bash
# lanes: phone
# bf-pacing.sh [mode...]: (Mac; queue it: queue.sh add <task> bf-pacing.sh base cap60) Broforce frame pacing + stale
# frames, ~3-4 min of screen per mode. Per mode: dxvk.conf in the game dir (base = none; cap60 = dxgi.maxFrameRate 60;
# fifo = syncInterval 1; nolatency = maxFrameLatency 1; play = base taken into a level first (bf-play.sh: keys
# BF_PLAY_KEYS, grabs in the mode's folder) so the numbers are gameplay's, not the menu's; env:K=V[,K=V] = those in the game's environment through
# ~/.config/powos/proton-settings.json, e.g. env:PROTON_USE_XALIA=0; gus:K=V[,K=V] anywhere = an Unreal game's own
# GameUserSettings.ini keys for the whole check, e.g. gus:ResolutionScale=SCALE_75 for ABZU, bf-lib.sh), start the game (KWin shows it as its own task),
# wait for its X window (+ its size vs the screen: unity-screen), 45 s settle, then 30 s of SurfaceFlinger present
# times + a 20 s screenrecord (bf-present.sh; BF_REC_S=<s>, 0 = none: no 48 MB pull + ffmpeg decode on the Mac), the same 30 s of per-thread CPU, cluster clocks and caps, GPU busy and
# clock, temperatures (bf-prof.sh: "prof <mode>" lines), and the session log's "Xwayland KGSL" lines. bf-frames.py turns
# that into fps / frame-time percentiles / % at 16.7 ms / dup + stale-back frames; its last line = the board result.
# Before it, bf-layers.py's "layers <mode>:" line: every stage's rate at once (game presents, Xwayland commits + frame
# callbacks/timeouts, KWin drawn, the consumer's queues + waits (logcat "pacing:"), SurfaceFlinger's actual presents, the
# panel's mode + render range) and skin temperature - the first stage whose rate drops is the cap (games-120).
# Restores: dxvk.conf, the game + Steam (bf-stop.sh; Steam restarted -silent if it ran before), the front activity.
# Exit 3 on a real touch (re-queued), 5 when the game doesn't start. An INVALID (exit 3 too) with nobody on the phone is
# the queue's "precond" (queue.sh rc3_kind, from the touch source): a FAIL precondition at its 3rd try, not endless
# retries; its line names what home showed instead (homewhy: the switcher up, the web windows). QUEUE_NEXT_APP=APP
# (the queue's next job is this game too): the game is left running ("WARM:"), and that job reuses it for the same mode. Artefacts: OUT (~/.cache/powos-verify/bfp-*).
# ColorOS touch idle (docs/research/broforce-fps.md): INPUT=touch|key|pad injects one event/s over the 30 s measurement
# (bf-lib.sh input_inject) - a run nobody touches measures ColorOS's 60 Hz no-touch cap. Every run prints "oti <mode>:"
# lines: ColorOS's OTI state + CVT rate and the game layers' requestedFrameRate votes at the end of the measurement.
# Valid only with the game ON SCREEN: a display ON, its task (PowosWindowActivity) in front and that task's SurfaceView
# layer there (unfolded: home in front and its full-screen web window's layer composed, bf-onscreen.sh), before and after the 30 s - else "INVALID: ..." and exit 3 (the next window). The 03:58 run of
# 2026-10-24 measured a game with no task surface (no SurfaceView layer, nothing resumed, no screen recording: the
# screen was off): KWin draws a window task only while its surface exists, so no frame callbacks and 2 commits/s.
# Fits its 300 s budget (one mode per job): every wait is ONE phone-side call (bf-nap.sh, bf-window.sh wait) instead of
# an adb call per 5 s (~2.5 s each through adb.sh: the 45 s settle took 68 s), the scripts go in one push, and the game
# window is waited for only while the rest still fits (WIN_S; else "FAIL no game window" instead of a budget kill).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"
. "$here/window-lock.sh"   # self_input_for
[ $# -gt 0 ] || set -- base
BF_ADB=$A . "$here/bf-lib.sh"   # pill <step>: the status pill's sub-step
cfg_take "$@"; set -- ${CFG_ARGS[@]+"${CFG_ARGS[@]}"}; [ $# -gt 0 ] || set -- base  # cfg:<x86|arm64>: bf-lib.sh cfg_take (bash 3.2-safe empty array)
gus_take "$@"; set -- ${GUS_ARGS[@]+"${GUS_ARGS[@]}"}; [ $# -gt 0 ] || set -- base  # gus:K=V: the game's GameUserSettings.ini (bf-lib.sh)
OUT=${OUT:-$HOME/.cache/powos-verify/bfp-$(date +%F_%H%M)}; mkdir -p "$OUT"
APP_GIVEN=${APP:+1}; APP=${APP:-274190} WIN_NAME=${WIN_NAME:-}  # any Steam game; default the test case. WIN_NAME
# (one word) only when its window isn't titled like Steam's name for it (bf-window.sh reads that name from the appmanifest).
case "$APP$WIN_NAME" in *[!A-Za-z0-9_.-]*) echo "APP / WIN_NAME: one word each"; exit 2 ;; esac
NAME=${WIN_NAME:-app $APP}
# f103: a fps job queued without APP= silently measured Broforce (the default) - say it loud, as the first line, so
# "fps job under task X" never reads as "measured game Y" by accident.
echo "measuring: $NAME$([ -z "$APP_GIVEN" ] && echo " (APP= not given - defaulted to Broforce $APP)")"
PS=/data/powos/root/home/powos/.config/powos/proton-settings.json
settings() {  # settings <K=V,K=V | empty>: the game's extra environment for this mode (none = file removed)
  "$A" shell "su -c 'rm -f $PS'"; [ -n "$1" ] || return 0
  # Split only at a comma that starts the next K=: WINE_CPU_TOPOLOGY=4:0,1,2,7 has commas in its value (02:53 run: the
  # plain split threw, settings.json came out empty and the mode ran with no environment at all).
  printf '%s' "$1" | python3 -c 'import json,re,sys; print(json.dumps(dict(kv.split("=", 1) for kv in re.split(r",(?=[A-Za-z_][A-Za-z0-9_]*=)", sys.stdin.read()))))' > "$OUT/settings.json" && [ -s "$OUT/settings.json" ] || { echo "FAIL settings: can't parse '$1'"; exit 2; }
  "$A" push "$OUT/settings.json" /data/local/tmp/powos-settings.json >/dev/null
  "$A" shell "su -c 'd=\$(dirname $PS); mkdir -p \$d; cp /data/local/tmp/powos-settings.json $PS; chown \$(stat -c %u:%g \$d) $PS; chmod 644 $PS; rm /data/local/tmp/powos-settings.json'"; }
LOG=/data/powos/root/run/powos-app/hyprland.log
T0=$(date +%s) BUDGET_S=${BUDGET_S:-300}
# After the window: settle 45 + measure 30 + collecting ~25 + restore ~25 + comparing ~25 s, and a margin.
AFTER_WIN_S=${AFTER_WIN_S:-165}
irq() { "$A" shell "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts" | tr -d '\r'; }
# asuser <script> [args]: ASUSER_PRE = an adb shell prefix run first as shell (self_input_for: bf-play's pad presses are
# the tools' own, not the user's); pad-lib.sh goes along (bf-play's input).
asuser() { local n=$1; shift
  "$A" shell "${ASUSER_PRE:-}su -c 'cp /data/local/tmp/powos-$n /data/local/tmp/powos-pad-lib.sh /data/powos/root/var/tmp/; chmod 644 /data/powos/root/var/tmp/powos-$n /data/powos/root/var/tmp/powos-pad-lib.sh; sh /data/powos/powos-run.sh \"APP=$APP WIN_NAME=$WIN_NAME sh /var/tmp/powos-$n $*\"'" 2>&1 | grep -v sysvipc | tr -d '\r'; }
pill "checking the phone (a game already up? Steam?)"
# Every phone-side script in ONE push (each adb.sh call is a docker run over the VPN, ~2-3 s).
st=$OUT/push; mkdir -p "$st"; for f in bf-start.sh bf-stop.sh bf-window.sh bf-present.sh bf-prof.sh bf-game.sh bf-nap.sh bf-onscreen.sh bf-play.sh bf-ask.sh pad-lib.sh; do
  cp "$here/$f" "$st/powos-$f"; done
"$A" push "$st"/powos-bf-*.sh "$st"/powos-pad-lib.sh /data/local/tmp/ >/dev/null || { echo "ENV: can't push the check's scripts"; exit 5; }
gs=$(asuser bf-game.sh state | tail -1); users=0
# Warm hand-over (queue.sh order_jobs + QUEUE_NEXT_APP): the job before this one, for the same game, left it running
# and wrote /var/tmp/powos-warm-<APP> = "<its last mode>|cfg:<CFG_TO>". That game is the queue's, not the user's: the
# same mode reuses it (no close, relaunch, window wait - 11-07: ABZU's jobs each spent ~20 s of launch and Steam
# restore), any other mode closes it and starts fresh (its env / dxvk.conf only apply at launch).
WM=/data/powos/root/var/tmp/powos-warm-$APP warm=
wm=$("$A" shell "su -c 'cat $WM 2>/dev/null; rm -f $WM'" | tr -d '\r')
if [ -n "$wm" ] && [ "$gs" = game=awake ]; then
  if [ "$wm" = "$1|cfg:$CFG_TO" ] && [ "$1" != play ]; then warm=1; echo "warm: $NAME left running by the job before (mode $1) - reused"
  else echo "warm: $NAME left running by the job before ($wm) - closed, mode $1 needs a fresh start"; asuser bf-stop.sh >/dev/null; fi
  gs=game=none
fi
G=$(asuser bf-game.sh dir | tail -1); [ -n "$G" ] || { echo "ENV: app $APP isn't installed (no Steam appmanifest)"; exit 5; }
case $gs in
  game=awake) echo "the user's $NAME is up and awake (they play it?) - skip"; exit 3 ;;
  game=frozen) [ -z "$CFG_TO" ] || { echo "the user's $NAME is left frozen: cfg:$CFG_TO needs a fresh start - skip"; exit 3; }
    users=1; echo "the user's $NAME, left frozen: measured as it is (base only), frozen again after"
    [ "$*" = base ] || echo "modes other than base need a fresh start: skipped (${*})"; set -- base ;;
esac
ph=$("$A" shell "dumpsys activity activities | grep -m1 topResumedActivity; echo; echo steam=\$(pgrep -f 'steam -cef' | head -1); dumpsys device_state | grep -m1 mCommittedState" | tr -d '\r')
front=$(echo "$ph" | grep -m1 topResumedActivity | sed -nE 's#.* ([a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+) .*#\1#p')
steam_before=$(echo "$ph" | sed -n 's/^steam=//p')
fold=$(echo "$ph" | sed -nE "s/.*mCommittedState.*name='([A-Z_]+)'.*/\1/p")
echo "front=${front:-?} steam_before=${steam_before:+yes} fold=$fold"
input_check || exit 2
restore() {  # restore [warm]: warm = the queue's next job is this game too (QUEUE_NEXT_APP): leave it running for it
  restored=1
  if [ "${1:-}" = warm ] && [ "${QUEUE_NEXT_APP:-}" = "$APP" ] && [ $users = 0 ] && [ -z "$CFG_TO" ]; then
    pill "leaving $NAME up for the next check"
    "$A" shell "su -c 'pkill -f powos-bf-present.sh; pkill -f powos-bf-prof.sh; pkill -INT screenrecord; printf %s \"$mode|cfg:$CFG_TO\" > $WM; chmod 644 $WM
      rm -rf /data/local/tmp/bfp /data/local/tmp/bfprof /data/local/tmp/powos-bf-*.sh /data/powos/root/var/tmp/powos-bf-*.sh'" >/dev/null 2>&1
    settings ''; "$A" shell "su -c 'rm -f /data/powos/root$G/dxvk.conf'"  # both only read at launch: the running game keeps its own
    echo "WARM: $NAME left running for the next check of app $APP (mode $mode)"; return 0
  fi
  pill "closing the game, putting Steam back"
  "$A" shell "su -c 'pkill -f powos-bf-present.sh; pkill -f powos-bf-prof.sh; pkill -INT screenrecord'" >/dev/null 2>&1
  settings ''
  if [ $users = 1 ]; then echo "the user's $NAME: $(asuser bf-game.sh freeze | tail -1)"; else asuser bf-stop.sh >/dev/null; fi
  "$A" shell "su -c 'rm -f /data/powos/root$G/dxvk.conf'"
  cfg_restore; gus_restore
  [ -n "$steam_before" ] && "$A" shell "su -c 'sh /data/powos/powos-run.sh \"cd /home/powos; setsid -f steam -silent </dev/null >/dev/null 2>&1\"'" >/dev/null 2>&1
  front_back "$front"  # bf-lib.sh: never a bare PowosWindowActivity (an empty window task over home)
  "$A" shell "su -c 'rm -rf /data/local/tmp/bfp /data/local/tmp/bfprof /data/local/tmp/powos-bf-*.sh /data/powos/root/var/tmp/powos-bf-*.sh'"
}
cfg_set || exit 5
gus_set || { restore; exit 5; }
# A stop from outside (TERM: game-input-alive.sh's own deadline, ahead of the queue's budget kill) still closes the game
# this run started and puts Steam + the front back, then ends as FAIL timeout (rc 124) with the step it was at. The
# stopper TERMs the running adb call too, so bash runs this at once instead of after that call. Not for the queue's
# kill itself: that TERMs the whole tree and gives 10 s, under restore's ~25 s (its game_left closes the game then).
restored=0
stopped_mac() { trap '' TERM INT HUP; echo "FAIL timeout: stopped from outside $(date +%T) - closing the game"
  [ "$restored" = 1 ] || restore; exit 124; }
trap stopped_mac TERM INT HUP
i0=$(irq); touched() { [ "$(irq)" != "$i0" ]; }
abort() { echo "touch $(date +%T) - abort, restoring"; restore; exit 3; }
# nap <secs>: one phone-side wait that returns early on a touch (bf-nap.sh).
nap() { case $("$A" shell "sh /data/local/tmp/powos-bf-nap.sh $1 $i0" | tr -d '\r') in *touched*) abort ;; esac; }
# onscreen: the game really on the screen - a display ON and a screen-sized game layer SurfaceFlinger composes
# (bf-onscreen.sh): its own task's SurfaceView with PowosWindowActivity resumed (folded: KWin's window task), or home's
# full-screen web window with HomeShell resumed (unfolded: every Linux window is one of home's web windows; 11-05 19:49 -
# 22:36 every unfolded run was "INVALID ... in front=HomeShell, task surfaces=0" while the game showed) - or why not.
onscreen() { local r on top sv how
  r=$("$A" shell "dumpsys display | grep -cE '^  DisplayDeviceInfo.* state ON,'; dumpsys activity activities | grep -m1 topResumedActivity; echo; sh /data/local/tmp/powos-bf-onscreen.sh" | tr -d '\r')
  on=$(echo "$r" | sed -n 1p); top=$(echo "$r" | grep -m1 topResumedActivity | sed -nE 's#.*/[a-zA-Z0-9_.]*\.([A-Za-z0-9_$]+) .*#\1#p')
  set -- $(echo "$r" | grep -m1 '^onscreen '); sv=${2:-0}; how=${3:-none}
  WHY="displays on=${on:-?}, in front=${top:-none}, switcher $(switcher_state), game layers=$sv ($how${4:+ ${4}})"; TOP=$top
  [ "${on:-0}" -ge 1 ] && [ "$sv" -ge 1 ] && { { [ "$how" = task ] && [ "$top" = PowosWindowActivity ]; } || { [ "$how" = web ] && [ "$top" = HomeShell ]; }; }; }
# homewhy: what home showed instead (the user, 11-07 03:3x: "atm its just waiting in the switcher") - the switcher up,
# and each web window's size / state, read from home's page (cdp.sh, read-only). One line, "home: ..." or "".
HOMEWHY_JS="(()=>{const l=document.querySelector('.recents');const up=!!l&&(l.classList.contains('shown')||getComputedStyle(l).visibility!=='hidden');const w=[...document.querySelectorAll('.webwindow')].map(e=>{const r=e.getBoundingClientRect();return Math.round(r.width)+'x'+Math.round(r.height)+(e.classList.contains('focused')?' focused':'')+(e.classList.contains('live')?'':' not-live')});return 'switcher '+(up?'UP':'down')+', web windows ['+w.join(', ')+']'})()"
homewhy() { local r; r=$(perl -e 'alarm 25; exec @ARGV' "$here/../cdp.sh" eval home "$HOMEWHY_JS" 2>/dev/null | tail -1 | tr -d '"'); [ -n "$r" ] && echo "home: $r"; }
invalid() { local h; h=$(homewhy); "$here/../shot.sh" "$OUT/invalid-$(date +%H%M%S).png" >/dev/null 2>&1
  echo "INVALID: $NAME wasn't on the screen $1 ($WHY${h:+; $h}) - frames of a game nobody sees say nothing (screenshot in $OUT)"; restore; exit 3; }
mi=0
for mode in "$@"; do
  mi=$((mi + 1)); lbl="$mode $mi/$#"
  case $mode in
    base|play) conf= ;; cap60) conf='dxgi.maxFrameRate = 60' ;; fifo) conf='dxgi.syncInterval = 1' ;;
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
  # A switcher left up is closed first (bf-lib.sh stray_switcher: the game would start under it, unseen), and what
  # was in front is said as it was.
  echo "$mode: before the launch: in front $("$A" shell "dumpsys activity activities | grep -m1 topResumedActivity" | tr -d '\r' | sed -nE 's#.* ([a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+) .*#\1#p'); $(stray_switcher)"
  # Home first (BF_HOME_FIRST=0: not): a launch while home's recent-apps overview or another app's task is in front
  # never brings the game's window forward - 7 of 9 ABZU runs 11-07 02:56-03:37 ended INVALID that way (in front
  # HomeShell/PowosWindowActivity, game layers 0 or a web layer behind it); the two valid ones came right after Home.
  # restore() starts the activity that was in front again. HACK: the real fix is a launch closing the overview, as
  # Android's does (docs/research/abzu-fps.md "Measurement friction"); then this line goes.
  # Home, then Back: 11-07 05:10 Home alone left the switcher (Steam + calculator cards) up and the run INVALID; Back
  # closes the switcher over home (shell/ui/recents.tsx) and does nothing on plain home.
  # A warm game reused (the job before left it in front) is neither sent behind home nor started again.
  if ! { [ "$mi" = 1 ] && [ -n "$warm" ]; }; then
    [ "${BF_HOME_FIRST:-1}" = 0 ] || { "$A" shell "input keyevent 3; sleep 1; input keyevent 4" >/dev/null 2>&1; sleep 1; }
    # A launch of this game Steam still holds, waiting on the user (bf-ask.sh): every new launch joins it and nothing
    # starts - ABZU 11-07 15:44 cloud sync "syncfailed", then 4 runs "no game window" with no game process at all.
    # HACK: this verify job closes Steam (its idle window; bf-start.sh starts it again) so the launch is a fresh one;
    # the real fix is the launch showing Steam's question - a nameless steamwebhelper dialog that powos-open-task's
    # "Steam Dialog" caption match never brings forward (docs/REMOTE-POWOS.md section 4).
    ask=$(asuser bf-ask.sh | tail -1)
    if [ "${ask:-ask none}" != "ask none" ]; then
      echo "$mode: Steam holds a launch of $NAME waiting on the user (${ask#ask }) - closing Steam so this one starts fresh"
      asuser bf-stop.sh --steam >/dev/null
    fi
    asuser bf-start.sh >/dev/null
  fi
  pill "$lbl: waiting for the game window"
  # The window, waited for only while the rest of this mode still fits the budget (WIN_S overrides).
  w0=$(date +%s); extra=0; [ "$mode" = play ] && extra=35  # play: keys + grabs + 10 s in the level
  left=${WIN_S:-$(( T0 + BUDGET_S - AFTER_WIN_S - extra - w0 ))}; [ "$left" -ge 20 ] || left=20
  win=$(asuser bf-window.sh wait "$left" "$i0" | tail -1)
  case $win in touched) abort ;; win=[0-9]*) ;; *) ask=$(asuser bf-ask.sh | tail -1)
    echo "FAIL no game window: $NAME showed none in $left s ($win)$([ "${ask:-ask none}" != "ask none" ] && echo "; Steam waits on the user for its launch: ${ask#ask }")"; restore; exit 5 ;; esac
  echo "$mode: window after $(( $(date +%s) - w0 )) s: $win"; echo "$win" | sed 's/win=//; s/screen=/on /' > "$M/window.txt"
  st=45; [ "$mi" = 1 ] && [ -n "$warm" ] && st=${WARM_SETTLE_S:-10}  # a warm game settled in the job before
  pill "$lbl: game up - settling $st s"
  nap $st  # KWin opens the game as its own task (folded) or home's web window (unfolded): nothing to bring forward
  onscreen; ok=$?; top=$TOP
  # Unity maps a 314x208 window first and goes full screen later: the size that counts is the one after the settle.
  win2=$(asuser bf-window.sh | tail -1); echo "$mode: after the settle: $win2"
  echo "$win2" | sed 's/win=/settled /; s/screen=/on /' >> "$M/window.txt"
  echo "$mode: in front: $top ($WHY)"; echo "front $top" >> "$M/window.txt"
  [ $ok = 0 ] || invalid "after the settle"
  if [ "$mode" = play ]; then
    # play: from the menu into a level (bf-play.sh: keys + a grab after each, pulled into the mode's folder), 10 s in
    # play, then the same measurement - the scene the user plays, not the title screen (11-06: menu 116 fps, play 38).
    pill "$lbl: into a level"
    # The pad presses are an input device on the phone: marked as the tools' own for the keys' run (+15 s).
    nk=$(set -- ${BF_PLAY_KEYS:-Return Return Return Return Return Return}; echo $#)
    echo "$mode: $(ASUSER_PRE=$(self_input_for $(( nk * ${BF_PLAY_GAP_S:-3} + 15 ))) asuser bf-play.sh /var/tmp/powos-bfplay ${BF_PLAY_KEYS:-} | tail -1)"
    "$A" pull /data/powos/root/var/tmp/powos-bfplay "$M/" >/dev/null 2>&1; "$A" shell "su -c 'rm -rf /data/powos/root/var/tmp/powos-bfplay'"
    nap 10; onscreen || invalid "after entering play"
  fi
  # The session log's line at the measurement's start: Xwayland's 30 s KGSL lines and KWin's 5 s frame lines come only
  # while something happens, so a stalled game leaves none in the window - the lines before it (11-08 02:02: "game 37 >
  # xwayland 38" from before the stall while KWin got 0 commits; the stall read as the web window's consumer's).
  l1=$("$A" shell "su -c 'wc -l < $LOG'" | tr -d '\r ')
  input_inject 32
  "$A" shell "su -c 'rm -rf /data/local/tmp/bfp /data/local/tmp/bfprof; nohup sh /data/local/tmp/powos-bf-present.sh 30 \"PowosWindowActivity|SurfaceView|powos-direct|powos-ww-[0-9]+-linux|steam_app${WIN_NAME:+|$WIN_NAME}\" /data/local/tmp/bfp ${BF_REC_S:-20} >/dev/null 2>&1 &
    nohup sh /data/local/tmp/powos-bf-prof.sh 30 /data/local/tmp/bfprof >/dev/null 2>&1 &'"
  pill "$lbl: measuring frames (30 s)"; nap 30
  onscreen || invalid "during the measurement"
  pill "$lbl: collecting the numbers"
  # bf-present (its screen recording) and bf-prof finished, at most 30 s more; then the session log's Xwayland KGSL and
  # KWin window-task lines of this mode, and prof.txt - one call.
  "$A" shell "su -c 'mkdir -p /data/local/tmp/bfp; for i in \$(seq 30); do [ -f /data/local/tmp/bfprof/done ] && ! pgrep -f powos-bf-present.sh >/dev/null && break; sleep 1; done
    { head -n $l1 $LOG | tail -n +$((l0 + 1)) | grep -E \"Xwayland KGSL|window task\"; echo \"Xwayland KGSL: == measuring\"; echo \"window task == measuring\"
      tail -n +$((l1 + 1)) $LOG | grep -E \"Xwayland KGSL|window task\"; } > /data/local/tmp/bfp/log.txt; cp /data/local/tmp/bfprof/prof.txt /data/local/tmp/bfp/ 2>/dev/null
    logcat -d -t 400 -s Andromarchy:I | grep \" pacing: \" | tail -8 > /data/local/tmp/bfp/consumer.txt
    dumpsys SurfaceFlinger --oplus vrr | grep -A3 -E \"^OTI Status|^CVT:\" | grep -vE \"^ +\\{ fps\" > /data/local/tmp/bfp/oti.txt
    dumpsys SurfaceFlinger | grep requestedFrameRate | grep -E \"SurfaceView|powos-direct|PowosWindowActivity\" | sed -E \"s/^[^A-Za-z]*//\" | head -6 >> /data/local/tmp/bfp/oti.txt
    logcat -d -t 2000 -s Andromarchy:I | grep \"surface votes\" | tail -4 >> /data/local/tmp/bfp/oti.txt; chmod -R 755 /data/local/tmp/bfp'" >/dev/null
  "$A" pull /data/local/tmp/bfp "$M/" >/dev/null && mv "$M"/bfp/* "$M"/ && rmdir "$M/bfp"
  grep "Xwayland KGSL" "$M/log.txt" > "$M/kgsl.txt"; grep "window task" "$M/log.txt" > "$M/kwin.txt"; rm -f "$M/log.txt"
  sed "s/^/kwin $mode: /" "$M/kwin.txt" | tail -5; sed "s/^/prof $mode: /" "$M/prof.txt" 2>/dev/null
  sed "s/^/oti $mode: /" "$M/oti.txt" 2>/dev/null
  "$A" shell "su -c 'rm -rf /data/local/tmp/bfp /data/local/tmp/bfprof'"
  # The next mode needs a fresh start (its dxvk.conf); the last one is closed (or frozen again) by restore.
  [ $mi -lt $# ] && { pill "$lbl: closing the game"; asuser bf-stop.sh >/dev/null; }
done
echo "== done $(date +%T)"; restore warm
pill "comparing $(echo "$*" | sed 's/ / vs /g')"
# uv runs it with its own numpy (the script's inline deps, uv's cache): nothing installed into the Mac's python.
# The per-layer rate table (game > Xwayland > KWin > consumer > SurfaceFlinger > panel, skin), before the board line.
python3 -I "$here/bf-layers.py" "$OUT" "$@"
# BF_APP: bf-frames.py compares the fps with this game's last PASSes (its history) and FAILs a measurement that isn't
# the game on the screen (11-08 02:02: "PASS ... 2.3 fps ... front HomeShell" while the game made 37/s).
BF_APP=$APP uv run --quiet --script "$here/bf-frames.py" "$OUT" "$@"
