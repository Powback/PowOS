#!/bin/bash
# Builds the OnePlus Open's own kernel (GKI android13-5.15, OnePlusOSS sources of the shipped Android 16 build) with
# what a normal Linux system needs (config/gki/powos.config) - the native-PowOS kernel. The phone's vendor modules
# (display, GPU, touch, Wi-Fi, charging) load on it unchanged, from the phone's own vendor_dlkm partition.
#   out/gki/Image          the kernel (boot_b)
#   out/gki/system_dlkm/   GKI modules, rebuilt and signed with our key (Google-signed stock ones won't verify on
#                          our kernel: MODULE_SIG_PROTECT)
#   out/gki/Module.symvers symbol CRCs - tools/kmi-check.py compares them with the phone's vendor modules
#   out/gki/kernel-version
# Compiler: Google's prebuilt Clang r450784e (build.config.constants) - same CFI/LTO/symbol versions as stock.
# Source and build tree live in the powos-gki-cache volume (incremental rebuilds).
#   ./build-gki-kernel.sh            BRANCH=oneplus/sm8550_v_15.0.0_oneplus_open ./build-gki-kernel.sh
set -euo pipefail
cd "$(dirname "$0")"
BRANCH=${BRANCH:-oneplus/sm8550_b_16.0.0_oneplus_open}
mkdir -p out/gki
docker build -q --platform linux/amd64 -t powos-gki-builder docker/gki > /dev/null
docker run --rm --platform linux/amd64 -v powos-gki-cache:/cache -v "$PWD":/native -e BRANCH="$BRANCH" \
  -e JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}" powos-gki-builder bash -euo pipefail -c '
  # Compiler: the r450784e directory of Android'"'"'s clang prebuilts, at the branch that still carries it.
  CLANG=/cache/clang-r450784e
  if [ ! -x $CLANG/bin/clang ]; then
    rm -rf $CLANG && mkdir -p $CLANG
    curl -fL --retry 3 "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/master-kernel-build-2022/clang-r450784e.tar.gz" \
      | tar -xz -C $CLANG
  fi
  $CLANG/bin/clang --version | head -1
  # Source: OnePlusOSS, laid out as their kernel_manifest checks it out (oneplus_open_b.xml) - the common kernel
  # links into the modules/devicetree repo at the root (kernel/oplus_cpu -> ../../../vendor/oplus/kernel/cpu, ...).
  # One commit each, no history.
  ROOT=/cache/oplus-${BRANCH//\//_}
  SRC=$ROOT/kernel_platform/common
  if [ ! -d $ROOT/vendor/oplus ]; then
    rm -rf $ROOT
    git clone -q --depth 1 -b "$BRANCH" https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8550 $ROOT
  fi
  if [ ! -f $SRC/Makefile ]; then
    rm -rf $SRC
    git clone -q --depth 1 -b "$BRANCH" https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8550 $SRC
  fi
  git -C $ROOT log -1 --format="modules/devicetree: %H %cd"
  git -C $SRC log -1 --format="source: %H %cd"
  B=/cache/build-${BRANCH//\//_}; mkdir -p $B
  export PATH=$CLANG/bin:$PATH
  # Host tools (fixdep, ...) link with lld too, like the Android kernel build - there is no system ld here.
  M="make -C $SRC O=$B ARCH=arm64 LLVM=1 LLVM_IAS=1 HOSTLDFLAGS=-fuse-ld=lld -s"
  # gki_defconfig + ours, regenerated every build so a fragment edit always takes effect.
  $M gki_defconfig
  $SRC/scripts/kconfig/merge_config.sh -m -O $B $B/.config /native/config/gki/*.config > /dev/null
  $M olddefconfig
  for c in $(grep -h "^CONFIG_.*=y" /native/config/gki/*.config | cut -d= -f1); do
    grep -q "^$c=y" $B/.config || { echo "ERROR: $c did not stay =y" >&2; exit 1; }
  done
  $M -j$JOBS Image Image.gz modules
  rm -rf /native/out/gki && mkdir -p /native/out/gki/system_dlkm
  cp $B/arch/arm64/boot/Image $B/arch/arm64/boot/Image.gz $B/Module.symvers /native/out/gki/
  $M -s kernelrelease > /native/out/gki/kernel-version
  # The GKI module set (what stock ships in system_dlkm), from the tree'"'"'s own list.
  S=$(mktemp -d)
  $M INSTALL_MOD_PATH=$S INSTALL_MOD_STRIP=1 modules_install
  while read -r m; do
    f=$(find $S/lib/modules -name "$(basename "$m")" | head -1)
    [ -n "$f" ] && cp "$f" /native/out/gki/system_dlkm/ || echo "missing GKI module: $m" >&2
  done < $SRC/android/gki_system_dlkm_modules
  echo "kernel $(cat /native/out/gki/kernel-version), $(ls /native/out/gki/system_dlkm | wc -l) GKI modules"
'
ls -la out/gki
