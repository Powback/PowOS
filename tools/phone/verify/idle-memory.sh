#!/bin/bash
# lanes: phone
# idle-memory.sh (board idle-phone-runs-out-of-memory-overnight-render-s; the user: "Idle phone runs out of memory
# overnight (render stalls, low-memory killer)"): read only, meant for the morning's first idle window. Reads how long
# the phone has been up, PowOS's LOW_MEMORY exits (app or WebView renderer, exit-info), MemAvailable, the PowOS app's PSS. PASS = up >= MIN_H hours (a night) with no
# lmk kill of com.powos.app (or its :processes), MemAvailable >= MIN_AVAIL % and the app's PSS < MAX_PSS_MB.
# SKIP when the phone hasn't been up a night yet (a reboot resets the evidence).
set -u
cd "$(dirname "$0")/../../.." || exit 5
A=tools/phone/adb.sh; MIN_H=${MIN_H:-6}; MIN_AVAIL=${MIN_AVAIL:-8}; MAX_PSS_MB=${MAX_PSS_MB:-1500}
up=$($A shell 'cat /proc/uptime' | tr -d '\r' | awk '{print int($1/3600)}')
[[ "$up" =~ ^[0-9]+$ ]] || { echo "SKIP: ENV: no uptime"; exit 5; }
mem=$($A shell 'cat /proc/meminfo' | tr -d '\r')
tot=$(awk '/^MemTotal:/{print $2}' <<<"$mem"); av=$(awk '/^MemAvailable:/{print $2}' <<<"$mem")
pss=$($A shell 'dumpsys meminfo com.powos.app' | tr -d '\r' | awk '/TOTAL PSS:/{print int($3/1024); exit}')
# Kills come from ApplicationExitInfo (survives the small events ring buffer): reason=3 (LOW_MEMORY) for the app or
# its WebView renderer (a killed renderer = the render stall) within the last WINDOW_H hours.
WINDOW_H=${WINDOW_H:-10}
# SINCE="YYYY-MM-DD HH:MM" (the night's start, queued at bedtime): judge only that night; until MIN_H hours have passed
# since it the job exits 3 (stays queued for a later window), so it can't pass on a half night.
if [ -n "${SINCE:-}" ]; then
  since=$SINCE; s0=$(date -j -f '%Y-%m-%d %H:%M' "${SINCE:0:16}" +%s 2>/dev/null || date -d "$SINCE" +%s)
  [ $(( ($(date +%s) - s0) / 3600 )) -ge "$MIN_H" ] || { echo "not a night yet since $SINCE (needs ${MIN_H} h) - again later"; exit 3; }
  up_s=$($A shell 'cat /proc/uptime' | tr -d '\r' | awk '{print int($1)}')
  [ $(( $(date +%s) - up_s )) -le "$s0" ] || { echo "SKIP: the phone rebooted after $SINCE - the night's evidence is gone"; exit 5; }
  up=$MIN_H
else since=$(date -v-"${WINDOW_H}"H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "-${WINDOW_H} hours" '+%Y-%m-%d %H:%M:%S'); fi
lmk=$($A shell 'dumpsys activity exit-info com.powos.app' | tr -d '\r' | awk -v s="$since" '/timestamp=/{t=$1" "$2; sub(/.*timestamp=/,"",t); sub(/ pid=.*/,"",t)} /reason=3 \(LOW_MEMORY\)/ && t>=s {print t" "$1}')
mine=$(grep -c . <<<"$lmk")
first="$since (exit-info, ${WINDOW_H} h)"; kills=$mine
pct=$(( ${av:-0} * 100 / ${tot:-1} ))
echo "idle-memory: up ${up} h, judged since ${first:-?}; PowOS LOW_MEMORY exits ${mine}; MemAvailable ${pct}% ($((av/1024)) of $((tot/1024)) MB); com.powos.app PSS ${pss:-?} MB"
[ -n "$lmk" ] && sed 's/^/  LOW_MEMORY /' <<<"$lmk" | tail -4
[ "$up" -ge "$MIN_H" ] || { echo "SKIP: up only ${up} h (needs a night, >= ${MIN_H} h, to say anything about overnight memory)"; exit 5; }
f=
[ "$mine" -eq 0 ] || f="$f PowOS killed ${mine}x by the low-memory killer;"
[ "$pct" -ge "$MIN_AVAIL" ] || f="$f MemAvailable ${pct}% < ${MIN_AVAIL}%;"
[ -n "$pss" ] && [ "$pss" -ge "$MAX_PSS_MB" ] && f="$f the app's PSS ${pss} MB >= ${MAX_PSS_MB} MB;"
[ -n "$f" ] && { echo "FAIL:$f"; exit 1; }
echo "PASS: ${up} h up overnight - no low-memory kill of PowOS, ${pct}% memory available, app PSS ${pss} MB"
