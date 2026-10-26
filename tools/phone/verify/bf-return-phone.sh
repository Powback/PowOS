#!/bin/bash
# bf-return-phone.sh launch|away|back|close: (in the PowOS session as powos; bf-return.sh pushes and runs it, one phase
# per call, state in /tmp/bf-return.env; APP=<appid>, any Steam game: bf-lib.sh) the user's own way back into a game
# they started: the game (default Broforce) started through
# powos-open-task (the drawer's path), left (bf-return.sh sends Android's HOME intent between launch and away), frozen
# in the background by unified sleep (not killed), its icon tapped again (powos-open-task) -> the first changed frame.
#   launch  clean_stale + step_launch (bf-lib.sh), then until Unity's window is full screen (it maps 314x208 first) and
#           draws; the game's audio streams. A Broforce the user had left (frozen) is used as it is (mine=0); one that
#           runs awake is the user playing it: "SKIP", exit 3.
#   away    out of sight -> frozen by itself (past the 2 min start grace + 15 s): Steam's cgroup frozen with every task
#           of the game's chain in it, no CPU, the same game still there (not closed); else FAIL freeze-auto + a manual
#           freeze, so the resume is still measured
#   back    the tap again: step_resume through powos-open-task -> tap -> first changed frame (<= RESUME_MS, 10000), the
#           window focused (input goes to it) and its audio streams back, uncorked
#   close   what this check started: closed (bf-stop.sh: the game, Steam stays); the user's game: frozen again
# Steps and asserts: bf-lib.sh ("FAIL <step>: <evidence>"); "TIMES ..." after back.
set -uo pipefail
RESUME_MS=${RESUME_MS:-10000}  # the limit (a FAIL past it); the goal is under 3 s (TIMES says which)
. /var/tmp/powos-bf-lib.sh
E=/tmp/bf-return.env
[ -f $E ] && . $E
save() { printf 'mine=%s W=%s R0=%s LAUNCH=%s AUD0=%q\n' "$mine" "${W:-}" "${R0:-}" "${LAUNCH:-}" "${AUD0:-}" > $E; }
# audio: the game's PipeWire streams (pactl sink-inputs whose process is in the game's chain, or Wine's): "<n> streams,
# <k> corked" ("0 streams" = none: the game muted or no sound device).
audio() { pactl -f json list sink-inputs 2>/dev/null | python3 -c '
import json, sys
pids = set(sys.argv[1].split())
try:
    s = json.load(sys.stdin)
except ValueError:
    s = []
g = [x for x in s if str(x.get("properties", {}).get("application.process.id", "")) in pids
     or "wine" in str(x.get("properties", {}).get("application.process.binary", "")).lower()
     or "broforce" in str(x.get("properties", {}).get("application.name", "")).lower()]
print("%d streams, %d corked" % (len(g), sum(1 for x in g if x.get("corked"))))' "$(tree "$(reaper)")"; }
case ${1:-} in
launch)
  rm -f $E; powos sleep never --remove steam >/dev/null 2>&1  # Steam sleepable, as the user has it
  r=$(reaper)
  if [ -n "$r" ]; then
    if [ "$(cat "$(cg)/cgroup.freeze" 2>/dev/null)" = 1 ]; then echo "the user's $GAME, left frozen: used as it is, frozen again after"
    else echo "SKIP: the user's $GAME runs awake (they play it?)"; exit 3; fi
  fi
  step_launch || { close_mine; exit 1; }
  R0=$(reaper)
  pill "$GAME up: waiting for its full-screen window"
  root=$(xwininfo -root | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}')
  for _ in $(seq 60); do W=$(gamewin); g=$(xwininfo -id "$W" 2>/dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} END{print w "x" h}'); [ "$g" = "$root" ] && break; touched; sleep 0.5; done
  echo "launch: window $W $g on $root$([ "$g" = "$root" ] || echo ' (not full screen after 30 s)')"
  sleep 3; AUD0=$(audio); echo "launch: audio $AUD0"
  save ;;
away)
  touched; pill "$GAME left (home): waiting for it to sleep"
  e=$(ps -o etimes= -p "$R0" 2>/dev/null | tr -d ' '); t0=$(now) auto=no
  # The start grace (2 min from the game's reaper) + 15 s out of sight + powos-sleep-gui's 5 s look.
  for _ in $(seq $((40 + (${e:-0} < 125 ? 125 - ${e:-0} : 0)))); do
    [ "$(cat "$(cg)/cgroup.freeze" 2>/dev/null)" = 1 ] && { auto=yes; break; }; touched; sleep 1; done
  AWAY=$(ms "$t0" "$(now)")
  alive="same game $([ "$(reaper)" = "$R0" ] && echo yes || echo "no ($R0 -> $(reaper))"), its chain $(tree "$R0" | wc -w) processes"
  if [ $auto = yes ] && freeze_ok; then echo "away: frozen by itself $AWAY ms after the check started waiting (game ${e:-?} s old) - $EVID; $alive"
  else
    [ $auto = yes ] && fail freeze-auto "$EVID; $alive" || fail freeze-auto "not frozen $AWAY ms out of sight (game ${e:-?} s old); $alive; watcher: $(watcher 3)"
    step_freeze || true
  fi
  [ "$(reaper)" = "$R0" ] || fail away "the game was closed, not frozen: $alive"
  save ;;
back)
  touched
  step_resume open-task open_task 30 "steam_app_$APP"
  sleep 3
  foc=$([ "$(active)" = "$(printf '%d' "$W")" ] && echo yes || echo no); aud=$(audio)
  echo "back: focused $foc (X input goes to the game), audio $aud (before leaving: ${AUD0:-?})"
  [ $foc = yes ] || fail resume-input "window $W not focused after the resume (active $(active))"
  case ${AUD0:-} in [1-9]*) case $aud in 0\ *|*" ${aud%% *} corked") fail resume-audio "streams before leaving: $AUD0, after the resume: $aud" ;; esac ;; esac
  echo "TIMES resume ${RES:-none} ms ($(case ${RES:-none} in none) echo 'no frame' ;; *) [ "$RES" -lt 3000 ] && echo 'goal < 3 s met' || echo 'over the 3 s goal' ;; esac)), launch ${LAUNCH:-?} ms to its window"
  save ;;
close)
  if [ "${mine:-0}" = 1 ]; then close_mine
  else pill "$GAME frozen again (the user's)"; echo "the user's $GAME: $(powos game $APP freeze 2>&1 | tail -1 | sed 's/\x1b\[[0-9;]*m//g')"; fi
  rm -f $E ;;
*) echo "usage: bf-return-phone.sh launch|away|back|close"; exit 2 ;;
esac
rm -rf "$T"
[ -z "$FAILS" ]
