#!/bin/bash
# tools/phone/record/run.sh <tag>: the swipe-home check, recorded. Only after `tools/phone/idle.sh --wait 120 1800`
# returned (idle, screen on). Installs rec.js in home's page, runs swipe.sh on the phone, then pulls the page's log
# (<tag>.json), the recording, the screencaps and logcat to $OUT/<tag>/ (default ~/powos-rec: under $HOME, which is
# what Colima shares with the containers). Frame-step: ffmpeg -i hg.mp4 -vf scale=170:-1 -fps_mode passthrough k%02d.png
set -euo pipefail
T=${1:?tag}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=${OUT:-$HOME/powos-rec}
A=$ROOT/tools/phone/adb.sh
mkdir -p "$OUT/$T"
# The scripts mounted into the containers from under $HOME.
W=$OUT/.scripts; mkdir -p "$W"; cp "$HERE/cdp.ts" "$HERE/rec.js" "$HERE/swipe.sh" "$W/"
P=$($A shell pidof com.powos.app | tr -d '\r' | awk '{print $1}')
$A forward tcp:9333 "localabstract:webview_devtools_remote_$P" >/dev/null
cdp() { docker run --rm --network container:powos-vadb -v "$W:/t" oven/bun:1 bun /t/cdp.ts index.html "$1"; }
cdp "$(cat "$W/rec.js")"
$A push "$W/swipe.sh" /data/local/tmp/hg-swipe.sh >/dev/null
$A shell su -c "sh /data/local/tmp/hg-swipe.sh"
cdp 'JSON.stringify(window.__hg)' > "$OUT/$T/$T.json"
for f in hg.mp4 hg.log hg-ai.png hg-after1.png hg-after2.png; do $A pull "/data/local/tmp/$f" "$OUT/$T/" >/dev/null 2>&1 || true; done
$A shell su -c "rm -f /data/local/tmp/hg*"
ls "$OUT/$T"
