#!/system/bin/sh
# Installs the rooted-mode scripts pushed to /data/local/tmp by `rooted.sh deploy` (run as root on the phone).
#   /data/powos/powos-start.sh + /data/adb/service.d/powos.sh   mounts + sshd, at every boot
#   /data/powos/powos-session.sh                                the desktop session the PowOS app starts (rooted mode)
#   /data/powos/root/usr/bin/powos-rooted-session               its part inside PowOS
# Plus: patches/andromarchy/0004 for an already installed rootfs (the no-root sudo shim runs commands directly when
# it is real root), and the flag the PowOS app checks for rooted mode (persist.powos.root=1, Magisk's resetprop -p).
set -e
T=/data/local/tmp
R=/data/powos/root
install -m 755 $T/powos-start.sh /data/powos/powos-start.sh
mkdir -p /data/adb/service.d
install -m 755 $T/powos-start.sh /data/adb/service.d/powos.sh
install -m 755 $T/powos-session.sh /data/powos/powos-session.sh
install -m 755 $T/powos-run.sh /data/powos/powos-run.sh
install -m 755 $T/powos-rooted-session $R/usr/bin/powos-rooted-session
install -m 755 $T/powos-android-app $R/usr/local/bin/powos-android-app
install -m 755 $T/powos-android-tasks $R/usr/local/bin/powos-android-tasks
install -m 644 $T/powos-android-tasks.desktop $R/etc/xdg/autostart/powos-android-tasks.desktop
# The phone's controller (Steam Deck over uhid) and the focus watcher, which the session starts (powos-rooted-session).
install -m 755 $T/powos-padd $R/usr/bin/powos-padd
install -m 755 $T/powos-focus-watch $R/usr/bin/powos-focus-watch
# The panel's launcher as the full-screen app grid (Application Dashboard), once per user (bin/powos-panel-phone;
# KWin's swipe-up on the desktop/taskbar opens the same launcher). Part of the PowOS image; installed here too so a
# rooted phone whose rootfs came from an older image has it.
install -m 755 $T/powos-panel-phone $R/usr/bin/powos-panel-phone
install -m 644 $T/powos-panel-phone.desktop $R/etc/xdg/autostart/powos-panel-phone.desktop
# The terminals' tmux shell (the launcher's terminal tiles and PowOS's terminals).
install -m 755 $T/powos-tmux-shell $R/usr/lib/powos/powos-tmux-shell
rm -f $T/powos-panel-phone $T/powos-panel-phone.desktop $T/powos-tmux-shell
# The desktop over Android's wallpaper (as install-powos-android.sh): transparent wallpaper + its update script.
W=$R/usr/share/plasma/wallpapers/org.powos.transparent
install -Dm 644 $T/powos-plasma/org.powos.transparent/metadata.json $W/metadata.json
install -Dm 644 $T/powos-plasma/org.powos.transparent/contents/ui/main.qml $W/contents/ui/main.qml
install -Dm 644 $T/powos-plasma/powos-transparent-desktop.js \
  $R/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/powos-transparent-desktop.js
# The phone's Android apps as a category of their own in the application menu (as install-powos-android.sh).
install -Dm 644 $T/powos-plasma/menus/powos-android.menu $R/etc/xdg/menus/applications-merged/powos-android.menu
install -Dm 644 $T/powos-plasma/menus/powos-android.directory $R/usr/share/desktop-directories/powos-android.directory
K=$R/usr/share/kwin/scripts/powos-translucent-desktop
install -Dm 644 $T/powos-plasma/powos-translucent-desktop/metadata.json $K/metadata.json
install -Dm 644 $T/powos-plasma/powos-translucent-desktop/contents/code/main.js $K/contents/code/main.js
rm -rf $T/powos-plasma
# FEX's config (as the fex-emu package installs it): RootFS + thunks, GPU on, ALSA off (see pkgs/fex-emu/PKGBUILD).
install -Dm644 $T/fex-Config.json $R/usr/share/fex-emu/Config.json
install -Dm644 $T/fex-thunks.json $R/usr/share/fex-emu/thunks.json
rm -f $T/fex-Config.json $T/fex-thunks.json
rm -f $T/powos-start.sh $T/powos-session.sh $T/powos-run.sh $T/powos-rooted-session $T/powos-android-app $T/powos-android-tasks \
  $T/powos-android-tasks.desktop $T/powos-padd $T/powos-focus-watch

# The user: powos, as on every PowOS (password powos, sudo through wheel). Its uid is the PowOS app's Android uid:
# the app's run dir (display socket, phone state) is then the user's own, as XDG_RUNTIME_DIR should be. Re-run
# after reinstalling the app (new Android uid). Arch Linux ARM's default user alarm goes, as in the VM build.
# Steam Input gives a game the controller as its own virtual pad, written to /dev/uinput; on Android that is
# root:uhid 0660 (SteamOS lets the desktop user write it, by udev rule; there's no udev here). So powos joins a group
# "uhid" with Android's gid - Android's node stays as it is. Without it Steam logs "Couldn't initialize virtual
# gamepad: Couldn't open /dev/uinput for writing" and games get no controller.
U=$(stat -c %u /data/data/com.powos.app)
UHID=$(stat -c %g /dev/uinput)
chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/bash -s "$U" "$UHID" <<'EOF'
u=$1 uhid=$2
getent group uhid >/dev/null || groupadd -g "$uhid" uhid
[ "$(getent group uhid | cut -d: -f3)" = "$uhid" ] || groupmod -g "$uhid" uhid
id alarm >/dev/null 2>&1 && userdel -r alarm 2>/dev/null
sed -i "/^android:x:$u:/d" /etc/passwd            # the no-root engine's name for the app uid (session/first-boot.sh)
getent group powos >/dev/null || groupadd -g "$u" powos
[ "$(getent group powos | cut -d: -f3)" = "$u" ] || groupmod -g "$u" powos
if ! id powos >/dev/null 2>&1; then
  useradd -m -u "$u" -g powos -s /bin/bash powos && echo powos:powos | chpasswd
elif [ "$(id -u powos)" != "$u" ]; then
  usermod -u "$u" powos
fi
usermod -aG wheel,video,audio,input,uhid powos
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel && chmod 440 /etc/sudoers.d/10-wheel
echo "user powos uid $u"
EOF

# Android apps as PowOS windows (powos-android-app: scrcpy through adb to the phone itself, 127.0.0.1:5555 - adbd
# listens there with persist.adb.tcp.port, rooted.sh wifi). The phone never shows its "Allow USB debugging?" prompt
# for a connection from itself, so PowOS's adb key is authorized here directly (the same as "Always allow";
# revoke: remove its line from /data/misc/adb/adb_keys).
chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/bash -c '
  pacman -Q scrcpy android-tools pyside6 foot fzf ibus libnm openal >/dev/null 2>&1 || pacman -S --noconfirm --needed scrcpy android-tools pyside6 foot fzf ibus libnm openal >/dev/null
  [ -f /home/powos/.android/adbkey.pub ] || setpriv --reuid=powos --regid=powos --init-groups -- \
    env HOME=/home/powos adb keygen /home/powos/.android/adbkey >/dev/null 2>&1'
K=$R/home/powos/.android/adbkey.pub
if [ -f $K ] && ! grep -qF "$(cat $K)" /data/misc/adb/adb_keys 2>/dev/null; then
  { cat $K; echo; } >> /data/misc/adb/adb_keys && chown system:shell /data/misc/adb/adb_keys && chmod 640 /data/misc/adb/adb_keys
  echo "adb: PowOS's key authorized"
fi
[ "$(getprop persist.adb.tcp.port)" = 5555 ] || setprop persist.adb.tcp.port 5555

# Rootless containers (podman/distrobox) as powos: newuidmap/newgidmap need their file capabilities (Arch ships them
# with setcap; the rootfs tarball lost them), and podman must leave cgroups alone (Android owns /sys/fs/cgroup) and
# log to a file (no journald).
chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/sh -c '
  pacman -Q podman distrobox fuse-overlayfs >/dev/null 2>&1 ||
    pacman -S --noconfirm --needed podman distrobox fuse-overlayfs >/dev/null
  setcap cap_setuid+ep /usr/bin/newuidmap && setcap cap_setgid+ep /usr/bin/newgidmap'
# distrobox shares the host's PID namespace by default, which podman refuses without cgroups: its own instead.
mkdir -p $R/etc/distrobox
grep -qs '^unshare_process=1' $R/etc/distrobox/distrobox.conf ||
  printf '%s\n' '# PowOS rooted mode (rooted/powos-deploy.sh): no cgroups for containers -> a private PID namespace.' \
    'unshare_process=1' >> $R/etc/distrobox/distrobox.conf
# The kernel refuses rootless overlayfs on Android's f2fs data partition; fuse-overlayfs does the same in userspace.
C=$R/home/powos/.config/containers
mkdir -p $C && printf '%s\n' '# PowOS rooted mode (rooted/powos-deploy.sh): no rootless kernel overlayfs on f2fs.' \
  '[storage]' 'driver = "overlay"' '[storage.options.overlay]' 'mount_program = "/usr/bin/fuse-overlayfs"' \
  > $C/storage.conf && chown -R $U:$U $R/home/powos/.config
mkdir -p $R/etc/containers/containers.conf.d
printf '%s\n' '# PowOS rooted mode on Android (rooted/powos-deploy.sh): Android owns the cgroups; no journald.' \
  '[containers]' 'cgroups = "disabled"' '# /dev/net/tun is Android'"'"'s VPN device (not for apps): containers use the phone'"'"'s network.' 'netns = "host"' '# No IPC namespace without System V IPC (Android'"'"'s kernel has neither).' 'ipcns = "host"' 'log_driver = "k8s-file"' '[engine]' 'cgroup_manager = "cgroupfs"' 'events_logger = "file"' \
  > $R/etc/containers/containers.conf.d/50-powos-phone.conf

# The no-root engine's sudo shim (fakeroot) first on PATH would shadow the real sudo: rooted mode has real root.
# Moved aside, not deleted; the no-root app's own rootfs keeps it.
S=$R/usr/local/bin/sudo
[ -f $S ] && mv $S $S.noroot-engine && echo "sudo: real sudo (shim moved to $S.noroot-engine)"
# Same for bubblewrap (Steam's pressure-vessel, Flatpak): the no-root engine's bwrap stand-in replaced
# /usr/bin/bwrap with a link to it; rooted mode has user namespaces (powos-session.sh: pivot_root, and a kernel with
# CONFIG_USER_NS - targets/native/config/gki/namespaces.config), so the real one goes back.
B=$R/usr/local/bin/bwrap
if [ -f $B ] || [ ! -e $R/usr/bin/bwrap ]; then
  [ -f $B ] && mv $B $B.noroot-engine
  rm -f $R/usr/bin/bwrap
  sed -i '/^NoExtract = usr\/bin\/bwrap$/d' $R/etc/pacman.conf   # the no-root engine kept pacman from installing it
  # -Sy only if the installed version has left the mirrors (Arch Linux ARM keeps just the current one).
  chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/sh -c \
    'pacman -S --noconfirm bubblewrap >/dev/null 2>&1 || pacman -Sy --noconfirm bubblewrap >/dev/null'
  echo "bwrap: real bubblewrap (shim moved to $B.noroot-engine)"
fi
resetprop -p persist.powos.root 1
echo "deployed (persist.powos.root=$(getprop persist.powos.root))"
