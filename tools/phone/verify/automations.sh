#!/bin/bash
# lanes: phone
# automations.sh [OUT] (Mac side; board automations-triggers-and-actions): a time-trigger automation made through home's
# bridge (automations.save, as Settings > automations saves) for the phone's next minute, its one action a harmless
# notification, runs from the app (Automations.kt's exact alarm - no page involved in the run): its last-run line
# says "notified" (automations.list lastRan/lastResult) and the notification is posted (dumpsys notification). No touch.
# Cleans up: the user's own list saved back exactly as it was (trap); the test notification auto-cancels on a tap.
# Exit 1 + "FAIL:" on a miss, 3 on no window, 5 + "ENV:" when it can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HOME/.cache/powos-verify/automations-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
. "$here/base.sh"
. "$here/window-lock.sh"; window_lock automations 60 "${MAX_WAIT:-10800}"
ID=verify$(date +%s); TAG="automation check $ID"
B0=""
# hcall's second argument is the call's ARGUMENT LIST (the bridge's positional args, bridge.ts call(method, ...args)):
# save takes one list, next one trigger - each wrapped in [...] (11-28 FAIL: passed bare, the host read the first
# automation / the trigger's first field as that list: "Value {...} cannot be converted to JSONArray").
restore() { [ -n "$B0" ] && hcall automations.save "[JSON.parse(atob('$B0'))]" 'v=>String(v.length)' >/dev/null; }
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT

B0=$(hcall automations.list '[]' 'v=>btoa(JSON.stringify(v))')
case "$B0" in ERR* | "") echo "ENV: no automations bridge on home ($B0) - an APK before automations?"; B0=""; exit 5 ;; esac
# The phone's clock: the next whole minute at least 20 s away.
# One plain word: sh_ wraps its command in su -c '...', so a quoted format (date +'%s %S') split there and came back
# empty (11-28: "trigger at 01:01").
s=$(sh_ "date +%s"); vb_int "$s" || { echo "ENV: no phone clock ('$s')"; exit 5; }
now=$((s % 60)); add=60; [ "$now" -ge 40 ] && add=120
AT=$(sh_ "date -d @$((s + add)) +%H:%M" 2>/dev/null)
[ -n "$AT" ] || AT=$(date -r $((s + add)) +%H:%M)
FIRE=$(( (s + add) / 60 * 60 ))
echo "phone time $(sh_ "date +%H:%M:%S"), trigger at $AT (in $((FIRE - s)) s)" | tee -a "$OUT/log.txt"
NEW="{id:'$ID',name:'verify',on:true,trigger:{kind:'time',at:'$AT',days:[]},actions:[{kind:'notify',title:'PowOS',text:'$TAG'}]}"
n=$(hcall automations.save "[[...JSON.parse(atob('$B0')),$NEW]]" 'v=>String(v.length)')
echo "saved: $n automations" | tee -a "$OUT/log.txt"
vb_int "$n" || fail "automations.save says $n"
next=$(hcall automations.next "[{kind:'time',at:'$AT',days:[]}]" 'v=>String(Math.round(v/1000))')
[ "$next" = "$FIRE" ] || fail "automations.next says $next, expected $FIRE"

ran=""; end=$((FIRE + 75))
while :; do
  ran=$(hcall automations.list '[]' "v=>{const a=v.find(x=>x.id==='$ID');return a&&a.lastRan?'ran@'+Math.round(a.lastRan/1000)+' '+a.lastResult:'not'}")
  case "$ran" in ran@*) break ;; esac
  [ "$(sh_ "date +%s")" -gt "$end" ] 2>/dev/null && break
  sleep 10
done
echo "last run: $ran" | tee -a "$OUT/log.txt"
case "$ran" in
  ran@*notified*)
    at=${ran#ran@}; at=${at%% *}
    late=$((at - FIRE)); echo "ran $late s after $AT" | tee -a "$OUT/log.txt"
    [ "$late" -ge -2 ] && [ "$late" -le 70 ] || fail "ran at the wrong time ($late s from $AT)" ;;
  *) fail "the automation didn't run by $AT + 75 s ($ran)" ;;
esac
# Grep the one-word $ID, unquoted: sh_ wraps its command in su -c '...', so a quoted '$TAG' closed that quote and the
# phone ran "grep -c automation check verify..." (files "check", "verify..."): empty output, a false FAIL (11-28 05:02,
# while logcat said "notified").
sh_ "logcat -d -s automations | tail -5" >"$OUT/logcat.txt"
c=$(sh_ "dumpsys notification --noredact | grep -c $ID")
echo "notification lines: $c" | tee -a "$OUT/log.txt"
vb_int "$c" || fail "dumpsys notification grep gave '$c'"
[ "${c:-0}" -ge 1 ] 2>/dev/null || { cat "$OUT/logcat.txt"; fail "no notification with '$TAG' posted"; }

restore; B0=""; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
echo "artefacts: $OUT"
result "a time automation saved for the next minute ran from the app at $AT and posted its notification"
