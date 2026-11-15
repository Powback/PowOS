#!/bin/bash
# lanes: phone
# Queue without --screen: this check owns unfolding AFTER its safety snapshot.
# Home setup is performed only AFTER the read-only camera ownership preflight.
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
POLICY="$T/verify/camera-ownership.py"
# Local transport AND remote dumps are bounded. Preserve stderr + status, not just
# grep's empty output (a failed probe is never evidence of absence).
probe() { local file=$1; shift
  perl -e 'alarm 12; exec @ARGV' "$A" shell "su -c '$*'" </dev/null >"$file" 2>"$file.err"
  local rc=$?; echo "$rc" >"$file.rc"; return "$rc"; }
camera_snapshot() { local dir=$1 key cmd failed=0
  mkdir -p "$dir"
  for key in tasks activities recents windows clients process; do
    case $key in
      tasks) cmd='timeout 5 am stack list' ;;
      activities) cmd='dumpsys -t 5 activity activities' ;;
      recents) cmd='dumpsys -t 5 activity recents' ;;
      windows) cmd='dumpsys -t 5 window windows' ;;
      clients) cmd='dumpsys -t 5 media.camera' ;;
      process) cmd='pidof com.oplus.camera; r=$?; if [ "$r" = 1 ]; then echo ABSENT; elif [ "$r" != 0 ]; then exit "$r"; fi' ;;
    esac
    probe "$dir/$key.txt" "$cmd" || failed=1
  done
  [ "$failed" = 0 ] || { say "camera snapshot probe failed; protected (evidence $dir)"; return 1; }
  local why
  why=$(python3 -I "$POLICY" guard "$dir" 2>&1) || { say "$why (evidence $dir)"; return 1; }
  say "$why (evidence $dir)"; }
wwc_extra() { local root
  if [ -n "$CAMTASK" ]; then
    if probe "$OUT/cleanup-tasks.txt" 'timeout 5 am stack list' &&
       root=$(python3 -I "$POLICY" cleanup "$OUT/prelaunch" "$OUT/cleanup-tasks.txt" "$CAMTASK" 2>"$OUT/cleanup-policy.txt"); then
      # stack remove takes a ROOT id: the policy proves this new root contains
      # exactly our identified task, never another app or a preexisting root.
      probe "$OUT/cleanup-remove.txt" "am stack remove $root" && say "removed owned camera task $CAMTASK (exclusive new root $root)"
    else say "camera cleanup withheld: identity/root unproven (evidence $OUT)"; fi
  elif [ "$STARTED" = 1 ]; then say "camera cleanup withheld: launch has no proven owned task (evidence $OUT)"; fi
  CAMTASK="" STARTED=0; }
# Before wwc_start can go home/fold; repeat immediately before launch to catch
# camera work appearing during setup. Cached PID alone remains a conservative skip.
camera_snapshot "$OUT/before-setup" || wwc_skip "camera ownership not safe before setup"
wwc_start
camera_snapshot "$OUT/prelaunch" || wwc_skip "camera ownership changed during setup"
r0=$(rot); say "display 0 rotation before: $r0"
case $r0 in [0-3]) ;; *) wwc_skip "display 0's rotation unreadable ($r0)" ;; esac
MARK=$(sh_ "date +%m-%d\ %H:%M:%S.000")
STARTED=1; probe "$OUT/launch.txt" 'am start -W -a android.media.action.STILL_IMAGE_CAMERA -p com.oplus.camera' || {
  bad "camera launch failed; no inferred ownership (evidence $OUT/launch.txt)"; wwc_end; }
tr -d '\r' <"$OUT/launch.txt" | grep -qE '^Status: ok$' &&
  grep -qE '^Activity: com[.]oplus[.]camera/' "$OUT/launch.txt" &&
  ! grep -qE 'Warning:|Error:' "$OUT/launch.txt" || {
    bad "camera launch not confirmed as new; cleanup withheld (evidence $OUT/launch.txt)"; wwc_end; }
moved="" maxr=$r0
for _ in $(seq 1 30); do
  r=$(rot); [ "$r" != "$r0" ] && maxr=$r
  if [ -z "$CAMTASK" ] && probe "$OUT/after-tasks.txt" 'timeout 5 am stack list'; then
    CAMTASK=$(python3 -I "$POLICY" owned "$OUT/prelaunch" "$OUT/after-tasks.txt" 2>"$OUT/ownership.txt") || CAMTASK=""
  fi
  # A generic last adoption log could belong to ANY app. Only our new camera
  # task's exact ID is evidence of the rotation transition under test.
  if [ -n "$CAMTASK" ]; then
    moved=$(sh_ "logcat -d -T \"$MARK\" -s PowosWebWindows:I" | grep -E "app.s task $CAMTASK moved onto display" | tail -1)
  fi
  [ -n "$moved" ] && break; sleep 0.5; done
[ -n "$moved" ] || { bad "the camera never moved into a web window (15 s)"; wwc_end; }
say "owned camera task $CAMTASK: $moved"
r=""; for _ in $(seq 1 16); do r=$(rot); [ "$r" = "$r0" ] && break; sleep 0.25; done
hr=$(sh_ "logcat -d -T \"$MARK\" -s PowosHomeRotation:I" | grep -v "^-" | tr -d "\r")
[ -n "$hr" ] && say "$hr"
if [ "$r" = "$r0" ] && [ -z "$hr" ] && [ "$maxr" = "$r0" ]; then
  say "NOT EXERCISED: the camera never turned display 0 (rotation $r0 throughout)"; wwc_clean; exit 3; fi
[ "$r" = "$r0" ] || bad "display 0 stays at rotation $r after the camera moved into its window (home's was $r0)"
wwc_end "display 0 back at rotation $r0 after the camera (which turned it to ${maxr}) moved into a web window"
