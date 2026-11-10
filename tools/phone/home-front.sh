#!/bin/bash
# home-front.sh [--check] [--wait SECS]: home (com.powos.app/andro.marchy.HomeShell) is the top resumed activity and
# its page answers CDP as visible - the one helper every page-based check uses before it reads or drives home's page.
#   (no flag)   brings it there: PowOS's lock face (PowosLockActivity) or Android's keyguard over it is dismissed
#               (`wm dismiss-keyguard`: the swipe lock, no PIN), anything else in front (a leftover
#               PowosWindowActivity, PowTerm, an app) goes behind home (`am start` of the HOME intent, our package)
#   --check     only says where things are; never changes the phone
# Never wakes the screen (the queue's wl_wake does, window-lock.sh) and never injects input: `am start`/`wm` only.
# Why (11-10 window-bench triage): the queue woke the phone with PowOS's lock face still on top, so home's WebView was
# hidden - its page answered `document.hidden`, rAF stopped, timers throttled - and ww-clamp, switcher-launch,
# plasma-modes and ww-stop spent their budgets on page calls that never settled.
# Prints one line "home: front visible" / "home: <why not>". Exit 0 = in front and visible, 1 = not (--check only),
# 3 = not now (screen off, or still not in front after SECS, default 8) - queue.sh's "again next window".
# Overrides (tests): HOME_ADB (adb.sh), HOME_CDP (cdp.sh), HOME_POLL_S (poll step, 1).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ADB=${HOME_ADB:-$here/adb.sh}
CDP=${HOME_CDP:-$here/cdp.sh}
check=0 wait=8
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1 ;;
    --wait) wait=${2:?--wait SECS}; shift ;;
    *) sed -n 2,13p "$0" >&2; exit 2 ;;
  esac
  shift
done
# One adb call: wakefulness and the top resumed activity.
state() {
  "$ADB" shell 'dumpsys power | grep -m1 mWakefulness=; dumpsys activity activities | grep -m1 topResumedActivity' 2>/dev/null | tr -d '\r'
}
top_of() { sed -nE 's/.*topResumedActivity=ActivityRecord\{[^ ]+ [^ ]+ ([^ ]+).*/\1/p' <<<"$1" | head -1; }
vis() { CDP_TIMEOUT_S=15 "$CDP" eval home 'document.visibilityState' 2>/dev/null | tr -d '\r"' | tail -1; }

s=$(state)
case "$s" in *mWakefulness=Awake*) ;; "") echo "home: phone unreachable over adb"; exit 3 ;;
  *) echo "home: screen not on ($(sed -n 's/.*mWakefulness=//p' <<<"$s" | head -1)) - not waking it"; exit 3 ;; esac
top=$(top_of "$s")
if [ "$top" = com.powos.app/andro.marchy.HomeShell ]; then
  v=$(vis); [ "$v" = visible ] && { echo "home: front visible"; exit 0; }
  [ "$check" = 1 ] && { echo "home: front but its page is ${v:-not answering}"; exit 1; }
else
  [ "$check" = 1 ] && { echo "home: ${top:-nothing} is in front"; exit 1; }
fi
[ "$check" = 1 ] && exit 1
was=${top:-nothing}
# The lock face (or Android's keyguard) first: home started under it stays hidden.
"$ADB" shell "wm dismiss-keyguard; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME -p com.powos.app >/dev/null" >/dev/null 2>&1
t0=$SECONDS
while :; do
  top=$(top_of "$(state)") v=
  if [ "$top" = com.powos.app/andro.marchy.HomeShell ]; then
    v=$(vis); [ "$v" = visible ] && { echo "home: front visible (was ${was})"; exit 0; }
  fi
  [ $((SECONDS - t0)) -ge "$wait" ] && break
  sleep "${HOME_POLL_S:-1}"
done
echo "home: not in front after ${wait}s (top ${top:-unknown}, page ${v:-not read})"
exit 3
