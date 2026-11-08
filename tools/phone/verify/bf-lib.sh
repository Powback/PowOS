# bf-lib.sh: (sourced in the PowOS session as powos by bf-resume-phone.sh and bf-launchpaths-phone.sh) Broforce's
# launch / freeze / resume as checked steps. Each step says what it does on the verify status pill, asserts that it
# happened (the game's X window mapped + KWin's task, Steam's sleep cgroup frozen with the game's tasks in it and not
# running, new frames after the resume) and prints "FAIL <step>: <evidence>" otherwise. A touch: what this check
# started is closed, exit 3 (the queue retries in the next window).
# Mac side (bf-pacing.sh, bf-run.sh, bf-checker.sh, bf-fold.sh): `BF_ADB=<tools/phone/adb.sh> . bf-lib.sh` defines
# only pill <text>: the same step file, written over adb as the session user (at most 15 s), and the log line.
if [ -n "${BF_ADB:-}" ]; then
  # `BF_ADB=$A . bf-lib.sh` sets BF_ADB only while this file is sourced: kept for pill(), which runs later (under
  # set -u, "BF_ADB: unbound variable" failed every bf-pacing/bf-checker/bf-fold job, 2026-10-23 05:02).
  BF_ADB_PATH=$BF_ADB
  pill() { local b; b=$(printf '%s\n' "$1" | base64 | tr -d '\n')
    perl -e 'alarm shift; exec @ARGV' 15 "$BF_ADB_PATH" shell "su -c 'sh /data/powos/powos-run.sh \"umask 022; echo $b | base64 -d > /tmp/powos-verify-step\"'" >/dev/null 2>&1
    echo "-- $(date +%T) $1"; }
  # cfg:<x86|arm64> as a check's FIRST argument (bf-pacing.sh, bf-checker.sh): the game runs under that compat tool
  # for this check only (bf-cfg-phone.sh), the user's choice back at the end. cfg_take "$@" sets CFG_TO (empty = as
  # installed) and CFG_ARGS (the rest); cfg_set before the first launch, cfg_restore in the check's restore().
  cfg_take() { local a; CFG_TO= CFG_ARGS=()  # a cfg: anywhere counts (the last one wins); never a mode
    for a in "$@"; do case $a in cfg:*) CFG_TO=${a#cfg:} ;; *) CFG_ARGS+=("$a") ;; esac; done; }
  cfg_run() { local here_; here_=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    "$BF_ADB_PATH" push "$here_/bf-cfg-phone.sh" /data/local/tmp/powos-bf-cfg-phone.sh >/dev/null \
      && "$BF_ADB_PATH" push "$here_/bf-stop.sh" /data/local/tmp/powos-bf-stop.sh >/dev/null \
      && "$BF_ADB_PATH" push "$here_/../../../targets/android/pkgs/steam/powos-steam-compat" /data/local/tmp/powos-steam-compat >/dev/null \
      || { echo "ENV: can't push bf-cfg-phone.sh"; return 5; }
    "$BF_ADB_PATH" shell "su -c 'cp /data/local/tmp/powos-bf-cfg-phone.sh /data/local/tmp/powos-bf-stop.sh /data/local/tmp/powos-steam-compat /data/powos/root/var/tmp/; chmod 644 /data/powos/root/var/tmp/powos-bf-cfg-phone.sh /data/powos/root/var/tmp/powos-steam-compat; sh /data/powos/powos-run.sh \"APP=${APP:-274190} bash /var/tmp/powos-bf-cfg-phone.sh $*\"'" 2>&1 | grep -v sysvipc | tr -d '\r'; }
  cfg_set() { [ -n "$CFG_TO" ] || return 0; pill "setup cfg:$CFG_TO (closing Steam)"; cfg_run set "$CFG_TO"; }
  cfg_restore() { [ -n "$CFG_TO" ] || return 0; cfg_run restore; }
  # gus:<Key=Value[,Key=Value]> anywhere in a check's arguments (bf-pacing.sh): those keys in an Unreal game's own
  # GameUserSettings.ini (its Proton prefix: AppData/Local/<Game>/Saved/Config/Windows*/) for this check only - e.g.
  # ABZU's render scale, gus:ResolutionScale=SCALE_75 (abzu-fps, 2026-11-07). Only keys already in the file are set.
  # The user's file is kept as <ini>.powos-gus-bak (once: a check killed mid-way never makes the test values the
  # backup) and put back by gus_restore after the game closed (UE writes the file again at exit). gus_take "$@" sets
  # GUS and GUS_ARGS (the rest); call it on cfg_take's CFG_ARGS.
  gus_take() { local a; GUS= GUS_ARGS=()
    for a in "$@"; do case $a in gus:*) GUS=${a#gus:} ;; *) GUS_ARGS+=("$a") ;; esac; done; }
  gus_ini() {  # the phone-side snippet that sets $f to the game's GameUserSettings.ini (empty: none)
    echo "f=\$(ls /data/powos/root/home/powos/.local/share/Steam/steamapps/compatdata/${APP:-274190}/pfx/drive_c/users/steamuser/AppData/Local/*/Saved/Config/Windows*/GameUserSettings.ini 2>/dev/null | grep -v /UnrealEngine/ | head -1)"; }
  gus_set() { [ -n "$GUS" ] || return 0; local kv sets=
    case "$GUS" in *[!A-Za-z0-9_.,=-]*) echo "gus: '$GUS': letters, digits and _ . - only"; return 5 ;; esac
    for kv in $(echo "$GUS" | tr , ' '); do
      sets="$sets if grep -q \"^${kv%%=*}=\" \$f; then sed -i \"s|^${kv%%=*}=.*|$kv|\" \$f; echo \"gus: $kv\"; else echo \"gus: ${kv%%=*} not in \$f - not set\"; fi;"; done
    pill "setup gus:$GUS"
    "$BF_ADB_PATH" shell "su -c '$(gus_ini); [ -n \"\$f\" ] || { echo \"gus: no GameUserSettings.ini for app ${APP:-274190}\"; exit 5; }; [ -f \$f.powos-gus-bak ] || cp -p \$f \$f.powos-gus-bak; $sets'" | tr -d '\r'; }
  gus_restore() { [ -n "$GUS" ] || return 0
    "$BF_ADB_PATH" shell "su -c '$(gus_ini); [ -n \"\$f\" ] && [ -f \$f.powos-gus-bak ] && cat \$f.powos-gus-bak > \$f && rm \$f.powos-gus-bak && echo \"gus: the game settings restored\"'" | tr -d '\r'; }
  # switcher_state: "up" / "down" / "?" - the switcher (recents overview) as PowOS's window log last said ("switcher
  # up|down", Switcher.open; older builds: "windows hidden under the switcher" / "shown again (switcher down)").
  switcher_state() { local l
    l=$(perl -e 'alarm shift; exec @ARGV' 15 "$BF_ADB_PATH" shell "su -c 'grep -E \"Switcher: switcher (up|down|closed)|windows hidden under the switcher|windows shown again \\(switcher down\\)\" /data/data/com.powos.app/files/window-log.txt | tail -1'" 2>/dev/null | tr -d '\r')
    case $l in *"switcher up"*|*"hidden under the switcher"*) echo up ;; *"switcher down"*|*"switcher closed"*|*"shown again"*) echo down ;; *) echo "?" ;; esac; }
  # stray_switcher: before a launch, a switcher left up (agent abzu-fps 11-07 02:58 / 03:36: the game started under it
  # and ran unseen) is closed with Home - sent only when it IS up: over home's main page Home opens it
  # (ShellActivity.homePressed). Prints what it found.
  stray_switcher() { local s; s=$(switcher_state)
    [ "$s" = up ] || { echo "switcher before the launch: $s"; return 0; }
    "$BF_ADB_PATH" shell "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1"; sleep 1
    echo "switcher before the launch: up - closed (Home); now $(switcher_state)"; }
  # front_back <component>: the activity that was in front put back - never PowosWindowActivity by name: started bare
  # it is an EMPTY window task (no Linux window in it), which covered home's web windows on the next check (agent
  # abzu-fps 11-07 04:19 "in front=PowosWindowActivity", the game behind it). Home instead (its explicit component,
  # not the HOME intent: that would be a Home press).
  front_back() { case $1 in "") ;; */*PowosWindowActivity*|*/*SwitcherActivity*) "$BF_ADB_PATH" shell "am start -n com.powos.app/andro.marchy.HomeShell >/dev/null 2>&1" ;;
    *) "$BF_ADB_PATH" shell "am start -n $1 >/dev/null 2>&1" ;; esac; }
  # INPUT=touch|key|pad (bf-pacing.sh; oti-cap 11-06, bf-60-cap 11-08): what a player who touches the
  # screen / only uses keys / a pad sees. ColorOS's touch idle (OTI, `dumpsys SurfaceFlinger --oplus vrr` "CVT:
  # CurrentRate [60, oti-adfr]") wakes SurfaceFlinger at 60 Hz 2.5 s after the last touch under a 120 Hz panel, so a
  # run nobody touches measures that 60 (user 11-06: "dw about 60 no touch" - judge 120 with the screen touched).
  # input_inject <secs>: one phone-side loop, a tap at the screen's centre / keyboard SCROLL_LOCK / gamepad THUMBL
  # every ~1 s for <secs> s (`input`: no touch IRQ, so the checks' own touch abort stays quiet; marked as the tools'
  # own input for idle.sh). Nothing when INPUT is unset.
  input_check() { case ${INPUT:-} in ''|touch|key|pad) ;; *) echo "INPUT: touch, key or pad"; return 2 ;; esac
    [ -z "${INPUT:-}" ] || echo "input probe: INPUT=$INPUT, one event/s over the measurement"; }
  input_inject() { local ev
    case ${INPUT:-} in touch) ev='input tap $((${s%x*} / 2)) $((${s#*x} / 2))' ;;
      key) ev='input keyboard keyevent KEYCODE_SCROLL_LOCK' ;; pad) ev='input gamepad keyevent KEYCODE_BUTTON_THUMBL' ;;
      *) return 0 ;; esac
    "$BF_ADB_PATH" shell "echo \$((\$(date +%s) + $1 + 5)) > /data/local/tmp/powos-selfinput
      nohup sh -c 's=\$(wm size | tail -1 | sed \"s/.*: //\"); e=\$((\$(date +%s) + $1)); while [ \$(date +%s) -lt \$e ]; do $ev; sleep 1; done' >/dev/null 2>&1 &"; }
  return 0
fi
# APP / GAME / WIN_NAME: the game under test - any Steam app id (default 274190, Broforce, the test case); GAME =
# Steam's name for it (appmanifest), WIN_NAME = its X window's name (default GAME). td-launch-phone.sh sets Teardown's.
steam_field() {  # steam_field <appid> <name|installdir>: from Steam's appmanifest (any library folder)
  local S=$HOME/.local/share/Steam f
  for f in "$S/steamapps/appmanifest_$1.acf" $(sed -nE 's/^\s*"path"\s*"(.*)"/\1/p' "$S/steamapps/libraryfolders.vdf" 2>/dev/null | sed "s|\$|/steamapps/appmanifest_$1.acf|"); do
    [ -f "$f" ] && { sed -nE "s/^\s*\"$2\"\s*\"(.*)\"/\1/p" "$f" | head -1; return; }; done; }
APP=${APP:-274190}
GAME=${GAME:-$(steam_field "$APP" name)}; GAME=${GAME:-app $APP}
WIN_NAME=${WIN_NAME:-$GAME} GLOG=/run/powos-app/powos-sleep-gui.log
export APP
RESUME_MS=${RESUME_MS:-3000}  # resume -> the game's first new frame, at most
LAUNCH_S=${LAUNCH_S:-360}     # a cold start's window (Steam + Proton under FEX), at most
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app} DISPLAY=${DISPLAY:-:0}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
XAUTHORITY=$(tr '\0' '\n' < "/proc/$(pgrep -x Xwayland | head -1)/cmdline" | grep -A1 -x -- -auth | tail -1); export XAUTHORITY
T=$(mktemp -d /tmp/bf-check.XXXX)
mine=0 FAILS=""
now() { date +%s.%N; }
ms() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%d", (b - a) * 1000}'; }
irq() { awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}' /proc/interrupts; }
I0=$(irq)
close_mine() { eval "${ON_CLOSE:-:}";  # eval: ON_CLOSE="fexcache_off; restore" ran as one word ("command not found"), restore never ran
  [ $mine = 1 ] && { pill "closing $GAME (this check started it)"; echo "== closing what this check started"; bash /var/tmp/powos-bf-stop.sh | head -1; mine=0
    # A diagnosis' second hand-off (handoff_diag) can start the game a few s AFTER this close: bf-return 2026-11-05
    # 12:10 left Broforce running 23 min (reaper 12:10:52, closed 12:10:50) - so watch for it and close it too.
    [ "${RETRIED:-0}" = 1 ] && for _ in $(seq 20); do [ -n "$(reaper)" ] && { echo "   the retried launch came after: $(bash /var/tmp/powos-bf-stop.sh | head -1)"; break; }; sleep 1; done; }
  rm -rf "$T" /tmp/powos-verify-step; }
touched() { [ "$(irq)" != "$I0" ] || return 1; echo "user input $(date +%T) - stopping"; close_mine; exit 3; }
# HACK: the Mac side (queue.sh's budget kill) ends adb first, so this script's stdout is a dead pipe before its TERM comes:
# the next pill/echo got SIGPIPE and bash died WITHOUT running this trap, leaving the game it started running
# (Broforce, 2026-10-24 06:50/06:55, blocked idle.sh --wait for hours). So PIPE is trapped too, and the handler
# first points its own output at a file. Real fix would be a phone-side watchdog independent of the adb pipe.
stopped() { trap '' HUP TERM INT PIPE; exec >>/tmp/powos-bf-trap.log 2>&1 </dev/null
  echo "stopped from outside ($1) $(date +%T)"; close_mine; exit 3; }
trap 'stopped TERM' HUP TERM INT
trap 'stopped PIPE' PIPE
fail() { echo "FAIL $1: $2"; FAILS="$FAILS $1"; }

# pill <text>: the check's current sub-step while the queue runs it: the runner's heartbeat shows
# /tmp/powos-verify-step under the check's name with its age ("waiting for the game window · 45 s", queue.sh put);
# the pill's file is rewritten now too (its "prev" line = the step, "step"/"stepel" for newer APKs).
pill() {
  printf '%s\n' "$1" > /tmp/powos-verify-step
  python3 - "$1" <<'PY' 2>/dev/null
import json, os, sys
for p in ("/run/powos-app/verify/status.json", "/run/powos-app/verify-status.json"):
    try:
        s = json.load(open(p))
    except (OSError, ValueError):
        continue
    if s.get("done") or "task" not in s:
        continue
    s["prev"] = sys.argv[1] + " · 0 s"
    s["step"], s["stepel"] = sys.argv[1], 0
    t = p + ".bf"
    with open(t, "w") as f:
        json.dump(s, f)
    os.chmod(t, 0o644)
    os.replace(t, p)
PY
  echo "-- $(date +%T) $1"
}

steam_pid() { cat ~/.steam/steam.pid 2>/dev/null; }
under() { local a=$1; while [ -n "$a" ] && [ "$a" -gt 1 ]; do [ "$a" = "$2" ] && return 0; a=$(awk '{print $4}' "/proc/$a/stat" 2>/dev/null); done; return 1; }
# The game's own launch chain. A Steam launch first runs the game's install script evaluator through the same reaper
# (`SteamLaunch AppId=<id> Install=1`, Proton `run iscriptevaluator.exe`): that one is iscript_reapers, never the game's
# (bf-coldstart took its pressure-vessel / wineserver for the game's, 2026-10-23).
reapers() { local p; for p in $(pgrep -f "SteamLaunch AppId=$APP( |\$)"); do grep -qa 'Install=1' "/proc/$p/cmdline" 2>/dev/null || echo "$p"; done; }
iscript_reapers() { pgrep -f "SteamLaunch AppId=$APP Install=1"; }
reaper() { local p; for p in $(reapers); do under "$p" "$(steam_pid)" && { echo "$p"; return; }; done; }  # Steam's own
tree() { local t=("$1") o=() p; while ((${#t[@]})); do p=${t[0]}; t=("${t[@]:1}"); [ -n "$p" ] && o+=("$p") && t+=($(pgrep -P "$p")); done; echo "${o[*]}"; }
ticks() { local n=0 p f; for p in "$@"; do f=$(cat "/proc/$p/stat" 2>/dev/null) || continue; f=${f##*) }; set -- $f; n=$((n + ${12} + ${13})); done; echo "$n"; }
# gamewin: the game's X window - the one named WIN_NAME, else one whose name starts with "WIN_NAME " (games that put
# their build in the title: Noita's "Noita - Build Aug 12 2024 - ..." under Steam's name "Noita").
gamewin() { { xwininfo -root -tree 2>/dev/null | awk -v n="\"$WIN_NAME\"" -v p="\"$WIN_NAME " '
  /has no name/ {next} index($0, n) {print $1; f = 1; exit} !q && index($0, p) {q = $1} END {if (!f && q) print q}' | grep . \
  || xdotool search --onlyvisible --class "^steam_app_$APP\$" 2>/dev/null | head -1 | awk '{printf "0x%x\n", $1}'; } \
  | head -1; }  # one id: Besiege (11-07) gave "0x5200003\n0x5200003" and bf-xframes.py died on it
# (else Proton's class steam_app_<id>: a game whose title isn't its Steam name at all, e.g. ABZU's "AbzuGame")
mapped() { xwininfo -id "$1" 2>/dev/null | awk '/Map State/ {print $3}'; }
active() { printf '%d' "$(xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | awk '{print $NF}')" 2>/dev/null; }
# cg2 <pid>: its cgroup v2 path (the "0::" line: since the 02:07 boot /proc/<pid>/cgroup also lists v1 hierarchies -
# freezer, memory:/apps, cpuset, cpu, blkio - and the whole file read as the path made every freeze look missing:
# bf-resume "FAIL freeze-auto" 02:58 while powos-sleep-gui had frozen Steam at 02:56:50).
cg2() { sed -n 's/^0:://p' "/proc/$1/cgroup" 2>/dev/null; }
cg() { local c; c=$(cg2 "$(steam_pid)"); case $c in */powos/sleep/*) echo "/sys/fs/cgroup$c" ;; esac; }
# steam_cm_state: Steam's CM link from the kernel (no thaw): the newest ConnectionCompleted's local port in
# connection_log and its TCP state - "live" (ESTABLISHED), "closed <hex state>" (the server dropped it), "none".
steam_cm_state() {
  local p s; p=$(grep -a -o -E 'ConnectionCompleted\(\) \([^)]*\) local address \([^)]*:[0-9]+\)' "$HOME/.local/share/Steam/logs/connection_log.txt" 2>/dev/null | tail -1 | sed -E 's/.*:([0-9]+)\)$/\1/')
  [ -n "$p" ] || { echo none; return; }
  s=$(awk -v p=":$(printf '%04X' "$p")" 'FNR > 1 && substr($2, length($2) - 4) == p { print $4; exit }' /proc/net/tcp /proc/net/tcp6)
  case $s in 01) echo live ;; '') echo none ;; *) echo "closed $s" ;; esac; }
watcher() { grep -i "steam\|app $APP" "$GLOG" | tail -${1:-2} | cut -c1-200 | tr '\n' '|'; }
# Frames of an X window: Xlib's XGetImage from python3 + ctypes. Not ffmpeg's x11grab: FFmpeg 9 only grabs through
# MIT-SHM, and Android's kernel has no System V shared memory - "Could not get shared memory buffer" / "Error during
# demuxing: Permission denied", no frame ever (every bf-coldstart "frame -", bf-checker's grabs, bf-fold's "changes",
# 2026-10-23; FFmpeg 8 still fell back to plain GetImage). A sample = 16 rows of the window, every 64th pixel.
#   xframes first <window name> <s>        epoch s of the named window's first drawn frame (looked up again each sample:
#                                          Unity maps a 314x208 window, then goes full screen): a sample that isn't flat
#                                          (brightest - darkest > 24) or differs from the window's first sample
#   xframes change <window id> <s> <fps>   epoch s of the first sample that differs from the first one
#   xframes count <window id> <s> <fps>    the number of distinct samples in <s> s (1 = a still window, 0 = none)
#   xframes grab <window name> <s> <dir>   whole frames as PNG for <s> s, 1 a second: <dir>/h%03d.png half size (every
#                                          2nd pixel, as bf-checker.py scores), f<n>.png full size every 10 s, a line
#                                          "<n> <time> <window> <WxH>" per 10 s in <dir>/grab.log, "done" at the end
# "none" when nothing came in <s>. The time is the sample's start (a sample takes a few ms; a whole frame ~0.2 s).
xframes() { python3 "${BF_XFRAMES:-/var/tmp/powos-bf-xframes.py}" "$@" || echo none; }  # body: bf-xframes.py
first_frame() { xframes first "$WIN_NAME" "$1"; }  # first_frame <s>: the game's first drawn frame (xframes first)
first_change() { xframes change "$1" "$2" "$3"; }  # first_change <window> <s> <fps>: its first new frame (xframes change)
open_task() {  # open_task <timeout s> <app id>: the drawer's / widget's launch path; its status line
  # POWOS_NO_LAUNCH_RECORD: the check records its own measured launches for the compat policy (bf-coldstart), not twice.
  # setsid: a Steam this launch starts (cold, or /usr/bin/steam's restart fallback) is the check's descendant
  # otherwise, in its session - the check then died silently at its close, no RESULT line (04:34 bf-coldstart, 06:32
  # bf-launchpaths: every step passed, then "FAIL run: no RESULT line"); a Steam started from the drawer isn't either.
  POWOS_NO_LAUNCH_RECORD=1 setsid -w timeout "$1" powos-open-task --app-id "$2" -- steam steam://rungameid/$APP >"$T/open.out" 2>&1 </dev/null
  # Its status line only (task / desktop / failed: ...): its stderr says "powos-open-task: Steam asks ..." too, and
  # 11-08 02:29 that line was read as the status - a FAIL launch for a game shown as its task.
  grep -m1 -E '^powos-open-task: (task|desktop|failed)' "$T/open.out" || echo "no status line"; }
# steam_ask: what Steam holds this launch of APP for, waiting on the user (bf-ask.sh's test: the newest GameAction of
# APP in console_log is "LaunchApp waiting for user response to <what>", older than 5 s - Steam continues its own steps
# within the second); status 1 when nothing. The user's question: a check never answers it, it SKIPs.
steam_ask() {
  local line t age; line=$(tail -c 4194304 "$HOME/.local/share/Steam/logs/console_log.txt" 2>/dev/null | grep -a "GameAction \[AppID $APP, ActionID " | tail -1)
  case $line in *"LaunchApp waiting for user response to "*) ;; *) return 1 ;; esac
  t=$(printf '%s\n' "$line" | sed -nE 's/^\[([0-9-]+ [0-9:]+)\].*/\1/p')
  age=$(( $(date +%s) - $(date -d "$t" +%s 2>/dev/null || date +%s) )); [ "$age" -gt 5 ] || return 1
  printf '%s\n' "$line" | sed -E 's/.*waiting for user response to //' | tr -d '\r' | cut -c1-80; }

# A launch chain outside Steam's tree (left by a dead Steam) is never frozen nor resumed and holds Proton's prefix: gone.
clean_stale() {
  local p s=""; for p in $(reapers); do under "$p" "$(steam_pid)" || s="$s $p"; done
  [ -n "$s" ] || return 0
  echo "stale Broforce launch chain(s) outside Steam:$s - closing them"
  for p in $s; do kill -9 $(tree "$p") 2>/dev/null; done; sleep 2
}

# handoff_diag: why a running Steam didn't take a steam:// launch: its state, its threads' states + the main thread's
# wchan, its cgroup, steam.pipe's mtime (the URL was written into it then), the frozen sleep cgroups (a D-Bus / X peer
# it may wait on), powos-sleep-gui's last lines. One line. handoff_detail: the rest, as "handoff:" lines - what decides
# where the URL got stuck: bytes still unread in steam.pipe (>0 = the client never read it; 0 = read and dropped), the
# main thread's syscall + wakeups in 1 s (its loop runs ppoll 50 ms when healthy, ~20/s), the forwarder's output,
# the main thread's stack (gdb), and a second hand-off of the same URL (taken = the first write was lost, not the client).
handoff_diag() {
  local p; p=$(steam_pid)
  echo "steam $p $(awk '{print "state " $3}' "/proc/$p/stat" 2>/dev/null || echo gone) threads $(cat /proc/"$p"/task/*/stat 2>/dev/null | awk '{print $3}' | sort | uniq -c | tr -s ' \n' ' ')wchan $(cat "/proc/$p/wchan" 2>/dev/null) cgroup $(cut -d: -f3 "/proc/$p/cgroup" 2>/dev/null | tail -1) exe $(readlink "/proc/$p/exe" 2>/dev/null); pipe written $(date -r ~/.steam/steam.pipe +%T 2>/dev/null); frozen cgroups: $(for f in /sys/fs/cgroup/powos/sleep/*/cgroup.freeze; do [ "$(cat "$f" 2>/dev/null)" = 1 ] && printf '%s ' "$(basename "$(dirname "$f")")"; done); console_log last: $(tail -1 "$HOME/.local/share/Steam/logs/console_log.txt" | cut -c1-120); sleep-gui: $(tail -2 "$GLOG" | cut -c1-160 | tr '\n' '|')"; }
# hang_diag <pid>: where a started game that shows no window stands - thread states, each thread's syscall number
# (/proc/<pid>/task/*/syscall: 98 futex, 73 ppoll, 63 read, 101 nanosleep on arm64; "running" = busy), wchans, CPU s,
# the sockets/pipes/files it has open (an X/Pulse/D-Bus peer it waits on), the newest files it wrote under $HOME.
# For any game (native or Wine): a cheap "is it busy, waiting on someone, or stuck" before guessing.
hang_diag() {
  local x=$1 t
  [ -d "/proc/$x" ] || { echo "pid $x gone"; return; }
  printf 'pid %s %s cpu %ss threads' "$x" "$(tr '\0' ' ' < /proc/$x/cmdline | cut -c1-90)" "$(sed 's/.*) //' /proc/$x/stat | awk '{printf "%.1f", ($12+$13)/100}')"
  for t in /proc/$x/task/*; do printf '%s:%s/%s/%s\n' "$(cut -c1-12 $t/comm 2>/dev/null | tr ' ' _)" "$(sed 's/.*) //' $t/stat 2>/dev/null | cut -d' ' -f1)" \
    "$(cut -d' ' -f1 $t/syscall 2>/dev/null)" "$(cat $t/wchan 2>/dev/null)"; done | sort | uniq -c | sort -rn | awk '{printf " %s%s", $2, ($1 > 1 ? "x" $1 : "")}' | cut -c1-700
  printf '; fds:'; ls -l /proc/$x/fd 2>/dev/null | awk '{print $NF}' | sed -E 's/\[[0-9]+\]//' | sort | uniq -c | sort -rn | head -8 | awk '{printf " %s x%s", $2, $1}'
  # Not Steam's own files (its web UI's htmlcache filled all 5 slots and hid Unity's Player.log, 2026-10-23 09:36).
  printf '; wrote:'; find "$HOME" -xdev -newer /proc/$x -type f ! -path '*/.local/share/Steam/*' ! -path '*/.cache/*' 2>/dev/null | head -8 | tr '\n' ' '; echo
  # Its preloads: LD_PRELOAD as it got it and which preloaded libraries it really mapped (the sysvipc shim: Android has
  # no System V IPC; Broforce native 10:19 spun on semget -> ENOSYS under FEX).
  echo "preload: env '$(tr '\0' '\n' < /proc/$x/environ 2>/dev/null | sed -n 's/^LD_PRELOAD=//p' | cut -c1-300)'; mapped: $(grep -o '[^/ ]*sysvipc[^ ]*\|[^/ ]*gameoverlayrenderer[^ ]*' /proc/$x/maps 2>/dev/null | sort -u | tr '\n' ' ')$(grep -c 'powos-sysvipc/x86_64' /proc/$x/maps 2>/dev/null) x86_64-shim maps"
  # The game's own log, last lines (Unity: ~/.config/unity3d/<company>/<product>/Player.log): where its start stands.
  local l; l=$(find "$HOME/.config" "$HOME/.local/share" -xdev -newer /proc/$x -type f \( -name '*.log' -o -name '*.txt' \) ! -path '*/Steam/*' 2>/dev/null | head -1)
  [ -n "$l" ] && { echo "game log $l ($(wc -l < "$l") lines), last:"; tail -12 "$l" | tr -d '\r' | cut -c1-160 | sed 's/^/  | /'; }
}
# hang_stack <pid>: WHERE the busiest thread of a started game is (a busy main thread with no window: Broforce native
# 2026-10-23, "exe" R at 100% for 4 min). gdb (in PowOS, no yama) attaches for one batch: the host backtrace (a thunked
# host library - Mesa, libX11 - shows by name) + registers; under FEX x28 = the JIT's guest state frame (CPUState:
# rip, then the 16 x86 gregs, rsp = gregs[4]), so the guest RIP and every guest return address on the x86 stack that
# lands in a file mapping is printed as file+offset (+ the nearest ELF symbol). Never on a frozen process (a SIGSTOP
# pending in a frozen cgroup outlives gdb: the Steam lesson of 04:40); SIGCONT after, in case gdb was killed. Lines
# start "stack:".
hang_stack() {
  local x=$1 tid
  [ -d "/proc/$x" ] || { echo "stack: pid $x gone"; return; }
  case $(cg2 "$x") in */powos/sleep/*) [ "$(cat "/sys/fs/cgroup$(cg2 "$x")/cgroup.freeze" 2>/dev/null)" = 1 ] && { echo "stack: $x frozen - not attaching"; return; } ;; esac
  command -v gdb >/dev/null || { echo "stack: no gdb"; return; }
  tid=$(for t in /proc/$x/task/*; do sed 's/.*) //' $t/stat 2>/dev/null | awk -v t="${t##*/}" '{print $12 + $13, t}'; done | sort -rn | head -1 | cut -d' ' -f2)
  # Before gdb: what the busy thread does with the kernel for 3 s - context switches, signals it took (FEX handles
  # unaligned atomics through SIGBUS), and the syscall mix (strace, when PowOS has it).
  local c0 c1 s0 s1
  c0=$(awk '/ctxt_switches/ {n += $2} END {print n}' /proc/$x/task/$tid/status 2>/dev/null); s0=$(awk '{print $10, $12}' /proc/$x/task/$tid/stat 2>/dev/null)
  if command -v strace >/dev/null; then timeout 3 strace -f -c -p "$x" -o "$T/strace.$x" >/dev/null 2>&1; kill -CONT "$x" 2>/dev/null
    echo "stack: syscalls in 3 s (strace -c): $(awk 'NR > 2 && $NF != "total" && $1 !~ /^-/ {print $NF "=" $4}' "$T/strace.$x" 2>/dev/null | head -12 | tr '\n' ' ')"
  else sleep 3; echo "stack: no strace in PowOS"; fi
  c1=$(awk '/ctxt_switches/ {n += $2} END {print n}' /proc/$x/task/$tid/status 2>/dev/null); s1=$(awk '{print $10, $12}' /proc/$x/task/$tid/stat 2>/dev/null)
  echo "stack: thread $tid in 3 s: $((${c1:-0} - ${c0:-0})) context switches; minflt/majflt $s0 -> $s1; signals caught: $(grep SigCgt /proc/$x/status | awk '{print $2}')"
  timeout 25 gdb -q -batch -nx -p "$tid" -ex 'set pagination off' -ex 'bt 14' -ex 'p/x $pc' -ex 'p/x $x28' -ex 'p/x $sp' -ex 'x/24i $pc-48' > "$T/gdb.$tid" 2>&1
  kill -CONT "$x" 2>/dev/null
  # body: bf-stack-syms.py (split out of this heredoc to keep hang_stack under the length budget)
  python3 /var/tmp/powos-bf-stack-syms.py "$x" "$tid" "$T/gdb.$tid" 2>&1 | head -40
}
# sems: the sysvipc shim's semaphores (/dev/shm/y700-sysv/sem-<id>: key, change count, values) - Steam's hand-off
# signal is one of them (the client's first, value 0 while idle).
sems() { python3 - <<'PY' 2>/dev/null
import glob, struct
for f in sorted(glob.glob("/dev/shm/y700-sysv/sem-[0-9]*")):
    b = open(f, "rb").read()
    _, _, _, seq, rm, n, key, _ = struct.unpack("IIiIiiii", b[:32])
    v = [struct.unpack("iiii", b[64 + 16 * i:80 + 16 * i])[0] for i in range(min(n, 4))]
    print("%s key %#x seq %d val %s%s" % (f.rsplit("-", 1)[1], key & 0xffffffff, seq, v, " removed" if rm else ""), end="; ")
PY
}
handoff_detail() {
  local p n0 n1 cl0; p=$(steam_pid)
  echo "handoff: steam.pipe unread bytes $(python3 -c 'import os,fcntl,termios,struct,sys
fd=os.open(sys.argv[1],os.O_RDONLY|os.O_NONBLOCK); print(struct.unpack("i",fcntl.ioctl(fd,termios.FIONREAD,b"\0"*4))[0])' ~/.steam/steam.pipe 2>&1 | tail -1); held by $(for d in /proc/[0-9]*; do ls -l "$d/fd" 2>/dev/null | grep -q 'steam\.pipe' && printf '%s ' "${d#/proc/}"; done)"
  n0=$(awk '/^voluntary/ {print $2}' "/proc/$p/status" 2>/dev/null); sleep 1; n1=$(awk '/^voluntary/ {print $2}' "/proc/$p/status" 2>/dev/null)
  echo "handoff: main thread syscall '$(cut -d' ' -f1-3 "/proc/$p/syscall" 2>/dev/null)' wchan $(cat "/proc/$p/wchan" 2>/dev/null), $((${n1:-0} - ${n0:-0})) wakeups in 1 s; steam processes: $(pgrep -a -f 'steamrtarm64/steam|^\./steam' | cut -c1-70 | tr '\n' '|')"
  echo "handoff: forwarder said: $(grep -v 'LD_PRELOAD\|^$' "$T/open.out" 2>/dev/null | tail -4 | cut -c1-140 | tr '\n' '|')"
  # No gdb here any more: its PTRACE_ATTACH sends SIGSTOP, and on a client unified sleep froze meanwhile gdb never got
  # it, `timeout` killed gdb and the SIGSTOP stayed pending - delivered at the next thaw, Steam sat stopped (state T,
  # do_signal_stop) and the next check's launch failed on that (2026-10-23 04:40 -> 04:59). The stack it gave twice
  # (04:32, 05:00): main thread in poll() <- vgui2_s.so <- steamui.so, a healthy main loop.
  echo "handoff: semaphores before: $(sems)"
  cl0=$(wc -l < "$HOME/.local/share/Steam/logs/console_log.txt")
  # Y700_SYSV_DEBUG: the shim logs the forwarder's semget/semop (pkgs/steam's sysvipc-emu): does it post the client's?
  RETRIED=1  # close_mine watches for the game this may start late
  ( cd ~ && Y700_SYSV_DEBUG=1 timeout 20 steam "steam://rungameid/$APP" > "$T/retry.out" 2>&1 < /dev/null )
  echo "handoff: semaphores after the second hand-off: $(sems); forwarder's IPC: $(grep -a 'sysvipc-emu' "$T/retry.out" | sed 's/^\[sysvipc-emu [0-9]*\] //' | tail -8 | cut -c1-90 | tr '\n' '|')"
  for _ in $(seq 20); do logged_since "$HOME/.local/share/Steam/logs/console_log.txt" "$cl0" "rungameid/$APP" && break; sleep 0.5; done
  echo "handoff: second hand-off (the same URL again): $(tail -n +$((cl0 + 1)) "$HOME/.local/share/Steam/logs/console_log.txt" | grep -q "rungameid/$APP" && echo "TAKEN" || echo "not taken either") - $(grep -v 'LD_PRELOAD\|^$' "$T/retry.out" | tail -2 | cut -c1-120 | tr '\n' '|')"
}

# logged_since <file> <lines before> <text>: <text> in a line after the first <lines before>. Not `tail | grep -q`: under
# the callers' `set -o pipefail` grep -q's early exit SIGPIPEs tail (141) and the pipeline reads as "not found" - Besiege
# 2026-11-07 01:05: "the running Steam didn't log the launch's URL in 20 s" while console_log had it 2 s after the tap.
logged_since() { awk -v n="$2" -v s="$3" 'NR > n && index($0, s) { f = 1; exit } END { exit !f }' "$1" 2>/dev/null; }
# step_launch: the game up through the drawer's path (a running one: brought up the same way). Sets W, LAUNCH.
# A Steam that runs (awake or frozen) logs the launch's URL at once ("ExecCommandLine ... steam://rungameid/<id>" in
# console_log): nothing in HANDOFF_S (20) = the launch was lost (2026-10-23 02:42: a -silent resident Steam took the
# URL into steam.pipe and never acted on it) - FAIL launch-handoff with handoff_diag, not a 6 min wait.
step_launch() {
  clean_stale
  local r t0 st e; r=$(reaper); W=$(gamewin)
  if [ -n "$r" ] && [ -z "$W" ] && [ "$(ps -o etimes= -p "$r" | tr -d ' ')" -gt 600 ]; then
    echo "a Broforce launch without a window for 10 min ($r) - closing it"; bash /var/tmp/powos-bf-stop.sh | tail -1; r=
  fi
  [ -z "$r" ] && mine=1
  pill "launching $GAME$([ -n "$r" ] && echo ' (already running)')"
  local CL=$HOME/.local/share/Steam/logs/console_log.txt cl0 up i q
  cl0=$(wc -l < "$CL" 2>/dev/null || echo 0); up=$([ -z "$r" ] && [ -d "/proc/$(steam_pid)" ] && echo 1)
  t0=$(now)
  # ${LAUNCH_S:-360}, not $LAUNCH_S: a phone copy sourced without the default above ran "LAUNCH_S: unbound variable"
  # under set -u - the launch wait was skipped in 11 ms and Broforce counted as a FAIL (2026-10-29).
  local ls_=${LAUNCH_S:-360}
  ( open_task $((ls_ + 10)) "steam_app_$APP" > "$T/open.status" ) &
  for i in $(seq $((ls_ * 2))); do W=$(gamewin); [ -n "$W" ] && [ "$(mapped "$W")" = IsViewable ] && break
    if [ "$up" = 1 ] && [ "$i" = $((${HANDOFF_S:-20} * 2)) ]; then
      if logged_since "$CL" "$cl0" "steam://rungameid/$APP"; then up=; echo "launch: Steam took the URL"
      elif logged_since "$CL" "$cl0" "Client version"; then up=; echo "launch: Steam restarted with the URL (/usr/bin/steam's fallback: $(grep '^steam: ' "$T/open.out" | tail -1))"
      else fail launch-handoff "the running Steam didn't log the launch's URL in ${HANDOFF_S:-20} s: $(handoff_diag); open-task: $(cat "$T/open.status" 2>/dev/null)"; handoff_detail; return 1; fi
    fi
    # Steam holding this launch for a question (steam_ask) is checked every 20 s, not only after LAUNCH_S: 11-08 03:53
    # game-present-rate waited out its 300 s job budget on "Steam took the URL" (a question left since 03:20) and
    # ended as "FAIL timeout" instead of this SKIP.
    if [ $((i % 40)) = 0 ] && q=$(steam_ask); then echo "SKIP Steam is asking: $q (the user's question - left unanswered)"; return 1; fi
    touched; sleep 0.5; done
  LAUNCH=$(ms "$t0" "$(now)")
  if [ -z "$W" ] || [ "$(mapped "$W")" != IsViewable ]; then
    q=$(steam_ask) && { echo "SKIP Steam is asking: $q (the user's question - left unanswered)"; return 1; }
    fail launch "no mapped $WIN_NAME window ${LAUNCH} ms after the launch (window '${W:-none}' $(mapped "${W:-0}")); steam $(steam_pid) frozen '$(cg)', reaper '$(reaper)' $(tree "$(reaper)" | wc -w) processes, watcher: $(watcher 3)"
    return 1
  fi
  for _ in $(seq 60); do [ -s "$T/open.status" ] && break; touched; sleep 0.5; done
  st=$(cat "$T/open.status" 2>/dev/null)
  echo "launch: window $W mapped ${LAUNCH} ms after the launch, $st"
  [ "$st" != "powos-open-task: task" ] && q=$(steam_ask) && { echo "SKIP Steam is asking: $q (the user's question - left unanswered)"; return 1; }
  [ "$st" = "powos-open-task: task" ] || fail launch "window $W is up but not shown as its own task: '${st:-still waiting}'"
  e=$(first_change "$W" 10 10)
  echo "launch: $([ "$e" = none ] && echo 'no new frame in 10 s (a still screen?)' || echo "drawing (a new frame $(ms "$t0" "$e") ms after the launch)")"
}

# freeze_ok: Steam's sleep cgroup frozen, every task of the game's chain in it, none of them running (prints evidence).
freeze_ok() {
  local c g n=0 in=0 p a b; c=$(cg); g=$(tree "$(reaper)")
  for p in $g; do n=$((n + 1)); [ "$(cg2 "$p")" = "${c#/sys/fs/cgroup}" ] && in=$((in + 1)); done
  a=$(ticks $g); sleep 2; b=$(ticks $g)
  EVID="cgroup ${c:-none}: cgroup.freeze=$(cat "$c/cgroup.freeze" 2>/dev/null) events '$(grep frozen "$c/cgroup.events" 2>/dev/null)', game tasks in it $in/$n, game CPU ticks in 2 s $((b - a)), window $(mapped "$W")"
  [ -n "$c" ] && [ "$(cat "$c/cgroup.freeze")" = 1 ] && grep -qx "frozen 1" "$c/cgroup.events" && [ $n -gt 0 ] && [ $in = $n ] && [ $((b - a)) = 0 ]
}

# step_freeze: `powos game <appid> freeze` (its window minimized, Steam + the game frozen). Sets FREEZE.
step_freeze() {
  local t0 out; touched; pill "freezing $GAME"; t0=$(now)
  out=$(powos game $APP freeze 2>&1 | tail -1)
  for _ in $(seq 20); do [ "$(cat "$(cg)/cgroup.freeze" 2>/dev/null)" = 1 ] && break; sleep 0.5; done
  FREEZE=$(ms "$t0" "$(now)")
  if freeze_ok; then echo "freeze: frozen in ${FREEZE} ms - $EVID"
  else fail freeze "'$out' -> $EVID; watcher: $(watcher)"; return 1; fi
}

# step_resume <label> <how...>: the launch path given (a command; open_task's status line counts), then: Steam out of
# its frozen cgroup, the same game, its window mapped, a new frame within RESUME_MS. Sets RES.
step_resume() {
  local label=$1 r0 t0 st f t; shift; touched; pill "resuming $GAME ($label)"
  r0=$(reaper); t0=$(now)
  st=$("$@" 2>&1 | tail -1)
  t=$(ms "$t0" "$(now)")
  for _ in $(seq 20); do [ "$(mapped "$W")" = IsViewable ] && break; sleep 0.25; done
  f=$(first_change "$W" 5 30)
  RES=$([ "$f" = none ] && echo none || ms "$t0" "$f")
  local ev="'$st' in $t ms, steam frozen '$(cg)', same game $([ "$(reaper)" = "$r0" ] && echo yes || echo "no ($r0 -> $(reaper))"), window $(mapped "$W"), focused $([ "$(active)" = "$(printf '%d' "$W")" ] && echo yes || echo no), first new frame ${RES} ms after the launch"
  if [ -z "$(cg)" ] && [ "$(reaper)" = "$r0" ] && [ "$(mapped "$W")" = IsViewable ] && [ "$RES" != none ] && [ "$RES" -ge 0 ] && [ "$RES" -le "$RESUME_MS" ] \
      && { [ "$label" = steam ] || [ "$st" = "powos-open-task: task" ]; }; then
    echo "resume ($label): $ev"
  else fail "resume-$label" "$ev; watcher: $(watcher)"; return 1; fi
}
