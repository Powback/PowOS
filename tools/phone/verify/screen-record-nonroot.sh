#!/bin/bash
# lanes: phone
# screen-record-nonroot.sh (board screen-record-works-on-galaxy-and-razr): on the UNROOTED razr fold (RAZR serial, default
# its Mac-adb mdns name adb-ZY22MQL54Q, as nonroot-desktop.sh), the control center's screen-record path short of the
# user's consent (which only a tap can give):
#   - the installed APK has PowOS's own recorder (system/ScreenRecord.kt: ScreenRecordConsentActivity + its
#     mediaProjection|microphone service) and the phone has no OnePlus recorder app (so the tile takes this path),
#   - its start intent (the tile's own path; --es audio none skips the audio sheet) brings up Android's screen-capture
#     consent (SystemUI's MediaProjectionPermissionActivity) and logs "consent asked",
#   - sent home afterwards: the consent is left unanswered and no recording runs (no PowosScreenRec "recording" line).
# The razr is a PRODUCTION phone: waits for its own idle (screen on, unlocked, no touch for RAZR_IDLE_S=120 s), exits 3
# (stays queued) when away/in use/locked or when the APK predates the recorder. No input is injected; it ends with a
# HOME intent (nothing force-stopped).
set -u
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
PKG=com.powos.app
S=${RAZR:-$("$ADB" devices | awk '/^(adb-ZY22MQL54Q[^ \t]*|192\.168\.50\.203:[0-9]+)[ \t]+device$/{print $1; exit}')}
[ -n "$S" ] || { echo "the razr isn't on the Mac's adb (adb mdns services: no adb-ZY22MQL54Q) - stays queued"; exit 3; }
sh_() { perl -e 'alarm 30; exec @ARGV' "$ADB" -s "$S" shell "$@" | tr -d '\r'; }
[ "$(sh_ 'su -c id 2>/dev/null | grep -c uid=0')" = 1 ] && { echo "SKIP: $S is rooted - this check is for the unrooted path"; exit 5; }

pw=$(sh_ 'dumpsys power' 2>/dev/null)
grep -q 'mWakefulness=Awake' <<<"$pw" || { echo "razr screen not awake - stays queued"; exit 3; }
ago=$(sed -n 's/.*mLastUserActivityTime=.*(\([0-9][0-9]*\) ms ago).*/\1/p' <<<"$pw" | head -1)
[ -n "$ago" ] || { echo "razr idle unreadable - stays queued"; exit 3; }
[ "$ago" -ge $(( ${RAZR_IDLE_S:-120} * 1000 )) ] || { echo "razr in use (last touch $((ago / 1000)) s ago) - stays queued"; exit 3; }
focus=$(sh_ 'dumpsys window' 2>/dev/null | awk '/mCurrentFocus=/{print; exit}')
case "$focus" in *NotificationShade*|*Keyguard*|*null*) echo "razr locked/shade in front ($focus) - stays queued"; exit 3 ;; esac

pkg=$(sh_ "dumpsys package $PKG")
ver=$(awk -F= '/versionName=/{print $2; exit}' <<<"$pkg")
grep -q 'ScreenRecordConsentActivity' <<<"$pkg" || { echo "PowOS $ver on $S predates the recorder (no ScreenRecordConsentActivity) - stays queued until the ship"; exit 3; }
oplus=$(sh_ 'pm path com.oplus.screenrecorder 2>/dev/null')
echo "screen-record-nonroot: $S, PowOS $ver, OnePlus recorder app: ${oplus:-none}"
[ -z "$oplus" ] || { echo "FAIL: com.oplus.screenrecorder is installed - the tile would open it, not PowOS's recorder"; exit 1; }

since=$(sh_ "date '+%m-%d %H:%M:%S.000'")
sh_ "am start -W -a com.powos.app.action.SCREEN_RECORD -n $PKG/dev.omalauncher.system.ScreenRecordConsentActivity --es audio none" | grep -E 'Status|Error' | tr '\n' ' '; echo
consent=
for _ in $(seq 10); do
  sleep 1
  top=$(sh_ 'dumpsys activity activities' 2>/dev/null | awk '/ResumedActivity/{for (i = 1; i <= NF; i++) if ($i ~ /\//) { print $i; exit }}')
  case "$top" in *MediaProjectionPermissionActivity*|*mediaprojection*) consent=$top; break ;; esac
done
log=$(sh_ "logcat -d -v brief -t '$since' -s PowosScreenRec:*" 2>/dev/null)
sh_ 'am start -a android.intent.action.MAIN -c android.intent.category.HOME' >/dev/null
sleep 2
log2=$(sh_ "logcat -d -v brief -t '$since' -s PowosScreenRec:*" 2>/dev/null)
grep -E 'PowosScreenRec' <<<"$log2" | tail -6
grep -q 'consent asked' <<<"$log" || { echo "FAIL: no 'consent asked' from PowosScreenRec - the recorder's start didn't run"; exit 1; }
[ -n "$consent" ] || { echo "FAIL: Android's capture consent never came to the front (front: ${top:-?})"; exit 1; }
grep -q ' recording ' <<<"$log2" && { echo "FAIL: a recording started without consent"; exit 1; }
echo "PASS: unrooted screen record reaches Android's capture consent ($consent) from PowOS's recorder; left unanswered, nothing recorded"
