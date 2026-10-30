#!/bin/bash
# game-window.sh: read-only check of every running game window (WM_CLASS steam_app_*) in the phone's X session - run
# after the user launched a game: `tools/phone/root.sh tools/phone/verify/game-window.sh` (runs in the Linux chroot).
# PASS per window: not minimised (WM_STATE Normal, no _NET_WM_STATE_HIDDEN) and its size = the X screen's (the
# container, folded or unfolded) within 2 px. Also prints KWin's anland lines about it (kwin 0040 "minimized itself",
# "full screen follows its task"). Android side: `tools/phone/adb.sh logcat -d -s PowosWindowFrames | grep -E
# "not hidden off page|hidden in WM|full screen"` (WindowFrames.mayHide).
export DISPLAY=:0 XAUTHORITY=$(ls /tmp/runtime-powos/xauth_* 2>/dev/null | head -1)
screen=$(xrandr 2>/dev/null | sed -n 's/^Screen 0:.* current \([0-9]*\) x \([0-9]*\),.*/\1 \2/p')
echo "X screen (container): ${screen/ /x}"
fail=0 n=0
for w in $(xprop -root _NET_CLIENT_LIST 2>/dev/null | grep -o '0x[0-9a-f]*'); do
  cls=$(xprop -id "$w" WM_CLASS 2>/dev/null)
  case $cls in *steam_app_*) ;; *) continue ;; esac
  n=$((n + 1))
  name=$(xprop -id "$w" _NET_WM_NAME 2>/dev/null | cut -d'"' -f2)
  ws=$(xprop -id "$w" WM_STATE 2>/dev/null | sed -n 's/.*window state: //p')
  ns=$(xprop -id "$w" _NET_WM_STATE 2>/dev/null | sed 's/.*= //')
  geo=$(xwininfo -id "$w" 2>/dev/null | awk '/Width:/{w=$2} /Height:/{h=$2} /Map State:/{m=$3} END{print w, h, m}')
  set -- $geo; gw=$1 gh=$2 map=$3; set -- $screen; sw=$1 sh=$2
  echo "$w \"$name\" $cls"
  echo "  WM_STATE=$ws  _NET_WM_STATE=$ns  map=$map  size=${gw}x${gh}"
  if [ "$ws" != Normal ] || [[ $ns == *HIDDEN* ]]; then echo "  FAIL: minimised/hidden"; fail=1; else echo "  PASS: not minimised"; fi
  if [ -n "$sw" ] && [ $(( (gw - sw) * (gw - sw) <= 4 && (gh - sh) * (gh - sh) <= 4 )) = 1 ]; then
    echo "  PASS: container size"
  else
    echo "  FAIL: size ${gw}x${gh}, container ${sw}x${sh} (a floating/stale size?)"; fail=1
  fi
done
[ $n = 0 ] && echo "no game window (steam_app_*) open"
log=$(ls -t /home/powos/.local/share/sddm/wayland-session.log /home/powos/.local/state/powos/*.log /tmp/powos-*kwin*.log 2>/dev/null | head -1)
journalctl --user -u plasma-kwin_wayland -n 0 >/dev/null 2>&1 && log=journal
echo "KWin log: ${log:-not found (KWin's stderr: see the session's own log)}"
[ -n "$log" ] && [ "$log" != journal ] && grep -a -E "minimized itself|keeps minimizing|never went live|full screen follows its task|full screen \(the app's own\)|full-screen window .* (opened as a task|stays on the desktop)" "$log" | tail -15
exit $fail
