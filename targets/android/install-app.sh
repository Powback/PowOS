#!/bin/bash
# Installs the PowOS app on the phone (adb install -r), refusing an APK that would stop the phone booting: the phone
# enforces the privileged-permission allowlist (ro.control_privapp_permissions=enforce), and PowOS is a priv-app (the
# PowOS system module), so an installed APK that asks for a privileged permission the phone's *mounted* module
# allowlist doesn't list makes PackageManager throw at the next boot - stuck at the boot screen. The allowlist is
# targets/android/system-module/privapp-permissions.txt; a new entry only counts once the rebuilt module is installed
# and the phone has booted with it (the check reads the live /system/etc/permissions file, not the module source).
#
# Usage: targets/android/install-app.sh [apk] [--check]   (default: android-app-dev's output/powos.apk; --check: no install)
#        ANDROID_SERIAL picks the phone when several are connected. Needs adb and aapt (the android-builder image has both).
set -euo pipefail
cd "$(dirname "$0")"
apk="${1:-${APK:-$HOME/Projects/android-app-dev/output/powos.apk}}"
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
[ "${2:-}" = "--check" ] && exit 0
adb install -r "$apk"
