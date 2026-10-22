#!/bin/bash
# tools/phone/verify/keyboard.sh: does Android's keyboard come up for a text field in the PowOS (Linux) session, and go
# when it closes? (skill: powos-gestures; task keyboard-follows-powos-text-fields). One free window, the verify lock only
# then. A FRESH app each time - never the user's windows or tmux sessions: a Wayland text field (kwrite, focused on
# open) and an X11 one through Xwayland (zenity --entry with GDK_BACKEND=x11: what Steam's CEF is). Each: open, the
# keyboard's state (dumpsys input_method mInputShown) and KWin's "Android keyboard shown/hidden" log, a screencap,
# then the app closed (only the pid this script started) and the keyboard state again.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); A=$here/adb.sh
OUT=${OUT:-$HOME/powos-rec/keyboard-$(date +%H%M%S)}; mkdir -p "$OUT"
. "$(dirname "$0")/window-lock.sh"
window_lock keyboard.sh 120
ime() { "$A" shell "dumpsys input_method | grep -m1 -oE 'mInputShown=[a-z]+'" | tr -d '\r'; }
user() { # a command in the PowOS session as its user, its output back
  local f=$OUT/.u.sh; printf '%s\n' "$1" > "$f"; "$here/user.sh" "$f" 2>/dev/null | grep -v "file pushed"; }
check() { # check <name> <launch command (prints its pid)>
  local name=$1 cmd=$2 pid
  "$A" shell logcat -c
  echo "== $name: before $(ime)"
  pid=$(user "$cmd" | tail -1); echo "   started pid $pid"
  sleep 6
  echo "   open: $(ime); focus: $("$A" shell 'dumpsys window | grep -m1 mCurrentFocus' | tr -d '\r' | sed 's/.*u0 //')"
  "$A" shell "logcat -d -v time | grep -iE 'Android keyboard|SystemIME|setKeyboard|PowosKeyboard' | tail -5"
  "$A" shell "screencap -p /data/local/tmp/kb-$name.png"; "$A" pull /data/local/tmp/kb-$name.png "$OUT/" >/dev/null 2>&1; "$A" shell rm -f /data/local/tmp/kb-$name.png
  [ -n "$pid" ] && user "kill $pid 2>/dev/null; true" >/dev/null
  sleep 3
  echo "   closed: $(ime)"
}
check wayland 'XDG_RUNTIME_DIR=/run/powos-app WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland nohup kwrite >/dev/null 2>&1 & echo $!'
check x11 'DISPLAY=:0 GDK_BACKEND=x11 nohup zenity --entry --title "keyboard check" --text "type here" >/dev/null 2>&1 & echo $!'
"$A" shell input keyevent KEYCODE_HOME
echo "out: $OUT"
