#!/system/bin/sh
# The PowOS desktop on a rooted phone: started by the PowOS app (SessionService, rooted mode) through
# `su -c sh /data/powos/powos-session.sh <run dir> <display socket> <physical mm> <LANG> <TZ> [<termux-va>]`.
#
# The session OUTLIVES the app: it runs under Magisk's su, outside the app's cgroup, so an APK update (am_kill
# "installPackageLI") or an app kill only takes the app's display daemon down; KWin (patch 0035) dials the new
# app's daemon and the screen comes back with every Linux app (Steam, Dolphin, ...) still running. So when the app
# starts and a healthy session already runs, this REATTACHES (no new session) instead of starting one.
#   powos-session.sh status    is a session running and healthy (exit 0) - rooted.sh session status
#   powos-session.sh restart   a new session on purpose, with the last start's arguments - rooted.sh session restart
# A start with POWOS_SESSION_RESTART=1 (or /data/powos/session.restart present, consumed) always makes a new one.
#
# The app keeps what only an Android app can do: the screen surface and its display daemon (buffers, touch, keyboard,
# audio relayed to KWin's Anland backend over <display socket>), plus the phone's state files in <run dir> (battery,
# network, Android requests). Everything else runs here, inside PowOS's own system (/data/powos/root), the desktop as
# the user powos (powos-rooted-session drops to it; sudo works for real) - no
# patched loader, fakechroot or fakeroot as in the no-root engine. The app's run dir appears inside PowOS at
# /run/powos-app (XDG_RUNTIME_DIR), so sockets, logs and desktop-ready are shared as-is.
R=/data/powos/root

# A session that is up and can take the new app: its process group alive (powos-rooted-session's pgid, in PowOS's
# /run), KWin running from the KWin package installed now (not one replaced under it), KWin new enough to dial a new
# display daemon (0035, kwin 6.7.5-3.40), and its Wayland socket in the app's run dir <$1> (a clear-data makes a new
# run dir: no socket there, so a new session). Prints why not.
healthy() {
  run=${1:-/data/user/0/com.powos.app/files/run}
  pg=$(cat "$R/run/powos-rooted-session.pgid" 2>/dev/null)
  [ -n "$pg" ] && kill -0 "-$pg" 2>/dev/null || { echo "no session process group"; return 1; }
  kw=$(pgrep -x kwin_wayland | head -n 1)
  [ -n "$kw" ] || { echo "no KWin"; return 1; }
  [ "$(awk '{print $5}' "/proc/$kw/stat" 2>/dev/null)" = "$pg" ] || { echo "KWin $kw is not the session's"; return 1; }
  case $(readlink "/proc/$kw/exe") in *deleted*) echo "KWin $kw runs a replaced binary (kwin updated)"; return 1 ;; esac
  # HACK: KWin's ability to dial a new daemon read off its package version (pacman's db). Real fix: KWin says so
  # itself (a "caps ... redial" on the control channel, or a file in the run dir the backend writes at start).
  v=$(sed -n '/^%VERSION%$/{n;p;q}' "$R"/var/lib/pacman/local/kwin-[0-9]*/desc 2>/dev/null)
  case $v in
    6.7.5-3.*) [ "${v#6.7.5-3.}" -ge 40 ] 2>/dev/null || { echo "KWin $v can't reattach (needs 6.7.5-3.40+)"; return 1; } ;;
    *) [ -n "$v" ] && [ "$(printf '%s\n' "$v" 6.7.5-3.40 | sort -V | head -n 1)" = 6.7.5-3.40 ] \
         || { echo "KWin ${v:-?} can't reattach"; return 1; } ;;
  esac
  [ -S "$run/wayland-0" ] || { echo "no Wayland socket in $run"; return 1; }
  echo "healthy: session $pg, KWin $kw ($v)"
}

case ${1:-} in
  status) healthy "${2:-}"; exit $? ;;
  restart)
    # A new session on purpose, with the arguments of the last start (the app's daemon keeps running; the new KWin
    # connects to it). Detached, so it outlives the caller (adb's shell).
    [ -s /data/powos/session.args ] || { echo "no previous start (/data/powos/session.args)"; exit 1; }
    POWOS_SESSION_RESTART=1 setsid sh /data/powos/powos-session.sh $(cat /data/powos/session.args) \
      > /dev/null 2>&1 < /dev/null &
    echo "restarting the session (log: /data/powos/session.log)"; exit 0 ;;
esac

RUN=$1 SOCK=$2 MM=$3 LANG_=$4 TZ_=$5 TVA=$6
exec >> /data/powos/session.log 2>&1
echo "--- $(date) powos-session run=$RUN"
echo "$*" > /data/powos/session.args
[ -e /data/powos/session.restart ] && { rm -f /data/powos/session.restart; POWOS_SESSION_RESTART=1; }

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
# The app's directories, bound into PowOS. A bind an earlier session left whose source has since been deleted (the
# app's data dir made anew: `pm uninstall-system-updates`, a clear-data) still shows as mounted, onto the dead
# directory: the session would keep running there, its apps installed where the app never looks. Replaced, not kept.
appbind() {
  while [ -n "$(m awk -v d="$2" '$5 == d && $4 ~ /deleted/' /proc/self/mountinfo)" ]; do
    echo "bind $2: its source was deleted (the app's data made anew) - bound again"; m umount -l "$2" || break
  done
  m grep -q " $2 " /proc/mounts || m mount --bind "$1" "$2"
}
m mkdir -p "$R/run/powos-app"
appbind "$RUN" "$R/run/powos-app"
# The launcher's widgets and styles, at the place its agents work on them (~/.config/omalauncher, as in the no-root
# guest): PowOS AI - the launcher's agent in a PowOS session - and the PowOS shell edit the very files the launcher
# draws. The app's files are the run dir's parent; powos owns them (its uid is the app's).
for d in widgets style; do
  m mkdir -p "$R/home/powos/.config/omalauncher/$d" "${RUN%/run}/$d"
  appbind "${RUN%/run}/$d" "$R/home/powos/.config/omalauncher/$d"
done
# PowOS apps' installed bundles (`powos app install`: ~/.local/share/powos/apps/<id>/<version>/, a `current` link) are
# the app's files/apps, which the shell serves (https://shell.powos/_app/<id>/) and watches for UI hot reload.
F=${RUN%/run}
U=$(stat -c %u "$F")
A=$R/home/powos/.local/share/powos/apps
m mkdir -p "$A" "$F/apps"
m chown "$U:$U" "$R/home/powos/.local" "$R/home/powos/.local/share" "$R/home/powos/.local/share/powos" "$A" "$F/apps"
appbind "$F/apps" "$A"

# Reattach: a healthy session keeps running (the app was updated or killed, not the session). Its KWin dials this app's
# new display daemon itself; the splash only needs desktop-ready again (the new app process deletes it: SplashScreen).
if [ -z "${POWOS_SESSION_RESTART:-}" ] && why=$(healthy "$RUN"); then
  echo "reattach: $why - no new session"
  # HACK: desktop-ready touched again a few times: the new app's SplashScreen deletes it when its activity comes up,
  # which may be after this. Real fix: the splash asks whether the session is up (wayland-0 + KWin connected to the
  # daemon) instead of trusting a file only a session start writes.
  ( for t in 0 2 5 10; do sleep $t; touch "$RUN/desktop-ready"; chown "$(stat -c %u "$RUN")" "$RUN/desktop-ready"; done ) \
    > /dev/null 2>&1 < /dev/null &
  exit 0
fi
[ -n "${POWOS_SESSION_RESTART:-}" ] && echo "restart requested" || echo "new session: $why"

# The display socket as PowOS sees it: "@name" is in the abstract namespace (the app's SessionService.DISPLAY_SOCKET),
# shared with the app as is; a socket file in the run dir is at /run/powos-app.
case $SOCK in
  @*) sock=$SOCK ;;
  *)  sock=/run/powos-app/${SOCK#$RUN/} ;;
esac

# Hardware video (VA-API through Mesa's termuxva driver -> Android's MediaCodec): the app's termux-va daemon <termux-va>,
# run here as root on Android's side, listening on <run dir>/termux-va.sock (/run/powos-app/termux-va.sock in PowOS,
# powos-rooted-session). Not run by the app: Mesa's client only connects to a socket file, and as a privileged app the
# app may not make one in its data (SELinux); root may. It lives as long as this session (this shell's pid survives the
# execs below) and is replaced by the next one.
if [ -n "$TVA" ] && [ -x "$TVA" ]; then
  old=$(cat /data/powos/termux-va.pid 2>/dev/null)
  [ -n "$old" ] && grep -q libtermuxva "/proc/$old/cmdline" 2>/dev/null && kill "$old"
  "$TVA" --sock "$RUN/termux-va.sock" > "$RUN/termux-va.log" 2>&1 < /dev/null &
  tva=$!
  echo $tva > /data/powos/termux-va.pid
  ( while kill -0 $$ 2>/dev/null; do sleep 10; done; kill $tva 2>/dev/null ) > /dev/null 2>&1 < /dev/null &
fi
# PowOS as the real root of its own mount namespace (pivot_root), not a chroot: Linux refuses user namespaces inside
# a chroot ("unshare: Operation not permitted"), and Steam (pressure-vessel/bubblewrap), Flatpak and rootless podman
# need them. Made private first (pivot_root fails on shared mounts); PowOS's own mount/pivot_root, through its
# loader: Android's toybox has no pivot_root and no --make-rprivate. powos-rooted-session detaches /.oldroot.
export L="$R/usr/lib/ld-linux-aarch64.so.1 --library-path $R/usr/lib" R
# Desktop mode (docs/DESKTOP-KWIN-NATIVE.md phase 1): the session's powos-desktop-shell start --auto reads it.
DESKTOP_MODE_=$(settings get global powos_desktop_mode 2>/dev/null); case "$DESKTOP_MODE_" in 1) ;; *) DESKTOP_MODE_=0 ;; esac
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
  ANDROMARCHY_SOCKET="$sock" ANDROMARCHY_PHYSICAL_MM="$MM" POWOS_DESKTOP_MODE="$DESKTOP_MODE_" \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/powos-app/bus \
  DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/powos-app/system_bus \
  XDG_DATA_DIRS=/run/powos-app/share:/home/powos/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share \
  /usr/bin/powos-rooted-session
