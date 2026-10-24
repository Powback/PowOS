#!/bin/bash
# lanes: phone
# tools/phone/verify/assist-swipe.sh: a swipe up on the side-button overlay (assist) closes it.
# Shows the assistant (`cmd voiceinteraction show`), swipes up from the bottom-edge strip (assist.tsx swipeAway) and
# expects the page hidden/gone; a short swipe must snap back (still visible). Needs a free window (queue.sh).
set -uo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
A=tools/phone/adb.sh
vis() { tools/phone/cdp.sh eval assist "document.visibilityState" 2>/dev/null | tr -d '"\r\n ' ; }
size=$($A shell wm size | tr -d '\r' | grep -o '[0-9]*x[0-9]*' | tail -1); w=${size%x*}; h=${size#*x}
x=$((w / 2)); yb=$((h - 12))
echo "== show"; $A shell 'cmd voiceinteraction show'; sleep 2
v=$(vis); echo "visible before: ${v:-none}"; [ "$v" = visible ] || { echo "RESULT FAIL assist did not show"; exit 1; }
echo "== short swipe snaps back"; $A shell "input swipe $x $yb $x $((yb - 30)) 300"; sleep 1
v=$(vis); [ "$v" = visible ] || { echo "RESULT FAIL a short swipe closed it (${v:-none})"; exit 1; }
echo "== swipe up from the bottom edge"; $A shell "input swipe $x $yb $x $((h / 2)) 250"; sleep 1.5
v=$(vis); echo "after: ${v:-none}"
if [ -z "$v" ] || [ "$v" = hidden ]; then echo "RESULT PASS swipe up closed the assist overlay"; else
  $A shell 'cmd voiceinteraction hide'; echo "RESULT FAIL overlay still visible after swipe up"; exit 1; fi
