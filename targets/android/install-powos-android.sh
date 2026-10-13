#!/bin/bash
# Installs KDE Plasma + the PowOS layer into the Android rootfs. Runs inside the aarch64 rootfs, called by
# Andromarchy's build/build-inside.sh at the step where it used to install Omarchy (see
# patches/andromarchy/0001-build-inside-powos.patch). Inputs, staged by build-rootfs.sh in $P (/tmp/lotfix/powos):
#   layer/     the PowOS layer tree, already laid out at its destinations (from layer.list)
#   pkgs/      our built packages (kwin with the Anland backend)
#   session/   the session launcher + first-boot/first-session
#   shims/     stand-ins for Omarchy commands Andromarchy's engine calls
set -euo pipefail
P=/tmp/lotfix/powos
L=/tmp/lotfix
C=/etc/pacman.conf

# ── KDE Plasma ────────────────────────────────────────────────────────────────────────────────────────
# A deliberately small Plasma: the shell, KDE's core apps and the portals. No plasma-nm/powerdevil/
# bluedevil/kscreen: Android owns network, power, Bluetooth and displays (the engine's android-nm and
# android-upower stand-ins answer the D-Bus calls Plasma makes).
pacman -S --noconfirm --needed \
  plasma-desktop plasma-workspace kdeplasma-addons breeze breeze-gtk kde-gtk-config systemsettings \
  xdg-desktop-portal-kde konsole dolphin kate ark spectacle gwenview okular \
  noto-fonts noto-fonts-emoji ttf-hack \
  tmux jq curl unzip uv python
# The desktop image's apps and tools, as mapped in packages.list ('+' lines; '~' ones are handled
# below or later, '-' ones are deliberately not on Android).
pacman -S --noconfirm --needed $(awk '/^\+ /{for (i = 3; i <= NF; i++) print $i}' "$P/packages.list" | sort -u)
# Our KWin (Anland backend) over Arch's, then pinned: pacman must never swap it for Arch's, which has no
# way to draw on Android. HACK: IgnorePkg means Plasma updates need a matching rebuild of our kwin
# (pacman warns about the held package); the real fix is the Anland backend upstream in KWin.
pacman -U --noconfirm "$P"/pkgs/kwin-*.pkg.tar.*
grep -q '^IgnorePkg.*\bkwin\b' $C || sed -i "/^IgnorePkg/ s/$/ kwin/" $C

# No systemd on Android: startplasma must start the session's services itself, not ask systemd to.
mkdir -p /etc/xdg
printf '[General]\nsystemdBoot=false\n' > /etc/xdg/startkderc

# ── The PowOS layer (the same files the desktop/Deck image ships; see layer.list) ──────────────────────
# Modes and symlinks kept, owner not: the staged files belong to the build host's user (macOS uid 501),
# and the image's /usr, /etc must be root's as on the desktop image.
cp -r --preserve=mode,timestamps,links --no-preserve=ownership "$P/layer/." /
# The app's user is root with home /root: seed it from /etc/skel as useradd would for a new user.
cp -a /etc/skel/. /root/ 2>/dev/null || true
mkdir -p /etc/powos && echo phone > /etc/powos/platform

# Same extras the Containerfile adds to the desktop image, aarch64 builds of the same versions.
# kzones (KWin window-zones script), pinned like the desktop image.
curl -fsSL -o /tmp/kzones.kwinscript https://github.com/gerritdevriese/kzones/releases/download/v0.9.2/kzones.kwinscript
mkdir -p /usr/share/kwin/scripts/kzones && bsdtar -xf /tmp/kzones.kwinscript -C /usr/share/kwin/scripts/kzones
rm -f /tmp/kzones.kwinscript
# bun: official aarch64 glibc build (the desktop image takes the x64 one).
curl -fsSL -o /tmp/bun.zip https://github.com/oven-sh/bun/releases/latest/download/bun-linux-aarch64.zip
bsdtar -xf /tmp/bun.zip -C /tmp && install -m 755 /tmp/bun-linux-aarch64/bun /usr/bin/bun && rm -rf /tmp/bun*
# tmux session persistence, pinned to the desktop image's versions (Containerfile TMUX_*_VER).
mkdir -p /usr/share/tmux-plugins
for spec in tmux-resurrect:v4.0.0 tmux-continuum:v3.1.0; do
  name=${spec%%:*} ver=${spec##*:}
  curl -fsSL "https://github.com/tmux-plugins/$name/archive/refs/tags/$ver.tar.gz" | tar xz -C /usr/share/tmux-plugins
  rm -rf "/usr/share/tmux-plugins/$name" && mv /usr/share/tmux-plugins/$name-* "/usr/share/tmux-plugins/$name"
done

# ── Session + Omarchy-name stand-ins ──────────────────────────────────────────────────────────────────
install -m 755 "$P/session/Hyprland" /usr/bin/Hyprland            # HACK: see the file
install -Dm 755 "$P/session/first-session.sh" /opt/powos/first-session.sh
# first-boot.sh goes to /opt/lotfix/ in build-inside.sh's own install step (patched to take ours).
# HACK: Omarchy command names the engine calls; see each file. omarchy-dns is Andromarchy's own
# Android version (resolv.conf from Android's network), unchanged.
install -m 755 "$L/native/omarchy-dns-android.sh" /usr/local/bin/omarchy-dns
install -m 755 "$P/shims/omarchy-toggle-idle" /usr/local/bin/omarchy-toggle-idle
install -m 755 "$P/shims/omarchy-lock-screen" /usr/local/bin/omarchy-lock-screen

echo "powos layer installed"
