#!/bin/bash
# Installs PowOS into the Android rootfs: everything comes from the published PowOS Deck image's manifest
# (.github/workflows/phone-manifest.yml), mapped by phone-rules.conf; only phone-specific parts are here.
# Runs inside the aarch64 rootfs, called by Andromarchy's build/build-inside.sh at the step where it used to
# install Omarchy (patches/andromarchy/0001-build-inside-powos.patch). Inputs, staged by build-rootfs.sh in $P:
#   manifest/  leaves.tsv, packages.tsv, flatpaks.txt, content.tar.zst, image.txt (tools/fetch-manifest.sh)
#   phone-rules.conf, resolve-packages.py
#   pkgs/      our built packages (kwin with the Anland backend)
#   session/   the session launcher + first-boot/first-session
#   shims/     stand-ins for Omarchy commands Andromarchy's engine calls
#
# POWOS_TARGET=vm installs the same PowOS for a virtual machine instead (targets/web: PowOS in the browser):
# everything but the phone-specific section, plus a kernel and a normal systemd boot. P= points at the inputs.
set -euo pipefail
POWOS_TARGET=${POWOS_TARGET:-phone}
P=${P:-/tmp/lotfix/powos}
L=/tmp/lotfix
C=/etc/pacman.conf
echo "powos: from $(cat $P/manifest/image.txt)"

# ── What the phone session itself needs (not PowOS content: the Plasma session on Android) ─────────────
pacman -S --noconfirm --needed plasma-workspace xdg-desktop-portal-kde kscreen python zstd

# ── Our packages (build-pkgs.sh): KWin with the Anland backend, FEX, and PowOS packages Arch Linux ARM doesn't
# build (recipes.list: upstream recipes built for aarch64). First, so the mapping below finds them.
pacman -U --noconfirm "$P"/pkgs/*.pkg.tar.*

# ── PowOS's packages: EVERY RPM in the image, mapped to Arch by phone-rules.conf ───────────────────────
# Not only the top-level ones: Fedora and Arch split dependencies differently, so Arch's dependency closure of
# the top level missed real PowOS software (embree, mtools, alsa-utils, bluez's tools... found by
# phone-parity.py). The report (what each RPM became, MISSING ones first) stays in the image for review.
mkdir -p /usr/share/powos
# Available = package names plus the names they provide: Arch's perl ships the core modules Fedora splits into
# ~130 perl-* RPMs, tinyxxd provides xxd... (pacman -S installs a provider by such a name).
{ pacman -Slq; pacman -Qq
  LC_ALL=C pacman -Si | awk '/^[A-Za-z][A-Za-z ]* *: / {p = ($1 == "Provides")} p {sub(/^Provides *: */, ""); print}' \
    | tr -s ' ' '\n' | sed 's/[<>=].*//' | grep -v -x -e None -e ''
} | sort -u > /tmp/arch-available.txt
POWOS_TARGET=$POWOS_TARGET python3 $P/resolve-packages.py $P/manifest/packages.tsv $P/phone-rules.conf /tmp/arch-available.txt \
  /tmp/powos-install.txt /usr/share/powos/phone-report.txt
# Ours are installed already (and in no repo, so pacman -S would not find them).
pacman -Qq | sort -u > /tmp/installed.txt
sort -u /tmp/powos-install.txt | comm -23 - /tmp/installed.txt > /tmp/r && mv /tmp/r /tmp/powos-install.txt
# PowOS's choice among alternative providers first (PipeWire for JACK and PulseAudio, as Fedora/PowOS does):
# otherwise a dependency pulls in pacman's default provider (jack2) and pipewire-jack then conflicts with it.
pacman -S --noconfirm --needed --ask 4 pipewire-jack pipewire-pulse
# One transaction first; if any single package breaks it (a conflict, a repo hiccup), the rest still go
# in one by one and the ones that failed are listed at the top of the report.
if ! pacman -S --noconfirm --needed $(cat /tmp/powos-install.txt); then
  for p in $(cat /tmp/powos-install.txt); do
    pacman -S --noconfirm --needed "$p" >/dev/null 2>&1 || echo "FAILED   $p  pacman could not install it" >> /tmp/powos-failed.txt
  done
  [ -s /tmp/powos-failed.txt ] && { cat /tmp/powos-failed.txt /usr/share/powos/phone-report.txt > /tmp/r && mv /tmp/r /usr/share/powos/phone-report.txt; }
fi

# Our KWin (Anland backend) over Arch's, then pinned: pacman must never swap it for Arch's, which has no
# way to draw on Android. HACK: IgnorePkg means Plasma updates need a matching rebuild of our kwin
# (pacman warns about the held package); the real fix is the Anland backend upstream in KWin.
grep -q '^IgnorePkg.*\bkwin\b' $C || sed -i "/^IgnorePkg/ s/$/ kwin/" $C
# Held with it: the kglobalacceld our kwin builds against (see pkgs/kglobalacceld/PKGBUILD).
grep -q '^IgnorePkg.*\bkglobalacceld\b' $C || sed -i "/^IgnorePkg/ s/$/ kglobalacceld/" $C

# FEX: PowOS's Steam (Valve's bootstrapper is 32-bit x86) and x86 games run through it, as on Valve's own ARM
# hardware. The engine's execve hands x86 programs to FEXInterpreter (patches/andromarchy/0002), standing in for
# the binfmt_misc registration an Android app cannot make. FEX's x86 rootfs comes from FEX's own fetcher,
# extracted: no FUSE mounts on Android.
FEXRootFSFetcher -y -x --distro-list-first --force-ui tty
# System-wide, so every user and service finds it: FEX's global config + rootfs location. (The fetcher's own
# "set as default" writes no config in this rootfs; verified on the S25: FEX then saw an empty RootFS path.)
mkdir -p /usr/share/fex-emu/RootFS
for d in ~/.local/share/fex-emu/RootFS/*/; do mv "$d" /usr/share/fex-emu/RootFS/; done
rm -rf ~/.local/share/fex-emu/RootFS
fexroot=$(ls -d /usr/share/fex-emu/RootFS/*/ | head -1)
printf '{"Config":{"RootFS":"%s"}}\n' "${fexroot%/}" > /usr/share/fex-emu/Config.json

# Windows games: powos-play runs a .exe through Proton without Steam's container runtime (pressure-vessel needs
# user namespaces; see play/powos-play). Proton itself (GE-Proton's aarch64 build, ~2 GB) is downloaded on first
# use, not shipped. What ARM64 Wine loads at run time (dlopen, so no package depends on it), and vulkaninfo for
# checking the GPU from a terminal.
pacman -S --noconfirm --needed vulkan-icd-loader vulkan-tools libxinerama libxcomposite libxrandr libxcursor \
  libxi libxkbcommon sdl2-compat gnutls freetype2 fontconfig gst-plugins-base-libs
install -m 755 "$P/play/powos-play" /usr/bin/powos-play
# Steam: Valve's native ARM64 client (play/powos-steam bootstraps it on first use, ~110 MB + its own update).
# What it links that Valve's Steam Runtime would otherwise provide (gtk2 is ours, recipes.list).
pacman -S --noconfirm --needed alsa-lib libasyncns at-spi2-core libcups gdk-pixbuf2 libibus libnm nspr \
  nss openal libpipewire libpulse libsndfile libvdpau libxdamage libxtst libxss
install -m 755 "$P/play/powos-steam" /usr/bin/powos-steam

# ── PowOS's files: everything in the image no package owns (PowOS layer, Bazzite's system_files, Deck
# presets...), architecture-independent only. Unpacked after the packages, as the image's layers sit on top
# of its packages.
# Never over an Arch package's own file (outside /etc, where PowOS's configs are meant to win): the image's
# unowned files can carry Fedora-specific copies of things Arch packages provide (a libgcc_s.so.1 symlink did).
# Nor over a directory an Arch package owns: Fedora's compatibility symlinks can sit where Arch has a real
# directory (usr/share/fonts/noto-cjk -> google-noto-sans-cjk-fonts, vs noto-fonts-cjk's noto-cjk/), and tar
# can't replace one. The content holds only files and symlinks (no directories), so skipping such a path drops
# exactly that one entry.
python3 - "$P/manifest/content.list" > /tmp/powos-content-skip <<'PY'
import glob, sys
owned = set()
for f in glob.glob('/var/lib/pacman/local/*/files'):
    for l in open(f):
        l = l.strip()
        if l and not l.startswith('%'):
            owned.add(l.rstrip('/'))
for l in open(sys.argv[1]):
    l = l.strip()
    if l in owned and not l.startswith('etc/'):
        print(l)
PY
echo "powos: $(wc -l < /tmp/powos-content-skip) content files left to the Arch packages that own them"
zstd -dc $P/manifest/content.tar.zst | tar -x -C / --no-same-owner --exclude-from=/tmp/powos-content-skip
# The PowOS widgets from the checkout being built, over the published image's copies: a widget fix reaches these
# targets with the build instead of waiting for the next image (the content is the image's; widgets are QML only).
[ -d $P/plasmoids ] && cp -a $P/plasmoids/. /usr/share/plasma/plasmoids/
# Keep the phone's PowOS code at the release revision even when the Deck manifest is older.
if [ -d "$P/current" ]; then
  cp -a "$P/current/bin/." /usr/bin/
  mkdir -p /usr/lib/powos
  cp -a "$P/current/lib/." /usr/lib/powos/
  install -Dm644 "$P/current/revision" /usr/share/powos/revision
fi
cp $P/manifest/flatpaks.txt /usr/share/powos/phone-flatpaks.txt

# HACK: bun is an x86 binary the PowOS image puts outside any package (Containerfile curl), so the manifest
# can't carry it; the aarch64 build of the same release. Real fix: the manifest lists such binaries too.
curl -fsSL -o /tmp/bun.zip https://github.com/oven-sh/bun/releases/latest/download/bun-linux-aarch64.zip
bsdtar -xf /tmp/bun.zip -C /tmp && install -m 755 /tmp/bun-linux-aarch64/bun /usr/bin/bun && rm -rf /tmp/bun*
mkdir -p /etc/powos && echo "$POWOS_TARGET" > /etc/powos/platform

if [ "$POWOS_TARGET" = phone ]; then
# ── Phone-specific ──────────────────────────────────────────────────────────────────────────────────────
# No systemd on Android: startplasma must start the session's services itself, not ask systemd to.
mkdir -p /etc/xdg
printf '[General]\nsystemdBoot=false\n' > /etc/xdg/startkderc
# No KDE splash: the PowOS app shows its own while the session starts (SplashScreen), over the desktop's surface;
# ksplashqml only drew on a screen nobody sees, a QML+GPU client competing with plasmashell at startup.
printf '[KSplash]\nEngine=none\nTheme=None\n' > /etc/xdg/ksplashrc
# Android's own lock screen guards the phone; KDE's idle lock on top asked for a password nobody set (the session
# runs as root).
printf '[Daemon]\nAutolock=false\nLockOnResume=false\n' > /etc/xdg/kscreenlockerrc
# Android owns the panel's power and timeout. PowerDevil's idle "turn off screen" can't switch it; it only faded KWin's
# scene to transparent, leaving the Android wallpaper where the desktop was (the default AC profile, i.e. on the charger).
for p in AC Battery LowBattery; do
  printf '[%s][Display]\nDimDisplayWhenIdle=false\nTurnOffDisplayWhenIdle=false\n\n' $p
done > /etc/xdg/powerdevilrc
# The app's user is root with home /root: seed it from /etc/skel as useradd would for a new user.
cp -a /etc/skel/. /root/ 2>/dev/null || true
# The PowOS widgets poll by spawning processes; podman (Containers widget, list + stats every 5 s) takes seconds of CPU
# per call here and kept a core busy. Every 30 s on a battery device.
mkdir -p /etc/powos && echo 'interval_scale=6' > /etc/powos/widgets.conf

# Session + Omarchy-name stand-ins
install -m 755 "$P/session/Hyprland" /usr/bin/Hyprland            # HACK: see the file
install -Dm 755 "$P/session/first-session.sh" /opt/powos/first-session.sh
# Android apps as PowOS windows (scrcpy on a virtual display, through adb to the phone itself; see the file).
pacman -S --noconfirm --needed scrcpy android-tools pyside6
# The PowOS Terminal widget (desktop/plasmoid/com.powos.terminal): its terminal component, Qt 6 build (Fedora, which
# the image comes from, only has a Qt 5 one, so the RPM mapping can't bring it).
pacman -S --noconfirm --needed qmltermwidget
install -m 755 "$P/session/powos-android-app" /usr/local/bin/powos-android-app
# Andromarchy's NetworkManager stand-in with the ObjectManager libnm reads (Steam's login waited 10-20 s without it).
install -m 755 "$P/session/android-nm" /usr/local/bin/android-nm
install -m 755 "$P/session/powos-android-tasks" /usr/local/bin/powos-android-tasks
install -m 755 "$P/session/powos-apps-export" /usr/local/bin/powos-apps-export
install -m 755 "$P/session/powos-apps-watch" /usr/local/bin/powos-apps-watch
install -Dm 644 "$P/session/powos-apps-watch.desktop" /etc/xdg/autostart/powos-apps-watch.desktop
install -m 755 "$P/session/powos-plasma-bridge" /usr/local/bin/powos-plasma-bridge
install -Dm 644 "$P/session/powos-plasma-bridge.desktop" /etc/xdg/autostart/powos-plasma-bridge.desktop
install -Dm 644 "$P/session/plasma/org.powos.plasma.desktop" /usr/share/applications/org.powos.plasma.desktop
install -m 755 "$P/session/powos-open-task" /usr/local/bin/powos-open-task
# The app's touch controls as a gamepad (started by powos-rooted-session).
install -m 755 "$P/session/powos-padd" /usr/bin/powos-padd
install -m 755 "$P/session/powos-focus-watch" /usr/bin/powos-focus-watch
# Android's keyboard for X11 apps' text fields (unit x11-ime-bridge; after the image's content, whose ibus.desktop and
# plasma-workspace env/ibus.sh these replace).
install -m 755 "$P/session/powos-ime-bridge" /usr/bin/powos-ime-bridge
install -Dm 644 "$P/session/powos-ime-bridge.desktop" /etc/xdg/autostart/ibus.desktop
install -Dm 644 "$P/session/plasma/powos-ime.sh" /etc/xdg/plasma-workspace/env/ibus.sh
install -Dm 644 "$P/session/plasma/powos-ime.sh" /etc/profile.d/60-powos-ime.sh
install -Dm 644 "$P/session/powos-android-tasks.desktop" /etc/xdg/autostart/powos-android-tasks.desktop
# The desktop over Android's wallpaper (the app's surface is translucent): a transparent wallpaper, made the desktop's
# once per user by a Plasma update script.
install -Dm 644 "$P/session/plasma/org.powos.transparent/metadata.json" /usr/share/plasma/wallpapers/org.powos.transparent/metadata.json
install -Dm 644 "$P/session/plasma/org.powos.transparent/contents/ui/main.qml" /usr/share/plasma/wallpapers/org.powos.transparent/contents/ui/main.qml
install -Dm 644 "$P/session/plasma/powos-transparent-desktop.js" /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/powos-transparent-desktop.js
# KWin then paints the transparent desktop as translucent (see its main.js: no trails under it).
install -Dm 644 "$P/session/plasma/powos-translucent-desktop/metadata.json" /usr/share/kwin/scripts/powos-translucent-desktop/metadata.json
install -Dm 644 "$P/session/plasma/powos-translucent-desktop/contents/code/main.js" /usr/share/kwin/scripts/powos-translucent-desktop/contents/code/main.js
# The phone's Android apps as a category of their own in the application menu (entries: andro.marchy.AndroidApps).
install -Dm 644 "$P/session/plasma/menus/powos-android.menu" /etc/xdg/menus/applications-merged/powos-android.menu
install -Dm 644 "$P/session/plasma/menus/powos-android.directory" /usr/share/desktop-directories/powos-android.directory
# Window edges a finger can grab (see the file).
install -Dm 644 "$P/session/plasma/breezerc" /etc/xdg/breezerc
install -Dm 755 "$P/session/powos-devtest-agent" /usr/lib/powos/phone/powos-devtest-agent
# first-boot.sh goes to /opt/lotfix/ in build-inside.sh's own install step (patched to take ours).
# HACK: Omarchy command names the engine calls; see each file. omarchy-dns is Andromarchy's own
# Android version (resolv.conf from Android's network), unchanged.
install -m 755 "$L/native/omarchy-dns-android.sh" /usr/local/bin/omarchy-dns
install -m 755 "$P/shims/omarchy-toggle-idle" /usr/local/bin/omarchy-toggle-idle
install -m 755 "$P/shims/omarchy-lock-screen" /usr/local/bin/omarchy-lock-screen
else
# ── Virtual machine (targets/web) ───────────────────────────────────────────────────────────────────────
# A normal boot: Arch Linux ARM's kernel, systemd as init, the root filesystem on the VM's first virtio disk.
# PowOS's login (powos/powos, as in PowOS's docs).
pacman -S --noconfirm --needed linux-aarch64 mkinitcpio
# The VM's initramfs: only what mounting the root needs (virtio disk + ext4), busybox init (base hook, no
# systemd/udev in the initramfs). The browser downloads it before booting, so size is time: ~3 MB instead of
# the ~185 MB generic one, and emulated systemd-in-initrd was the slow stage that also timed out waiting for
# /dev/vda (devtmpfs makes the node as soon as virtio_blk loads).
cat > /etc/mkinitcpio-powos-vm.conf <<'EOF'
MODULES=(virtio_pci virtio_blk ext4)
BINARIES=()
FILES=()
HOOKS=(base)
COMPRESSION=zstd
COMPRESSION_OPTIONS=(-19)
EOF
mkinitcpio -k "$(ls /usr/lib/modules | head -1)" -c /etc/mkinitcpio-powos-vm.conf -g /boot/initramfs-powos-vm.img
echo '/dev/vda / ext4 rw,relatime 0 1' > /etc/fstab
echo powos > /etc/hostname
# Arch Linux ARM ships a default user alarm/alarm (uid 1000): a known password, and Bazzite's autologin picks the
# first uid >= 1000 - it logged the VM in as alarm. PowOS has one user, powos.
id alarm >/dev/null 2>&1 && userdel -r alarm 2>/dev/null
id powos >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash powos
echo powos:powos | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel && chmod 440 /etc/sudoers.d/10-wheel
# The browser shows PowOS's desktop: SDDM logs powos straight into Plasma (Wayland), and KWin composites in software
# with QPainter - no GPU in the VM, and OpenGL on llvmpipe is far slower under emulation.
mkdir -p /etc/sddm.conf.d
# zzz-: SDDM applies /etc/sddm.conf.d in name order, last wins, and Bazzite ships zz-bazzite-autologin (User) and
# zz-holo-autologin (Session=Steam game mode). Game mode is gamescope on Vulkan - the VM has no GPU, so it exits.
rm -f /etc/sddm.conf.d/10-powos-vm-autologin.conf
printf '[Autologin]\nUser=powos\nSession=plasma\n' > /etc/sddm.conf.d/zzz-powos-vm-autologin.conf
grep -q '^KWIN_COMPOSE=' /etc/environment || echo 'KWIN_COMPOSE=Q' >> /etc/environment
grep -q '^QT_QUICK_BACKEND=' /etc/environment || echo 'QT_QUICK_BACKEND=software' >> /etc/environment
# The PowOS widgets poll by spawning processes (ps, nvidia-smi, podman, ...) every 3-30 s - ~10% of a real CPU, which
# saturates an emulated one. 20x less often in the VM; real hardware keeps interval_scale 1 (no file).
mkdir -p /etc/powos && echo 'interval_scale=20' > /etc/powos/widgets.conf
# Arch enables nothing on install (Fedora's presets do it for Bazzite): without these graphical.target is reached
# with no display manager at all, and the machine sits at a text login.
systemctl enable sddm.service
systemctl set-default graphical.target
# Login autostarts the VM can't use (x86 Steam client, first-run wizards, printers, SPICE) or can't afford in 1 GB
# of emulated RAM (file indexer, KDE Connect, a second input method): hidden for powos only - real hardware keeps them.
mkdir -p /home/powos/.config/autostart
for a in steam bazzite-desktop-bootstrap bazzite-announcement bazzite-portal baloo_file org.kde.kdeconnect.daemon ibus \
         geoclue-demo-agent input-remapper-autoload print-applet spice-vdagent \
         org.gnome.SettingsDaemon.DiskUtilityNotify org.kde.kunifiedpush-distributor; do
  printf '[Desktop Entry]\nHidden=true\n' > /home/powos/.config/autostart/$a.desktop
done
chown -R powos:powos /home/powos/.config
# Bazzite's "Return to Gaming Mode" desktop shortcut: game mode is gamescope on Vulkan, which the VM can't run.
rm -f /home/powos/Desktop/*[Gg]am*[Mm]ode*.desktop /etc/skel/Desktop/*[Gg]am*[Mm]ode*.desktop
fi

# Parity with the PowOS image: every command, app, autostart entry and enabled unit it offers, checked here.
# Gaps are listed by the PowOS package they come from; the report stays in the image.
install -Dm 644 $P/manifest/index.tsv /usr/share/powos/phone-index.tsv
install -Dm 755 $P/phone-parity.py /usr/lib/powos/phone/phone-parity.py
python3 /usr/lib/powos/phone/phone-parity.py /usr/share/powos/phone-index.tsv > /usr/share/powos/phone-parity.txt || true

echo "powos installed: $(head -1 /usr/share/powos/phone-report.txt)"
sed -n '2,7p' /usr/share/powos/phone-parity.txt
