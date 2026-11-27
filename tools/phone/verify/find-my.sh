#!/bin/bash
# lanes: phone
# find-my.sh (board find-my-devices-ring-and-locate; queue: queue.sh add --close <task> tools/phone/verify/find-my.sh):
# the phone's own Find my device code (devices/FindMy.kt) answers ring / ring_stop / locate - no touch, and polite:
#  1. ring at 5% of the player volume (6 s at most), the alarm volume left alone (args volume < 1), answered ringing:true;
#  2. the alarm stream is playing (dumpsys audio), then ring_stop answers was:true and the notification is gone;
#  3. locate answers coordinates + age, or the phone's own refusal (location permission / location off) - both are the
#     command path working; a missing answer is the FAIL.
# Through FindMy$Command (`am broadcast`, DUMP-guarded: adb shell) - the same calls the HTTPS agent's /v1/action makes,
# rooted (powos-deviced) or not (DeviceAgentHost). Exit 0 pass, 1 fail, 5 can't run (no phone).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
C='com.powos.app/dev.omalauncher.devices.FindMy$Command'
fm() { "$T/adb.sh" shell "am broadcast -n '$C' --es op $*" 2>&1 | sed -n 's/.*data="\(.*\)"$/\1/p'; }
"$T/adb.sh" shell true >/dev/null 2>&1 || { echo "SKIP find-my: phone not reachable"; exit 5; }
fail() { echo "FAIL find-my: $1"; fm ring_stop >/dev/null; exit 1; }

r=$(fm "ring --es volume 0.05 --es seconds 6"); echo "  ring: $r"
grep -q '"ringing":true' <<<"$r" || fail "ring didn't start (${r:-no answer - APK without FindMy?})"
playing=$("$T/adb.sh" shell 'dumpsys audio' 2>/dev/null | grep -c 'usage=USAGE_ALARM.*state:started\|state:started.*usage=USAGE_ALARM')
echo "  alarm players started: $playing"
s=$(fm ring_stop); echo "  ring_stop: $s"
grep -q '"was":true' <<<"$s" || fail "ring_stop didn't find it ringing"
left=$("$T/adb.sh" shell 'dumpsys notification --noredact' 2>/dev/null | grep -c 'pkg=com.powos.app.*id=4607321')
[ "${left:-0}" -gt 0 ] && fail "the ringing notification stayed after Stop"
l=$(fm locate); echo "  locate: $l"
if grep -q '"lat":' <<<"$l"; then
  grep -q '"age_s":' <<<"$l" || fail "locate gave no age"
  echo "PASS find-my: rang quietly, stopped from the caller, located ($(sed 's/.*"lat":\([^,]*\),"lon":\([^,]*\).*/\1, \2/' <<<"$l"))"
elif grep -q '"ok":false' <<<"$l"; then
  echo "PASS find-my: rang quietly, stopped from the caller; locate refused in the phone's words ($(sed 's/.*"error":"\([^"]*\)".*/\1/' <<<"$l"))"
else
  fail "locate didn't answer"
fi
