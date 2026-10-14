#!/bin/bash
# Builds the mainline kernel + device trees for PowOS on phones (first device: OnePlus Open, xueying, SM8550).
#   out/Image.gz, out/dtbs/<name>.dtb, out/kernel-version
# Kernel source: a kernel.org stable tarball (KVER), kept with the build tree in the powos-native-cache volume, so
# rebuilds are incremental. Our device trees (dts/*.dts) are copied into arch/arm64/boot/dts/qcom on every build;
# config = arm64 defconfig + config/*.config fragments.
#   KVER=7.2.10 ./build-kernel.sh            DTBS_ONLY=1 ./build-kernel.sh   (just the device trees)
set -euo pipefail
cd "$(dirname "$0")"
KVER=${KVER:-7.2.10}
DTBS="sm8550-oneplus-xueying sm8550-samsung-q5q"
mkdir -p out
docker build -q -t powos-native-builder docker > /dev/null
docker run --rm -v powos-native-cache:/cache -v "$PWD":/native -e KVER="$KVER" -e DTBS="$DTBS" \
  -e DTBS_ONLY="${DTBS_ONLY:-}" -e JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}" powos-native-builder bash -euo pipefail -c '
  SRC=/cache/linux-$KVER
  if [ ! -f $SRC/Makefile ]; then
    major=${KVER%%.*}
    curl -fL --retry 3 -o /cache/linux-$KVER.tar.xz https://cdn.kernel.org/pub/linux/kernel/v$major.x/linux-$KVER.tar.xz
    tar -C /cache -xf /cache/linux-$KVER.tar.xz && rm /cache/linux-$KVER.tar.xz
  fi
  Q=$SRC/arch/arm64/boot/dts/qcom
  cp /native/dts/*.dtsi $Q/
  for f in /native/dts/*.dts; do
    n=$(basename $f .dts); cp $f $Q/
    grep -q "$n.dtb" $Q/Makefile || echo "dtb-\$(CONFIG_ARCH_QCOM) += $n.dtb" >> $Q/Makefile
  done
  B=/cache/build-$KVER; mkdir -p $B
  # defconfig + our fragments, regenerated every build so a fragment edit always takes effect.
  make -C $SRC O=$B ARCH=arm64 -s defconfig
  $SRC/scripts/kconfig/merge_config.sh -m -O $B $B/.config /native/config/*.config > /dev/null
  make -C $SRC O=$B ARCH=arm64 -s olddefconfig
  for c in $(grep -h "^CONFIG_.*=y" /native/config/*.config | cut -d= -f1); do
    grep -q "^$c=y" $B/.config || echo "WARNING: $c did not stay =y (missing dependency?)"
  done
  targets=$(for d in $DTBS; do echo qcom/$d.dtb; done)
  if [ -z "$DTBS_ONLY" ]; then make -C $SRC O=$B ARCH=arm64 -j$JOBS -s Image.gz $targets
  else make -C $SRC O=$B ARCH=arm64 -j$JOBS -s $targets; fi
  mkdir -p /native/out/dtbs
  for d in $DTBS; do cp $B/arch/arm64/boot/dts/qcom/$d.dtb /native/out/dtbs/; done
  [ -n "$DTBS_ONLY" ] || { cp $B/arch/arm64/boot/Image.gz /native/out/; make -C $SRC O=$B -s kernelrelease > /native/out/kernel-version; }
'
ls -la out out/dtbs
