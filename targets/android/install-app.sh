#!/bin/bash
# Installs the PowOS app on the phone (adb install -r), refusing an APK that would stop the phone booting: the phone
# enforces the privileged-permission allowlist (ro.control_privapp_permissions=enforce), and PowOS is a priv-app (the
# PowOS system module), so an installed APK that asks for a privileged permission the phone's *mounted* module
# allowlist doesn't list makes PackageManager throw at the next boot - stuck at the boot screen. The allowlist is
# targets/android/system-module/privapp-permissions.txt; a new entry only counts once the rebuilt module is installed
# and the phone has booted with it (the check reads the live /system/etc/permissions file, not the module source).
#
# Usage: targets/android/install-app.sh [apk] --note "what changed, for the user" [--check]
#        (default apk: android-app-dev's output/powos.apk; --check: no install, no note needed). The note becomes the
#        phone's quiet "update applied" notification (tools/deploy-note.sh): plain words, never a commit hash.
#        ANDROID_SERIAL picks the phone when several are connected. Needs adb and aapt (the android-builder image has both).
set -euo pipefail
cd "$(dirname "$0")"
note="" check="" pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --note) note=${2:-}; shift 2 || shift ;;
    --note=*) note=${1#--note=}; shift ;;
    --check) check=1; shift ;;
    *) pos+=("$1"); shift ;;
  esac
done
[ -n "$check" ] || [ -n "${note// }" ] ||
  { echo "install-app.sh: --note \"what changed, for the user\" is required (the phone's update notification)" >&2; exit 2; }
apk="${pos[0]:-${APK:-$HOME/Projects/android-app-dev/output/powos.apk}}"
[ -f "$apk" ] || { echo "install-app.sh: no apk at $apk" >&2; exit 1; }
aapt="$(command -v aapt || ls /opt/android-sdk/build-tools/*/aapt 2>/dev/null | tail -1 || true)"
[ -n "$aapt" ] || { echo "install-app.sh: aapt not found (run in the android-builder image)" >&2; exit 1; }

requested=$("$aapt" dump permissions "$apk" | sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p" | sort -u)
privileged=$(grep -v '^\s*#' system-module/privileged-perms.txt | sed 's/\s.*//' | grep . | sort -u)
need=$(comm -12 <(echo "$requested") <(echo "$privileged"))

# What the phone allows now: PowOS's privapp file as mounted (the module's, once booted with it) - and Android's own.
allowed=$(adb shell "cat /system/etc/permissions/privapp-permissions-com.powos.app.xml 2>/dev/null" |
  sed -n 's/.*<permission name="\([^"]*\)".*/\1/p' | sort -u)
enforce=$(adb shell getprop ro.control_privapp_permissions | tr -d '\r')

missing=$(comm -23 <(echo "$need") <(echo "$allowed") | grep . || true)
if [ -n "$missing" ] && [ "$enforce" = "enforce" ]; then
  echo "install-app.sh: REFUSED - $apk asks for privileged permissions the phone's mounted PowOS module doesn't allowlist:" >&2
  echo "$missing" | sed 's/^/  /' >&2
  echo "The phone enforces the allowlist: installing this would stop it at the boot screen on the next reboot." >&2
  echo "Install the rebuilt system module (privapp-permissions.txt) and reboot first, or drop the uses-permission." >&2
  exit 2
fi
echo "install-app.sh: privileged permissions OK (${need:+$(echo $need | wc -w) asked, all allowlisted})"
[ -n "$check" ] && exit 0
# The app's data first (rooted/powos-appdata.sh: /data/powos/backup/app-data-<time>-install.tar). `install -r` keeps
# the data, but an install that goes wrong (or one followed by a re-base) must never be the moment it's all lost.
# No downgrade here (no -d); going back to the system copy is `powos-appdata.sh rebase` on the phone, never a bare
# `pm uninstall-system-updates` (it wipes the data: docs/APP-DATA-BACKUP.md).
# Checked as root: /data/powos isn't readable by adb's shell user, so a plain test never saw the script (every install
# then skipped the backup with a warning).
if adb shell "su -c '[ -f /data/powos/powos-appdata.sh ]'"; then
  adb shell "su -c 'sh /data/powos/powos-appdata.sh backup install'" ||
    { echo "install-app.sh: REFUSED - backing up the app's data failed (/data/powos/appdata.log on the phone)" >&2; exit 2; }
else
  echo "install-app.sh: warning - no /data/powos/powos-appdata.sh on the phone (rooted.sh deploy): no app-data backup" >&2
fi
# Compiled ahead of time as it installs (`speed`), not left to the interpreter: the APK carries no profile, so
# Android's install filter (speed-profile) compiles nothing ("verify") and the app ran interpreted, warming its JIT,
# after each of the many installs a day - measured 2026-10-21 on an idle home: the app's main thread ~4.7% of a core,
# mostly the interpreter. Only for this install: the property is put back right after (every other app keeps it).
# HACK: a system property flipped around our own install. Real fix: a baseline profile in the APK
# (src/main/baseline-prof.txt + a .dm next to the APK at install), so speed-profile compiles what matters.
was=$(adb shell getprop pm.dexopt.install | tr -d '\r')
adb shell "su -c 'setprop pm.dexopt.install speed'" >/dev/null 2>&1 || true
adb install -r "$apk"; rc=$?
adb shell "su -c 'setprop pm.dexopt.install ${was:-speed-profile}'" >/dev/null 2>&1 || true
[ $rc -eq 0 ] || exit $rc
# A one-shot re-base of the app (pm uninstall-system-updates + reinstall, e.g. powos-idle-sysupdate.sh) reinstalls
# /data/local/tmp/powos-current.apk: keep it the APK just installed, or it would put an older build back.
adb push "$apk" /data/local/tmp/powos-current.apk >/dev/null && adb shell chmod 0644 /data/local/tmp/powos-current.apk
ADB=adb tools/deploy-note.sh "$note"
