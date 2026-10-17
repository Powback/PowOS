#!/system/bin/sh
# powos-run.sh <command>: runs `bash -lc <command>` inside the running PowOS desktop session (rooted mode), as the
# user powos, with the session's environment. The PowOS app's launcher uses it for its terminal tiles
# (`su -c sh /data/powos/powos-run.sh 'foot ... -e /usr/lib/powos/powos-tmux-shell'`), so they are PowOS terminals:
# the same system, home, tmux sessions and dbus as the desktop's Konsole.
#
# It joins the session's mount namespace (PowOS pivoted to /, see powos-session.sh) - setns into a mount namespace
# also moves our root there, so /usr/bin/... below are PowOS's own. The launcher's Wayland socket is in the app's run
# dir, which the session sees at /run/powos-app.
session() {
  PID=$(cat /data/powos/session.pid 2>/dev/null)
  [ -n "$PID" ] && [ -d "/proc/$PID" ] || PID=$(pidof kwin_wayland | cut -d' ' -f1)
  [ -n "$PID" ]
}
# The app starts the session alongside its launcher (after an update, a reboot): a tile opened first waits for it
# rather than exiting at once.
i=0
until session; do
  i=$((i + 1))
  [ $i -le 30 ] || { echo "powos-run: no PowOS session running (start PowOS first)" >&2; exit 1; }
  sleep 1
done
# The session's own language: the one PowOS compiled (Android's, e.g. en_CH, may not be).
L=$(tr '\0' '\n' < /proc/$PID/environ 2>/dev/null | sed -n 's/^LANG=//p')
# Its time zone, likewise (else Android's): su gives none, PowOS has no /etc/localtime, so what this started (Steam
# from the games widget, its logs) ran on UTC.
Z=$(tr '\0' '\n' < /proc/$PID/environ 2>/dev/null | sed -n 's/^TZ=//p')
[ -n "$Z" ] || Z=$(getprop persist.sys.timezone)
# The desktop's X server (Xwayland): its display and auth file, as the desktop's own apps get them from KWin - each
# session start makes a new auth file, and X11 programs (Steam) then failed with "Authorization required".
# From KWin's own arguments (it starts Xwayland: --xwayland-display, --xwayland-xauthority), known from KWin's start:
# plasmashell, the other source, comes up later - a shell started before it (the launcher's widget shell, at the
# session's start) got neither, and Steam then said "Unable to open a connection to X".
KA=$(tr '\0' '\n' < /proc/$(pidof kwin_wayland | cut -d' ' -f1)/cmdline 2>/dev/null)
XD=$(printf '%s\n' "$KA" | sed -n '/^--xwayland-display$/{n;p;}')
XA=$(printf '%s\n' "$KA" | sed -n '/^--xwayland-xauthority$/{n;p;}')
X="${XD:+DISPLAY=$XD} ${XA:+XAUTHORITY=$XA}"
P=$(pidof plasmashell | cut -d' ' -f1)
[ -n "$XD" ] || X=$( [ -n "$P" ] && tr '\0' '\n' < /proc/$P/environ 2>/dev/null | grep -E '^(DISPLAY|XAUTHORITY)=' | tr '\n' ' ')
# The session's GPU setup (powos-rooted-session: Mesa on KGSL, Andromarchy's display, VA-API, the phone's own
# /etc/powos/session.env), as KWin got it. Without it Mesa finds no driver ("No driver found"): Steam, games and
# a restarted plasmashell rendered without the Adreno. Values have no spaces (word-split below, like $X).
K=$(pidof kwin_wayland | cut -d' ' -f1)
E=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' /data/powos/root/etc/powos/session.env 2>/dev/null | tr '\n' '|')
G=$( [ -n "$K" ] && tr '\0' '\n' < /proc/$K/environ 2>/dev/null |
  grep -E "^(${E}TURNIP_|FD_|MESA_|GALLIUM_|XWAYLAND_|ANDROMARCHY_|LIBVA_|TERMUX_VA_|POWOS_SESSION_MODE|QT_FORCE_STDERR_LOGGING)[A-Za-z0-9_]*=" |
  tr '\n' ' ')
# The session's open-file limit (see powos-rooted-session: Proton's esync needs >= 524288), raised while still root.
ulimit -n 1048576 2>/dev/null
# On a terminal (the launcher's terminals: a pty the PowOS app owns, through su), a session of its own with that
# terminal as its controlling tty, set while still root: su passes the pty on but not as one, and bash then had no job
# control ("cannot set terminal process group") and /dev/tty didn't open (tmux, fzf).
CTTY=
[ -t 0 ] && CTTY="/usr/bin/setsid -c"
exec nsenter -t "$PID" -m -- $CTTY /usr/bin/setpriv --reuid=powos --regid=powos --init-groups -- /usr/bin/env -i \
  HOME=/home/powos USER=powos LOGNAME=powos SHELL=/bin/bash TERM=xterm-256color \
  PATH=/home/powos/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin \
  LANG="${L:-${LANG:-C.UTF-8}}" TZ="${Z:-$TZ}" \
  XDG_RUNTIME_DIR=/run/powos-app \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/powos-app/bus \
  DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/powos-app/system_bus \
  ${WAYLAND_DISPLAY:+WAYLAND_DISPLAY="$WAYLAND_DISPLAY"} $X $G \
  /bin/bash -lc "cd ~ && $1"
