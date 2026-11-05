#!/bin/bash
# lanes: phone
# bf-quiet.sh [secs=600]: (Mac) the non-game load while a game is the full-screen window (board
# broforce-fps-low-cpu-bound-under-fex, docs/research/broforce-fps.md "Non-game load"). Starts Steam + Broforce the way
# bf-pacing/bf-checker do (bf-start.sh: powos-open-task, so KWin shows the game as its own task in front), waits for
# its X window, then 60 s past the loading screens. A Broforce that already runs is the user's (bf-game.sh state):
# awake = measured as it is and never closed; frozen = skipped (exit 3, never woken). NO_START=1: never start one.
# Then every ~60 s (bf-quiet-phone.sh, one adb call per sample):
#   front    mCurrentFocus + topResumedActivity at the sample's start and end
#   gamecpu  the game's processes (FEX wine64 running Broforce_beta.exe) over the sample, % of one core
#   top      the top processes over that 60 s (top -n2 -d 60, the second frame)
#   therm    skin-msm-therm (C) and policy0/3/7 scaling_max_freq (the thermal caps)
#   fps      KWin's "window task N frames:" lines of that minute (commits / 5 = the game's fps)
# once at the start and the end:
#   app      com.powos.app's versionName (the build the HWC/blur evidence belongs to)
#   hwc      SurfaceFlinger's HWC list: each layer's composition (DEVICE = overlay, CLIENT = GPU-composed), and any
#            blur region / background blur radius / BLUR client type (GlassBlur's stray radius-0 region: game-quiet)
#   home     home's page under the game: rAF/s, BeginFrames/s, script ms/s (cdp.sh idle 15) - 0 rAF/s when paused (GQ1)
#   gq1      the GQ1 log lines (home's page paused / running again)
# and tools/phone/verify/game-boost.sh 20 mid-run (the boost + the vendor game thermal table while boosted).
# PASS (bf-quiet-verdict.py, test/tier1/test-bf-quiet-verdict.py): the samples cover <secs> s, the game's window
# (PowosWindowActivity) focused + resumed at every sample's start and end, its processes >= MIN_CPU % (default 25) in
# every sample. The 03:02 soak of 2026-11-05 printed PASS with home in front for 600 s and no game: the old
# `adb shell "pgrep -f Broforce_beta.exe"` matched its own sh -c, so it never started the game.
# Exit 3 on a touch (what this check started is closed), 5 when the game doesn't start.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
SECS=${1:-600}; MIN_CPU=${MIN_CPU:-25}
case "$SECS$MIN_CPU" in *[!0-9]*) echo "secs / MIN_CPU: numbers"; exit 2 ;; esac
OUT=${OUT:-$HOME/.cache/powos-verify/bf-quiet-$(date +%F_%H%M)}; mkdir -p "$OUT"
LOG=/data/powos/root/run/powos-app/hyprland.log   # KWin's session log (bf-pacing's; /data/powos/root/run/hyprland.log doesn't exist)
BF_ADB=$A . "$here/bf-lib.sh"
asuser() { local n=$1; shift
  "$A" shell "su -c 'cp /data/local/tmp/powos-$n /data/powos/root/var/tmp/powos-$n; chmod 644 /data/powos/root/var/tmp/powos-$n; sh /data/powos/powos-run.sh \"sh /var/tmp/powos-$n $*\"'" 2>&1 | grep -v sysvipc | tr -d '\r'; }
irq() { "$A" shell "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts" | tr -d '\r'; }
hwc() { "$A" shell "su -c 'dumpsys SurfaceFlinger'" | tr -d '\r' > "$OUT/sf-$1.txt"
  awk '/\(active\) HWC layers/{p=1;next} p&&/^Display .*HWC layers/{p=0} p&&/^ [^ -]/{n=$0} p&&/\|/&&n{split($0,c,"|"); gsub(/ /,"",c[4]); print "hwc", c[4], n; n=""}' "$OUT/sf-$1.txt"
  grep -E 'blurRegions|backgroundBlurRadius=[1-9]|clientType=BLUR' "$OUT/sf-$1.txt" | sed 's/^ *//' | sort | uniq -c | sed 's/^ */blur /' | head -8
  # Who owns each blur region (any one makes SF GPU-compose every layer under it: the verify pill's glass, 11-05).
  awk '/^ *Layer \[/{n=$0; sub(/^ *Layer \[[0-9]+\] /,"",n)} /blurRegions.size\(\)=[1-9]/&&n{print "blurowner", n; n=""}' "$OUT/sf-$1.txt" | sort -u; }
home() { "$T/cdp.sh" idle 15 home 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("home", p["page"], "hidden=%s" % p["hidden"], " ".join("%s=%s" % kv for kv in p["perSec"].items())) for p in d["pages"]]' || echo "home: cdp failed"; }
app() { "$A" shell "dumpsys package com.powos.app 2>/dev/null | grep -m1 versionName" | tr -d '\r ' | sed 's/^/app /'; }
st=$OUT/push; mkdir -p "$st"; for f in bf-start.sh bf-stop.sh bf-window.sh bf-game.sh bf-nap.sh bf-quiet-phone.sh; do cp "$here/$f" "$st/powos-$f"; done
"$A" push "$st"/powos-bf-*.sh /data/local/tmp/ >/dev/null || { echo "ENV: can't push the check's scripts"; exit 5; }
gs=$(asuser bf-game.sh state | tail -1); started=""
front=$("$A" shell "dumpsys activity activities | grep -m1 topResumedActivity" | sed -nE 's#.* ([a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+) .*#\1#p')
steam_before=$("$A" shell "pgrep -f 'steam -cef' | head -1" | tr -d '\r')
restore() {
  if [ -n "$started" ]; then pill "closing the game"; asuser bf-stop.sh >/dev/null; started=""
    [ -n "$steam_before" ] && "$A" shell "su -c 'sh /data/powos/powos-run.sh \"cd /home/powos; setsid -f steam -silent </dev/null >/dev/null 2>&1\"'" >/dev/null 2>&1
    [ -n "$front" ] && "$A" shell "am start -n $front >/dev/null 2>&1"
  fi
  "$A" shell "su -c 'rm -f /data/local/tmp/powos-bf-*.sh /data/local/tmp/powos-bfq-top.txt /data/powos/root/var/tmp/powos-bf-*.sh'" >/dev/null 2>&1; }
i0=$(irq)
abort() { echo "touch $(date +%T) - abort, restoring"; restore; exit 3; }
nap() { case $("$A" shell "sh /data/local/tmp/powos-bf-nap.sh $1 $i0" | tr -d '\r') in *touched*) abort ;; esac; }
echo "game before: $gs front=${front:-?} steam_before=${steam_before:+yes}"
case $gs in
  game=frozen) echo "SKIP the user's Broforce is left frozen: not woken for a soak"; restore; exit 3 ;;
  game=awake) echo "the user's Broforce is up: measured as it is, never closed" ;;
  *) [ "${NO_START:-}" ] && { echo "SKIP no game running (NO_START)"; restore; exit 5; }
     pill "starting Steam + Broforce"; asuser bf-start.sh | tail -1; started=1
     pill "waiting for the game window"
     win=$(asuser bf-window.sh wait 300 "$i0" | tail -1)
     case $win in touched) abort ;; win=[0-9]*) echo "window: $win" ;; *) echo "FAIL no game window in 300 s ($win)"; restore; exit 5 ;; esac
     pill "game up - 60 s past the loading screens"; nap 60 ;;
esac
app | tee "$OUT/app.txt"
hwc start | tee "$OUT/hwc-start.txt"; home | tee "$OUT/home-start.txt"
k0=$("$A" shell "su -c 'wc -l < $LOG'" | tr -d '\r ')
: > "$OUT/samples.txt"; t0=$(date +%s); boosted=""
while [ $(( $(date +%s) - t0 )) -lt "$SECS" ]; do
  el=$(( $(date +%s) - t0 )); pill "game load sample $el/$SECS s"
  r=$("$A" shell "su -c 'sh /data/local/tmp/powos-bf-quiet-phone.sh 60 $i0'" | tr -d '\r')
  case $r in *touched*) abort ;; esac
  { echo "sample t=$el"; echo "$r"; } | tee -a "$OUT/samples.txt"
  # The verdict's own rule, early: the game out of front or not running ends the soak at once (FAIL below).
  python3 "$here/bf-quiet-verdict.py" "$OUT/samples.txt" 0 "$MIN_CPU" >/dev/null || break
  k1=$("$A" shell "su -c 'wc -l < $LOG'" | tr -d '\r ')
  [ -n "$k0" ] && [ -n "$k1" ] && "$A" shell "su -c 'sed -n \"$((k0 + 1)),${k1}p\" $LOG'" | tr -d '\r' | grep 'window task .* frames:' | tail -3 | sed 's/^/fps /'
  k0=$k1
  if [ -z "$boosted" ] && [ $(( $(date +%s) - t0 )) -ge $(( SECS / 2 )) ]; then boosted=1; "$here/game-boost.sh" 20 2>&1 | sed 's/^/boost /' | tail -25; fi
done
hwc end | tee "$OUT/hwc-end.txt"; home | tee "$OUT/home-end.txt"
"$A" shell "logcat -d | grep GQ1 | tail -6" | tr -d '\r' | sed 's/^/gq1 /'
restore
echo "artefacts: $OUT (samples.txt, sf-start/end.txt); compare top/skin/caps/hwc/home with docs/research/broforce-fps.md Non-game load"
python3 "$here/bf-quiet-verdict.py" "$OUT/samples.txt" "$SECS" "$MIN_CPU"
