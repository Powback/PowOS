#!/bin/bash
# lanes: phone
# statusbar-icons.sh (Mac side, board statusbar-parity; the user 11-25: "the statusbar doesnt contain all the icons it
# should like the sim card status"): READ-ONLY. Reads the live status bar page (mode=statusbar) over CDP - the host's
# "system.status" (StatusSignals.kt) and the icons drawn from it - plus Android's own SIM/telephony state over adb, and
# checks they agree: each SIM Android reports ready has an icon with its signal bars, the data SIM shows a network type
# while in service, no SIM -> the no-SIM icon. No touch, no page mutation; a screencap of the strip for the board.
set -u
cd "$(dirname "$0")/../../.." || exit 1
ev() { tools/phone/cdp.sh eval statusbar "$1" 2>&1 | tail -1 | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g'; }
status=$(ev '(async()=>JSON.stringify(await (await importShim("./bridge.ts")).powos.system.status?.()??null))()')
icons=$(ev 'JSON.stringify([...document.querySelectorAll(".status-indicators [aria-label]")].map(e=>e.getAttribute("aria-label")))')
# Android's own per-slot SIM state (isub's mSimState[n]: READY/LOADED, ABSENT, NOT_READY - a disabled eSIM - ...).
sims=$(tools/phone/adb.sh shell 'dumpsys isub' | tr -d '\r' | sed -nE 's/^ *mSimState\[[0-9]+\]=([A-Z_]+).*/\1/p' | paste -sd, -)
types=$(tools/phone/adb.sh shell getprop gsm.network.type | tr -d '\r')
shot=$HOME/.cache/statusbar-icons/device-statusbar.png; mkdir -p "$(dirname "$shot")"
tools/phone/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
echo "statusbar-icons: android sims=[$sims] types=[$types]"
echo "statusbar-icons: system.status=$status"
echo "statusbar-icons: icons=$icons shot=$shot"
fail=
case "$status" in null|""|*"no such call"*|*rror*) echo "FAIL: no system.status from the host (old APK?)"; exit 1 ;; esac
ready=$(tr ',' '\n' <<<"$sims" | grep -c -E '^(READY|LOADED)$')
cells=$(grep -o '"sim":"ready"' <<<"$status" | wc -l | tr -d ' ')
[ "$ready" -le "$cells" ] || fail="$fail android-ready-sims=$ready-but-status-cells=$cells"
if [ "$ready" -gt 0 ]; then
  grep -q '"bars":[0-4]' <<<"$status" || fail="$fail no-signal-bars"
  grep -qE 'of 4 bars' <<<"$icons" || fail="$fail no-signal-icon"
  if grep -q '"service":"in"' <<<"$status" && ! grep -q '"airplane":true' <<<"$status"; then
    grep -qE '"type":"[^"]+"' <<<"$status" || fail="$fail no-network-type"
    grep -qE ', (5G|5G\+|LTE|LTE\+|4G|4G\+|H|H\+|3G|E|G|1X)(,|")' <<<"$icons" || fail="$fail no-network-type-icon"
  fi
else
  grep -q 'No SIM' <<<"$icons" || grep -q '"airplane":true' <<<"$status" || fail="$fail no-sim-icon-missing"
fi
grep -q '"limited":true' <<<"$status" && echo "note: phone permission missing (limited: first SIM, no 5G override)"
[ -n "$fail" ] && { echo "FAIL:$fail"; exit 1; }
echo "PASS: $ready ready SIM(s) drawn with signal + network type: $icons"
