#!/bin/bash
# On the phone: Chromium metrics in the live home page for 3 s at rest, then around a probe (default slow2s.js: a 2 s
# slow drawer drag and a close - synthetic touches IN the page, so only with the screen on, home visible and the user
# idle: one `tools/phone/idle.sh --wait 120 1800` first, never a polling loop, never waking the screen).
#   shell/dev/perf/device.sh [probe.js]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
phone=$(cd "$here/../../../tools/phone" && pwd)
probe=$(basename "${1:-slow2s.js}")
pid=$("$phone/adb.sh" shell pidof com.powos.app | tr -d '\r' | awk '{print $1}')
[ -n "$pid" ] || { echo "com.powos.app isn't running" >&2; exit 1; }
"$phone/adb.sh" forward tcp:9333 "localabstract:webview_devtools_remote_$pid" >/dev/null
exec docker run --rm -i --network container:powos-vadb -v "$here:/t:ro" oven/bun:1 bun /t/devperf.ts "/t/$probe"
