#!/bin/bash
# Container half of build-rootfs.sh. Adapted from Andromarchy's build/build-rootfs.sh @ 220754d (steps 2-5),
# minus its x86 parts (apt, qemu-user binfmt) and the prebuilt Hyprland tarball. /in = staged inputs (ro),
# /work = Docker volume for the rootfs, /out = output directory.
set -euo pipefail
ALARM_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
MESA_URL=https://github.com/lfdevs/mesa-for-android-container/releases/download/mesa-26.3.0-devel-20260824/mesa-for-android-container_26.3.0-devel-20260824_archlinux_arm64.tar
FAKEROOT_URL=https://deb.debian.org/debian/pool/main/f/fakeroot/fakeroot_1.37.1.1.orig.tar.gz
R=/work/rootfs
A=/in/andromarchy

# HACK: same pacman-sandbox workaround as the build container (Landlock not permitted in Docker).
grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
pacman -Sy --noconfirm --needed libarchive curl >/dev/null

# Fresh Arch Linux ARM base every build: a half-built rootfs from an interrupted run is not reusable.
curl -fL -o /work/alarm.tar.gz -z /work/alarm.tar.gz "$ALARM_URL"
rm -rf "$R" && mkdir -p "$R"
bsdtar -xpf /work/alarm.tar.gz -C "$R"

# Inputs the chroot needs (layout build-inside.sh expects in /tmp/lotfix).
mkdir -p "$R/tmp/lotfix"
cp -r "$A/patches" "$A/native" "$R/tmp/lotfix/"
cp -r /in/powos "$R/tmp/lotfix/powos"
curl -fsSL -o "$R/tmp/lotfix/mesa.tar" "$MESA_URL"
curl -fsSL -o "$R/tmp/lotfix/fakeroot.tar.gz" "$FAKEROOT_URL"
cp "$A/build/build-inside.sh" "$R/tmp/lotfix/build-inside.sh"

cleanup() { for m in dev/pts dev proc sys; do umount -l "$R/$m" 2>/dev/null || true; done; }
trap 'rc=$?; cleanup; exit $rc' EXIT
mount -t proc proc "$R/proc"
mount --rbind /sys "$R/sys" && mount --make-rslave "$R/sys"
mount --rbind /dev "$R/dev" && mount --make-rslave "$R/dev"
rm -f "$R/etc/resolv.conf" && cp -L /etc/resolv.conf "$R/etc/resolv.conf"

chroot "$R" /bin/bash /tmp/lotfix/build-inside.sh

# Host-side fixups, then pack. Hard links become plain files: Android's SELinux forbids creating them.
bash "$A/native/relativize-symlinks.sh" "$R" 2>/dev/null || true
cleanup; trap - EXIT
rm -rf "$R/tmp/lotfix" "$R/var/cache/pacman/pkg/"* "$R/etc/resolv.conf"
tar --numeric-owner --hard-dereference -C "$R" -I 'gzip -6' -cf /out/powos-rootfs.tar.gz .
(cd /out && sha256sum powos-rootfs.tar.gz | tee powos-rootfs.tar.gz.sha256)
