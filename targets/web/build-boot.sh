#!/bin/bash
# Remakes only the VM's boot files - Image.gz and the minimal initramfs - from the exact kernel package the disk was
# built with (the shared package cache), without rebuilding the rootfs. Same recipe as the rootfs build
# (install-powos-android.sh, POWOS_TARGET=vm: /etc/mkinitcpio-powos-vm.conf). Output: out/disk/{Image.gz,initramfs.img}
#
# Usage: targets/web/build-boot.sh [kernel package version]   (default: the disk's, from the cached package)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VER=${1:-7.2.10-1}
docker run --rm --privileged --platform linux/arm64 -v powos-android-cache:/cache:ro -v "$HERE/out/disk:/out" \
  -e VER="$VER" menci/archlinuxarm:latest bash -c '
  set -euo pipefail
  grep -q "^DisableSandbox" /etc/pacman.conf || sed -i "/^\[options\]/a DisableSandbox" /etc/pacman.conf
  pacman -Sy --noconfirm --needed zstd >/dev/null
  pacman -U --noconfirm --needed /cache/pkg/mkinitcpio-*.pkg.tar.xz /cache/pkg/linux-aarch64-$VER-aarch64.pkg.tar.xz >/dev/null 2>&1
  kv=$(ls /usr/lib/modules | grep -v extramodules | head -1)
  cat > /etc/mkinitcpio-powos-vm.conf <<EOF
MODULES=(virtio_pci virtio_blk ext4)
BINARIES=()
FILES=()
HOOKS=(base)
COMPRESSION=zstd
COMPRESSION_OPTIONS=(-19)
EOF
  mkinitcpio -k "$kv" -c /etc/mkinitcpio-powos-vm.conf -g /out/initramfs.img 2>&1 | tail -3
  cp /boot/Image.gz /out/Image.gz
  echo "$kv" > /out/kernel-version
  ls -la /out/Image.gz /out/initramfs.img'
