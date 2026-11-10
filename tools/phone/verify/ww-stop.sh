#!/bin/bash
# lanes: phone
# needs: kwin
# ww-stop.sh: a Linux web window's consumer stops fast (board task linux-web-window-stop-takes-2-1-s-after-d9d7edcd,
# af5ebd75: nativeStopWindow had joined a render thread blocked up to 5 s on an idle KWin window's next frame). Runs
# the ship gate's window-render.sh --hidden (its Linux step: foot through the KWin -> web-window consumer offscreen,
# LinuxSelftest.kt) and judges the stop time its PASS line carries ("linux stopMs=N"): PASS when 0 <= N < STOP_MAX_MS
# (2000; the goal is 0-100 ms, window-render itself fails past 1000). Nothing of the user's is opened or moved.
# Exit 0 PASS, 1 FAIL, 3 not judged (window-render's exit 2: the phone asleep / the user on it), 5 can't run.
#   ww-stop.sh --parse FILE   judge a saved window-render log (no phone; the tier1 fixture run)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
MAX=${STOP_MAX_MS:-2000}
judge() {  # judge <window-render output> <its rc>
  local ms; ms=$(grep -oE 'linux stopMs=-?[0-9]+' <<<"$1" | tail -1 | cut -d= -f2)
  [ "$2" = 2 ] && { echo "SKIP: window-render not judged ($(grep -m1 'NOT JUDGED' <<<"$1" | cut -c1-160))"; return 3; }
  grep -q 'linux: not run' <<<"$1" && { echo "SKIP: the Linux step didn't run ($(grep -m1 'linux: not run' <<<"$1" | cut -c1-160))"; return 3; }
  [ "$2" = 0 ] || { echo "FAIL ww-stop: window-render FAILed: $(grep -m1 '^FAIL' <<<"$1" | cut -c1-200)"; return 1; }
  [ -n "$ms" ] || { echo "FAIL ww-stop: window-render's PASS carries no stopMs (an older window-render?)"; return 1; }
  if [ "$ms" -ge 0 ] && [ "$ms" -lt "$MAX" ]; then echo "PASS ww-stop: the Linux consumer's stop took $ms ms (< $MAX; goal 0-100)"; return 0; fi
  echo "FAIL ww-stop: the Linux consumer's stop took $ms ms (want 0..$((MAX - 1)); -1 = still blocked after 3 s)"; return 1; }
if [ "${1:-}" = --parse ]; then judge "$(cat "$2")" "${3:-0}"; exit $?; fi
# Folded, the host refuses the Linux step ("web windows don't take Linux windows here") - found only after
# window-render's other steps: 11-09 22:02 spent 218 s of an idle window for a precond rc 3. Unfold first, like
# wwc-lib.sh's wwc_start (cmd device_state, marked as the tools' own input so the touch detection doesn't read the
# panels' resume as the user), and give the hinge its own state back after.
A="$here/../adb.sh"
sh_() { "$A" shell "su -c '$*'" </dev/null 2>/dev/null | tr -d '\r'; }
case $(sh_ "dumpsys device_state | grep -m1 mCommittedState") in
  *CLOSED*) sh_ "echo \$(( \$(date +%s) + 8 )) > /data/local/tmp/powos-selfinput; cmd device_state state 3" >/dev/null
    trap 'sh_ "echo \$(( \$(date +%s) + 8 )) > /data/local/tmp/powos-selfinput; cmd device_state state reset" >/dev/null' EXIT
    echo "ww-stop: the phone was folded - unfolded for the Linux step (reset after)"; sleep 3 ;;
esac
out=$("$here/window-render.sh" --hidden 2>&1); rc=$?
printf '%s\n' "$out" | grep -E '^linux:|window-render: ' | cut -c1-240
judge "$out" "$rc"
