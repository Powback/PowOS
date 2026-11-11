#!/bin/bash
# lanes: emu phone
# switcher-empty.sh: the real switcher on a device with NO windowed tasks (board switcher-empty-state-list-background-
# running-app): zero `.task[data-task]` cards AND "No open apps" visible, then a background-only workload the check
# starts itself (the com.powos.verifybackground companion, a real foreground service with no task) listed under
# "N running in background" with its icon, name and a Stop (switcherEmptyNow in shell/dev/device-checks.js).
# Refuses first (SKIP, exit 5) on any device with a pre-existing user task (user-tasks.py: live or backgrounded, e.g.
# Termux on the phone) - it never closes, stops or removes anything it didn't start, so the empty state can only be
# proven where it already is: in practice the emulator lane (queue.sh add --dev emu). The companion: on the phone the
# coordinator installs it (units/phone-android/verify-background.json); on the emulator (POWOS_DEVICE=emu, a snapshot
# that resets every start) the check installs the canonical build ($VERIFY_BG_APK) itself and removes it again.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
ADB_SH=${ADB_SH:-$T/adb.sh}   # tier1 stubs it (test-switcher-empty-guard.py)
. "$here/window-lock.sh"
window_lock switcher-empty 120
pkg=com.powos.verifybackground
sh_() { "$ADB_SH" shell "$*" | tr -d '\r'; }
OUT=${OUT:-$HOME/.cache/powos-verify/switcher-empty-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
echo "switcher-empty evidence: $OUT"
# 1. The guard, before anything on the device changes: any user task -> SKIP, nothing touched.
sh_ 'dumpsys activity recents' > "$OUT/tasks-before.txt"
if ! users=$(python3 -I "$here/user-tasks.py" < "$OUT/tasks-before.txt"); then
  echo "SKIP: can't read the device's tasks (raw $OUT/tasks-before.txt) - refusing rather than guessing nobody's there"; exit 5
fi
if [ -n "$users" ]; then
  echo "SKIP: pre-existing user tasks - this check never closes apps to make an empty switcher: $(tr '\n' ';' <<<"$users" | sed 's/;$//')"; exit 5
fi
started_at=$(date +%s)
owned_pid= installed=0 nonce=
cleanup() {
  local current
  current=$(sh_ "run-as $pkg cat files/run" 2>/dev/null || true)
  # Only what this run started: our nonce AND the PID that acknowledged it (switcher-owned-bg.sh's rule).
  if [ -n "$owned_pid" ] && [[ "$current" == "$nonce $owned_pid "* ]] && [ "$(sh_ "pidof $pkg")" = "$owned_pid" ]; then
    sh_ "am force-stop $pkg" >/dev/null
  fi
  [ "$installed" = 1 ] && "$ADB_SH" uninstall "$pkg" >/dev/null 2>&1 || true
  [ "${LOCK_HELD:-0}" = 1 ] || rmdir "$HOME/.cache/powos-verify.lock" 2>/dev/null || true
}
trap cleanup EXIT
# 2. The companion: present (phone: the coordinator's install) or, on the emulator only, installed by this run.
if [ -z "$(sh_ "pm path $pkg")" ]; then
  apk=${VERIFY_BG_APK:-$HOME/Projects/android-app-dev/output/verification/powos-verify-background.apk}
  [ "${POWOS_DEVICE:-}" = emu ] || { echo 'SKIP: coordinator must install the registered background verification companion'; exit 5; }
  [ -f "$apk" ] || { echo "SKIP: no companion build at $apk (targets/android/build-verify-background.sh)"; exit 5; }
  "$ADB_SH" install -r "$apk" >/dev/null && installed=1 || { echo "SKIP: companion install failed ($apk)"; exit 5; }
fi
[ -z "$(sh_ "pidof $pkg")" ] || { echo 'SKIP: companion already running; not adopted'; exit 5; }
nonce=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
sh_ "am start -W -n $pkg/.StartActivity --es nonce $nonce" >/dev/null
for _ in $(seq 1 10); do
  current=$(sh_ "run-as $pkg cat files/run" 2>/dev/null || true)
  if [[ "$current" == "$nonce "* ]]; then read -r _ owned_pid _ _ <<<"$current"; break; fi
  sleep 1
done
[ -n "$owned_pid" ] || { echo 'FAIL: companion did not acknowledge owned nonce'; exit 1; }
[ $(( $(date +%s) - started_at )) -lt 45 ] || { echo 'SKIP: setup used too much of the 90 s fixture lease'; exit 5; }
# 3. The real switcher (the recents key), then the page's answer.
# From home (the recents key toggles: an open switcher would close); HOME closes nothing.
sh_ 'input keyevent KEYCODE_HOME'; sleep 1
# The recents key can land before home takes keys again (a lost press read as "no empty state", emulator 11-11): pressed
# again only while the host says the switcher is still closed - never a toggle back.
sw_open() { "$T/cdp.sh" eval home "importShim('./bridge.ts').then(async({powos})=>String(!!(await powos.recents.state())?.open))" 2>/dev/null | tail -1 | tr -d '"\r'; }
for _ in 1 2 3; do
  sh_ 'input keyevent KEYCODE_APP_SWITCH'
  for _ in 1 2 3 4 5 6; do sleep 0.5; [ "$(sw_open)" = true ] && break 2; done
done
sleep 1
SHELL_CHECK_LIB=1 . "$here/shell-check.sh"
r=$(shell_check home device-checks.js switcherEmptyNow 'PowOS Background Check')
echo "switcher-empty: $r"
case $r in '["SKIP:'*) echo "SKIP: the page says $r"; exit 5 ;; '[]') ;; *) echo "FAIL: $r"; exit 1 ;; esac
# The row's Stop itself is switcher-owned-bg.sh's proof (on the emulator the app's su can't run: Android's app seccomp
# filter refuses setuid(0), so BackgroundApps.stop fails there); this run ends its own companion (cleanup: nonce+PID).
[ "$(sh_ "pidof $pkg")" = "$owned_pid" ] || { echo 'FAIL: the owned workload ended before the switcher was read (lease?)'; exit 1; }
sh_ 'dumpsys activity recents' > "$OUT/tasks-after.txt"
python3 -I "$here/background-task-preservation.py" "$OUT/tasks-before.txt" "$OUT/tasks-after.txt" || { echo "FAIL: task identities changed ($OUT/tasks-{before,after}.txt)"; exit 1; }
sh_ 'input keyevent KEYCODE_HOME'
echo 'PASS: no tasks -> zero cards + "No open apps"; the owned background workload listed under "running in background" with Stop'
