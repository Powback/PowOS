#!/bin/bash
# The one way to take a screencap of the phone (never a bare `screencap`):
#   tools/phone/shot.sh OUT.png [--all] [--phone]
# Picks the display that is ON now - the cover (folded) or the inner screen (unfolded); --all: every ON display, saved
# as OUT-<cover|inner>.png - and refuses rather than saving black:
#   exit 3  the screen is off/dozing (never woken: wait with `AWAKE_ONLY=1 tools/phone/idle.sh --wait 120 MAX`)
#   exit 4  the capture came back blank (all black) - the reason it can tell is printed: a FLAG_SECURE window on
#           screen (screencap leaves secure layers black), or nothing drawn yet (a window at alpha 0 / still fading in:
#           shoot again later, after the transition)
#   exit 2  no phone / adb failed
# OUT is on the Mac (under $HOME: Colima shares only that). --phone: OUT is a path ON the phone (for scripts that run
# there; nothing pulled). Prints each saved file and its display.
#
# Why black screencaps happened (2026-10-22): `screencap` without -d takes the FIRST display, which on the Open is the
# inner screen (HWC 0) - black whenever the phone is folded; a fixed cover id is black whenever it's unfolded; and a
# capture taken after the idle check had let the screen doze is black too. Display ids: `dumpsys display`
# (DisplayDeviceInfo uniqueId local:<id> ... state ON|OFF), the same ids `dumpsys SurfaceFlinger --display-id` lists.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out="" all="" onphone=""
for a in "$@"; do case "$a" in --all) all=1 ;; --phone) onphone=1 ;; -h|--help) sed -n '2,19p' "$0"; exit 0 ;; *) out=$a ;; esac; done
[ -n "$out" ] || { sed -n '2,3p' "$0"; exit 2; }
base=${out%.png}
tag=powos-shot-$$
# One root shell on the phone does all of it: state, display pick, capture, blank check.
res=$("$here/adb.sh" shell "su -c 'sh -s'" <<EOF 2>&1
w=\$(dumpsys power | sed -n "s/.*mWakefulness=//p" | head -1)
[ "\$w" = Awake ] || { echo "OFF \$w"; exit 0; }
dumpsys display | grep -E "^  DisplayDeviceInfo" | sed -nE 's/.*uniqueId="local:([0-9]+)", ([0-9]+) x ([0-9]+),.* state ON,.*/\1 \2 \3/p' > /data/local/tmp/$tag.ids
[ -s /data/local/tmp/$tag.ids ] || { echo "OFF no-display-on"; exit 0; }
while read id dw dh; do
  name=inner; [ "\$dw" -lt "\$dh" ] && [ "\$dw" -lt 1500 ] && name=cover
  f=/data/local/tmp/$tag-\$name.png
  screencap -d \$id -p \$f
  # blank: no byte other than 00/ff in the raw pixels (black, or nothing drawn)
  n=\$(screencap -d \$id | tail -c +17 | tr -d '\000\377' | head -c 1 | wc -c)
  sec=\$(dumpsys window windows | grep -cE "fl=.*SECURE")
  echo "SHOT \$name \$id \$dw \$dh \$n \$sec \$f"
  [ -n "$all" ] || break
done < /data/local/tmp/$tag.ids
rm -f /data/local/tmp/$tag.ids
EOF
) || { echo "shot: adb failed: $res" >&2; exit 2; }
res=$(echo "$res" | tr -d '\r')
case "$res" in OFF*) echo "shot: refused - the screen is ${res#OFF } (never woken; AWAKE_ONLY=1 tools/phone/idle.sh --wait 120 MAX)" >&2; exit 3 ;; esac
echo "$res" | grep -q '^SHOT' || { echo "shot: failed: $res" >&2; exit 2; }
rc=0
while read -r _ name id dw dh n sec f; do
  dest=$base.png; [ -n "$all" ] && dest=$base-$name.png
  if [ -n "$onphone" ]; then "$here/adb.sh" shell "su -c 'mv $f $dest'" >/dev/null
  else
    # adb.sh mounts only paths that exist: pull into OUT's folder, then rename.
    d=$(cd "$(dirname "$dest")" && pwd) || { echo "shot: no folder for $dest" >&2; exit 2; }
    "$here/adb.sh" shell "su -c 'chmod 644 $f'" >/dev/null
    "$here/adb.sh" pull "$f" "$d/" >/dev/null 2>&1 && mv "$d/$(basename "$f")" "$dest" || { echo "shot: pull failed for $dest" >&2; rc=2; }
    "$here/adb.sh" shell "su -c 'rm -f $f'" >/dev/null
  fi
  if [ "$n" = 0 ]; then
    why="nothing drawn - a window at alpha 0 or mid-transition; shoot again after it settles"
    [ "$sec" -gt 0 ] && why="a FLAG_SECURE window is on screen ($sec) - screencap leaves secure layers black"
    echo "shot: BLANK $dest ($name, display $id ${dw}x${dh}): $why" >&2; rc=4
  else
    echo "$dest ($name, display $id ${dw}x${dh})"
  fi
done <<< "$(echo "$res" | grep '^SHOT')"
exit $rc
