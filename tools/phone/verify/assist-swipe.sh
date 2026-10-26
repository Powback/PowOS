#!/bin/bash
# lanes: phone
# tools/phone/verify/assist-swipe.sh: a swipe up on the side-button overlay (assist) closes it.
# Shows the assistant (`su -c cmd voiceinteraction show`: the adb shell user lacks ACCESS_VOICE_INTERACTION_SERVICE, so
# a plain `cmd voiceinteraction show` is denied and the old check read the never-shown warm page as "visible" - 2026-10-24),
# swipes up from the panel's handle (assist.tsx swipeAway; the bottom 12 px belong to the system's home gesture) and
# expects the page hidden/gone; a short swipe must snap back (still visible). Needs a free window (queue.sh).
set -uo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
A=tools/phone/adb.sh
vis() { tools/phone/cdp.sh eval assist "document.visibilityState" 2>/dev/null | tr -d '"\r\n ' ; }
size=$($A shell wm size | tr -d '\r' | grep -o '[0-9]*x[0-9]*' | tail -1); w=${size%x*}; h=${size#*x}
x=$((w / 2))
echo "== show"; out=$($A shell "su -c 'cmd voiceinteraction show'" 2>&1); echo "$out"; sleep 2
case "$out" in *Error*|*Exception*|*denied*) echo "RESULT FAIL could not show the assistant: $out"; exit 1;; esac
v=$(vis); echo "visible before: ${v:-none}"; [ "$v" = visible ] || { echo "RESULT FAIL assist did not show"; exit 1; }
# The handle's centre in device px (CSS px x devicePixelRatio).
g=$(tools/phone/cdp.sh eval assist "(()=>{const r=document.querySelector('.assist-grip').getBoundingClientRect();return [Math.round((r.left+r.width/2)*devicePixelRatio),Math.round((r.top+r.height/2)*devicePixelRatio)].join(' ')})()" 2>/dev/null | tr -d '"\r')
gx=${g% *}; yb=${g#* }; echo "handle at $gx,$yb"
case "$gx$yb" in ''|*[!0-9]*) $A shell "su -c 'cmd voiceinteraction hide'"; echo "RESULT FAIL no handle found (${g:-none})"; exit 1;; esac
x=$gx
echo "== short swipe snaps back"; $A shell "input swipe $x $yb $x $((yb - 30)) 300"; sleep 1
v=$(vis); [ "$v" = visible ] || { echo "RESULT FAIL a short swipe closed it (${v:-none})"; exit 1; }
echo "== swipe up from the handle"; $A shell "input swipe $x $yb $x $((yb - 400)) 250"; sleep 1.5
v=$(vis); echo "after: ${v:-none}"
if [ -z "$v" ] || [ "$v" = hidden ]; then echo "RESULT PASS swipe up closed the assist overlay"; else
  $A shell "su -c 'cmd voiceinteraction hide'"; echo "RESULT FAIL overlay still visible after swipe up"; exit 1; fi
