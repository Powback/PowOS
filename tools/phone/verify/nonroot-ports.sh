#!/bin/bash
# lanes: phone
# nonroot-ports.sh (board no-root-spacetimedb-app-api-ports-reachable-by-a; the user: "No root: SpacetimeDB/App API
# ports reachable by any app"): on the UNROOTED phone (the razr fold, reached by the Mac's own adb: RAZR serial, default
# the mdns name adb-ZY22MQL54Q), read only, from adb's shell uid = "any other app":
#   1. nothing listens on TCP 3410/3411 (SpacetimeDB, App API) or 5037 (the image's adb server: any app reaching it
#      gets a shell with PowOS's access - 11-09, board-close-waiting) - connects are refused, adb's host:version unanswered
#   2. EVERY other TCP listener of PowOS's uid (LoopbackGate, anything the image's programs open) proves it needs a
#      token: a token-less GET must get an HTTP 4xx (the gate's 403, a 401/404); a 2xx/3xx/5xx, a non-HTTP answer
#      (a raw protocol speaks to anyone) or silence is a FAIL - and no adb protocol (OKAY) on any port. 3416 is the
#      device agent (docs/DEVICES.md: TLS, a per-device token from pairing, whose code is shown on the phone): it must
#      not answer plain HTTP. The image's fixed loopback ports are private sockets since SessionService.LOOPBACK_PORTS
#      has "loopback", so a listener here is the gate, the device agent, a port-0 or LAN bind - each with its own auth.
#   3. the services are up behind private sockets: files/run/loopback holds 0600 sockets owned by the app (islands can
#      connect) - empty = SpacetimeDB/App API aren't running, which this check can't call a pass.
# Not for the verify queue (that is the rooted OnePlus); run it from the Mac. FAIL on 1/2, FAIL on 3 unless SKIP_UP=1.
set -u
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
S=${RAZR:-$("$ADB" devices | awk '/adb-ZY22MQL54Q.*device$/{print $1; exit}')}
[ -n "$S" ] || { echo "SKIP: ENV: the razr isn't on the Mac's adb (adb mdns services)"; exit 5; }
sh_() { perl -e 'alarm 30; exec @ARGV' "$ADB" -s "$S" shell "$@" | tr -d '\r'; }
[ "$(sh_ 'su -c id 2>/dev/null | grep -c uid=0')" = 1 ] && { echo "SKIP: $S is rooted - this check is for the unrooted path"; exit 5; }
uid=$(sh_ 'stat -c %u /proc/$(pidof com.powos.app | cut -d" " -f1) 2>/dev/null')
[[ "$uid" =~ ^[0-9]+$ ]] || { echo "SKIP: ENV: PowOS isn't running on $S"; exit 5; }
lis=$(sh_ 'cat /proc/net/tcp /proc/net/tcp6' | awk -v u="$uid" '$4=="0A" && $8==u {split($2,a,":"); print strtonum("0x" a[2])}' 2>/dev/null)
[ -n "$lis" ] || lis=$(sh_ 'cat /proc/net/tcp /proc/net/tcp6' | awk -v u="$uid" '$4=="0A" && $8==u {split($2,a,":"); print a[2]}' | while read -r h; do echo $((16#$h)); done)
echo "nonroot-ports: $S, PowOS uid $uid listens on TCP: $(tr '\n' ' ' <<<"$lis")"
f=
for p in 3410 3411 5037; do
  grep -qx "$p" <<<"$lis" && f="$f TCP $p listens;"
  r=$(sh_ "printf 'GET / HTTP/1.0\r\n\r\n' | toybox nc -w 2 127.0.0.1 $p 2>&1 | head -1")
  echo "  127.0.0.1:$p from the shell uid: ${r:-no answer}"; grep -q '^HTTP' <<<"$r" && f="$f $p answered another uid ($r);"
done
# adb's smart-socket request (4 hex digits of length + "host:version"): a server answers OKAY.
for p in $(printf '5037\n%s\n' "$lis" | sort -un); do
  r=$(sh_ "printf '000chost:version' | toybox nc -w 2 127.0.0.1 $p 2>&1 | head -c 4")
  [ "$r" = OKAY ] && f="$f :$p is an adb server another uid can drive;"
done
for p in $lis; do case $p in 3410|3411|5037) continue;; esac
  r=$(sh_ "printf 'GET / HTTP/1.0\r\n\r\n' | toybox nc -w 2 127.0.0.1 $p 2>/dev/null | head -1 | tr -c '[:print:]' '?' | head -c 60")
  echo "  127.0.0.1:$p without a token: ${r:-no answer}"
  if [ "$p" = 3416 ]; then grep -q '^HTTP' <<<"$r" && f="$f :3416 (device agent) answers plain HTTP, not TLS;"
  elif grep -qE '^HTTP/1\.[01] 2' <<<"$r"; then f="$f :$p served another uid without a token;"
  elif ! grep -qE '^HTTP/1\.[01] 4[0-9][0-9]' <<<"$r"; then f="$f :$p is a token-less listener (no 4xx without a token: ${r:-silent});"
  fi
done
socks=$(sh_ 'run-as com.powos.app ls -ln files/run/loopback 2>&1' | grep '^s')
echo "  files/run/loopback: $(grep -c . <<<"$socks") sockets $(awk '{print $1,$NF}' <<<"$socks" | tr '\n' ' ')"
grep -vq '^srw-------' <<<"$socks" && [ -n "$socks" ] && f="$f a loopback socket isn't 0600;"
[ -n "$f" ] && { echo "FAIL:$f"; exit 1; }
[ -n "$socks" ] || { [ "${SKIP_UP:-0}" = 1 ] && { echo "SKIP: ports closed, but SpacetimeDB/App API aren't up (no loopback sockets)"; exit 5; }
  echo "FAIL: ports 3410/3411 closed to other apps, but SpacetimeDB/App API aren't running (files/run/loopback empty) - islands can't connect"; exit 1; }
echo "PASS: unrooted - 3410/3411/5037 refused to other uids, no adb server reachable, every other listener answers 4xx without a token, the services on $(grep -c . <<<"$socks") private 0600 sockets"
