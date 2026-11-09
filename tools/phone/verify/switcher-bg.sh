#!/bin/bash
# lanes: phone
# switcher-bg.sh (board switcher-empty-state-list-background-running-app; shell ui/recents.tsx, host BackgroundApps.kt,
# gate switcher-background-*): Termux running in the background with no task - started here as its service alone when
# it isn't running (the user's own Termux session is never touched: running already, it's used as it is) - then the
# real switcher (the recents key): "No open apps" when no card shows, "N running in background" counting the host's
# apps.background(), opened: Termux's row with icon, name and Stop (dev/device-checks.js switcherBackgroundNow; Stop is
# never pressed). Home after; a Termux this script started is stopped again.
# Exit 0 PASS, 1 FAIL, 3 no free window, 5 SKIP.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
SHELL_CHECK_LIB=1 . "$here/shell-check.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/switcher-bg-$(date +%m%d-%H%M%S)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
. "$here/window-lock.sh"
window_lock switcher-bg.sh 120
STARTED=
restore() {
  "$T/adb.sh" shell "input keyevent KEYCODE_HOME" >/dev/null 2>&1
  [ -z "$STARTED" ] || "$T/adb.sh" shell "am force-stop com.termux" >/dev/null 2>&1
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
}
trap restore EXIT
sh_() { "$T/adb.sh" shell "$*" 2>/dev/null | tr -d '\r'; }
if [ -z "$(sh_ pidof com.termux)" ]; then
  STARTED=1
  sh_ "am start-foreground-service -n com.termux/.app.TermuxService" >/dev/null
  sleep 3
  [ -n "$(sh_ pidof com.termux)" ] || { echo "SKIP: Termux's service didn't start (is Termux installed?)"; exit 5; }
fi
[ "$(sh_ "dumpsys activity recents | grep -c 'realActivity=com.termux'")" = 0 ] || echo "switcher-bg: note - Termux has a task too (its card, not a background row)"
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5
sh_ "input keyevent KEYCODE_APP_SWITCH"; sleep 2
r=$(shell_check home device-checks.js switcherBackgroundNow Termux)
"$T/shot.sh" "$OUT/switcher.png" >/dev/null 2>&1 || true
echo "switcher-bg: $r (shot $OUT/switcher.png)"
case $r in
  '[]') echo "PASS switcher-bg: background Termux listed with its Stop; the empty state right"; exit 0 ;;
  '["SKIP:'*) echo "SKIP: $r"; exit 5 ;;
  *) echo "FAIL switcher-bg: $r"; exit 1 ;;
esac
