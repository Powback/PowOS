#!/bin/bash
# lanes: phone
# switcher-bg.sh (board switcher-empty-state-list-background-running-app; shell ui/recents.tsx, host BackgroundApps.kt,
# gate switcher-background-*): Termux running in the background with no task - started via its launcher activity when
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
# Start a real terminal session via the supported exported activity, not its private service.
# Only a fresh, single task created here is eligible for removal. Never alter an existing session/task.
# Parse each record independently: OxygenOS uses mActivityComponent in Task blocks and
# realActivity={...} in RecentTaskInfo blocks. Never carry a Task id into the second section.
termux_task_ids() {
  awk '
    /Task\{/ { id=""; t=$0; sub(/^.*Task\{/, "", t); if (match(t, /#[0-9]+/)) id=substr(t,RSTART+1,RLENGTH-1) }
    /RecentTaskInfo #[0-9]+:/ { id="" }
    /^[[:space:]]*id=[0-9]+ / { t=$0; sub(/^[[:space:]]*id=/,"",t); sub(/ .*/,"",t); id=t }
    /mActivityComponent=com\.termux\/|realActivity=\{?com\.termux\// { if (id != "" && !seen[id]++) print id }
  '
}
termux_tasks() { sh_ "dumpsys activity recents" | termux_task_ids; }

[ -z "$(termux_tasks)" ] || { echo "SKIP: existing Termux task left untouched; background check needs no task"; exit 5; }
if [ -z "$(sh_ pidof com.termux)" ]; then
  component=$(sh_ "cmd package resolve-activity --brief com.termux" | tail -1)
  case $component in com.termux/*) ;; *) echo "SKIP: no Termux launcher activity: $component"; exit 5 ;; esac
  [ -z "$(sh_ pidof com.termux)$(termux_tasks)" ] || { echo "SKIP: Termux started during setup; left untouched"; exit 5; }
  before=$(termux_tasks)
  [ -z "$before" ] || { echo "SKIP: Termux task appeared before launch; left untouched"; exit 5; }
  launch=$(sh_ "am start -W -n $component" 2>&1)
  echo "switcher-bg launch: $launch"
  # COLD plus an empty pre-launch task snapshot and one new id establish fixture ownership.
  # A reused/hot task may belong to the user: no cleanup authority in that case.
  grep -q '^LaunchState: COLD$' <<<"$launch" || { echo "SKIP: launch was not cold; leaving Termux untouched"; exit 5; }
  sleep 3
  [ -n "$(sh_ pidof com.termux)" ] || { echo "SKIP: Termux launcher did not start a process: $launch"; exit 5; }
  owned=$(termux_tasks)
  case $owned in ''|*[!0-9]*) STARTED=; echo "SKIP: cannot identify one owned Termux task; leaving it untouched"; exit 5 ;; esac
  STARTED=1
  "$T/cdp.sh" eval home "importShim('./bridge.ts').then(m=>m.powos.tasks.remove($owned))"
  sleep 2
  [ -z "$(termux_tasks)" ] || { echo "SKIP: owned Termux task did not close"; exit 5; }
  [ -n "$(sh_ pidof com.termux)" ] || { echo "SKIP: Termux did not retain a terminal service (first-run setup may be needed)"; exit 5; }
fi
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5
# The real switcher (the recents key). A single press could be lost (OnePlus folded 11-11, job 20261111-124838: home's
# page never showed the layer, the check then read an empty page as "no running in background"). Read the PAGE's layer
# (.recents.open), not only the host's flag: pressed again only while both say closed, never a toggle back. Host
# open + page closed = the recents key would toggle a layer nobody sees: reported as itself, not as missing rows.
sw_state() { "$T/cdp.sh" eval home "window.__gw.mod('./bridge.ts').then(async({powos})=>!!(await powos.recents.state())?.open+'/'+!!document.querySelector('.recents.open'))" 2>/dev/null | tail -1 | tr -d '"\r'; }
open_switcher() {
  local st= _p _w
  for _p in 1 2 3; do
    sh_ "input keyevent KEYCODE_APP_SWITCH"
    for _w in 1 2 3 4 5 6; do
      sleep 0.5; st=$(sw_state)
      case $st in */true) return 0 ;; esac
    done
    case $st in true/false) echo "the host has the switcher open but home's page shows no layer (the recents key is dead)"; return 1 ;; esac
  done
  echo "3 recents-key presses opened no switcher on home's page (host/page: ${st:-no answer})"; return 1
}
if ! why=$(open_switcher); then
  "$T/shot.sh" "$OUT/switcher.png" >/dev/null 2>&1 || true
  echo "FAIL switcher-bg: $why (shot $OUT/switcher.png)"; exit 1
fi
sleep 0.5
r=$(shell_check home device-checks.js switcherBackgroundNow Termux)
"$T/shot.sh" "$OUT/switcher.png" >/dev/null 2>&1 || true
echo "switcher-bg: $r (shot $OUT/switcher.png)"
case $r in
  '[]') echo "PASS switcher-bg: background Termux listed with its Stop; the empty state right"; exit 0 ;;
  '["SKIP:'*) echo "SKIP: $r"; exit 5 ;;
  *) echo "FAIL switcher-bg: $r"; exit 1 ;;
esac
