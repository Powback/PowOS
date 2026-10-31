#!/bin/bash
# App API health check (AA1). Read-only. Prints each piece green/red and exits non-zero if the
# runtime (the part that must always be up) is down. Run inside PowOS (chroot) as the powos user,
# or from the status view / a boot unit. No sending, no capture, no secrets printed.
#
#   tools/phone/root.sh tools/app-api/health-check.sh      # from the Mac, read-only
#   /usr/lib/powos/app-api/health-check.sh                 # on-device (deployed copy)
set -u
API="http://127.0.0.1:3411"
ok=0; bad=0
green() { printf '  [ok]   %s\n' "$1"; ok=$((ok+1)); }
red()   { printf '  [DOWN] %s\n' "$1"; bad=$((bad+1)); }
note()  { printf '  [ --]  %s\n' "$1"; }

echo "App API health:"

# 1. Runtime service (must be up). appcap_serve on loopback 3411.
if command -v curl >/dev/null 2>&1 && curl -s --max-time 4 "$API/apps" >/tmp/.aa_apps 2>/dev/null; then
  n=$(tr ',' '\n' </tmp/.aa_apps | grep -c '"app":')
  green "runtime service (127.0.0.1:3411) answering, $n app spec(s)"
else
  red "runtime service (127.0.0.1:3411) not answering - restart service app-api"
fi
rm -f /tmp/.aa_apps

# 2. Spec store + token store dir (persistent; where enablement + encrypted sessions live).
[ -d /usr/lib/powos/app-api ] && green "runtime files present" || red "runtime files missing - redeploy unit app-api"
[ -d "${HOME:-/home/powos}/.local/state/powos/app-api" ] && green "state dir (specs + token store) present" \
  || note "state dir not yet created (no app linked yet)"

# 3. Notification read path (ban-safe source for needs-me): launcher holds notification access.
L=$(settings get secure enabled_notification_listeners 2>/dev/null || cat /sys/..//dev/null 2>/dev/null)
case "$L" in
  *com.powos.app*MediaListener*) green "notification listener granted (read path for needs-me)";;
  *) note "notification access not readable from here (check on-device: Settings > Notification access)";;
esac

# 4. Capture-path units (on-demand, OPTIONAL; missing is the default resting state, not a failure).
#    These are only needed for in-app hook capture of an app the user explicitly enabled.
[ -e /data/local/tmp/frida-server ] && green "on-demand frida-server present (unit app-frida)" \
  || note "on-demand frida-server not installed (unit app-frida) - needed only for in-app capture"
[ -d /data/adb/modules/powos-appca ] && green "local CA module present (unit app-ca)" \
  || note "local CA module not installed (unit app-ca) - needed only for HTTPS capture of enabled apps"

echo "App API: $ok ok, $bad down."
# Only the runtime being down is a failure the board/notification should fire on.
[ "$bad" -eq 0 ]
