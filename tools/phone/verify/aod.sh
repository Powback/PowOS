#!/bin/bash
# lanes: phone
# aod.sh (Mac side, board always-on-display-shows-now-playing-and-the-fing): the screen-off display (shell/ui/aod.tsx)
# with its now-playing line and an in-display fingerprint sensor's spot, on the phone - no root. The doze component
# itself needs the PowOS system module's overlay, so this shows the same page the no-root way: PowOS's "when charging"
# screensaver held upright (PowosDozeService: StandBy upright = the aod screen, with the transport since that dream
# takes touches). Runs only on a charging phone (else SKIP). Nothing is played or paused: it compares the page with
# what the phone says. Steps, every setting put back at the end:
#   1. PowOS picked as the screensaver, the screen held portrait, the dream started;
#   2. the aod page is up (CDP "standby"): the clock; a now-playing line exactly when dumpsys media_session has a
#      playing session (state=3), with its previous / play / next;
#   3. the fingerprint spot only on a phone with an in-display sensor (the host's lock.sensor answer): the
#      OnePlus Open (a side sensor) has none.
# PASS = all three. Screenshot: $OUT/aod.png when OUT is set.
set -u
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
. "$here/base.sh"
. "$here/dream.sh"
cd "$here/../../.." || exit 1
ash() { "$A" shell "$@" 2>/dev/null | tr -d '\r'; }
COMP=com.powos.app/dev.omalauncher.shell.PowosDozeService

dump=$(ash dumpsys battery)
echo "$dump" | grep -qE '(AC|USB|Wireless|Dock) powered: true' || skip "not plugged in - the screensaver shows only on a charger"

step "pick PowOS as the screensaver, portrait, start it" 60
old_comp=$(ash settings get secure screensaver_components)
old_on=$(ash settings get secure screensaver_enabled)
old_acc=$(ash settings get system accelerometer_rotation)
old_rot=$(ash settings get system user_rotation)
put_back() { if [ -z "$3" ] || [ "$3" = null ]; then ash settings delete "$1" "$2" >/dev/null; else ash settings put "$1" "$2" "$3" >/dev/null; fi; }
restore() {
  put_back secure screensaver_components "$old_comp"
  put_back secure screensaver_enabled "$old_on"
  put_back system user_rotation "$old_rot"
  put_back system accelerometer_rotation "$old_acc"
  dream_stop
  dream_restore
}
trap restore EXIT
ash settings put system accelerometer_rotation 0 >/dev/null
ash settings put system user_rotation 0 >/dev/null
if dream_start "$COMP"; then pass "the dream is up: $(dream_line)"; else fail "the dream didn't start ($DREAM_WHY)"; fi

step "the aod page and its now-playing line" 40
playing=0
ash dumpsys media_session | grep -qE 'state=PlaybackState \{state=3\b|state=3,' && playing=1
st=""
for _ in 1 2 3 4 5 6 7 8; do
  st=$(cdp_val 'JSON.stringify({aod:!!document.querySelector(".aod-time"),title:document.querySelector(".aod-title")?.textContent??null,buttons:document.querySelectorAll(".aod-transport button").length,fp:!!document.querySelector(".aod-fp")})' standby 2>/dev/null)
  echo "$st" | grep -q '"aod":true' && break
  sleep 2
done
echo "page: $st (phone playing: $playing)"
echo "$st" | grep -q '"aod":true' || fail "no aod screen on the upright dream ($st)"
if [ "$playing" = 1 ]; then
  echo "$st" | grep -q '"title":null' && fail "the phone plays, the aod has no now-playing line ($st)"
  echo "$st" | grep -q '"buttons":3' || fail "the now-playing line has no previous / play / next ($st)"
  pass "now playing on the aod: $st"
else
  pass "nothing playing on the phone; aod: $st"
fi
[ -n "${OUT:-}" ] && shot "$OUT/aod.png" >/dev/null 2>&1

step "the fingerprint spot" 15
# The host's own answer (home's page asks it; the same FingerprintSensor.read the aod's page got). Quotes stripped.
sensor=$(hcall_once lock.sensor '[]' 'v=>JSON.stringify(v)')
echo "sensor: $sensor"
if echo "$sensor" | grep -q 'kind:udfps' && echo "$sensor" | grep -q 'enrolled:true'; then
  echo "$st" | grep -q '"fp":true' && pass "spot drawn for the in-display sensor" || fail "an in-display sensor, no spot ($st)"
else
  echo "$st" | grep -q '"fp":false' && pass "no spot (sensor: ${sensor:-unknown})" || fail "a spot drawn without an in-display sensor ($sensor)"
fi

result "the aod shows what's playing and the fingerprint spot where there is one"
