#!/bin/bash
# scratch (untracked, agent unity-load): bf-coldstart.sh steam with the game boost engaged AT THE TAP - what
# GameBoost's launch mark (powos-open-task run/game-launch) does once the APK ships. Same script, same lease as the app.
here=/Users/macback/pw/unity-load/tools/phone; A=$here/adb.sh
export OUT=$HOME/.cache/powos-verify/bf-coldstart-boost-$(date +%F_%H%M%S); mkdir -p "$OUT"
L=/data/user/0/com.powos.app/files/game-boost.lease G=/data/user/0/com.powos.app/files/game-boost.sh
"$here/verify/bf-coldstart.sh" "$@" & job=$!
until grep -q 'cold start timing: steam #1 - tap' "$OUT/run.txt" 2>/dev/null || ! kill -0 $job 2>/dev/null; do sleep 0.2; done
"$A" shell "su -c 'touch $L; sh $G engage steam_app_274190 $L'" 2>&1 | tail -1 | sed 's/^/boost at tap: /'
until grep -q 'checking the visible game' "$OUT/run.txt" 2>/dev/null || ! kill -0 $job 2>/dev/null; do "$A" shell "su -c 'touch $L'" >/dev/null 2>&1; sleep 2; done
wait $job
