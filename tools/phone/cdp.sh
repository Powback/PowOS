#!/bin/bash
# CDP to the PowOS shell's WebView pages on the phone (tools/phone/cdp.ts): forwards the app's devtools socket to
# powos-vadb's port 9333 (again each call: the app's pid changes on every install/crash), then runs cdp.ts there.
#   tools/phone/cdp.sh pages | eval <page> '<js>' | idle [secs] [page]      (page: home, lock, shade, assist, ...)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# Never a silent exit: under set -e a failed adb call inside $(...) ended the script with no output, and a check read
# the empty answer as the page's ("Calculator's key from home's apps.list: ", 2026-10-23). Say what failed, exit 2.
pid=$("$here/adb.sh" shell pidof com.powos.app 2>&1 | tr -d '\r' | awk '{print $1}') || { echo "cdp: adb failed (pidof): $pid" >&2; exit 2; }
[[ "$pid" =~ ^[0-9]+$ ]] || { echo "com.powos.app isn't running${pid:+ ($pid)}" >&2; exit 1; }
# The emulator lane (POWOS_DEVICE=emu): its adb forwards to the Mac's own localhost, so cdp.ts runs here (node strips
# its types), on a port of its own.
if [ "${POWOS_DEVICE:-phone}" = emu ]; then
  "$here/adb.sh" forward tcp:9334 "localabstract:webview_devtools_remote_$pid" >/dev/null || { echo "cdp: adb forward failed" >&2; exit 2; }
  CDP_PORT=9334 exec node --no-warnings "$here/cdp.ts" "$@"
fi
"$here/adb.sh" forward tcp:9333 "localabstract:webview_devtools_remote_$pid" >/dev/null || { echo "cdp: adb forward failed" >&2; exit 2; }
exec docker run --rm -i -e CDP_TIMEOUT_S --network container:powos-vadb -v "$here:/t:ro" oven/bun:1 bun /t/cdp.ts "$@"
