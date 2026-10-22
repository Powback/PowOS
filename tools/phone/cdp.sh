#!/bin/bash
# CDP to the PowOS shell's WebView pages on the phone (tools/phone/cdp.ts): forwards the app's devtools socket to
# powos-vadb's port 9333 (again each call: the app's pid changes on every install/crash), then runs cdp.ts there.
#   tools/phone/cdp.sh pages | eval <page> '<js>' | idle [secs] [page]      (page: home, lock, shade, assist, ...)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pid=$("$here/adb.sh" shell pidof com.powos.app | tr -d '\r' | awk '{print $1}')
[ -n "$pid" ] || { echo "com.powos.app isn't running" >&2; exit 1; }
"$here/adb.sh" forward tcp:9333 "localabstract:webview_devtools_remote_$pid" >/dev/null
exec docker run --rm -i -e CDP_TIMEOUT_S --network container:powos-vadb -v "$here:/t:ro" oven/bun:1 bun /t/cdp.ts "$@"
