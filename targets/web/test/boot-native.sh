#!/bin/bash
# Boots the published disk on native QEMU (build-qemu-native.sh: the same source as the browser build) with the
# browser's machine (args.js: virt, neoverse-n1, 1G), serial on stdout. For telling PowOS problems from
# qemu-wasm ones, and the base for making snapshots. Stops after TIMEOUT seconds (default 600).
#
# Usage: targets/web/test/boot-native.sh [extra QEMU args...]
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
docker run --rm -i -v "$HERE/out/disk:/disk:ro" -v "$HERE/out/qemu-native:/q:ro" powos-web-qemu-native \
  timeout "${TIMEOUT:-600}" /q/qemu-system-aarch64 -nographic -M virt -cpu neoverse-n1 -m 1024M -accel tcg \
    -nic none -kernel /disk/Image -initrd /disk/initramfs.img \
    -append 'console=ttyAMA0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target' \
    -drive if=none,id=disk0,format=raw,file.driver=chunked,file.url=/disk \
    -device virtio-blk-pci,drive=disk0 "$@"
