#!/bin/bash
# lint fixture: none of these is a hit
set -euo pipefail
A=adb
focus() { "$A" shell dumpsys window | awk '/mCurrentFocus/&&!f{print; f=1}'; }
if "$A" shell dumpsys power | awk '/mWakefulness=Awake/{f=1} END{exit !f}'; then echo awake; fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi lock && echo locked
grep -i exception "$OUT/logcat-sys.txt" | head -8
echo "$out" | grep -q yes && echo yes
"$A" shell dumpsys window | head -n1 > /tmp/first.txt
# lint-ok: the dump is two lines, both written before head can exit
"$A" shell dumpsys -l | head -n1 && echo listed
"$A" shell dumpsys input_method | awk '/x/{print; exit}' # lint-ok: fixture escape on the line itself
