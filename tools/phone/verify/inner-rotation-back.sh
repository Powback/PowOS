#!/bin/bash
# lanes: phone
# screen: inner
# needs: home
# inner-rotation-back.sh: the inner screen turns back to home's rotation after an app that turned it moves into a web
# window (board inner-screen-stays-landscape-after-an-app-moves; 11-11 21:45 the camera turned display 0 landscape,
# moved into its window, and the inner screen + home stayed landscape: home asks UNSPECIFIED and a flat phone's sensor
# proposes nothing, so WM kept the camera's rotation). Fix: shell/HomeRotation.kt (home's rotation at its pause asked
# back after WebWindows.moveTask takes a task off display 0).
# Unfolded home; the camera started full screen (am start STILL_IMAGE_CAMERA, as board-look-more rec-light) -> adopted
# into a web window -> display 0's rotation must equal the one before within 4 s. The camera never turned display 0
# (no PowosHomeRotation line, rotation unchanged throughout): not exercised (exit 3). Closes only the camera it started.
# Exit 0 PASS, 1 FAIL, 3 not now.
set -uo pipefail
NAME=inner-rotation-back; . "$(dirname "$0")/wwc-lib.sh"
rot() { sh_ "dumpsys window displays" | awk '/Display: mDisplayId=/{on=($0 ~ /mDisplayId=0 /)} on && !f && /^ *mRotation=[0-9]/{sub(/.*mRotation=/,""); r=$1+0; f=1} END{if (f) print r}'; }   # read to the end (no early exit: sigpipe under pipefail)
CAMTASK="" STARTED=0
wwc_extra() { if [ -n "$CAMTASK" ]; then sh_ "am stack remove $CAMTASK" >/dev/null; say "closed the camera's task $CAMTASK"
  elif [ "$STARTED" = 1 ]; then sh_ "am force-stop com.oplus.camera"; say "stopped the camera this check started"; fi
  CAMTASK="" STARTED=0; }
wwc_start
sh_ "pidof com.oplus.camera" | grep -q . && wwc_skip "the camera already runs (the user's)"
r0=$(rot); say "display 0 rotation before: $r0"
case $r0 in [0-3]) ;; *) wwc_skip "display 0's rotation unreadable ($r0)" ;; esac
MARK=$(sh_ "date +%m-%d\ %H:%M:%S.000")
STARTED=1; sh_ "am start -a android.media.action.STILL_IMAGE_CAMERA >/dev/null"
moved="" maxr=$r0
for _ in $(seq 1 30); do
  r=$(rot); [ "$r" != "$r0" ] && maxr=$r
  moved=$(sh_ "logcat -d -T \"$MARK\" -s PowosWebWindows:I" | grep -E "app.s task [0-9]+ moved onto display" | tail -1)
  [ -n "$moved" ] && break; sleep 0.5; done
[ -n "$moved" ] || { bad "the camera never moved into a web window (15 s)"; wwc_end; }
CAMTASK=$(sed -nE "s/.*task ([0-9]+) moved onto display.*/\1/p" <<<"$moved"); say "camera: $moved"
r=""; for _ in $(seq 1 16); do r=$(rot); [ "$r" = "$r0" ] && break; sleep 0.25; done
hr=$(sh_ "logcat -d -T \"$MARK\" -s PowosHomeRotation:I" | grep -v "^-" | tr -d "\r")
[ -n "$hr" ] && say "$hr"
if [ "$r" = "$r0" ] && [ -z "$hr" ] && [ "$maxr" = "$r0" ]; then
  say "NOT EXERCISED: the camera never turned display 0 (rotation $r0 throughout)"; wwc_clean; exit 3; fi
[ "$r" = "$r0" ] || bad "display 0 stays at rotation $r after the camera moved into its window (home's was $r0)"
wwc_end "display 0 back at rotation $r0 after the camera (which turned it to ${maxr}) moved into a web window"
