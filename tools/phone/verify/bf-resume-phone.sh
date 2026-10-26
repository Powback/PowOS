#!/bin/bash
# bf-resume-phone.sh: (in the PowOS session as powos; bf-resume.sh pushes and runs it) Broforce launched (cold if it
# isn't running), put out of sight until unified sleep freezes it by itself (manual freeze if not, a FAIL), CPU awake
# vs frozen, X/KWin answering while frozen, ~90 s frozen, resumed by a plain `steam steam://rungameid/<appid>` (the
# /usr/bin/steam wrapper), Steam's connection log after. Steps and asserts: bf-lib.sh. "RESULT ..." last.
set -uo pipefail
. /var/tmp/powos-bf-lib.sh
CLOG=$HOME/.local/share/Steam/logs/connection_log.txt
cpu() {  # cpu <seconds>: % of a core used by Steam's whole tree (the game included) over that time
  local pids t0 t1; pids=$(tree "$(steam_pid)"); t0=$(ticks $pids); sleep "$1"; t1=$(ticks $pids)
  awk -v d=$((t1 - t0)) -v s="$1" -v hz="$(getconf CLK_TCK)" 'BEGIN {printf "%.2f", d * 100 / hz / s}'; }
echo "== $(date +%T) steam=$(steam_pid) $(pacman -Q steam) reapers: $(reapers | tr '\n' ' ')"
powos sleep never --remove steam >/dev/null 2>&1  # the check needs Steam sleepable (bf-start.sh adds it)
cold=$([ -z "$(reaper)" ] && echo cold || echo running)
step_launch || { close_mine; echo "RESULT bf-resume: FAIL launch"; exit 1; }
touched
# Out of sight: every window of Steam's tree minimized (the game's and Steam's), as when the user leaves it.
pill "Broforce out of sight: waiting for it to sleep"
for x in $(xdotool search --onlyvisible --name . 2>/dev/null); do
  p=$(xdotool getwindowpid "$x" 2>/dev/null) || continue
  case " $(tree "$(steam_pid)") " in *" $p "*) xdotool windowminimize "$x" 2>/dev/null ;; esac
done
awake=$(cpu 10)
echo "awake, out of sight: Steam's tree ${awake}% of a core (10 s)"
auto=no e=$(ps -o etimes= -p "$(reaper)" | tr -d ' ')  # past the start grace (2 min after the game's launch) + 15 s idle
for _ in $(seq $((60 + (${e:-0} < 125 ? 125 - ${e:-0} : 0)))); do [ "$(cat "$(cg)/cgroup.freeze" 2>/dev/null)" = 1 ] && { auto=yes; break; }; touched; sleep 1; done
if [ $auto = yes ] && freeze_ok; then echo "freeze (automatic, ~15 s out of sight): $EVID"
else
  [ $auto = yes ] && fail freeze-auto "$EVID" || fail freeze-auto "not frozen 70 s out of sight; watcher: $(watcher 3)"
  step_freeze || { close_mine; echo "RESULT bf-resume: FAIL$FAILS"; exit 1; }
fi
fcpu=$(cpu 30)
echo "frozen: Steam's tree ${fcpu}% of a core (30 s)"
# The session doesn't wait on a frozen client: the X server and KWin answer.
t0=$(now); xwininfo -root -children >/dev/null; x=$(ms "$t0" "$(now)")
t0=$(now); dbus-send --session --print-reply --dest=org.kde.KWin /KWin org.freedesktop.DBus.Peer.Ping >/dev/null; k=$(ms "$t0" "$(now)")
echo "while frozen: X server answers in $x ms, KWin in $k ms"
pill "Broforce frozen: 45 s more (Steam's connection)"
for _ in $(seq 45); do touched; sleep 1; done
cl=$(wc -l < "$CLOG" 2>/dev/null || echo 0)
step_resume steam steam steam://rungameid/$APP
sleep 20
echo "Steam's connection log after the thaw:"; tail -n +$((cl + 1)) "$CLOG" 2>/dev/null | tail -8
close_mine
echo "RESULT bf-resume: ${FAILS:+FAIL$FAILS - }$cold launch ${LAUNCH} ms; resume (steam) first frame ${RES:-none} ms; CPU awake-hidden ${awake}% -> frozen ${fcpu}% (auto-freeze $auto); X ${x} ms KWin ${k} ms while frozen"
[ -z "$FAILS" ]
