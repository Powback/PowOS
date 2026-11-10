#!/bin/bash
# lanes: phone
# Live by-area drill-down; queue only, unfolded screen already present. No fixtures, no board writes.
# Missing live mixed/idle areas => SKIP (5). User touch/unreadable guard => stop (3), never further UI input.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
SHELL_CHECK_LIB=1 . "$here/shell-check.sh"
. "$here/e2e-lib.sh"
. "$here/window-lock.sh"
[ "${LOCK_HELD:-0}" = 1 ] || { echo 'SKIP: run via verify queue (LOCK_HELD required)'; exit 5; }
window_lock ai-area-drilldown.sh 120
e2e_touchwatch >/dev/null
I0=$(irq)
[[ "$I0" =~ ^[0-9]+$ ]] || { echo 'SKIP: hardware touch guard unavailable'; exit 5; }
guard() { local n; n=$(irq); [ "$n" = "$I0" ] && [ -n "$n" ]; }
cleanup() {
  if guard; then shell_check home ai-area-device.js aiAreaDevice restore >/dev/null
  else echo 'STOP: user touch/guard lost; no restore input'; fi
}
trap cleanup EXIT
for step in setup mixed area rest task all collapse; do
  guard || { echo "STOP: user touch/guard lost before $step"; exit 3; }
  r=$(shell_check home ai-area-device.js aiAreaDevice "$step")
  guard || { echo "STOP: user touch/guard lost during $step"; exit 3; }
  echo "ai-area-drilldown $step: $r"
  case "$r" in
    '[]') ;;
    '["SKIP:'*) echo "SKIP: $r"; exit 5 ;;
    *) echo "FAIL: $step $r"; exit 1 ;;
  esac
done
echo 'PASS: live mixed/idle counts, exclusive expansion/collapse, task/area/all Progress routing'
