#!/bin/bash
# lint fixture: each command below is one sigpipe hit (7)
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
