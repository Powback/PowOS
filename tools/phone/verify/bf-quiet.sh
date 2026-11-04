#!/bin/bash
# lanes: phone
# bf-quiet.sh [secs=600]: (Mac) the non-game load while a game is the full-screen window (board
# broforce-fps-low-cpu-bound-under-fex, docs/research/broforce-fps.md "Non-game load"). Starts Steam + Broforce unless a
# game already runs (NO_START=1: never start; the user's game is measured as it is, never closed), then every ~60 s:
#   top      the top processes over that 60 s (top -n2 -d 60, the second frame)
#   therm    skin-msm-therm (C) and policy0/3/7 scaling_max_freq (the thermal caps)
#   fps      KWin's "window task N frames:" lines of that minute (commits / 5 = the game's fps)
# once at the start and the end:
#   hwc      SurfaceFlinger's HWC list: each layer's composition (DEVICE = overlay, CLIENT = GPU-composed)
#   home     home's page under the game: rAF/s, BeginFrames/s, script ms/s (cdp.sh idle 15) - 0 rAF/s when paused (GQ1)
#   gq1      the GQ1 log lines (home's page paused / running again)
# and tools/phone/verify/game-boost.sh 20 mid-run (the boost + the vendor game thermal table while boosted).
# PASS: the game ran the whole window; the evidence is the lines (compare with the baseline in the doc).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
SECS=${1:-600}
OUT=${OUT:-$HOME/.cache/powos-verify/bf-quiet-$(date +%F_%H%M)}; mkdir -p "$OUT"
LOG=/data/powos/root/run/hyprland.log
BF_ADB=$A . "$here/bf-lib.sh"
asuser() { "$A" push "$here/$1" /data/local/tmp/powos-$1 >/dev/null; "$A" shell "su -c 'cp /data/local/tmp/powos-$1 /data/powos/root/var/tmp/powos-$1; chmod 644 /data/powos/root/var/tmp/powos-$1; sh /data/powos/powos-run.sh \"sh /var/tmp/powos-$1\"'"; }
game() { "$A" shell "pgrep -f Broforce_beta.exe | head -1" | tr -d '\r'; }
hwc() { "$A" shell "su -c 'dumpsys SurfaceFlinger'" | tr -d '\r' | awk '/\(active\) HWC layers/{p=1;next} p&&/^Display .*HWC layers/{p=0} p&&/^ [^ -]/{n=$0} p&&/\|/&&n{split($0,c,"|"); gsub(/ /,"",c[4]); print "hwc", c[4], n; n=""}'; }
home() { "$T/cdp.sh" idle 15 home 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("home", p["page"], "hidden=%s" % p["hidden"], " ".join("%s=%s" % kv for kv in p["perSec"].items())) for p in d["pages"]]' || echo "home: cdp failed"; }
started=""
if [ -z "$(game)" ]; then
  [ "${NO_START:-}" ] && { echo "SKIP no game running (NO_START)"; exit 5; }
  pill "starting Steam + Broforce"; asuser bf-start.sh; started=1
  for _ in $(seq 1 30); do [ -n "$(game)" ] && break; sleep 10; done
  [ -z "$(game)" ] && { echo "FAIL no game after 300 s"; exit 1; }
  sleep 60   # past the loading screens
fi
"$A" shell "dumpsys window | grep -E 'mCurrentFocus'" | tr -d '\r' | sed 's/^/focus /'
hwc | tee "$OUT/hwc-start.txt"; home | tee "$OUT/home-start.txt"
k0=$("$A" shell "su -c 'wc -l < $LOG'" | tr -d '\r ')
t0=$(date +%s); ok=1; boosted=""
while [ $(( $(date +%s) - t0 )) -lt "$SECS" ]; do
  pill "game load sample $(( $(date +%s) - t0 ))/$SECS s"
  [ -z "$(game)" ] && { echo "game gone at $(( $(date +%s) - t0 )) s"; ok=0; break; }
  "$A" shell "su -c 'top -b -n2 -d 60 -m 12'" | tr -d '\r' | awk '/^Tasks:/{f++} f==2&&/^ *[0-9]+ /{printf "top %s%% %s\n", $9, substr($0, index($0,$12), 60)}' | head -12
  "$A" shell "su -c 'for z in /sys/class/thermal/thermal_zone*; do [ \"\$(cat \$z/type)\" = skin-msm-therm ] && echo skin \$(cat \$z/temp); done; echo caps \$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq) \$(cat /sys/devices/system/cpu/cpufreq/policy3/scaling_max_freq) \$(cat /sys/devices/system/cpu/cpufreq/policy7/scaling_max_freq)'" | tr -d '\r' | sed "s/^/t+$(( $(date +%s) - t0 ))s /"
  k1=$("$A" shell "su -c 'wc -l < $LOG'" | tr -d '\r ')
  "$A" shell "su -c 'sed -n \"$((k0 + 1)),${k1}p\" $LOG'" | tr -d '\r' | grep 'window task .* frames:' | tail -3 | sed 's/^/fps /'
  k0=$k1
  if [ -z "$boosted" ] && [ $(( $(date +%s) - t0 )) -ge $(( SECS / 2 )) ]; then boosted=1; "$here/game-boost.sh" 20 2>&1 | sed 's/^/boost /' | tail -25; fi
done
hwc | tee "$OUT/hwc-end.txt"; home | tee "$OUT/home-end.txt"
"$A" shell "logcat -d | grep GQ1 | tail -6" | tr -d '\r' | sed 's/^/gq1 /'
[ -n "$started" ] && { pill "closing the game"; asuser bf-stop.sh; }
[ "$ok" = 1 ] && echo "PASS game ran ${SECS} s: compare top/skin/caps/hwc/home with docs/research/broforce-fps.md Non-game load" || echo "FAIL the game ended before ${SECS} s"
