#!/bin/bash
# Builds PowOS for the browser the same way the phone gets it (targets/android): Arch Linux ARM + every PowOS
# package mapped by phone-rules.conf + our builds + PowOS's own files, all from the published deck image's
# manifest, by the same installer (install-powos-android.sh, POWOS_TARGET=vm: a kernel and a normal systemd
# boot instead of the phone's Android parts). Then the root filesystem becomes the disk the browser streams:
# ext4, split into content-addressed chunks (tools/chunk-disk.py), fetched only when the guest reads them.
#
# Output: targets/web/out/disk/   chunks/  index.bin  manifest.json  Image  initramfs.img  image.txt
#
# Usage: targets/web/build-rootfs.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ANDROID=$HERE/../android
OUT=$HERE/out
W=$OUT/stage
IMAGE=menci/archlinuxarm:latest
REPO=${POWOS_REPO_DIR:-$HOME/Projects/android-app-dev/output/repo}   # [powos]: newest build of each (publish-repo.sh)

# 1. Inputs, staged as the phone build stages them (targets/android/build-rootfs.sh step 2).
rm -rf "$W" && mkdir -p "$W/powos/pkgs" "$OUT/disk"
"$ANDROID/tools/fetch-manifest.sh" "$W/powos/manifest" "${POWOS_MANIFEST:-ghcr.io/powback/powos-phone:deck}"
cp "$REPO"/*.pkg.tar.* "$W/powos/pkgs/"
cp -a "$ANDROID/session" "$ANDROID/shims" "$ANDROID/phone-rules.conf" "$ANDROID/tools/resolve-packages.py" \
  "$ANDROID/tools/phone-parity.py" "$W/powos/"
install -m 755 "$ANDROID/install-powos-android.sh" "$W/powos/"
# The PowOS desktop widgets from this checkout (install-powos-android.sh puts them over the image content's).
cp -a "$ANDROID/../../desktop/plasmoid" "$W/powos/plasmoids"

# 2. Build in a privileged aarch64 container (chroot + mounts). The rootfs needs a Linux filesystem (ownership,
#    device nodes) but must NOT go on the Docker disk: that disk is shared with live services (Pi-hole, databases)
#    and a ~17 GB rootfs can fill it. So the scratch filesystem is a sparse ext4 image on the Mac's disk
#    (out/work/rootfs-scratch.ext4), loop-mounted at /work inside the container, deleted afterwards.
NEED_GB=45   # scratch rootfs (~17 GB) + the raw disk image (~17 GB, sparse) + chunks (~8 GB), all on the Mac side
free_gb=$(df -g "$OUT" | awk 'NR == 2 {print $4}')
if [ "${free_gb:-0}" -lt "$NEED_GB" ]; then
  echo "only ${free_gb} GB free on the Mac disk under $OUT; need ${NEED_GB} GB" >&2
  exit 1
fi
mkdir -p "$OUT/work"
cleanup_scratch() { rm -f "$OUT/work/rootfs-scratch.ext4"; }
# Also on INT/TERM: bash skips EXIT traps when killed, and a stopped build once left 7 GB behind.
trap cleanup_scratch EXIT
trap 'cleanup_scratch; exit 130' INT TERM
# powos-android-cache: the phone build's persistent cache (ALARM tarball, pacman packages) - shared, so the
# two builds download Arch once.
docker run --rm --privileged --platform linux/arm64 --cpus 8 --memory 16g \
  -v powos-android-cache:/cache -v "$W:/in:ro" -v "$OUT:/out" \
  -v "$HERE/rootfs-in-container.sh:/rootfs-in-container.sh:ro" -v "$HERE/tools:/tools:ro" \
  "$IMAGE" bash -c 'set -e
    truncate -s 48G /out/work/rootfs-scratch.ext4
    mke2fs -q -F -t ext4 /out/work/rootfs-scratch.ext4
    mkdir -p /work && mount -o loop /out/work/rootfs-scratch.ext4 /work
    trap "umount -l /work 2>/dev/null || true" EXIT
    bash /rootfs-in-container.sh'
cp "$W/powos/manifest/image.txt" "$OUT/disk/image.txt"
rm -rf "$W"
echo "disk: $OUT/disk ($(du -sh "$OUT/disk/chunks" | cut -f1) of chunks)"
