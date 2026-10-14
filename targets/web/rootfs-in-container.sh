#!/bin/bash
# Container half of build-rootfs.sh. The base is targets/android/rootfs-in-container.sh's (fresh Arch Linux ARM,
# European mirrors, the shared package cache), without Andromarchy's engine. /in = staged inputs (ro),
# /work = scratch volume, /out = targets/web/out.
set -euo pipefail
ALARM_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
R=/work/rootfs

# HACK: pacman's download sandbox (Landlock) isn't permitted in Docker; same workaround as the phone build.
grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
pacman -Sy --noconfirm --needed libarchive curl e2fsprogs python >/dev/null

mkdir -p /cache/dl /cache/pkg
curl -fL -o /cache/dl/alarm.tar.gz -z /cache/dl/alarm.tar.gz "$ALARM_URL"
rm -rf "$R" && mkdir -p "$R"
bsdtar -xpf /cache/dl/alarm.tar.gz -C "$R"
cat > "$R/etc/pacman.d/mirrorlist" <<'EOF'
Server = http://de3.mirror.archlinuxarm.org/$arch/$repo
Server = http://de.mirror.archlinuxarm.org/$arch/$repo
Server = http://de4.mirror.archlinuxarm.org/$arch/$repo
Server = http://fr.mirror.archlinuxarm.org/$arch/$repo
Server = http://dk.mirror.archlinuxarm.org/$arch/$repo
Server = http://hu.mirror.archlinuxarm.org/$arch/$repo
Server = http://mirror.archlinuxarm.org/$arch/$repo
EOF
grep -q '^DisableSandbox' "$R/etc/pacman.conf" || sed -i '/^\[options\]/a DisableSandbox' "$R/etc/pacman.conf"
cp -r /in/powos "$R/tmp/powos"

cleanup() {
  for m in var/cache/pacman/pkg dev/pts dev proc sys; do umount -l "$R/$m" 2>/dev/null || true; done
  umount -l "$R" 2>/dev/null || true
}
trap 'rc=$?; cleanup; exit $rc' EXIT
# The rootfs bound onto itself, as arch-chroot does: / inside the chroot is then a mount point, so pacman can
# measure it (otherwise "could not determine root mount point" and its free-space check refuses everything).
mount --bind "$R" "$R"
mkdir -p "$R/var/cache/pacman/pkg" && mount --bind /cache/pkg "$R/var/cache/pacman/pkg"
mount -t proc proc "$R/proc"
mount --rbind /sys "$R/sys" && mount --make-rslave "$R/sys"
mount --rbind /dev "$R/dev" && mount --make-rslave "$R/dev"
rm -f "$R/etc/resolv.conf" && cp -L /etc/resolv.conf "$R/etc/resolv.conf"

chroot "$R" /bin/bash -c '
  set -euo pipefail
  pacman-key --init && pacman-key --populate archlinuxarm
  pacman -Syu --noconfirm
  POWOS_TARGET=vm P=/tmp/powos bash /tmp/powos/install-powos-android.sh'

cleanup; trap - EXIT
mkdir -p /out/disk
cp "$R/boot/Image" /out/disk/Image
cp "$R/boot/initramfs-powos-vm.img" /out/disk/initramfs.img
rm -rf "$R/tmp/powos" "$R/var/cache/pacman/pkg/"* "$R/etc/resolv.conf"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$R/etc/resolv.conf"
du -sh "$R" | sed 's/^/rootfs: /'

# The disk: ext4 from the tree (sparse: unused space costs nothing on disk, in the chunks, or in the browser),
# then chunks. The raw image is scratch on the Mac's side (/out/work), not the shared Docker disk, never kept.
mkdir -p /out/work
mke2fs -q -F -t ext4 -L powos -d "$R" /out/work/disk.img 32G
rm -rf "$R"
python3 /tools/chunk-disk.py /out/work/disk.img /out/disk
rm -f /out/work/disk.img
