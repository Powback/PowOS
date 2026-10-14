#!/bin/bash
# Packs out/boot-bringup.img: kernel + bring-up initramfs + the xueying DTB, Android boot image header v2.
# For `fastboot boot` only (RAM, nothing flashed). Header v2 carries the DTB inside the image; with the phone's own
# header v4 layout the DTB would come from the vendor_boot partition, i.e. the stock (downstream) one.
# HACK: base/offsets are the common Qualcomm values; compare against the stock boot.img header saved by
# `phone.sh dump` (unpack_bootimg) and adjust if the bootloader refuses the image.
set -euo pipefail
cd "$(dirname "$0")"
DTB=out/dtbs/sm8550-oneplus-xueying.dtb
if grep -q POWOS-PLACEHOLDER dts/sm8550-oneplus-xueying-board.dtsi && [ "${ALLOW_PLACEHOLDER:-}" != 1 ]; then
  echo "dts/sm8550-oneplus-xueying-board.dtsi still has placeholders - run 'phone.sh dump' on the phone first," >&2
  echo "then build-kernel.sh (the bootloader picks the DTB by qcom,msm-id/board-id). ALLOW_PLACEHOLDER=1 to pack anyway." >&2
  exit 1
fi
for f in out/Image.gz out/initramfs-bringup.img "$DTB"; do [ -f "$f" ] || { echo "missing $f (build-kernel.sh / build-initramfs.sh)" >&2; exit 1; }; done
# clk/pd_ignore_unused: keep what the bootloader left on (display, USB clocks) until drivers claim it.
CMDLINE=${CMDLINE:-"rdinit=/init clk_ignore_unused pd_ignore_unused console=tty0 loglevel=7"}
docker run --rm -v "$PWD":/native -w /native powos-native-builder bash -euo pipefail -c "
  mkbootimg --header_version 2 --pagesize 4096 --base 0x0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
    --tags_offset 0x100 --dtb_offset 0x1f00000 --kernel out/Image.gz --ramdisk out/initramfs-bringup.img \
    --dtb $DTB --cmdline '$CMDLINE' -o out/boot-bringup.img
  # Round trip: what the bootloader will see.
  rm -rf /tmp/u && unpack_bootimg --boot_img out/boot-bringup.img --out /tmp/u | grep -E 'header version|command line|dtb size|kernel size|ramdisk size'
  cmp /tmp/u/kernel out/Image.gz && cmp /tmp/u/dtb $DTB && echo 'round trip: kernel + dtb identical'
"
ls -la out/boot-bringup.img
