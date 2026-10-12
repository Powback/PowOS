#!/bin/bash
# /opt/lotfix/first-boot.sh in the PowOS Android rootfs: the device-specific half of an install, run by
# the app (SessionService) inside the rootfs before the session starts.
#
# HACK: the path /opt/lotfix/first-boot.sh is Andromarchy's; their app calls it by that name. Ours
# replaces theirs (theirs configures Omarchy/Hyprland). Real fix: our own app calls /opt/powos/first-boot.sh.
#
# Adapted from Andromarchy's native/first-boot.sh @ 220754d: the generic parts are kept as-is
# (locale, app uid as the only user, machine-id, sticky tmp dirs, DNS); the Hyprland input config and
# Omarchy's XCompose are replaced by KDE's keyboard config.
#   ANDROMARCHY_UID/GID   the app's Android uid/gid (every process runs as it)
#   LANG                  Android's language as a glibc locale (fr_FR.UTF-8...)
# Setup form answers in /root/.config/andromarchy/setup.conf: KB_LAYOUTS, FULL_NAME, EMAIL.
set -uo pipefail
conf=/root/.config/andromarchy/setup.conf
done_mark=/root/.local/state/powos/first-boot.done

# Language: glibc reads locales from LOCPATH directories (no locale-archive). Compile Android's.
loc=${LANG:-C.UTF-8}
if [[ $loc != C.UTF-8 && ! -d /usr/lib/locale/$loc ]]; then
  base=${loc%%.*}
  [ -f "/usr/share/i18n/locales/$base" ] && localedef --no-archive -i "$base" -f UTF-8 "/usr/lib/locale/$loc" || true
fi

[ -f "$done_mark" ] && exit 0

# The app's uid is the only user: give it /root and bash.
uid=${ANDROMARCHY_UID:-$(id -u)} gid=${ANDROMARCHY_GID:-$(id -g)}
grep -q "^[^:]*:[^:]*:$uid:" /etc/passwd || echo "android:x:$uid:$gid:Android app user:/root:/usr/bin/bash" >> /etc/passwd
grep -q "^[^:]*:[^:]*:$gid:" /etc/group || echo "android:x:$gid:" >> /etc/group

# D-Bus (dconf, portals) refuses an empty machine-id; systemd would normally fill it.
[ -s /etc/machine-id ] || { rm -f /etc/machine-id; tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id; }

mkdir -p /tmp/.X11-unix /tmp/.ICE-unix
chmod 1777 /tmp /var/tmp /tmp/.X11-unix /tmp/.ICE-unix 2>/dev/null

# DNS: Android's current network's servers (android-nm keeps them current afterwards).
omarchy-dns DHCP

# Setup form answers.
KB_LAYOUTS=us FULL_NAME= EMAIL=
[ -f "$conf" ] && . "$conf"
kwriteconfig6 --file kxkbrc --group Layout --key Use true
kwriteconfig6 --file kxkbrc --group Layout --key LayoutList "$KB_LAYOUTS"
[ -n "${FULL_NAME// /}" ] && git config --global user.name "$FULL_NAME"
[ -n "${EMAIL// /}" ] && git config --global user.email "$EMAIL"

mkdir -p "${done_mark%/*}" && touch "$done_mark"
echo "first boot done"
