#!/bin/bash
# Packs out/boot-powos-gki.img: the phone's own stock boot image (backup/<serial>/boot_b.img, header v4) with only
# the kernel replaced by ours (out/gki/Image, build-gki-kernel.sh: namespaces etc. for Steam). Everything else -
# header, cmdline, OS version/patch level - comes from the stock image, so Android boots as before on our kernel.
# Ramdisk and DTB are not in this partition on the Open (init_boot = Magisk root, vendor_boot = DTB + vendor modules).
#   ./make-gki-boot.sh [stock boot.img] [kernel Image]
# Try first with `fastboot boot out/boot-powos-gki.img` (RAM only, nothing flashed); flash only after that works.
# Tools: AOSP's mkbootimg/unpack_bootimg (plain Python), fetched into out/tools/ on first use.
set -euo pipefail
cd "$(dirname "$0")"
STOCK=${1:-backup/8e5d600d/boot_b.img}
KERNEL=${2:-out/gki/Image}
for f in "$STOCK" "$KERNEL"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }; done
T=out/tools/mkbootimg
[ -f $T/mkbootimg.py ] || git clone -q --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg $T
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
echo "stock:"
python3 $T/unpack_bootimg.py --boot_img "$STOCK" --out "$W/s" | grep -E 'header version|os version|os patch|kernel size|command line'
args=$(python3 $T/unpack_bootimg.py --boot_img "$STOCK" --out "$W/s" --format mkbootimg)
# The stock arguments, with our kernel instead of the stock one.
eval python3 $T/mkbootimg.py "$(printf '%s' "$args" | sed "s#--kernel [^ ]*#--kernel $KERNEL#")" -o out/boot-powos-gki.img
echo "ours:"
python3 $T/unpack_bootimg.py --boot_img out/boot-powos-gki.img --out "$W/u" | grep -E 'header version|os version|os patch|kernel size'
cmp "$W/u/kernel" "$KERNEL" && echo "round trip: kernel identical"
ls -la out/boot-powos-gki.img
