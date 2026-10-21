#!/bin/bash
# Seconds since the user last touched the phone, and the screen state: "idle=<s> screen=<Awake|Dozing|Asleep>".
# Drive the phone (injected input, screenrecord journeys, installs that restart the session) only when idle>=120
# and screen=Awake; never wake the screen with key events.
here=$(dirname "$0")
"$here/adb.sh" shell 'dumpsys power | grep -m1 -E "^ *lastUserActivityTime="; dumpsys power | grep -m1 mWakefulness=' 2>/dev/null |
  awk '/lastUserActivityTime=/{ if (match($0, /\(([0-9]+) ms ago\)/)) { s=substr($0, RSTART+1, RLENGTH-9); idle=int(s/1000) } }
       /mWakefulness=/{split($0,b,"="); w=b[2]} END{ printf "idle=%d screen=%s\n", idle, w }'
