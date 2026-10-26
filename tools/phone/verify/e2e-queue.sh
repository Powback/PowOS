#!/bin/bash
# e2e-queue.sh [--if-idle] [--round R]: queue one round of the "use the phone like a user" journeys for the manager:
# e2e-desktop.sh parts 1-3 (unfolded home: --screen inner) then e2e-appapi.sh, each its own job of <= 300 s on board
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
add() { tools/phone/verify/queue.sh add --budget 300 "$@" | tail -1; sleep 1; }   # 1 s apart: the jobs run in name order
add --name e2e-desktop --screen inner "$TASK" tools/phone/verify/e2e-desktop.sh --round "$round" --part 1 --of 3
add --name e2e-desktop --screen inner "$TASK" tools/phone/verify/e2e-desktop.sh --round "$round" --part 2 --of 3
add --name e2e-desktop --screen inner "$TASK" tools/phone/verify/e2e-desktop.sh --round "$round" --part 3 --of 3
add --name e2e-appapi "$TASK" tools/phone/verify/e2e-appapi.sh --round "$round"
echo "e2e round $round queued"
