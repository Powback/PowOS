#!/bin/bash
# PowOS alongside Android on a ROOTED phone (Magisk), driven from the Mac over adb. Not the no-root app: PowOS's
# own Linux system runs with root on the phone's kernel, with the real GPU (Turnip on KGSL).
#   install   push targets/android/out/powos-rootfs.tar.gz, unpack to /data/powos/root, install the boot service
#   start     mount + start PowOS now (rooted/powos-start.sh; also runs at every boot via Magisk)
#   shell     root shell inside PowOS
#   check     what works: PowOS CLI, systemd-free services, GPU (vulkaninfo through Turnip)
#   log       /data/powos/start.log
# Everything lives in /data/powos (+ /data/adb/service.d/powos.sh). Removing PowOS = deleting those.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOTFS=${ROOTFS:-$HERE/../out/powos-rootfs.tar.gz}

# Magisk's su: on PATH once Magisk finished its setup, always at /debug_ramdisk/su while it runs.
SU=$(adb shell 'command -v su || echo /debug_ramdisk/su' | tr -d '\r')
asu() { adb shell "$SU -c '$1'"; }
in_powos() { asu "chroot /data/powos/root /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/usr/sbin HOME=/root TERM=xterm-256color /bin/bash -lc \"$1\""; }

case "${1:-}" in
install)
  [ -f "$ROOTFS" ] || { echo "no $ROOTFS (targets/android/build-rootfs.sh)"; exit 1; }
  asu id | grep -q uid=0 || { echo "no root (Magisk)"; exit 1; }
  want=$(awk '{print $1}' "$ROOTFS.sha256")
  adb push "$ROOTFS" /data/local/tmp/powos-rootfs.tar.gz
  got=$(asu "sha256sum /data/local/tmp/powos-rootfs.tar.gz" | awk '{print $1}')
  [ "$want" = "$got" ] || { echo "CHECKSUM MISMATCH after push"; exit 1; }
  asu "mkdir -p /data/powos/root && tar -xzpf /data/local/tmp/powos-rootfs.tar.gz -C /data/powos/root --numeric-owner && rm /data/local/tmp/powos-rootfs.tar.gz"
  adb push "$HERE/powos-start.sh" /data/local/tmp/powos-start.sh
  asu "install -m 755 /data/local/tmp/powos-start.sh /data/powos/powos-start.sh && mkdir -p /data/adb/service.d && install -m 755 /data/local/tmp/powos-start.sh /data/adb/service.d/powos.sh && rm /data/local/tmp/powos-start.sh"
  echo "installed: /data/powos/root ($(asu 'du -sh /data/powos/root' | awk '{print $1}')), boot service in /data/adb/service.d" ;;
start)
  asu "sh /data/powos/powos-start.sh"; asu "tail -5 /data/powos/start.log" ;;
shell)
  exec adb shell -t "$SU -c 'chroot /data/powos/root /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/usr/sbin HOME=/root TERM=xterm-256color /bin/bash -l'" ;;
check)
  in_powos "cat /etc/powos/platform; uname -a; powos version 2>&1 | head -3"
  in_powos "ls -la /dev/kgsl-3d0 /dev/dma_heap 2>&1 | head -5"
  in_powos "vulkaninfo --summary 2>&1 | grep -E 'deviceName|driverName|driverInfo|apiVersion' | head -6" ;;
log)
  asu "cat /data/powos/start.log" ;;
*)
  sed -n '2,10p' "$0"; exit 1 ;;
esac
