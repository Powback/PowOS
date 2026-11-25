#!/bin/bash
# lint fixture: each command below is one sigpipe hit (9)
set -euo pipefail
A=adb
focus() { "$A" shell dumpsys window | awk '/mCurrentFocus/{print; exit}'; }
if "$A" shell dumpsys power | grep -q 'mWakefulness=Awake'; then echo awake; fi
sh_ "dumpsys window windows" | grep mCurrentFocus | grep -qi lock && echo locked
x=$(adb logcat -d | head -n1)
flags() {
  adb shell dumpsys statusbar | sed -n 's/x/y/p' | head -1
}
"$A" shell "logcat -d -s Tag:I" | grep -m1 'a touch' || echo none
sh_ "dumpsys notification" | grep "mId=.plasma-v1" >/dev/null || echo none
# docker's CLI dies of SIGPIPE too, and awk's options/continuations/$(...) must not hide the exit (adb.sh wg_age, 11-25)
wg_age() {
  docker exec wireguard wg show wg0 dump 2>/dev/null | awk -F'\t' -v now="$(date +%s)" \
    -v ip="$ip" 'NR > 1 && index("," $4 ",", "," ip "/32,") { print now - $5; exit }'
}
up=$(docker ps -q --filter name=x | grep -q . && echo yes)
