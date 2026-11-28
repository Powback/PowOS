#!/bin/bash
# lint fixture: none of these is a hit
set -euo pipefail
A=adb
focus() { "$A" shell dumpsys window | awk '/mCurrentFocus/&&!f{print; f=1}'; }
if "$A" shell dumpsys power | awk '/mWakefulness=Awake/{f=1} END{exit !f}'; then echo awake; fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi lock && echo locked
grep -i exception "$OUT/logcat-sys.txt" | head -8 || true
out=$(cat /tmp/answer); grep -q yes <<<"$out" && echo yes
"$A" shell dumpsys window | head -n1 > /tmp/first.txt
# lint-ok: the dump is two lines, both written before head can exit
"$A" shell dumpsys -l | head -n1 && echo listed
"$A" shell dumpsys input_method | awk '/x/{print; exit}' # lint-ok: fixture escape on the line itself
wg_age() {
  { docker exec wireguard wg show wg0 dump 2>/dev/null || true; } | awk -F'\t' -v now="$(date +%s)" \
    -v ip="$ip" 'NR > 1 && !f && index("," $4 ",", "," ip "/32,") { print now - $5; f = 1 }'
}
up=$(docker ps -q --filter name=x | awk 'NF{f=1} END{exit !f}' && echo yes)
echo "$up"
# tiny or phone-bounded producers, and the herestring fix for a big variable
grep -qx "$m" <<<"$have" && echo have
pkgdump=$(sh_ "pm dump $PKG" 2>/dev/null || true); [[ $pkgdump == *LiveTextActivity* ]] && echo has
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
kg | grep -q true && echo locked
sh_ "getprop sys.boot_completed" | grep -q 1 && echo booted
us "pgrep -x plasmashell >/dev/null && echo up" | grep -q up && echo up
echo literal | grep -q lit && echo lit
