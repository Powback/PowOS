# shellcheck shell=bash
# tools/phone/verify/dream.sh - start / check / stop PowOS's screensaver (PowosDozeService) for the phone checks that
# show its page (standby.sh, aod.sh). Source after base.sh; needs $A (tools/phone/adb.sh).
#   dream_start <comp>   pick <comp> as the screensaver (screensaver_components + _enabled; the caller saves and puts
#                        back those two) and start it; rc 0 once dumpsys dreams shows it, else rc 1 and DREAM_WHY says
#                        what each way answered. dream_restore puts back what dream_start itself changed.
#   dream_on             rc 0 while PowOS's dream is the current dream (dumpsys dreams' mCurrentDream).
#   dream_stop           end it (root, else a back key - a dream ends on any key).
# WHY (11-28, standby.sh + aod.sh "the dream didn't start", mCurrentDream=null): the checks ran
# `ash cmd dreams start-dream || am start Somnambulator`. The verb is `start-dreaming` (DreamShellCommand:
# start-dreaming / stop-dreaming), the shell command is ROOT-only (it refuses the adb shell uid), and `ash` is a
# pipe into tr, so its status was always 0 and the Somnambulator fallback never ran. Now each way is tried in turn and checked on its own:
#   1. root `cmd dreams start-dreaming` (DreamManagerService.requestStartDreamFromShell -> PowerManager nap);
#   2. SystemUI's Somnambulator (exported; Sandman.startDreamByUserRequest -> IDreamManager.dream), no root;
#   3. the user's own path, no root: "start when charging" (screensaver_activate_on_sleep 1) and a 10 s screen
#      timeout, the screen woken (KEYCODE_WAKEUP) and left alone until PowerManager naps into the dream.
_dsh() { "$A" shell "$@" 2>/dev/null | tr -d '\r'; }
DREAM_WHY=""; _d_sleep=""; _d_to=""; _d_saved=0
dream_line() { _dsh dumpsys dreams | grep -m1 'mCurrentDream='; }
dream_on() { dream_line | grep -q 'PowosDozeService'; }
_dream_wait() { local _; for _ in $(seq 1 "$1"); do dream_on && return 0; sleep 1; done; return 1; }
dream_start() {
  local comp=$1 out
  _dsh settings put secure screensaver_components "$comp" >/dev/null
  _dsh settings put secure screensaver_enabled 1 >/dev/null
  _dsh input keyevent KEYCODE_WAKEUP >/dev/null
  sleep 1
  out=$(_dsh "su -c 'cmd dreams start-dreaming'" | head -2 | tr '\n' ' ')
  _dream_wait 6 && { echo "dream started: root cmd dreams start-dreaming"; return 0; }
  DREAM_WHY="cmd dreams start-dreaming (root): ${out:-no output};"
  out=$(_dsh am start -W -n com.android.systemui/.Somnambulator | grep -iE 'error|warning|status' | head -2 | tr '\n' ' ')
  _dream_wait 6 && { echo "dream started: SystemUI Somnambulator"; return 0; }
  DREAM_WHY="$DREAM_WHY Somnambulator: ${out:-no output};"
  _d_sleep=$(_dsh settings get secure screensaver_activate_on_sleep)
  _d_to=$(_dsh settings get system screen_off_timeout)
  _d_saved=1
  _dsh settings put secure screensaver_activate_on_sleep 1 >/dev/null
  _dsh settings put system screen_off_timeout 10000 >/dev/null
  _dsh input keyevent KEYCODE_WAKEUP >/dev/null
  _dream_wait 25 && { echo "dream started: screen timeout while charging"; return 0; }
  DREAM_WHY="$DREAM_WHY screen timeout: no dream in 25 s; $(dream_line)"
  return 1
}
_dput() { if [ -z "$3" ] || [ "$3" = null ]; then _dsh settings delete "$1" "$2" >/dev/null; else _dsh settings put "$1" "$2" "$3" >/dev/null; fi; }
dream_restore() {
  [ "$_d_saved" = 1 ] || return 0
  _dput secure screensaver_activate_on_sleep "$_d_sleep"
  _dput system screen_off_timeout "$_d_to"
  _d_saved=0
}
dream_stop() {
  dream_on || return 0
  _dsh "su -c 'cmd dreams stop-dreaming'" >/dev/null
  sleep 1
  dream_on && _dsh input keyevent KEYCODE_BACK >/dev/null
  return 0
}
