#!/system/bin/sh
# The PowOS desktop on a rooted phone: started by the PowOS app (SessionService, rooted mode) through
# `su -c sh /data/powos/powos-session.sh <run dir> <display socket> <physical mm> <LANG> <TZ>`.
#
# The app keeps what only an Android app can do: the screen surface and its display daemon (buffers, touch, keyboard,
# audio relayed to KWin's Anland backend over <display socket>), plus the phone's state files in <run dir> (battery,
# network, Android requests). Everything else runs here, inside PowOS's own system (/data/powos/root), the desktop as
# the user powos (powos-rooted-session drops to it; sudo works for real) - no
# patched loader, fakechroot or fakeroot as in the no-root engine. The app's run dir appears inside PowOS at
# /run/powos-app (XDG_RUNTIME_DIR), so sockets, logs and desktop-ready are shared as-is.
RUN=$1 SOCK=$2 MM=$3 LANG_=$4 TZ_=$5
R=/data/powos/root
exec >> /data/powos/session.log 2>&1
echo "--- $(date) powos-session run=$RUN"

sh /data/powos/powos-start.sh                       # mounts (idempotent; also done at boot)
m() { nsenter -t 1 -m -- "$@"; }
m mkdir -p "$R/run/powos-app"
m grep -q " $R/run/powos-app " /proc/mounts || m mount --bind "$RUN" "$R/run/powos-app"

# The display socket as PowOS sees it.
sock=/run/powos-app/${SOCK#$RUN/}
exec nsenter -t 1 -m -- chroot "$R" /usr/bin/env -i \
  HOME=/home/powos USER=powos LOGNAME=powos SHELL=/bin/bash \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin \
  LANG="$LANG_" TZ="$TZ_" \
  XDG_RUNTIME_DIR=/run/powos-app \
  ANDROMARCHY_SOCKET="$sock" ANDROMARCHY_PHYSICAL_MM="$MM" \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/powos-app/bus \
  DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/powos-app/system_bus \
  XDG_DATA_DIRS=/home/powos/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share \
  /usr/bin/powos-rooted-session
