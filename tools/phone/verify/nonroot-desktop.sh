#!/bin/bash
# lanes: phone
# nonroot-desktop.sh (board debug-no-root-phone-plasma-stuck-loading-galaxy; the user: "Plasma stuck loading" on a
# phone without root): on the UNROOTED razr fold (RAZR serial, default its Mac-adb mdns name adb-ZY22MQL54Q, as
# nonroot-ports.sh), open PowOS's desktop (andro.marchy.MainActivity) and require, within DESKTOP_WAIT_S (240):
#   - files/run/desktop-ready (the session launcher touches it once plasmashell runs, session/Hyprland) - read with
#     run-as (the APK is debuggable; no root anywhere),
#   - no restart loop: at most one "session: starting (try N)" and no "session: gave up" in the app's log since the open
#     (67dfaf0a9 + eef4679ab: SetupGate first start, retries end every guest, no loop under the phantom limit).
# "From cold" when the session wasn't up before the open (no guest process); a session that already ran is checked
# as is and the PASS says "warm" - this never force-stops PowOS (it can be the razr's home screen) to make it cold.
# The razr is a PRODUCTION phone the user carries, and the verify window is the OnePlus's: this check waits for the
# razr's OWN idle (screen on, unlocked, no user activity for RAZR_IDLE_S=120 s) and exits 3 (stays queued) when the
# razr is away (not on the Mac's adb), in use, locked or asleep. Afterwards it sends the razr home (HOME intent) if
# something else was in front - no app is closed, no input is injected.
set -u
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
PKG=com.powos.app
S=${RAZR:-$("$ADB" devices | awk '/^(adb-ZY22MQL54Q[^ \t]*|192\.168\.50\.203:[0-9]+)[ \t]+device$/{print $1; exit}')}
[ -n "$S" ] || { echo "the razr isn't on the Mac's adb (adb mdns services: no adb-ZY22MQL54Q) - stays queued"; exit 3; }
sh_() { perl -e 'alarm 30; exec @ARGV' "$ADB" -s "$S" shell "$@" | tr -d '\r'; }
[ "$(sh_ 'su -c id 2>/dev/null | grep -c uid=0')" = 1 ] && { echo "SKIP: $S is rooted - this check is for the unrooted path"; exit 5; }

# The razr's own idle: Awake, not on the lock screen, last user activity >= RAZR_IDLE_S ago.
pw=$(sh_ 'dumpsys power' 2>/dev/null)
grep -q 'mWakefulness=Awake' <<<"$pw" || { echo "razr screen not awake - stays queued"; exit 3; }
ago=$(sed -n 's/.*mLastUserActivityTime=.*(\([0-9][0-9]*\) ms ago).*/\1/p' <<<"$pw" | head -1)
[ -n "$ago" ] || { echo "razr idle unreadable (dumpsys power has no 'mLastUserActivityTime=... (N ms ago)') - stays queued"; exit 3; }
[ "$ago" -ge $(( ${RAZR_IDLE_S:-120} * 1000 )) ] || { echo "razr in use (last touch $((ago / 1000)) s ago) - stays queued"; exit 3; }
focus=$(sh_ 'dumpsys window' 2>/dev/null | awk '/mCurrentFocus=/{print; exit}')
case "$focus" in *NotificationShade*|*Keyguard*|*null*) echo "razr locked/shade in front ($focus) - stays queued"; exit 3 ;; esac
front=$(sh_ 'dumpsys activity activities' 2>/dev/null | awk '/ResumedActivity/{for (i = 1; i <= NF; i++) if ($i ~ /\//) { print $i; exit }}')

ver=$(sh_ "dumpsys package $PKG" | awk -F= '/versionName=/{print $2; exit}')
build=$(sh_ "run-as $PKG cat files/shell/shell-build.txt 2>/dev/null")
echo "nonroot-desktop: $S, PowOS $ver${build:+ (shell $build)}, in front: ${front:-?}"
uid=$(sh_ "pm list packages -U $PKG" | sed -n "s/^package:$PKG uid:\([0-9]*\).*/\1/p" | head -1)
# Guest processes = the app's uid running something other than the app's own Android processes.
guests() { sh_ "ps -A -o UID,NAME 2>/dev/null" | awk -v u="$uid" '$1 == u && $2 !~ /^com\.powos\.app/' | wc -l | tr -d ' '; }
was=$(guests); state=cold; [ "${was:-0}" -gt 0 ] && state=warm
t0=$(sh_ 'date +%s'); since=$(sh_ "date '+%m-%d %H:%M:%S.000'")
sh_ "am start -W -n $PKG/andro.marchy.MainActivity" | grep -E 'Status|Activity|Error' | tr '\n' ' '; echo
ready=; tries=0; gave=
for _ in $(seq $(( ${DESKTOP_WAIT_S:-240} / 5 ))); do
  m=$(sh_ "run-as $PKG stat -c %Y files/run/desktop-ready 2>/dev/null")
  log=$(sh_ "logcat -d -v brief -t '$since' -s Andromarchy:*" 2>/dev/null)
  tries=$(grep -c 'session: starting (try' <<<"$log"); grep -q 'session: gave up' <<<"$log" && gave=1
  [ -n "$gave" ] && break
  # warm: desktop-ready from the running session counts; cold: it must be (re)touched after the open.
  if [[ "$m" =~ ^[0-9]+$ ]] && { [ "$state" = warm ] || [ "$m" -ge "$t0" ]; }; then ready=$m; break; fi
  sleep 5
done
now=$(sh_ 'date +%s'); g=$(guests)
echo "nonroot-desktop: $state start, desktop-ready=${ready:-none} ($(( ${ready:-$now} - t0 )) s), session starts since open: $tries, guest processes: $g"
grep -E 'session: (starting|up|no D-Bus|gave up)|ended .* after try' <<<"$log" | tail -8
# Leave the razr as found: something else was in front -> home (nothing closed).
case "$front" in "$PKG/andro.marchy.MainActivity"|"") ;; *) sh_ 'am start -a android.intent.action.MAIN -c android.intent.category.HOME' >/dev/null ;; esac
[ -z "$gave" ] || { echo "FAIL: the session gave up ($tries starts) - Plasma never came up"; exit 1; }
[ -n "$ready" ] || { echo "FAIL: no files/run/desktop-ready ${DESKTOP_WAIT_S:-240} s after opening the desktop ($state; $tries session starts) - Plasma stuck loading"; exit 1; }
[ "$tries" -le 1 ] || { echo "FAIL: restart loop - $tries session starts before desktop-ready"; exit 1; }
echo "PASS: Plasma desktop drew unrooted ($state start, desktop-ready after $(( ready - t0 > 0 ? ready - t0 : 0 )) s, $tries session start(s), no loop)"
