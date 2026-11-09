#!/bin/bash
# lanes: phone
# dock-folded.sh (board folded-dock-shows-only-pinned-apps-open-apps-go; shell ui/home.tsx PD1, gate pd1-*): on the
# FOLDED phone, an app open that isn't pinned - the dock's pinned row is only the pinned apps and the open one leads
# its recents (dev/dock-search-check.js pd1Now, read in home's live page). With no unpinned app open it opens one
# itself through home's launch call (Calculator, else the first unpinned Android app), goes home, checks, and stops
# that app again after. Never touches the dock's pins or the layout.
# Exit 0 PASS, 1 FAIL, 3 not folded / no free window, 5 SKIP.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
SHELL_CHECK_LIB=1 . "$here/shell-check.sh"
OUT=${OUT:-$HOME/.cache/powos-verify/dock-folded-$(date +%m%d-%H%M%S)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
. "$here/window-lock.sh"
window_lock dock-folded.sh 120
LAUNCHED=
restore() {
  [ -z "$LAUNCHED" ] || "$T/adb.sh" shell "am force-stop $LAUNCHED" >/dev/null 2>&1
  "$T/adb.sh" shell "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null" >/dev/null 2>&1
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
}
trap restore EXIT
[ "$(phone_fold)" = folded ] || { echo "dock-folded: the phone is unfolded - this is the folded dock (queue it with --screen cover)"; exit 3; }
"$T/adb.sh" shell "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null" >/dev/null 2>&1; sleep 1.5
r=$(shell_check home dock-search-check.js pd1Now folded)
if [[ $r == '["SKIP: no unpinned app open"]' ]]; then
  key=$("$T/cdp.sh" eval home 'importShim("./state.ts").then(s=>{const k=[...s.byKey.value.keys()].filter(k=>k.startsWith("a:")&&!s.dock.value.includes(k));return k.find(k=>/calculator/i.test(k))||k[0]||""})' 2>&1 | tail -1 | tr -d '"')
  [ -n "$key" ] || { echo "SKIP: no unpinned Android app to open"; exit 5; }
  LAUNCHED=$(sed -E 's/^a:([^/]+).*/\1/' <<<"$key")
  echo "dock-folded: opening $key (not pinned)"
  "$T/cdp.sh" eval home "importShim('./bridge.ts').then(b=>b.powos.apps.launch('$key')).then(()=>'ok')" >/dev/null 2>&1
  sleep 3
  "$T/adb.sh" shell "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null" >/dev/null 2>&1; sleep 2
  r=$(shell_check home dock-search-check.js pd1Now folded "$key")
fi
"$T/shot.sh" "$OUT/dock.png" >/dev/null 2>&1 || true
echo "dock-folded: $r (shot $OUT/dock.png)"
case $r in
  '[]') echo "PASS dock-folded: pinned row only pinned apps, the open app leads the recents"; exit 0 ;;
  '["SKIP:'*) echo "SKIP: $r"; exit 5 ;;
  *) echo "FAIL dock-folded: $r"; exit 1 ;;
esac
