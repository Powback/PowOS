#!/bin/bash
# lint fixture: each command below is one sigpipe hit (12)
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
# any producer that can outrun a pipe buffer, not only dumpsys/logcat/docker (11-27/28): a big variable through
# printf (bash 3.2 writes it in chunks; bridge-detect-check.sh), `pm dump` through a wrapper split over two lines
# (live-text.sh), and a function of this file whose output is a logcat
while read -r m; do
  printf '%s\n' "$have" | grep -qx "$m" && continue
done < /dev/null
pkgdump_ok() {
  sh_ "pm dump $PKG" 2>/dev/null |
    grep -q 'livetext.LiveTextActivity' || skip "this app build has no LiveTextActivity yet"
}
logs() { sh_ "logcat -d -s Steam:I" | tr -d '\r'; }
logs | grep -q "launch window" && echo seen
