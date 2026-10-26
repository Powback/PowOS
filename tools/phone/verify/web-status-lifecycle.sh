#!/bin/bash
# lanes: emu
# The web status bar failing must restore the stock clock/icons; a reload must regain ownership.
set -euo pipefail
cd "$(dirname "$0")/../../.."
[ "${POWOS_DEVICE:-}" = emu ] || { echo 'emulator only'; exit 5; }
adb() { tools/phone/adb.sh "$@"; }
cdp() { CDP_TIMEOUT_S=6 tools/phone/cdp.sh eval statusbar "$1"; }
OUT=${OUT:-$HOME/.cache/powos-verify/web-status-lifecycle-$(date +%m%d-%H%M%S)}
mkdir -p "$OUT"
flags() { adb shell dumpsys statusbar | sed -nE 's/.*mDisabled1=(0x[0-9a-fA-F]+).*/\1/p' | head -1; }
wait_owner() {
  local want=$1 f
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    f=$(flags)
    if [[ "$f" =~ ^0x[0-9a-fA-F]+$ ]] && [ "$(( (f & 0x800000) != 0 ))" = "$want" ]; then return 0; fi
    sleep 1
  done
  echo "FAIL: wanted web ownership=$want, flags=$f"; return 1
}
adb shell input keyevent 3
wait_owner 1
trap 'cdp "location.reload()" >/dev/null 2>&1 || true' EXIT
cdp 'window.__powosAlive = false' >/dev/null
wait_owner 0
tools/phone/shot.sh "$OUT/fallback.png"
cdp 'location.reload()' >/dev/null
wait_owner 1
tools/phone/shot.sh "$OUT/recovered.png"
trap - EXIT
echo "PASS: stock clock restored after web failure; shared web bar recovered after reload: $OUT"
