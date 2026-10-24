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
# The app's data kept safe (backup/restore/rebase + the hourly light backup powos-start.sh starts); the idle re-base
# runner, which refuses without it. Never `pm uninstall-system-updates com.powos.app` by hand: it wipes the app's data.
install -m 755 $T/powos-appdata.sh /data/powos/powos-appdata.sh
install -m 755 $T/powos-idle-sysupdate.sh /data/powos/powos-idle-sysupdate.sh
# `powos units` for Android's side (Magisk, /data/powos, /data/local/tmp), PowOS's python run from there.
install -m 755 $T/powos-units.sh /data/powos/powos-units.sh
# The VPN client kept running while the phone rests (unit vpn-keep): applied now, and at every boot by powos-start.sh.
install -m 755 $T/powos-vpn-keep.sh /data/powos/powos-vpn-keep.sh
sh /data/powos/powos-vpn-keep.sh apply || true
install -m 755 $T/powos-rooted-session $R/usr/bin/powos-rooted-session
install -m 755 $T/powos-android-app $R/usr/local/bin/powos-android-app
install -m 755 $T/powos-android-tasks $R/usr/local/bin/powos-android-tasks
# PowOS's apps for Android: the PowOS app's drawer, search and Android shortcuts (it runs this, rooted mode).
install -m 755 $T/powos-apps-export $R/usr/local/bin/powos-apps-export
# ...kept current when kded6 rebuilds KSycoca (inotify, nothing polls), and Plasma itself as an app in that drawer.
install -m 755 $T/powos-apps-watch $R/usr/local/bin/powos-apps-watch
install -m 644 $T/powos-apps-watch.desktop $R/etc/xdg/autostart/powos-apps-watch.desktop
install -Dm 644 $T/powos-plasma/org.powos.plasma.desktop $R/usr/share/applications/org.powos.plasma.desktop
# Plasma's notifications in PowOS's shade and the clipboard both ways (D-Bus signals + inotify, nothing polls).
install -m 755 $T/powos-plasma-bridge $R/usr/local/bin/powos-plasma-bridge
install -m 644 $T/powos-plasma-bridge.desktop $R/etc/xdg/autostart/powos-plasma-bridge.desktop
# A PowOS app tapped on Android opens in its own Android task, like a phone app (the PowOS app runs this).
install -m 755 $T/powos-open-task $R/usr/local/bin/powos-open-task
install -m 644 $T/powos-android-tasks.desktop $R/etc/xdg/autostart/powos-android-tasks.desktop
# Linux apps the size of Android apps' windows: the output scale, set once by the session (powos-rooted-session) - and
# here in the running session, once (it does nothing after its first run: the scale is the user's then).
install -m 755 $T/powos-output-scale $R/usr/local/bin/powos-output-scale
[ -f /data/powos/session.pid ] && WAYLAND_DISPLAY=wayland-0 sh /data/powos/powos-run.sh powos-output-scale || true
# The session's NetworkManager stand-in (Andromarchy's, with the D-Bus ObjectManager libnm needs: without it libnm saw
# no NetworkManager and Steam's login waited 10-20 s for a network at every start). A changed one replaces the running
# one at once, with the environment the session gave it (powos-rooted-session starts it as root on the system bus).
if ! cmp -s $T/android-nm $R/usr/local/bin/android-nm; then
  install -m 755 $T/android-nm $R/usr/local/bin/android-nm
  if pkill -f 'python3 /usr/local/bin/android-nm' 2>/dev/null; then
    chroot $R /usr/bin/env -i HOME=/home/powos XDG_RUNTIME_DIR=/run/powos-app PATH=/usr/local/bin:/usr/bin:/usr/sbin \
      DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/powos-app/system_bus DBUS_SESSION_BUS_ADDRESS=unix:path=/run/powos-app/bus \
      setsid -f sh -c 'exec android-nm >> /run/powos-app/android-nm.log 2>&1' < /dev/null > /dev/null 2>&1
  fi
fi
# The phone's controller (Steam Deck over uhid) and the focus watcher, which the session starts (powos-rooted-session).
install -m 755 $T/powos-padd $R/usr/bin/powos-padd
install -m 755 $T/powos-focus-watch $R/usr/bin/powos-focus-watch
# Android's keyboard for X11 apps' text fields (unit x11-ime-bridge): IBus with powos-ime-bridge as its panel, started
# by the session's autostart (ours replaces the image's ibus.desktop), and the IBus environment for every app.
install -m 755 $T/powos-ime-bridge $R/usr/bin/powos-ime-bridge
install -Dm 644 $T/powos-ime-bridge.desktop $R/etc/xdg/autostart/ibus.desktop
install -Dm 644 $T/powos-plasma/powos-ime.sh $R/etc/xdg/plasma-workspace/env/ibus.sh
install -Dm 644 $T/powos-plasma/powos-ime.sh $R/etc/profile.d/60-powos-ime.sh
# The panel's launcher as the full-screen app grid (Application Dashboard), once per user (bin/powos-panel-phone;
# KWin's swipe-up on the desktop/taskbar opens the same launcher). Part of the PowOS image; installed here too so a
# rooted phone whose rootfs came from an older image has it.
install -m 755 $T/powos-panel-phone $R/usr/bin/powos-panel-phone
install -m 644 $T/powos-panel-phone.desktop $R/etc/xdg/autostart/powos-panel-phone.desktop
# The terminals' tmux shell (the launcher's terminal tiles and PowOS's terminals).
install -m 755 $T/powos-tmux-shell $R/usr/lib/powos/powos-tmux-shell
# Left twice on an empty prompt in a tmux session: back to its session picker (config/etc/profile.d, as the image).
install -Dm 644 $T/60-powos-picker-key.sh $R/etc/profile.d/60-powos-picker-key.sh
rm -f $T/powos-panel-phone $T/powos-panel-phone.desktop $T/powos-tmux-shell $T/60-powos-picker-key.sh
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
# Window edges a finger can grab (see the file).
install -Dm 644 $T/powos-plasma/breezerc $R/etc/xdg/breezerc
# No KDE splash under the app's own (as install-powos-android.sh; a rootfs from an older image lacks it).
printf '[KSplash]\nEngine=none\nTheme=None\n' > $R/etc/xdg/ksplashrc
rm -rf $T/powos-plasma
# PowOS's desktop widgets, as the image installs them (Containerfile: desktop/plasmoid -> /usr/share/plasma/plasmoids).
# powos-units: /data/powos/root/usr/share/plasma/plasmoids/com.powos.*
cp -a $T/powos-plasmoids/. $R/usr/share/plasma/plasmoids/
rm -rf $T/powos-plasmoids
# FEX's config (as the fex-emu package installs it): RootFS + thunks, GPU on, ALSA off (see pkgs/fex-emu/PKGBUILD).
install -Dm644 $T/fex-Config.json $R/usr/share/fex-emu/Config.json
install -Dm644 $T/fex-thunks.json $R/usr/share/fex-emu/thunks.json
rm -f $T/fex-Config.json $T/fex-thunks.json
rm -f $T/powos-start.sh $T/powos-session.sh $T/powos-run.sh $T/powos-rooted-session $T/powos-android-app $T/powos-android-tasks \
  $T/powos-units.sh $T/powos-vpn-keep.sh \
  $T/powos-android-tasks.desktop $T/powos-padd $T/powos-focus-watch $T/powos-apps-export $T/powos-open-task \
  $T/powos-apps-watch $T/powos-apps-watch.desktop $T/powos-plasma-bridge $T/powos-plasma-bridge.desktop \
  $T/powos-ime-bridge $T/powos-ime-bridge.desktop $T/powos-output-scale $T/android-nm

# The user: powos, as on every PowOS (password powos, sudo through wheel). Its uid is the PowOS app's Android uid:
# the app's run dir (display socket, phone state) is then the user's own, as XDG_RUNTIME_DIR should be. Re-run
# after reinstalling the app (new Android uid). Arch Linux ARM's default user alarm goes, as in the VM build.
# Steam Input gives a game the controller as its own virtual pad, written to /dev/uinput; on Android that is
# root:uhid 0660 (SteamOS lets the desktop user write it, by udev rule; there's no udev here). So powos joins a group
# "uhid" with Android's gid - Android's node stays as it is. Without it Steam logs "Couldn't initialize virtual
# gamepad: Couldn't open /dev/uinput for writing" and games get no controller.
# The same for the game's side: the pad Steam Input writes to /dev/uinput turns up as /dev/input/eventN, created by
# Android's kernel as root:input(Android's gid 1004) 0660 - and games (Proton's winebus/SDL, native SDL) open that
# node as powos. With no udev to hand it over, PowOS's "input" group takes Android's input gid, so powos (in it, as on
# any desktop) can read every pad node the moment it appears. Without it Steam shows the controller, but games see
# none ("controller doesn't do anything in games", 2026-10-20). Running processes keep their old groups: restart Steam.
U=$(stat -c %u /data/data/com.powos.app)
UHID=$(stat -c %g /dev/uinput)
INPUT=$(stat -c %g /dev/input/event0)
chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/bash -s "$U" "$UHID" "$INPUT" <<'EOF'
u=$1 uhid=$2 input=$3
getent group uhid >/dev/null || groupadd -g "$uhid" uhid
[ "$(getent group uhid | cut -d: -f3)" = "$uhid" ] || groupmod -g "$uhid" uhid
getent group input >/dev/null || groupadd -g "$input" input
old=$(getent group input | cut -d: -f3)
if [ "$old" != "$input" ]; then
  groupmod -g "$input" input
  find / -xdev -gid "$old" -exec chgrp -h input {} + 2>/dev/null   # files that had the old number
fi
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
# The Agents view's reporter (lib/ai/agents, docs/AGENTS-VIEW-DESIGN.md Phase 1): the hook and powos-agentsd, and
# comms writing the view's feed. The hooks go into the powos user's own Claude settings, next to whatever is there
# (install-hooks.py keeps the rest; a backup of the file as it was, once), so every claude in PowOS reports - the
# manager and hand-started sessions alike. Async: they never hold a tool call up - but for the approval hook
# (powos-agent-ask: Allow / Deny from the phone), which waits up to 60 s for an answer and then lets Claude ask at its
# terminal as it would have. Undo: install-hooks.py ... --remove.
A=$R/usr/lib/powos/ai/agents
mkdir -p $A
install -m 755 $T/powos-agents/powos-agent-hook $T/powos-agents/powos-agent-ask $T/powos-agents/powos-agentsd \
  $T/powos-agents/install-hooks.py $T/powos-agents/powos-agents-cli $A/
install -m 644 $T/powos-agents/claude-hooks.json $A/claude-hooks.json
install -m 755 $T/comms-mcp.py $R/usr/lib/powos/ai/comms/comms-mcp.py
# The manager (unit ai-manager): PowOS AI's chat starts a turn of it per message.
if [ -d $T/powos-manager ]; then
  mkdir -p $R/usr/lib/powos/ai/manager
  install -m 644 $T/powos-manager/manager.py $T/powos-manager/manager.sh $R/usr/lib/powos/ai/manager/
fi
rm -rf $T/powos-agents $T/comms-mcp.py $T/powos-manager
# The manager's TypeScript sandbox (unit ai-sandbox): its sources plus its deps from its lock, which rooted.sh built
# (sandbox.sh setup, stamped) - unpacked beside the old one, then swapped in whole (a running sandbox server keeps
# what it loaded). PowOS's bun runs it; manager.sh wires it in when `powos sandbox status` says deps ok.
# powos-units: /data/powos/root/usr/lib/powos/ai/sandbox
if [ -f $T/powos-sandbox.tar.gz ]; then
  S=$R/usr/lib/powos/ai
  rm -rf $S/.sandbox.new $S/.sandbox.old && mkdir -p $S/.sandbox.new
  if tar -xzf $T/powos-sandbox.tar.gz -C $S/.sandbox.new && [ -f $S/.sandbox.new/sandbox/node_modules/.powos-lock ]; then
    chown -R 0:0 $S/.sandbox.new && chmod -R a+rX,go-w $S/.sandbox.new
    [ -d $S/sandbox ] && mv $S/sandbox $S/.sandbox.old
    mv $S/.sandbox.new/sandbox $S/sandbox
    echo "sandbox: $(du -sh $S/sandbox | cut -f1) in /usr/lib/powos/ai/sandbox"
  else
    echo "sandbox: the tarball didn't unpack - the old one kept"
  fi
  rm -rf $S/.sandbox.new $S/.sandbox.old $T/powos-sandbox.tar.gz
fi
# App API's runtime (unit app-api, docs/APP-API-CAPTURE.md 1b.0): appcap_*.py and the example specs, run by the system
# tier's app-api service (lib/apps/services/app-api.json: appcap_serve.py on 127.0.0.1:3411, port-locked).
if [ -d $T/powos-app-api ]; then
  rm -rf $R/usr/lib/powos/app-api && mkdir -p $R/usr/lib/powos/app-api/examples
  install -m 644 $T/powos-app-api/*.py $R/usr/lib/powos/app-api/
  install -m 644 $T/powos-app-api/examples/*.appcap.json $R/usr/lib/powos/app-api/examples/
  rm -rf $T/powos-app-api
fi
chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin /usr/bin/setpriv --reuid=powos --regid=powos --init-groups -- \
  /usr/bin/env HOME=/home/powos python3 /usr/lib/powos/ai/agents/install-hooks.py /home/powos/.claude/settings.json \
  --command "POWOS_AGENTS_HOST=phone /usr/lib/powos/ai/agents/powos-agent-hook" \
  --ask "POWOS_AGENTS_HOST=phone /usr/lib/powos/ai/agents/powos-agent-ask" \
  --backup /home/powos/.claude/settings.json.bak-agents-view
# PowOS apps (docs/POWOS-APPS-FEASIBILITY.md): SpacetimeDB (our package of the official aarch64 binaries, pinned), the
# runtime switch + the system tier's supervisor + the app CLI (lib/apps -> /usr/lib/powos/apps), the service manifests,
# the registry's module, and the CLI's front doors (`powos app`, `powos config app-runtime`). The system tier starts
# from powos-start.sh (at boot, and now); its data and settings are the user's, under /var/lib/powos.
A=$T/powos-apps
# older <pkgname> <file>: true when <file> is older than the installed <pkgname>. A deploy installs the newest build in
# ITS checkout's out/pkgs, which can be an old one: it downgraded xwayland-kgsl 24.1.13-2 -> -1 (friction f29,
# 2026-10-23). Never downgrade here; POWOS_ALLOW_DOWNGRADE=1 to mean it.
older() {
  local have want; have=$(chroot $R /usr/bin/pacman -Q "$1" 2>/dev/null | cut -d' ' -f2); [ -n "$have" ] || return 1
  want=$(basename "$2" | sed -E "s/^$1-//; s/-[^-]+\.pkg\.tar\..*$//")
  [ "${POWOS_ALLOW_DOWNGRADE:-0}" != 1 ] && [ "$(chroot $R /usr/bin/vercmp "$want" "$have")" -lt 0 ] &&
    echo "$1: keeping $have (this deploy's package is older: $want)"
}
if [ -d $A ]; then
  # powos-units: pkg:spacetimedb
  for p in $A/spacetimedb-*.pkg.tar.*; do
    [ -e "$p" ] || continue; older spacetimedb "$p" && continue
    # --ask 4: the patched build replaces spacetimedb-bin (pacman's "remove the conflicting package?" answered yes).
    cp "$p" $R/tmp/ && chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/sh -c "pacman -U --noconfirm --ask 4 --needed /tmp/${p##*/} >/dev/null && rm -f /tmp/${p##*/}" &&
      echo "spacetimedb: $(chroot $R /usr/bin/spacetime --version 2>/dev/null | head -1)"
  done
  # The desktop's Xwayland, our package (pkgs/xwayland-kgsl), in /usr/local/bin ahead of Arch's: --overwrite takes over
  # the copy an older rootfs's build left there unowned. The running session keeps its Xwayland until it restarts.
  # powos-units: pkg:xwayland-kgsl
  for p in $A/xwayland-kgsl-*.pkg.tar.*; do
    [ -e "$p" ] || continue; older xwayland-kgsl "$p" && continue
    cp "$p" $R/tmp/ && chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/sh -c "pacman -U --noconfirm --needed --overwrite /usr/local/bin/Xwayland /tmp/${p##*/} >/dev/null && rm -f /tmp/${p##*/}" &&
      echo "xwayland-kgsl: $(chroot $R /usr/bin/pacman -Q xwayland-kgsl 2>/dev/null)"
  done
  # KWin, our package (pkgs/kwin: the Anland backend). The running session keeps its KWin until it restarts.
  # powos-units: pkg:kwin
  for p in $A/kwin-*.pkg.tar.*; do
    [ -e "$p" ] || continue; older kwin "$p" && continue
    cp "$p" $R/tmp/ && chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/sh -c "pacman -U --noconfirm --needed /tmp/${p##*/} >/dev/null && rm -f /tmp/${p##*/}" &&
      echo "kwin: $(chroot $R /usr/bin/pacman -Q kwin 2>/dev/null)"
  done
  L=$R/usr/lib/powos/apps
  mkdir -p $L/services $L/registry
  # powos-container: containers with hard limits in Android's cgroups (docs/PHONE-KERNEL-CONTAINERS.md section 12;
  # `powos containers run`, the runtime's container mode). It installs its OCI hooks itself on first use.
  # powos-units: /data/powos/root/usr/lib/powos/apps/powos-runtime /data/powos/root/usr/lib/powos/apps/powos-supervisor /data/powos/root/usr/lib/powos/apps/powos-app /data/powos/root/usr/lib/powos/apps/powos-container /data/powos/root/usr/lib/powos/apps/powos-units /data/powos/root/usr/bin/powos-runtime /data/powos/root/usr/bin/powos-supervisor /data/powos/root/usr/bin/powos-app /data/powos/root/usr/bin/powos-container /data/powos/root/usr/bin/powos-units
  for f in powos-runtime powos-supervisor powos-app powos-container powos-units; do install -m 755 $A/$f $L/$f; ln -sf /usr/lib/powos/apps/$f $R/usr/bin/$f; done
  # powos-container's autosleep (section 13) and the never-sleep list + manifest key every sleeper shares: modules,
  # loaded from next to powos-container. Their unit manifests come with the rest (units/phone, below).
  for f in powos-autosleep powos-sleep-common; do install -m 755 $A/$f $L/$f; done
  # Unified sleep (docs/UNIFIED-SLEEP.md): `powos sleep`, the system-tier sleeper (powos-start.sh starts it) and the
  # session's GUI watcher with its KWin script (powos-rooted-session starts it).
  for f in powos-sleep powos-sleepd powos-sleep-gui; do install -m 755 $A/$f $L/$f; done
  # `powos glasses` (docs/GLASSES.md): the smart glasses the app drives, through its run dir.
  install -m 755 $A/powos-glasses $L/powos-glasses
  # `powos pet` (the pet on home, the local.pet app): speaks through the app's module.
  install -m 755 $A/powos-pet $L/powos-pet
  # `powos compose` (docs/COMPOSER.md): widgets made from building blocks, and the one module every composition runs
  # (apps/composed: its source, and its build when rooted.sh had one - then nothing builds per composition).
  install -m 755 $A/powos-compose $L/powos-compose
  if [ -d $A/composed ]; then rm -rf $L/composed && cp -r $A/composed $L/composed && chmod -R a+rX $L/composed; fi
  # powos-units: /data/powos/root/usr/bin/powos-sleepd /data/powos/root/usr/bin/powos-sleep-gui
  for f in powos-sleepd powos-sleep-gui; do ln -sf /usr/lib/powos/apps/$f $R/usr/bin/$f; done
  rm -rf $L/sleep && cp -r $A/sleep $L/sleep && chmod -R a+rX $L/sleep
  # Their unit manifests come with the rest (units/phone, below).
  install -m 644 $A/services/*.json $L/services/
  # `powos app new`'s templates (lib/apps/templates).
  if [ -d $A/templates ]; then rm -rf $L/templates && cp -r $A/templates $L/templates && chmod -R a+rX $L/templates; fi
  [ -f $A/registry.wasm ] && install -m 644 $A/registry.wasm $L/registry/module.wasm
  install -m 755 $A/powos $R/usr/bin/powos
  install -m 644 $A/config.sh $R/usr/lib/powos/config.sh
  U=$(stat -c %u /data/data/com.powos.app)
  for d in /var/lib/powos/runtime /var/lib/powos/stdb /var/lib/powos/sleep; do mkdir -p $R$d && chown $U:$U $R$d; done
  mkdir -p $R/var/log/powos
  rm -rf $A
fi
# The units (lib/apps/powos-units): every file and process this deploy put on the phone, registered with its owner,
# purpose, limits and how to remove it - PowOS's side in /etc/powos/units.d, Android's in /data/powos/units.d. Then the
# running ones with limits go into cgroups of their own (the containers' hybrid cgroups). `powos units check` flags
# whatever has no unit (test/tier1/test-units-registry.sh: a deploy that installs without one fails).
U=$T/powos-units
if [ -d $U ]; then
  mkdir -p $R/etc/powos/units.d /data/powos/units.d
  install -m 644 $U/phone/*.json $R/etc/powos/units.d/
  install -m 644 $U/phone-android/*.json /data/powos/units.d/
  rm -rf $U
  chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin python3 /usr/lib/powos/apps/powos-units enforce || true
  sh /data/powos/powos-units.sh enforce || true
  chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin python3 /usr/lib/powos/apps/powos-units publish || true
  sh /data/powos/powos-units.sh publish || true
fi
resetprop -p persist.powos.root 1
echo "deployed (persist.powos.root=$(getprop persist.powos.root))"
