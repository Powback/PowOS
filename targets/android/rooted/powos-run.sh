#!/system/bin/sh
# powos-run.sh <command>: runs `bash -lc <command>` inside the running PowOS desktop session (rooted mode), as the
# user powos, with the session's environment. The PowOS app's launcher uses it for its terminal tiles
# (`su -c sh /data/powos/powos-run.sh 'foot ... -e /usr/lib/powos/powos-tmux-shell'`), so they are PowOS terminals:
# the same system, home, tmux sessions and dbus as the desktop's Konsole.
#
# It joins the session's mount namespace (PowOS pivoted to /, see powos-session.sh) - setns into a mount namespace
# also moves our root there, so /usr/bin/... below are PowOS's own. The launcher's Wayland socket is in the app's run
# dir, which the session sees at /run/powos-app.
PID=$(cat /data/powos/session.pid 2>/dev/null)
[ -n "$PID" ] && [ -d "/proc/$PID" ] || PID=$(pidof kwin_wayland | cut -d' ' -f1)
[ -n "$PID" ] || { echo "powos-run: no PowOS session running (start PowOS first)" >&2; exit 1; }
exec nsenter -t "$PID" -m -- /usr/bin/setpriv --reuid=powos --regid=powos --init-groups -- /usr/bin/env -i \
  HOME=/home/powos USER=powos LOGNAME=powos SHELL=/bin/bash TERM=xterm-256color \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin \
  LANG="${LANG:-C.UTF-8}" TZ="$TZ" \
  XDG_RUNTIME_DIR=/run/powos-app \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/powos-app/bus \
  DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/powos-app/system_bus \
  ${WAYLAND_DISPLAY:+WAYLAND_DISPLAY="$WAYLAND_DISPLAY"} \
  /bin/bash -lc "cd ~ && $1"
