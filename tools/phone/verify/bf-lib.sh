# bf-lib.sh: (sourced in the PowOS session as powos by bf-resume-phone.sh and bf-launchpaths-phone.sh) Broforce's
# launch / freeze / resume as checked steps. Each step says what it does on the verify status pill, asserts that it
# happened (the game's X window mapped + KWin's task, Steam's sleep cgroup frozen with the game's tasks in it and not
# running, new frames after the resume) and prints "FAIL <step>: <evidence>" otherwise. A touch: what this check
# started is closed, exit 3 (the queue retries in the next window).
# Mac side (bf-pacing.sh, bf-run.sh, bf-checker.sh, bf-fold.sh): `BF_ADB=<tools/phone/adb.sh> . bf-lib.sh` defines
# only pill <text>: the same step file, written over adb as the session user (at most 15 s), and the log line.
if [ -n "${BF_ADB:-}" ]; then
  pill() { local b; b=$(printf '%s\n' "$1" | base64 | tr -d '\n')
    perl -e 'alarm shift; exec @ARGV' 15 "$BF_ADB" shell "su -c 'sh /data/powos/powos-run.sh \"umask 022; echo $b | base64 -d > /tmp/powos-verify-step\"'" >/dev/null 2>&1
    echo "-- $(date +%T) $1"; }
  return 0
fi
APP=274190 GLOG=/run/powos-app/powos-sleep-gui.log
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
close_mine() { ${ON_CLOSE:-:}; [ $mine = 1 ] && { pill "closing Broforce (this check started it)"; echo "== closing what this check started"; bash /var/tmp/powos-bf-stop.sh | head -1; mine=0; }; rm -rf "$T" /tmp/powos-verify-step; }
touched() { [ "$(irq)" != "$I0" ] || return 1; echo "user input $(date +%T) - stopping"; close_mine; exit 3; }
trap 'echo "stopped from outside $(date +%T)"; close_mine; exit 3' HUP TERM INT
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
reapers() { pgrep -f "SteamLaunch AppId=$APP( |\$)"; }
reaper() { local p; for p in $(reapers); do under "$p" "$(steam_pid)" && { echo "$p"; return; }; done; }  # Steam's own
tree() { local t=("$1") o=() p; while ((${#t[@]})); do p=${t[0]}; t=("${t[@]:1}"); [ -n "$p" ] && o+=("$p") && t+=($(pgrep -P "$p")); done; echo "${o[*]}"; }
ticks() { local n=0 p f; for p in "$@"; do f=$(cat "/proc/$p/stat" 2>/dev/null) || continue; f=${f##*) }; set -- $f; n=$((n + ${12} + ${13})); done; echo "$n"; }
gamewin() { xwininfo -root -tree 2>/dev/null | awk '/"Broforce"/ && !/has no name/ {print $1; exit}'; }
mapped() { xwininfo -id "$1" 2>/dev/null | awk '/Map State/ {print $3}'; }
active() { printf '%d' "$(xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | awk '{print $NF}')" 2>/dev/null; }
cg() { local c; c=$(cat "/proc/$(steam_pid)/cgroup" 2>/dev/null); case $c in *powos/sleep/*) echo "/sys/fs/cgroup${c#0::}" ;; esac; }
watcher() { grep -i "steam\|app $APP" "$GLOG" | tail -${1:-2} | cut -c1-200 | tr '\n' '|'; }
first_change() {  # first_change <window> <seconds> <fps>: epoch s of the first grabbed frame that differs from the first
  local s; s=$(now)
  ffmpeg -nostdin -loglevel error -f x11grab -framerate "$3" -window_id "$1" -i "$DISPLAY" -t "$2" -copyts \
      -f framemd5 - 2>/dev/null \
    | awk -F', *' -v fps="$3" -v s="$s" '/^#tb 0:/ {split($0, t, /[: \/]+/); tn = t[3]; td = t[4]}
        !/^#/ {n++; if (n == 1) h = $NF; else if ($NF != h) {x = (td ? $3 * tn / td : 0)
          printf "%.3f", (x > 1e9 ? x : s + (n - 1) / fps); found = 1; exit}}
        END {if (!found) printf "none"}'; }
open_task() {  # open_task <timeout s> <app id>: the drawer's / widget's launch path; its status line
  timeout "$1" powos-open-task --app-id "$2" -- steam steam://rungameid/$APP >"$T/open.out" 2>&1 </dev/null
  grep -m1 '^powos-open-task:' "$T/open.out" || echo "no status line"; }

# A launch chain outside Steam's tree (left by a dead Steam) is never frozen nor resumed and holds Proton's prefix: gone.
clean_stale() {
  local p s=""; for p in $(reapers); do under "$p" "$(steam_pid)" || s="$s $p"; done
  [ -n "$s" ] || return 0
  echo "stale Broforce launch chain(s) outside Steam:$s - closing them"
  for p in $s; do kill -9 $(tree "$p") 2>/dev/null; done; sleep 2
}

# step_launch: Broforce up through the drawer's path (a running one: brought up the same way). Sets W, LAUNCH.
step_launch() {
  clean_stale
  local r t0 st e; r=$(reaper); W=$(gamewin)
  if [ -n "$r" ] && [ -z "$W" ] && [ "$(ps -o etimes= -p "$r" | tr -d ' ')" -gt 600 ]; then
    echo "a Broforce launch without a window for 10 min ($r) - closing it"; bash /var/tmp/powos-bf-stop.sh | tail -1; r=
  fi
  [ -z "$r" ] && mine=1
  pill "launching Broforce$([ -n "$r" ] && echo ' (already running)')"
  t0=$(now)
  ( open_task $((LAUNCH_S + 10)) "steam_app_$APP" > "$T/open.status" ) &
  for _ in $(seq $((LAUNCH_S * 2))); do W=$(gamewin); [ -n "$W" ] && [ "$(mapped "$W")" = IsViewable ] && break; touched; sleep 0.5; done
  LAUNCH=$(ms "$t0" "$(now)")
  if [ -z "$W" ] || [ "$(mapped "$W")" != IsViewable ]; then
    fail launch "no mapped Broforce window ${LAUNCH} ms after the launch (window '${W:-none}' $(mapped "${W:-0}")); steam $(steam_pid) frozen '$(cg)', reaper '$(reaper)' $(tree "$(reaper)" | wc -w) processes, Broforce_beta.exe $(pgrep -fc 'Broforce_beta.exe' ), watcher: $(watcher 3)"
    return 1
  fi
  for _ in $(seq 60); do [ -s "$T/open.status" ] && break; touched; sleep 0.5; done
  st=$(cat "$T/open.status" 2>/dev/null)
  echo "launch: window $W mapped ${LAUNCH} ms after the launch, $st"
  [ "$st" = "powos-open-task: task" ] || fail launch "window $W is up but not shown as its own task: '${st:-still waiting}'"
  e=$(first_change "$W" 10 10)
  echo "launch: $([ "$e" = none ] && echo 'no new frame in 10 s (a still screen?)' || echo "drawing (a new frame $(ms "$t0" "$e") ms after the launch)")"
}

# freeze_ok: Steam's sleep cgroup frozen, every task of the game's chain in it, none of them running (prints evidence).
freeze_ok() {
  local c g n=0 in=0 p a b; c=$(cg); g=$(tree "$(reaper)")
  for p in $g; do n=$((n + 1)); case $(cat "/proc/$p/cgroup" 2>/dev/null) in "0::${c#/sys/fs/cgroup}") in=$((in + 1)) ;; esac; done
  a=$(ticks $g); sleep 2; b=$(ticks $g)
  EVID="cgroup ${c:-none}: cgroup.freeze=$(cat "$c/cgroup.freeze" 2>/dev/null) events '$(grep frozen "$c/cgroup.events" 2>/dev/null)', game tasks in it $in/$n, game CPU ticks in 2 s $((b - a)), window $(mapped "$W")"
  [ -n "$c" ] && [ "$(cat "$c/cgroup.freeze")" = 1 ] && grep -qx "frozen 1" "$c/cgroup.events" && [ $n -gt 0 ] && [ $in = $n ] && [ $((b - a)) = 0 ]
}

# step_freeze: `powos game <appid> freeze` (its window minimized, Steam + the game frozen). Sets FREEZE.
step_freeze() {
  local t0 out; touched; pill "freezing Broforce"; t0=$(now)
  out=$(powos game $APP freeze 2>&1 | tail -1)
  for _ in $(seq 20); do [ "$(cat "$(cg)/cgroup.freeze" 2>/dev/null)" = 1 ] && break; sleep 0.5; done
  FREEZE=$(ms "$t0" "$(now)")
  if freeze_ok; then echo "freeze: frozen in ${FREEZE} ms - $EVID"
  else fail freeze "'$out' -> $EVID; watcher: $(watcher)"; return 1; fi
}

# step_resume <label> <how...>: the launch path given (a command; open_task's status line counts), then: Steam out of
# its frozen cgroup, the same game, its window mapped, a new frame within RESUME_MS. Sets RES.
step_resume() {
  local label=$1 r0 t0 st f t; shift; touched; pill "resuming Broforce ($label)"
  r0=$(reaper); t0=$(now)
  st=$("$@" 2>&1 | tail -1)
  t=$(ms "$t0" "$(now)")
  for _ in $(seq 20); do [ "$(mapped "$W")" = IsViewable ] && break; sleep 0.25; done
  f=$(first_change "$W" 5 30)
  RES=$([ "$f" = none ] && echo none || ms "$t0" "$f")
  local ev="'$st' in $t ms, steam frozen '$(cg)', same game $([ "$(reaper)" = "$r0" ] && echo yes || echo "no ($r0 -> $(reaper))"), window $(mapped "$W"), focused $([ "$(active)" = "$(printf '%d' "$W")" ] && echo yes || echo no), first new frame ${RES} ms after the launch"
  if [ -z "$(cg)" ] && [ "$(reaper)" = "$r0" ] && [ "$(mapped "$W")" = IsViewable ] && [ "$RES" != none ] && [ "$RES" -le "$RESUME_MS" ] \
      && { [ "$label" = steam ] || [ "$st" = "powos-open-task: task" ]; }; then
    echo "resume ($label): $ev"
  else fail "resume-$label" "$ev; watcher: $(watcher)"; return 1; fi
}
