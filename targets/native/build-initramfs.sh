#!/bin/bash
# Builds the phone's initramfs images - static busybox + an init script:
#   out/initramfs-bringup.img  mainline bring-up: initramfs/init (USB shell only, gzip)
#   out/initramfs-native.img   native PowOS on the vendor kernel (init_boot_b): initramfs-native/init, which loads
#                              the first-stage vendor modules, finds the "powos" partition and starts PowOS; the
#                              bring-up init ships as /rescue (USB shell when anything fails). lz4 legacy, the
#                              format Android's own init_boot ramdisk uses (the GKI kernel decompresses it).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
docker build -q -t powos-native-builder docker > /dev/null
docker run --rm -v "$PWD":/native powos-native-builder bash -euo pipefail -c '
  base() {
    R=$(mktemp -d)
    mkdir -p $R/{bin,sbin,dev,proc,sys,etc,run,tmp,var,newroot}
    cp /bin/busybox $R/bin/
    for a in $($R/bin/busybox --list); do [ -e $R/bin/$a ] || ln -s busybox $R/bin/$a; done
    for need in telnetd udhcpd ifconfig setsid insmod switch_root; do
      [ -e $R/bin/$need ] || { echo "busybox lacks $need"; exit 1; }
    done
  }
  base
  install -m 755 /native/initramfs/init $R/init
  (cd $R && find . | cpio -o -H newc --quiet | gzip -9) > /native/out/initramfs-bringup.img
  base
  install -m 755 /native/initramfs-native/init $R/init
  install -m 755 /native/initramfs/init $R/rescue
  (cd $R && find . | cpio -o -H newc --quiet | lz4 -l -12 -q) > /native/out/initramfs-native.img
'
ls -la out/initramfs-bringup.img out/initramfs-native.img
