#!/bin/bash
# lanes: emu phone
# tools/phone/verify/edge-more.sh: the powos-shell checks edge.sh doesn't do (skill: powos-shell), in one idle
# window: (1) Back as an edge action (right edge straight in, in a Settings sub-page -> its parent), (2) landscape
# (user_rotation 1, auto-rotate off) + the Quick Tools swipe, (3) the left edge turned on -> Back. Everything it
# changes - the edge config (files/shell-data/edgeGestures.json) and the two rotation settings - is put back exactly as
# it was at the end, and at once if a real touch shows up mid-run (the touch watcher's lasttouch moves).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); A=$here/adb.sh
CFG=/data/data/com.powos.app/files/shell-data/edgeGestures.json
OUT=${OUT:-$HOME/powos-rec/edge-more-$(date +%H%M%S)}; mkdir -p "$OUT"
# A free window first, the verify lock only then (handbook 5a); the settings restore runs before the lock goes.
WL_TRAP='restore'
. "$(dirname "$0")/window-lock.sh"
window_lock edge-more.sh 120
sh_() { "$A" shell "$@" | tr -d '\r'; }
t0=$(sh_ cat /data/local/tmp/powos-lasttouch)
rot0=$(sh_ settings get system user_rotation); acc0=$(sh_ settings get system accelerometer_rotation)
had=$(sh_ "su -c 'test -f $CFG && echo yes'")
[ "$had" = yes ] && sh_ "su -c 'cp -p $CFG /data/local/tmp/edge-cfg.bak'"
owner=$(sh_ "su -c 'stat -c %u:%g /data/data/com.powos.app/files'")
restore() {
  sh_ settings put system user_rotation "$rot0"; sh_ settings put system accelerometer_rotation "$acc0"
  if [ "$had" = yes ]; then sh_ "su -c 'cp -p /data/local/tmp/edge-cfg.bak $CFG && rm /data/local/tmp/edge-cfg.bak'"; else sh_ "su -c 'rm -f $CFG'"; fi
  echo "restored: user_rotation=$(sh_ settings get system user_rotation) accelerometer_rotation=$(sh_ settings get system accelerometer_rotation) config=$(sh_ "su -c 'test -f $CFG && echo present || echo absent'")"
}
touched() { [ "$(sh_ cat /data/local/tmp/powos-lasttouch)" != "$t0" ] && { echo "ABORT: the user touched the phone"; exit 4; }; return 1; }
cfg() { sh_ "su -c 'echo '\''$1'\'' > $CFG && chown $owner $CFG'"; sleep 1; }
focus() { sh_ "dumpsys activity activities | grep -m1 topResumedActivity" | sed 's/.* \([^ ]*\/[^ ]*\) .*/\1/'; }
# The display's current (rotated) size.
size() { sh_ "dumpsys window displays | grep -m1 -o 'cur=[0-9]*x[0-9]*'" | sed 's/cur=\([0-9]*\)x\([0-9]*\)/\1 \2/'; }
subpage() { sh_ am start -W -n com.android.settings/.Settings >/dev/null; sleep 1.5; sh_ am start -W -a android.settings.DISPLAY_SETTINGS >/dev/null; sleep 1.5; }
edgeback() { # <right|left>: a straight swipe in from that edge's lower half
  read W H <<<"$(size)"
  if [ "$1" = right ]; then sh_ input swipe $((W-3)) $((H*75/100)) $((W*60/100)) $((H*76/100)) 200; else sh_ input swipe 3 $((H*75/100)) $((W*40/100)) $((H*76/100)) 200; fi
}
ok=0; bad=0; res() { if [ "$1" = pass ]; then ok=$((ok+1)); else bad=$((bad+1)); fi; echo "$2: $1 - $3" | tee -a "$OUT/result.txt"; }
# (1) Back on the right edge (the default: right, straight in = back).
cfg '{"right":{"on":true,"actions":{"short.straight":"back"}}}'
subpage; touched; a=$(focus); sh_ logcat -c; edgeback right; sleep 1.5; b=$(focus); touched
sh_ "logcat -d -v time | grep -E PowosEdge" > "$OUT/back-right.log"
[ "$a" != "$b" ] && grep -q "short.straight -> back" "$OUT/back-right.log" && res pass "back (right)" "$a -> $b" || res fail "back (right)" "$a -> $b, $(tail -1 "$OUT/back-right.log")"
# (3) The left edge on: straight in = back.
cfg '{"left":{"on":true}}'
subpage; touched; a=$(focus); sh_ logcat -c; edgeback left; sleep 1.5; b=$(focus); touched
sh_ "logcat -d -v time | grep -E PowosEdge" > "$OUT/back-left.log"
[ "$a" != "$b" ] && grep -q "short.straight -> back" "$OUT/back-left.log" && res pass "back (left)" "$a -> $b" || res fail "back (left)" "$a -> $b, $(tail -1 "$OUT/back-left.log")"
sh_ "su -c 'rm -f $CFG'"; [ "$had" = yes ] && sh_ "su -c 'cp -p /data/local/tmp/edge-cfg.bak $CFG'"; sleep 1
# (2) Landscape: the Quick Tools swipe (right edge in and up, ~42 degrees: a flatter one is straight in = Back) and the
# handle laid out for it.
sh_ input keyevent KEYCODE_HOME; sleep 1
sh_ settings put system accelerometer_rotation 0; sh_ settings put system user_rotation 1; sleep 2.5; touched
read W H <<<"$(size)"
sh_ logcat -c
sh_ "input motionevent DOWN $((W-3)) $((H*75/100)); for i in 1 2 3 4 5 6 7 8 9 10; do input motionevent MOVE \$(($((W-3)) - i*$((W*2/100)))) \$(($((H*75/100)) - i*$((W*2/100*9/10)))); done; input motionevent UP $((W*80/100)) $((H*55/100))"
sleep 1.2; vis=$(sh_ "dumpsys window windows | grep -E 'Window #.*PowOS quick tools' -A20 | grep -m1 -o 'mViewVisibility=0x[0-9]'")
sh_ "screencap -p /data/local/tmp/edge-land.png" ; "$A" pull /data/local/tmp/edge-land.png "$OUT/" >/dev/null 2>&1; sh_ rm -f /data/local/tmp/edge-land.png
sh_ "logcat -d -v time | grep -E PowosEdge" > "$OUT/landscape.log"; touched
sh_ input tap $((W/5)) $((H/5)); sleep 1
[ "$vis" = mViewVisibility=0x0 ] && res pass "landscape quick tools" "${W}x${H}, $vis, $(tail -1 "$OUT/landscape.log")" || res fail "landscape quick tools" "${W}x${H}, $vis, $(tail -1 "$OUT/landscape.log")"
echo "passed $ok, failed $bad; out: $OUT"
