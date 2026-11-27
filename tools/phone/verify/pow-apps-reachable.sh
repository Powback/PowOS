#!/bin/bash
# lanes: phone
# needs: ship:apk
# tools/phone/verify/pow-apps-reachable.sh: the auto .pow apps are never greyed out as offline while the .pow network
# works (the user 11-27: "Pow apps all greyed out as offline while the network works"; WebApps.kt / WebAppSync.Reach:
# greyed only after two tries in a row got no answer from the hub, re-checked on screen-on, network change and within
# seconds of a miss). Read-only, no touches: the phone must reach powstation.pow (else exit 3, nothing to judge), then
# the launcher's app list (home page's state) has .pow apps ("w:") and none marked offline - an offline mark gets up to
# 45 s to clear (the 3 s / 30 s retry). Prints the app's PowosWebApps log lines.
# Exit 0 PASS, 1 FAIL, 3 can't judge (phone off the LAN/VPN).
set -uo pipefail
cd "$(dirname "$0")/../../.."
A=tools/phone/adb.sh
export CDP_TIMEOUT_S=30
ev() { tools/phone/cdp.sh eval home "$1" 2>&1 | tail -1 | tr -d '\r\\' | sed -E 's/^"(.*)"$/\1/'; }
if ! "$A" shell 'ping -c1 -W3 powstation.pow' </dev/null >/dev/null 2>&1; then
  echo "SKIP: the phone doesn't reach powstation.pow (off the LAN/VPN) - nothing to judge"; exit 3
fi
# The host's own app list (ShellBridge apps.list, the "offline" flag the launcher greys by), asked through the page's
# bridge with a private call id - not the page's module state (importShim can stall while the page is in the background).
state='new Promise(res=>{const h=window.__powosHost,o=h.resolve,id=900000+Math.floor(Math.random()*1e5),P=window.PowosHost;h.resolve=(i,v)=>{if(i===id){h.resolve=o;const a=typeof v==="string"?JSON.parse(v):v;const w=a.filter(x=>String(x.key).startsWith("w:"));res(w.length+" "+w.filter(x=>x.offline).length)}else o(i,v)};P.call?P.call(id,"apps.list","[]"):P.postMessage(JSON.stringify([id,"apps.list","[]"]))})'
for i in $(seq 0 9); do
  r=$(ev "$state"); n=${r% *}; off=${r#* }
  echo "try $i: $n .pow apps, $off offline"
  [[ "$n" =~ ^[0-9]+$ && "$off" =~ ^[0-9]+$ ]] || { echo "FAIL: couldn't read the launcher's app list: $r"; exit 1; }
  [ "$off" = 0 ] && break
  sleep 5
done
"$A" shell "su -c 'logcat -d -s PowosWebApps | tail -8'" </dev/null 2>/dev/null | tr -d '\r'
[ "$n" -gt 0 ] || { echo "FAIL: no .pow apps on the launcher while powstation.pow answers"; exit 1; }
[ "$off" = 0 ] || { echo "FAIL: $off of $n .pow apps greyed out as offline while the phone reaches powstation.pow"; exit 1; }
echo "PASS: $n .pow apps on the launcher, none greyed out as offline, the phone reaches powstation.pow"
