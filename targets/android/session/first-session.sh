#!/bin/bash
# /opt/powos/first-session.sh: once per rootfs, inside the running session (needs the session bus).
# Adapted from Andromarchy's native/first-session.sh @ 220754d (Flatpak setup kept; the Omarchy
# plugin and GNOME theme settings dropped: KDE reads PowOS's /etc/xdg defaults instead).
mark=/root/.local/state/powos/first-session.done
[ -f "$mark" ] && exit 0
sleep 5
flatpak --user remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
mkdir -p ~/.local/share/flatpak/repo/tmp ~/.local/share/flatpak/exports/share/applications \
  ~/.local/share/flatpak/exports/share/icons ~/.local/share/flatpak/exports/bin
# Flatpak's own GL runtimes have no KGSL Mesa: masked so apps use the rootfs's (Andromarchy's finding).
flatpak --user mask 'org.freedesktop.Platform.GL.*'
flatpak --user mask 'org.freedesktop.Platform.GL32.*'
flatpak --user config --set languages "${LANG%%_*};en"
# (PowOS's widgets are added by powos-widget-autoadd from /etc/xdg/autostart, as on the desktop.)
mkdir -p "${mark%/*}" && touch "$mark"
