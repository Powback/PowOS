#!/bin/bash
# The phone's own vendor modules, for tools/kmi-check.py: the first-stage set in vendor_boot's ramdisk and the
# second-stage set in vendor_dlkm, from the stock 16.0.5.1301 images (byte-identical to what the phone runs:
# targets/native/backup/<serial>/stock-*/SHA256SUMS). Read-only; nothing touches the phone.
#   ./extract-vendor-modules.sh [stock image dir]      -> out/vendor-modules/{vendor_boot,vendor_dlkm}/
set -euo pipefail
cd "$(dirname "$0")"
STOCK=${1:-../../native/backup/8e5d600d/stock-16.0.5.1301-EX01}
(cd "$STOCK" && shasum -a 256 -c SHA256SUMS > /dev/null) || { echo "$STOCK: checksums do not match" >&2; exit 1; }
T=../../native/out/tools/mkbootimg
[ -f $T/unpack_bootimg.py ] || git clone -q --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg $T
rm -rf out/vendor-modules && mkdir -p out/vendor-modules
python3 $T/unpack_bootimg.py --boot_img "$STOCK/vendor_boot.img" --out out/vendor-modules/vb > /dev/null
cp "$STOCK/vendor_dlkm.img" out/vendor-modules/vendor_dlkm.img
docker run --rm -v "$PWD/out/vendor-modules":/w -w /w debian:bookworm bash -euo pipefail -c '
  apt-get update -qq > /dev/null && apt-get install -y -qq lz4 cpio e2fsprogs > /dev/null 2>&1
  mkdir -p ramdisk vendor_boot vendor_dlkm
  (cd ramdisk && lz4 -dc ../vb/vendor_ramdisk00 | cpio -idm --quiet)
  cp ramdisk/lib/modules/*.ko vendor_boot/
  debugfs -R "rdump /lib/modules vendor_dlkm" vendor_dlkm.img 2> /dev/null
  rm -rf ramdisk vb vendor_dlkm.img'
echo "vendor_boot: $(find out/vendor-modules/vendor_boot -name '*.ko' | wc -l) modules," \
  "vendor_dlkm: $(find out/vendor-modules/vendor_dlkm -name '*.ko' | wc -l) modules"
