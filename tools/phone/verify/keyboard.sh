#!/bin/bash
# tools/phone/verify/keyboard.sh: does Android's keyboard come up for a text field in the PowOS (Linux) session, and go
# when it closes? (skill: powos-gestures; task keyboard-follows-powos-text-fields). One free window, the verify lock only
# then. A FRESH app each time - never the user's windows or tmux sessions: a Wayland text field (kwrite, focused on
# open) and an X11 one through Xwayland (zenity --entry with GDK_BACKEND=x11: what Steam's CEF is). Each: open, the
# keyboard's state (dumpsys input_method mInputShown) and KWin's "Android keyboard shown/hidden" log, a screencap,
# then the app closed (only the pid this script started) and the keyboard state again. X11: the keyboard comes through
# IBus -> powos-ime-bridge -> KWin's SetX11TextFocus (unit x11-ime-bridge, KWin patch 0016); its log is shown too.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); A=$here/adb.sh
OUT=${OUT:-$HOME/powos-rec/keyboard-$(date +%H%M%S)}; mkdir -p "$OUT"
. "$(dirname "$0")/window-lock.sh"
window_lock keyboard.sh 120
ime() { "$A" shell "dumpsys input_method | grep -m1 -oE 'mInputShown=[a-z]+'" | tr -d '\r'; }
user() { # a command in the PowOS session as its user, its output back
  local f=$OUT/.u.sh; printf '%s\n' "$1" > "$f"; "$here/user.sh" "$f" 2>/dev/null | grep -v "file pushed"; }
# KWin's log (its stderr: "Android keyboard shown/hidden - <why>"), read as root from its fd 2.
kwinlog() { "$A" shell "su -c 'k=\$(pidof kwin_wayland | cut -d\" \" -f1); f=\$(readlink /proc/\$k/fd/2); case \$f in /*) tail -n 400 /data/powos/root\$f 2>/dev/null || tail -n 400 \$f ;; esac'" | tr -d '\r' | grep -E "Android keyboard" | tail -4; }
check() { # check <name> <command for the PowOS session, its args carrying the marker powos-kb-check>
  local name=$1 cmd=$2
  "$A" shell logcat -c
  echo "== $name: before $(ime)"
  # Opened as a launcher tap opens a Linux app (the debug build's exec extra): the PowOS desktop comes to the front with it.
  "$A" shell am start -n com.powos.app/dev.omalauncher.shell.ShellActivity --es exec "'$cmd'" >/dev/null
  sleep 8
  echo "   open: $(ime); focus: $("$A" shell 'dumpsys window | grep -m1 mCurrentFocus' | tr -d '\r' | sed 's/.*u0 //')"
  "$A" shell "logcat -d -v time | grep -iE 'Android keyboard|SystemIME|setKeyboard|PowosKeyboard|launch:' | tail -5"
  kwinlog
  [ "$name" = x11 ] && user 'tail -n 4 "$XDG_RUNTIME_DIR/powos-ime-bridge.log" 2>/dev/null' | sed 's/^/   /'
  "$A" shell "screencap -p /data/local/tmp/kb-$name.png"; "$A" pull /data/local/tmp/kb-$name.png "$OUT/" >/dev/null 2>&1; "$A" shell rm -f /data/local/tmp/kb-$name.png
  # Only what this check opened (its marker in the command line).
  user "pkill -f powos-kb-check; true" >/dev/null
  sleep 3
  echo "   closed: $(ime)"
}
# What the X11 case needs: the RUNNING KWin with patch 0016 (its D-Bus slot; an installed package loads only with the
# next session) and the bridge with its ibus-daemon.
echo "== setup: $(user 'pacman -Q kwin ibus 2>&1 | tr "\n" " "
  dbus-send --session --print-reply --dest=org.kde.KWin /org/powos/Keyboard org.freedesktop.DBus.Introspectable.Introspect 2>/dev/null | grep -q SetX11TextFocus && echo "kwin-slot=yes " || echo "kwin-slot=NO (old KWin running) "
  pgrep -fa "powos-ime-bridge|ibus-daemon" | cut -c1-80 | tr "\n" ";"')"
check wayland 'kwrite /tmp/powos-kb-check.txt'
check x11 'env GDK_BACKEND=x11 zenity --entry --title powos-kb-check --text type-here'
"$A" shell input keyevent KEYCODE_HOME
echo "out: $OUT"
