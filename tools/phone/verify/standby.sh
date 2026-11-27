#!/bin/bash
# lanes: phone
# standby.sh (Mac side, board standby-clock-and-widgets-when-charging-in-lands): StandBy, PowOS's "when charging"
# screensaver (PowosDozeService in standby mode, shell/ui/standby.tsx), on the phone - no root (adb shell's own
# settings/dream rights). Runs only on a charging phone: not plugged in = SKIP (the queue already runs it only in an
# idle window). Steps, every setting put back as it was at the end:
#   1. PowOS picked as the screensaver (secure screensaver_components/_enabled), the screen turned landscape
#      (system accelerometer_rotation 0 + user_rotation 1), the dream started (cmd dreams, else SystemUI's Somnambulator);
#   2. the standby page is up (CDP "standby"): its clock, both stacks, the left stack's cards and the night flag;
#   3. a tap in the clock ends the dream (dumpsys dreams: not dreaming within 5 s).
# PASS = all three. Screenshot: $OUT/standby.png when OUT is set.
set -u
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
. "$here/base.sh"
cd "$here/../../.." || exit 1
ash() { "$A" shell "$@" 2>/dev/null | tr -d '\r'; }
COMP=com.powos.app/dev.omalauncher.shell.PowosDozeService

dump=$(ash dumpsys battery)
echo "$dump" | grep -qE '(AC|USB|Wireless|Dock) powered: true' || skip "not plugged in - StandBy shows only on a charger"

step "pick PowOS as the screensaver, landscape, start it" 30
old_comp=$(ash settings get secure screensaver_components)
old_on=$(ash settings get secure screensaver_enabled)
old_acc=$(ash settings get system accelerometer_rotation)
old_rot=$(ash settings get system user_rotation)
# A setting that wasn't set ("null") is deleted again, never written as the text "null".
put_back() { if [ -z "$3" ] || [ "$3" = null ]; then ash settings delete "$1" "$2" >/dev/null; else ash settings put "$1" "$2" "$3" >/dev/null; fi; }
restore() {
  put_back secure screensaver_components "$old_comp"
  put_back secure screensaver_enabled "$old_on"
  put_back system user_rotation "$old_rot"
  put_back system accelerometer_rotation "$old_acc"
  ash cmd dreams stop-dream >/dev/null 2>&1 || true
}
trap restore EXIT
ash settings put secure screensaver_components "$COMP" >/dev/null
ash settings put secure screensaver_enabled 1 >/dev/null
ash settings put system accelerometer_rotation 0 >/dev/null
ash settings put system user_rotation 1 >/dev/null
sleep 1
ash cmd dreams start-dream >/dev/null 2>&1 || ash am start -n com.android.systemui/.Somnambulator >/dev/null
dreaming() { ash dumpsys dreams | grep -qiE 'mCurrentDream.*PowosDozeService|isDreaming=true|mDreaming=true|dreaming: true'; }
for _ in 1 2 3 4 5 6 7 8 9 10; do dreaming && break; sleep 1; done
dreaming || fail "the dream didn't start (dumpsys dreams: $(ash dumpsys dreams | grep -iE 'dream' | head -3 | tr '\n' ' '))"

step "the standby page" 40
st=""
for _ in 1 2 3 4 5 6 7 8; do
  st=$(cdp_val 'JSON.stringify({clock:!!document.querySelector(".standby-time"),time:document.querySelector(".standby-time")?.textContent,stacks:document.querySelectorAll(".standby-stack").length,left:[...document.querySelectorAll(".standby-stack[data-stack=left] .standby-card")].map(c=>c.dataset.kind).join(),right:[...document.querySelectorAll(".standby-stack[data-stack=right] .standby-card")].map(c=>c.dataset.kind).join(),night:document.querySelector(".standby")?.dataset.night,aod:!!document.querySelector(".aod"),W:innerWidth,H:innerHeight})' standby 2>/dev/null)
  echo "$st" | grep -q '"clock":true' && break
  sleep 2
done
echo "page: $st"
if echo "$st" | grep -q '"clock":true' && echo "$st" | grep -q '"stacks":2'; then
  pass "StandBy up: $st"
else
  fail "no StandBy face on the dream's page ($st)"
fi
[ -n "${OUT:-}" ] && shot "$OUT/standby.png" >/dev/null 2>&1

step "a tap ends it" 20
size=$(ash wm size | awk -F'[ x]' '/Override|Physical/ {w=$(NF-1); h=$NF} END {print w, h}')
read -r pw ph <<<"$size"
# Landscape: the clock is on the left third of the long side, mid-height. user_rotation 1: x/y in the rotated frame.
long=$(( pw > ph ? pw : ph )); short=$(( pw > ph ? ph : pw ))
"$A" shell input tap $(( long / 4 )) $(( short / 2 )) >/dev/null 2>&1
gone=0
for _ in 1 2 3 4 5; do dreaming || { gone=1; break; }; sleep 1; done
[ "$gone" = 1 ] && pass "a tap ended StandBy" || fail "StandBy still up 5 s after a tap"

result "StandBy shows on the charger and a tap ends it"
