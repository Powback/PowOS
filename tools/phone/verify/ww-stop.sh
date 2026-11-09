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
out=$("$here/window-render.sh" --hidden 2>&1); rc=$?
printf '%s\n' "$out" | grep -E '^linux:|window-render: ' | cut -c1-240
judge "$out" "$rc"
