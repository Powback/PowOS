#!/bin/bash
# lanes: emu
# Web status bar: native state reaches the DOM, clock/controls taps open the shared shade, battery updates live.
set -euo pipefail
cd "$(dirname "$0")/../../.."
[ "${POWOS_DEVICE:-}" = emu ] || { echo 'emulator only: changes the simulated battery'; exit 5; }
adb() { tools/phone/adb.sh "$@"; }
cdp() { CDP_TIMEOUT_S=8 tools/phone/cdp.sh eval "$1" "$2"; }
OUT=${OUT:-$HOME/.cache/powos-verify/web-status-$(date +%m%d-%H%M%S)}
mkdir -p "$OUT"
trap 'adb shell dumpsys battery reset >/dev/null; adb shell input keyevent 4 >/dev/null' EXIT
adb shell input keyevent 3
ready=0
for _ in 1 2 3 4 5 6 7 8; do
  if cdp statusbar 'window.__powosAlive === true && !!document.querySelector("time")' 2>/dev/null | grep -q true; then ready=1; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { echo 'FAIL: web status bar did not render'; exit 1; }
tools/phone/shot.sh "$OUT/status.png"
adb shell dumpsys battery set level 73
sleep 1
cdp statusbar 'document.querySelector(".status-battery")?.textContent' | tee "$OUT/battery.txt" | grep -q '73%' || { echo 'FAIL: battery update did not reach the web UI'; exit 1; }
for button in status-clock status-indicators; do
  xy=$(cdp statusbar "(()=>{const r=document.querySelector('.$button').getBoundingClientRect();return [Math.round((r.x+r.width/2)*devicePixelRatio),Math.round((r.y+r.height/2)*devicePixelRatio)].join(' ')})()" | tr -d '"\r' | tail -1)
  read -r x y <<<"$xy"
  [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]] || { echo "FAIL: no $button bounds: $xy"; exit 1; }
  adb shell input tap "$x" "$y"
  sleep 2
  # Native window visibility is independent of the warm page's DOM.
  adb shell dumpsys window windows > "$OUT/$button-windows.txt"
  cdp shade 'importShim("./state.ts").then(s=>JSON.stringify({open:s.notif.value,panel:s.panel.value}))' | tr -d '\\' > "$OUT/$button-dom.txt"
  grep -q '"open":true' "$OUT/$button-dom.txt" || { echo "FAIL: $button did not open the shade"; exit 1; }
  tools/phone/shot.sh "$OUT/$button.png"
  adb shell input keyevent 4
  sleep 1
done
echo "PASS: web status bar ready and live battery update; tap captures: $OUT"
