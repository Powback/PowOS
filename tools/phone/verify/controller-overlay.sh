#!/bin/bash
# lanes: emu phone
# Queue only: the control-center pad must own a visible window without the Linux display activity.
# Restore the previous toggle state; save a screenshot and native window evidence for visual review.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
OUT=$HOME/.cache/powos-verify/controller-$(date +%m%d-%H%M)
mkdir -p "$OUT"
. "$here/window-lock.sh"
window_lock controller-overlay 120
I0=$(irq)
was=$(hcall pad.state '[]' 'v=>String(v)')
case "$was" in true|false) ;; *) echo "FAIL: cannot read controller state: $was"; exit 1 ;; esac
restore() {
  hcall pad.overlay "[$was]" 'v=>String(v)' >/dev/null
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
}
trap restore EXIT
result=$(hcall pad.overlay '[true]' 'v=>String(v)')
[ "$result" = true ] || { echo "FAIL: controller enable: $result"; exit 1; }
sleep 1
chk enabled
sh_ 'dumpsys window windows' > "$OUT/windows.txt"
if ! grep -q 'PowOS controller' "$OUT/windows.txt"; then
  echo "FAIL: controller reports enabled but has no window"
  exit 1
fi
"$T/shot.sh" "$OUT/controller.png" >/dev/null || { echo "FAIL: no controller screenshot"; exit 1; }
result=$(hcall pad.overlay '[false]' 'v=>String(v)')
[ "$result" = false ] || { echo "FAIL: controller disable: $result"; exit 1; }
sleep 0.3
if sh_ 'dumpsys window windows' | grep -q 'PowOS controller'; then
  echo "FAIL: controller window remains after disabling"
  exit 1
fi
echo "PASS: controller window opens and closes; visual review: $OUT/controller.png"
