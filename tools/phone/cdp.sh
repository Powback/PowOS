#!/bin/bash
# CDP to the PowOS shell's WebView pages on the phone (tools/phone/cdp.ts): forwards the app's devtools socket to
# powos-vadb's port 9333 (again each call: the app's pid changes on every install/crash), then runs cdp.ts there.
#   tools/phone/cdp.sh pages | eval <page> '<js>' | idle [secs] [page]      (page: home, lock, shade, assist, ...)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# The device, explicit: one serial for the socket lookup, the forward and its port (adb.sh's own default chain), so a
# second phone on the same adb server (the razr) is never the one answering - exported for adb.sh.
serial=${PHONE_SERIAL:-${POWOS_PHONE_ADDR:-10.13.13.7:5555}}
export PHONE_SERIAL=$serial
# adb with a deadline (CDP_ADB_TIMEOUT_S, 30): a hung adb (VPN drop mid-call) otherwise held the check past its budget
# before cdp.ts's own timeout even started.
cadb() { perl -e 'alarm shift; exec @ARGV' "${CDP_ADB_TIMEOUT_S:-30}" "${CDP_ADB:-$here/adb.sh}" "$@"; }
# The devtools socket, resolved fresh on every call in ONE adb call (11-10: an app restart or APK install gives a new
# pid, so a socket name from before is a dead forward): com.powos.app's pid(s) and the webview devtools sockets that
# exist. The socket used is one that exists for a running pid; none listed (an unreadable /proc/net/unix) -> pidof's
# first pid, as before. Never a silent exit: under set -e a failed adb call inside $(...) ended the script with no
# output, and a check read the empty answer as the page's ("Calculator's key from home's apps.list: ", 2026-10-23).
# Say what failed, exit 2.
out=$(cadb shell 'echo "pid=$(pidof com.powos.app)"; grep -ao "@webview_devtools_remote_[0-9]*" /proc/net/unix 2>/dev/null | sort -u' 2>&1 | tr -d '\r') || { echo "cdp: adb failed (devtools lookup on $serial): $(tail -1 <<<"$out")" >&2; exit 2; }
pids=$(sed -n 's/^pid=//p' <<<"$out" | head -1)
socks=$(sed -n 's/^@webview_devtools_remote_\([0-9][0-9]*\)$/\1/p' <<<"$out")
pid=
for p in $pids; do [[ "$p" =~ ^[0-9]+$ ]] || continue; [ -n "$socks" ] || { pid=$p; break; }; grep -qx "$p" <<<"$socks" && { pid=$p; break; }; done
if [ -z "$pid" ]; then
  [[ "${pids%% *}" =~ ^[0-9]+$ ]] || { echo "com.powos.app isn't running on $serial${out:+ ($(head -c 200 <<<"$out" | tr '\n' ' '))}" >&2; exit 1; }
  echo "cdp: com.powos.app (pid $pids) on $serial has no devtools socket yet (sockets: $(tr '\n' ' ' <<<"$socks"))" >&2; exit 1
fi
sock=webview_devtools_remote_$pid
# The emulator lane (POWOS_DEVICE=emu): its adb forwards to the Mac's own localhost, so cdp.ts runs here (node strips
# its types), on a port of its own.
if [ "${POWOS_DEVICE:-phone}" = emu ]; then
  cadb forward tcp:9334 "localabstract:$sock" >/dev/null || { echo "cdp: adb forward failed" >&2; exit 2; }
  CDP_PORT=9334 exec node --no-warnings "$here/cdp.ts" "$@"
fi
# A second phone (PHONE_SERIAL, e.g. the unrooted razr fold) forwards on its own port: one adb server holds both
# forwards, and reusing 9333 would re-point the OnePlus's checks at the other phone mid-run.
port=9333
case "$serial" in 10.13.13.7:5555) ;; *) port=$((9340 + $(printf %s "$serial" | cksum | cut -d' ' -f1) % 50)) ;; esac
cadb forward tcp:$port "localabstract:$sock" >/dev/null || { echo "cdp: adb forward failed ($serial tcp:$port -> $sock)" >&2; exit 2; }
# The warm runner (tools/phone/cdp-warm.sh): `docker exec` into one long-lived bun container instead of a fresh
# container per call (7-10 s each at Mac load ~25, 2026-11-09). Rc 75 = it couldn't run: the per-call path below.
. "$here/cdp-warm.sh"
rc=0; cdp_warm_run "$port" "$@" || rc=$?
[ "$rc" = 75 ] || exit "$rc"
exec "${CDP_DOCKER:-docker}" run --rm -i -e CDP_TIMEOUT_S -e CDP_PORT=$port --network "container:${CDP_NETNS:-powos-vadb}" -v "$here:/t:ro" oven/bun:1 bun /t/cdp.ts "$@"
