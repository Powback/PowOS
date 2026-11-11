#!/bin/bash
# e2e-queue.sh [--if-idle] [--round R]: queue one round of the "use the phone like a user" journeys for the manager:
# e2e-desktop.sh parts 1-3 (unfolded home: --screen inner) then e2e-appapi.sh parts 1-2, each its own job of <= 450 s on board
# task manager-end-to-end-user-journeys-on-the-phone-qa (no --close: the manager reviews the screenshots). The round
# number is the next of ~/.cache/powos-e2e/round; the screenshots go to /home/powos/design-qa/e2e-<journey>/<round>/
# and the last part of each mails the manager "E2E round N ready: <dir>".
#   --if-idle  queue nothing while a round is still queued (ship.sh runs this after every successful ship: ships come
#              many times a night, a round is ~15 min of phone time - never more than one waiting)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
TASK=manager-end-to-end-user-journeys-on-the-phone-qa
Q=${QUEUE_DIR:-$HOME/.cache/powos-verify-queue}
idle=0 round=
while [ $# -gt 0 ]; do case "$1" in --if-idle) idle=1; shift ;; --round) round=$2; shift 2 ;; *) echo "usage: e2e-queue.sh [--if-idle] [--round R]"; exit 2 ;; esac; done
if [ $idle = 1 ] && grep -lsE 'e2e-(desktop|appapi)\.sh' "$Q"/*.job >/dev/null 2>&1; then
  echo "e2e: a round is still queued ($(grep -lsE 'e2e-(desktop|appapi)\.sh' "$Q"/*.job | wc -l | tr -d ' ') jobs) - none added"; exit 0
fi
c=$HOME/.cache/powos-e2e; mkdir -p "$c"
if [ -z "$round" ]; then round=$(( $(cat "$c/round" 2>/dev/null || echo 0) + 1 )); echo "$round" > "$c/round"; fi
cd "$here/../../.." || exit 1
# The budget: a journey part is 11-25 real steps, each screenshot + logcat + CDP reads; idle passes took up to 294 s
# (part 3, 11-01) and 8 of the 10 FAIL timeouts of 10-31..11-01 were parts killed on their last 1-3 steps or in the
# end step's restore (19:24 round 205 part 1: every step PASS, killed after "restored"). 300 s made load a FAIL.
export QUEUE_BUDGET_WHY="an e2e journey part is long by design: 11-25 user steps with a screenshot and logcat each"
# f368: queue.sh refused every add (no such board task) and this still said "round queued"; nothing ran for 3 h.
# Each add's own exit code counts; any refusal is loud (stderr, exit 1) and a round with none queued gives its
# number back.
refused=0
add() { local o rc; o=$(tools/phone/verify/queue.sh add --budget 450 "$@" 2>&1); rc=$?
  printf '%s\n' "$o" | tail -1; [ $rc = 0 ] || { refused=$((refused + 1)); printf 'e2e: queue.sh add refused (rc %s): %s\n' "$rc" "$o" >&2; }
  sleep 1; }   # 1 s apart: the jobs run in name order
add --name e2e-desktop --screen inner "$TASK" tools/phone/verify/e2e-desktop.sh --round "$round" --part 1 --of 3
add --name e2e-desktop --screen inner "$TASK" tools/phone/verify/e2e-desktop.sh --round "$round" --part 2 --of 3
add --name e2e-desktop --screen inner "$TASK" tools/phone/verify/e2e-desktop.sh --round "$round" --part 3 --of 3
add --name e2e-appapi "$TASK" tools/phone/verify/e2e-appapi.sh --round "$round" --part 1 --of 2
add --name e2e-appapi "$TASK" tools/phone/verify/e2e-appapi.sh --round "$round" --part 2 --of 2
if [ $refused != 0 ]; then
  [ $refused = 5 ] && [ "$(cat "$c/round" 2>/dev/null)" = "$round" ] && echo $((round - 1)) > "$c/round"
  echo "e2e round $round NOT queued: $refused of 5 jobs refused by queue.sh (above)" >&2; exit 1
fi
echo "e2e round $round queued"
