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
# SELinux: PowOS's programs run in Magisk's domain and some are Wayland clients of the app's own compositor (the
# launcher's terminal tiles: foot). A Wayland client hands the compositor its shared-memory fd (a memfd, labelled
# tmpfs); Android's policy does not let an app use a Magisk-domain fd or tmpfs files, so the kernel dropped it and the
# compositor failed foot with "wl_shm create_pool without an fd" - the tile showed "exited". Allow exactly that, for
# the app's own domain (untrusted_app_<targetSdk>, read from the running app). Live policy: applied each session start.
APP_DOMAIN=$(ps -AZ | awk '$NF == "com.powos.app" {split($1, c, ":"); print c[3]; exit}')
[ -n "$APP_DOMAIN" ] && magiskpolicy --live "allow $APP_DOMAIN magisk fd use" \
  "allow $APP_DOMAIN tmpfs file { read write map getattr }" && echo "sepolicy: $APP_DOMAIN may use PowOS's Wayland buffers"
m mkdir -p "$R/run/powos-app"
m grep -q " $R/run/powos-app " /proc/mounts || m mount --bind "$RUN" "$R/run/powos-app"
# The launcher's widgets and styles, at the place its agents work on them (~/.config/omalauncher, as in the no-root
# guest): PowOS AI - the launcher's agent in a PowOS session - and the PowOS shell edit the very files the launcher
# draws. The app's files are the run dir's parent; powos owns them (its uid is the app's).
for d in widgets style; do
  m mkdir -p "$R/home/powos/.config/omalauncher/$d" "${RUN%/run}/$d"
  m grep -q " $R/home/powos/.config/omalauncher/$d " /proc/mounts ||
    m mount --bind "${RUN%/run}/$d" "$R/home/powos/.config/omalauncher/$d"
done

# The display socket as PowOS sees it.
sock=/run/powos-app/${SOCK#$RUN/}
# PowOS as the real root of its own mount namespace (pivot_root), not a chroot: Linux refuses user namespaces inside
# a chroot ("unshare: Operation not permitted"), and Steam (pressure-vessel/bubblewrap), Flatpak and rootless podman
# need them. Made private first (pivot_root fails on shared mounts); PowOS's own mount/pivot_root, through its
# loader: Android's toybox has no pivot_root and no --make-rprivate. powos-rooted-session detaches /.oldroot.
export L="$R/usr/lib/ld-linux-aarch64.so.1 --library-path $R/usr/lib" R
# The session keeps this pid through the execs below: powos-run.sh joins its mount namespace.
echo $$ > /data/powos/session.pid
exec nsenter -t 1 -m -- unshare -m sh -c '
  $L $R/usr/bin/mount --make-rprivate / && $L $R/usr/bin/mount --rbind $R $R && cd $R && mkdir -p .oldroot &&
    $L $R/usr/bin/pivot_root . .oldroot || exit 1
  exec "$@"' powos-session /usr/bin/env -i \
  HOME=/home/powos USER=powos LOGNAME=powos SHELL=/bin/bash \
  PATH=/home/powos/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin \
  LANG="$LANG_" TZ="$TZ_" \
  XDG_RUNTIME_DIR=/run/powos-app \
  ANDROMARCHY_SOCKET="$sock" ANDROMARCHY_PHYSICAL_MM="$MM" \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/powos-app/bus \
  DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/powos-app/system_bus \
  XDG_DATA_DIRS=/run/powos-app/share:/home/powos/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share \
  /usr/bin/powos-rooted-session
