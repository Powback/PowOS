#!/bin/bash
# Builds the bring-up initramfs (out/initramfs-bringup.img): static busybox + initramfs/init. No modules - the
# kernel has everything the USB shell needs built in (config/bringup.config).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
docker build -q -t powos-native-builder docker > /dev/null
docker run --rm -v "$PWD":/native powos-native-builder bash -euo pipefail -c '
  R=$(mktemp -d)
  mkdir -p $R/{bin,sbin,dev,proc,sys,etc,run,tmp,var}
  cp /bin/busybox $R/bin/
  for a in $($R/bin/busybox --list); do [ -e $R/bin/$a ] || ln -s busybox $R/bin/$a; done
  for need in telnetd udhcpd ifconfig setsid; do [ -e $R/bin/$need ] || { echo "busybox lacks $need"; exit 1; }; done
  install -m 755 /native/initramfs/init $R/init
  (cd $R && find . | cpio -o -H newc --quiet | gzip -9) > /native/out/initramfs-bringup.img
'
ls -la out/initramfs-bringup.img
