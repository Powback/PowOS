#!/bin/bash
# tools/phone/ship-guard.sh: the APK ship's safety net (run by ship-apk.sh around an install).
#   ship-guard.sh snapshot DIR   the known-good state, before the install: the installed APK file (pm path, pulled whole)
#                                -> DIR/prev.apk, the app's exact override set (files/shell + shell-commits.txt +
#                                shell-push.json) -> DIR/overrides.tar, the installed commit -> DIR/commit. Exit 1 = no
#                                snapshot (ship-apk then doesn't install).
#   ship-guard.sh check [S]      every page boots: window.__powosAlive on home (and home drawn: __powosHomeBlank), shade and assist (read-only CDP), polled
#                                for up to S (120) s after the install + re-push. Exit 1 = a page didn't (named).
#   ship-guard.sh restore DIR    the WHOLE snapshot back: the overrides cleared FIRST (the previous APK must not boot on
#                                the new overrides - the 00:59 race), the previous APK reinstalled (install -r -d: data
#                                kept), then its old overrides restored as they were, the installed-commit record back.
#   ship-guard.sh restore-overrides DIR   only the old overrides back (a ship that stopped before its install).
# Why (2026-10-23): APK 29878476 + its re-push left the phone's shell inconsistent (a desktopPages export missing) and
# home broke until someone noticed.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
A=$here/adb.sh PKG=com.powos.app F=/data/data/com.powos.app/files
case "${1:-}" in
snapshot)
  D=${2:?dir}; mkdir -p "$D"
  p=$("$A" shell pm path $PKG | tr -d '\r' | sed -n 's/^package://p' | head -1)
  [ -n "$p" ] || { echo "ship-guard: no installed $PKG (pm path)" >&2; exit 1; }
  "$A" exec-out "su -c 'cat $p'" > "$D/prev.apk" 2>/dev/null
  unzip -l "$D/prev.apk" >/dev/null 2>&1 || { echo "ship-guard: couldn't pull the installed APK ($p)" >&2; exit 1; }
  "$A" exec-out "su -c 'cd $F && tar -cf - shell shell-commits.txt shell-push.json 2>/dev/null'" > "$D/overrides.tar" 2>/dev/null
  tar -tf "$D/overrides.tar" >/dev/null 2>&1 || { echo "ship-guard: couldn't read the app's overrides" >&2; exit 1; }
  cp "$HOME/.cache/powos-installed-commit" "$D/commit" 2>/dev/null || : > "$D/commit"
  echo "ship-guard: snapshot $D ($(du -h "$D/prev.apk" | cut -f1) APK, $(tar -tf "$D/overrides.tar" | grep -c '^shell/.*[^/]$') overrides)" ;;
check)
  # Pages don't boot while the screen dozes (the WebViews are paused): two APKs of good builds were rolled back at
  # 09:22/09:5x with "not booted: home" on a Dozing phone (friction f25). Wake it for the check (installs only run on
  # an idle phone), and put it back to sleep afterwards if this woke it.
  woke=
  if ! "$here/adb.sh" shell 'dumpsys power' 2>/dev/null | grep -q 'mWakefulness=Awake'; then
    "$here/adb.sh" shell 'input keyevent KEYCODE_WAKEUP; sleep 1; wm dismiss-keyguard' >/dev/null 2>&1 && woke=1
    echo "ship-guard: woke the dozing screen for the boot check"
  fi
  [ -n "$woke" ] && trap '"$here/adb.sh" shell "input keyevent KEYCODE_SLEEP" >/dev/null 2>&1' EXIT
  end=$(( $(date +%s) + ${2:-120} ))
  while :; do
    bad=""
    for pg in "" shade assist; do
      # Home alive and drawn: __powosHomeBlank (shell/ui/homedrawn.ts) names a home laid out off the screen (10-31 02:50:
      # alive, no errors, only the wallpaper showing).
      js='window.__powosAlive === true'
      [ -z "$pg" ] && js='window.__powosAlive === true && !(window.__powosHomeBlank && window.__powosHomeBlank())'
      r=$(CDP_TIMEOUT_S=15 "$here/cdp.sh" eval "$pg" "$js" 2>/dev/null | tr -d '\r' | tail -1)
      [ "$r" = true ] || bad="$bad ${pg:-home}"
    done
    # Home's page only exists once Android starts home. After an install it does that only when home is needed: with
    # another app in front (the user in Chrome, a game, a web window's display holding focus) it doesn't, and two good
    # APKs were rolled back for it (10-30 15:48, 15:58: Calculator / Chrome on top). Then home isn't required; shade
    # and assist (same process) still are.
    if [ "$bad" = " home" ]; then
      top=$("$here/adb.sh" shell 'dumpsys activity activities' 2>/dev/null | grep -m1 'topResumedActivity' | grep -o 'u0 [^ ]*' | cut -d' ' -f2)
      case "$top" in
        com.powos.app/*|"") ;;
        *) echo "ship-guard: every page booted (shade assist); home not started by Android: $top is in front"; exit 0 ;;
      esac
    fi
    [ -z "$bad" ] && { echo "ship-guard: every page booted (home shade assist)"; exit 0; }
    [ "$(date +%s)" -ge "$end" ] && { echo "ship-guard: not booted within ${2:-120} s:$bad"; exit 1; }
    sleep "${GUARD_POLL_S:-10}"
  done ;;
restore|restore-overrides)
  D=${2:?dir}
  [ -s "$D/prev.apk" ] && [ -f "$D/overrides.tar" ] || { echo "ship-guard: no snapshot in $D" >&2; exit 1; }
  if [ "$1" = restore ]; then
    "$A" shell "su -c 'cd $F && mkdir -p shell && echo > shell/.pushing && find shell -mindepth 1 -maxdepth 1 ! -name .pushing -exec rm -rf {} + ; rm -rf shell-commits.txt shell-push.json shell-prev; rm -f shell/.pushing'" ||
      echo "ship-guard: clearing the overrides before the reinstall failed - reinstalling anyway" >&2
    "$A" install -r -d "$D/prev.apk" || { echo "ship-guard: reinstalling the previous APK failed" >&2; exit 1; }
    # The re-base copy (powos-idle-sysupdate.sh reinstalls it) must be the APK that's installed again.
    "$A" push "$D/prev.apk" /data/local/tmp/powos-current.apk >/dev/null && "$A" shell chmod 0644 /data/local/tmp/powos-current.apk
  fi
  "$A" push "$D/overrides.tar" /data/local/tmp/powos-ship-restore.tar >/dev/null || { echo "ship-guard: pushing the old overrides failed" >&2; exit 1; }
  # As one change, between files/shell/.pushing written and removed (the shell reloads once, on the whole set);
  # owned by the app again (root wrote them).
  "$A" shell "su -c 'cd $F && u=\$(ls -nd .. | awk \"{print \\\$3\\\":\\\"\\\$4}\") && mkdir -p shell && echo > shell/.pushing && find shell -mindepth 1 -maxdepth 1 ! -name .pushing -exec rm -rf {} + ; rm -rf shell-commits.txt shell-push.json shell-prev; tar -xf /data/local/tmp/powos-ship-restore.tar && chown -R \$u shell \$(ls shell-commits.txt shell-push.json 2>/dev/null); rc=\$?; rm -f shell/.pushing /data/local/tmp/powos-ship-restore.tar; exit \$rc'" ||
    { echo "ship-guard: restoring the old overrides failed" >&2; exit 1; }
  [ "$1" = restore-overrides ] && { echo "ship-guard: restored the $(tar -tf "$D/overrides.tar" | grep -c '^shell/.*[^/]$') overrides"; exit 0; }
  [ -s "$D/commit" ] && cp "$D/commit" "$HOME/.cache/powos-installed-commit"
  echo "ship-guard: restored the previous APK $(cut -c1-9 "$D/commit") and its $(tar -tf "$D/overrides.tar" | grep -c '^shell/.*[^/]$') overrides" ;;
*) sed -n 2,11p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
