#!/bin/bash
# bf-resume-phone.sh: (in the PowOS session as powos; bf-resume.sh pushes and runs it) the measurements of
# bf-resume.sh. Prints one "RESULT ..." line last.
set -uo pipefail
APP=274190 GLOG=/run/powos-app/powos-sleep-gui.log CLOG=$HOME/.local/share/Steam/logs/connection_log.txt
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/powos-app} DISPLAY=${DISPLAY:-:0}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}
XAUTHORITY=$(tr '\0' '\n' < "/proc/$(pgrep -x Xwayland | head -1)/cmdline" | grep -A1 -x -- -auth | tail -1); export XAUTHORITY
now() { date +%s.%N; }
ms() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%d", (b - a) * 1000}'; }
irq() { awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}' /proc/interrupts; }
I0=$(irq)
touched() { [ "$(irq)" != "$I0" ] && { echo "user input $(date +%T) - stopping"; return 0; }; return 1; }
reaper() { pgrep -f "SteamLaunch AppId=$APP( |\$)" | head -1; }
steam_pid() { cat ~/.steam/steam.pid 2>/dev/null; }
tree() { local t=("$1") o=() p; while ((${#t[@]})); do p=${t[0]}; t=("${t[@]:1}"); o+=("$p"); t+=($(pgrep -P "$p")); done; echo "${o[*]}"; }
ticks() { local n=0 p f; for p in "$@"; do f=$(cat "/proc/$p/stat" 2>/dev/null) || continue; f=${f##*) }; set -- $f; n=$((n + ${12} + ${13})); done; echo "$n"; }
cpu() {  # cpu <seconds>: % of a core used by Steam's whole tree (the game included) over that time
  local pids t0 t1; pids=$(tree "$(steam_pid)"); t0=$(ticks $pids); sleep "$1"; t1=$(ticks $pids)
  awk -v d=$((t1 - t0)) -v s="$1" -v hz="$(getconf CLK_TCK)" 'BEGIN {printf "%.2f", d * 100 / hz / s}'; }
frozen() { case $(cat "/proc/$(steam_pid)/cgroup" 2>/dev/null) in *powos/sleep/*) echo yes ;; *) echo no ;; esac; }
gamewin() {  # the game's X window: the visible one named Broforce
  xwininfo -root -tree 2>/dev/null | awk '/"Broforce"/ && !/has no name/ {print $1; exit}'; }
active() { xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | awk '{print $NF}'; }
first_change() {  # first_change <window> <seconds> <fps>: the time (epoch s) of the first grabbed frame that differs
  # from the first one, or "none". x11grab stamps frames with the wall clock (-copyts keeps it); if this ffmpeg
  # doesn't, the frame's index from the grab's start is used.
  local s; s=$(now)
  ffmpeg -nostdin -loglevel error -f x11grab -framerate "$3" -window_id "$1" -i "$DISPLAY" -t "$2" -copyts \
      -f framemd5 - 2>/dev/null \
    | awk -F', *' -v fps="$3" -v s="$s" '/^#tb 0:/ {split($0, t, /[: \/]+/); tn = t[3]; td = t[4]}
        !/^#/ {n++; if (n == 1) h = $NF; else if ($NF != h) {x = (td ? $3 * tn / td : 0)
          printf "%.3f", (x > 1e9 ? x : s + (n - 1) / fps); found = 1; exit}}
        END {if (!found) printf "none"}'; }
echo "== $(date +%T) steam=$(steam_pid) $(pacman -Q steam) never: $(powos sleep never 2>/dev/null | tr '\n' ' ' | cut -c1-120)"
powos sleep never --remove steam >/dev/null 2>&1  # the check needs Steam sleepable (bf-start.sh adds it)
mine=0; cold_win=- cold_frame=-
if [ -z "$(reaper)" ]; then
  # Cold: Steam (if it isn't up) + Proton + Broforce, from the launch to the window and its first new frame.
  mine=1; t0=$(now)
  setsid -f steam steam://rungameid/$APP >/tmp/bf-resume-steam.out 2>&1 </dev/null
  w=
  for _ in $(seq 600); do w=$(gamewin); [ -n "$w" ] && break; touched && exit 3; sleep 0.5; done
  [ -n "$w" ] || { echo "no Broforce window in 5 min"; bash /var/tmp/powos-bf-stop.sh; exit 1; }
  t1=$(now); cold_win=$(ms "$t0" "$t1")
  f=$(first_change "$w" 30 10); cold_frame=$([ "$f" = none ] && echo none || ms "$t0" "$f")
  echo "cold: window $cold_win ms after the launch, first new frame at $cold_frame ms"
  # Past the start grace (2 min after the game's launcher), as the automatic sleep needs.
  e=$(ps -o etimes= -p "$(reaper)" | tr -d ' '); [ "${e:-0}" -lt 125 ] && sleep $((125 - ${e:-0}))
fi
r=$(reaper); w=$(gamewin)
echo "game: reaper $r, window $w, steam $(steam_pid), tree $(tree "$(steam_pid)" | wc -w) processes"
grep -n "app_pid\|window" "$GLOG" | tail -3
touched && exit 3
# Out of sight: every window of Steam's tree minimized (the game's and Steam's), as when the user leaves it.
for x in $(xdotool search --onlyvisible --name . 2>/dev/null); do
  p=$(xdotool getwindowpid "$x" 2>/dev/null) || continue
  case " $(tree "$(steam_pid)") " in *" $p "*) xdotool windowminimize "$x" 2>/dev/null ;; esac
done
awake=$(cpu 10)
echo "awake, out of sight: Steam's tree ${awake}% of a core (10 s)"
auto=no
for _ in $(seq 40); do [ "$(frozen)" = yes ] && { auto=yes; break; }; sleep 1; done
if [ $auto = no ]; then
  echo "not frozen on its own in 50 s - the watcher says: $(grep -i 'steam\|broforce' "$GLOG" | tail -2 | tr '\n' ' ')"
  powos game $APP freeze; sleep 2
fi
echo "frozen: $(frozen) (automatic: $auto) - $(grep -i 'frozen in' "$GLOG" | tail -1)"
[ "$(frozen)" = yes ] || { echo "RESULT not frozen; cold $cold_win/$cold_frame ms"; exit 1; }
fcpu=$(cpu 30)
echo "frozen: Steam's tree ${fcpu}% of a core (30 s)"
# The session doesn't wait on a frozen client: the X server and KWin answer.
t0=$(now); xwininfo -root -children >/dev/null; x=$(ms "$t0" "$(now)")
t0=$(now); dbus-send --session --print-reply --dest=org.kde.KWin /KWin org.freedesktop.DBus.Peer.Ping >/dev/null; k=$(ms "$t0" "$(now)")
echo "while frozen: X server answers in $x ms, KWin in $k ms; Xwayland $(pgrep -x Xwayland) kwin $(pgrep -x kwin_wayland)"
touched && { powos game $APP thaw; exit 3; }
sleep 45  # frozen ~90 s in all: long enough for Steam's server connection to time out
cl=$(wc -l < "$CLOG" 2>/dev/null || echo 0)
# Thawed start: the real launch path (what the games widget runs).
( sleep 1; t0=$(now); steam steam://rungameid/$APP; echo "launch $t0 $(now)" > /tmp/bf-resume-launch ) &
f=$(first_change "$w" 6 30)
wait
read -r _ l0 l1 < /tmp/bf-resume-launch
lms=$(ms "$l0" "$l1")
a=no; [ "$(printf '%d' "$(active)" 2>/dev/null)" = "$(printf '%d' "$w")" ] && a=yes
frame=$([ "$f" = none ] && echo none || ms "$l0" "$f")
echo "thawed start: the launch command returned in $lms ms, game window focused: $a, first new frame $frame ms after the launch"
grep -i "resumed\|thawed" "$GLOG" | tail -2
sleep 20
echo "Steam's connection log after the thaw:"; tail -n +$((cl + 1)) "$CLOG" 2>/dev/null | tail -8
echo "Steam/game still up: steam $(steam_pid) reaper $(reaper) frozen $(frozen)"
[ $mine = 1 ] && { echo "== closing what this check started"; bash /var/tmp/powos-bf-stop.sh | tail -2; }
rm -f /tmp/bf-resume-launch /tmp/bf-resume-steam.out
echo "RESULT bf-resume: cold window ${cold_win} ms / first frame ${cold_frame} ms; thawed: launch ${lms} ms, first frame ${frame} ms, focused $a; idle CPU awake-hidden ${awake}% -> frozen ${fcpu}% (auto-freeze $auto); X ${x} ms KWin ${k} ms while frozen"
