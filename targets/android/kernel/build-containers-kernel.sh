#!/bin/bash
# The OnePlus Open kernel with container resource control - pids.max, cpu.max and nftables - for PowOS's
# rootless podman, built so the phone's own vendor modules keep loading (docs/PHONE-KERNEL-CONTAINERS.md).
#
# Base: exactly the kernel the phone runs now (targets/native/build-gki-kernel.sh: OnePlusOSS android13-5.15,
# CPH2551 16.0.3.500 sources, gki_defconfig + targets/native/config/gki/*.config + futex_waitv), plus
#   config/containers.config   CGROUP_PIDS, CFS_BANDWIDTH, NF_TABLES=m + NFT_*
#   patches/*.patch            what makes those KMI-preserving (pids in net_prio's slot, bandwidth state
#                              beside cfs_rq/task_group, nf_tables gencursor out of struct net)
# Out (targets/android/kernel/out/, not committed):
#   Image, Image.gz, Module.symvers, kernel-version, config
#   modules/*.ko + modules/load-order.txt   nf_tables & co., signed, insmod order
#   boot-powos-containers.img                 stock boot_b header + this kernel, for `fastboot boot`
#   kmi-check.txt, layout-diff.txt, SHA256SUMS
# Checks (the build fails on any): every fragment option stays as asked; no other config line differs from
# the running kernel's; tools/kmi-check.py against the phone's vendor modules (vendor_boot ramdisk +
# vendor_dlkm, see extract-vendor-modules.sh); no struct layout change vs the running kernel (pahole, BTF)
# except the allow-listed internal ones.
# Same toolchain as stock (Google clang r450784e, under Rosetta), same cache volume (powos-gki-cache) as
# targets/native - its own source worktree and build dir, so the running kernel's tree stays untouched.
#   ./build-containers-kernel.sh            JOBS=8 ./build-containers-kernel.sh
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../../.. && pwd)
NATIVE=$REPO/targets/native
BRANCH=${BRANCH:-oneplus/sm8550_b_16.0.0_oneplus_open}
STOCK_BOOT=${STOCK_BOOT:-$NATIVE/backup/8e5d600d/boot_b.img}
STOCK_BOOT_SHA=07dba7ac86e02ea0ff628250991d638da09b8e0680886aee1933df8f56bc4d3b  # stock 16.0.5.1301 boot.img
VMODS=out/vendor-modules
[ -d $VMODS/vendor_boot ] || ./extract-vendor-modules.sh
mkdir -p out
start=$(date +%s)
docker build -q --platform linux/amd64 -t powos-gki-builder "$NATIVE/docker/gki" > /dev/null
docker run --rm --platform linux/amd64 -v powos-gki-cache:/cache -v "$REPO":/repo -e BRANCH="$BRANCH" \
  -e JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}" powos-gki-builder bash -euo pipefail -c '
  git config --global --add safe.directory "*"
  CLANG=/cache/clang-r450784e
  [ -x $CLANG/bin/clang ] || { echo "no clang in the cache: run targets/native/build-gki-kernel.sh once" >&2; exit 1; }
  ROOT=/cache/oplus-${BRANCH//\//_}
  BASE=$ROOT/kernel_platform/common            # targets/native/build-gki-kernel.sh: the running kernel'"'"'s tree
  BASEB=/cache/build-${BRANCH//\//_}           # ... and its build dir (baseline for the config + layout checks)
  [ -f $BASE/Makefile ] && [ -f $BASEB/vmlinux ] || { echo "run targets/native/build-gki-kernel.sh first" >&2; exit 1; }
  # Own worktree next to common/ (the tree links into ../../vendor/oplus), recreated whenever the patch set changes.
  SRC=$ROOT/kernel_platform/common-containers
  PATCHES="$(ls /repo/targets/native/patches/gki/*.patch /repo/targets/android/kernel/patches/*.patch)"
  SUM=$(cat $PATCHES | sha256sum | cut -c1-16)
  if [ "$(cat $SRC/.powos-patches 2>/dev/null)" != "$SUM" ]; then
    git -C $BASE worktree remove --force $SRC 2>/dev/null || rm -rf $SRC
    git -C $BASE worktree prune
    git -C $BASE worktree add -q --detach $SRC HEAD
    for p in $PATCHES; do git -C $SRC apply "$p" && echo "patch: ${p##*/}"; done
    echo $SUM > $SRC/.powos-patches
  fi
  git -C $SRC log -1 --format="source: %H %cd"
  B=/cache/build-containers; mkdir -p $B/certs
  # The running kernel'"'"'s module signing key, so modules of either build verify on both kernels.
  [ -f $B/certs/signing_key.pem ] || cp $BASEB/certs/signing_key.pem $BASEB/certs/x509.genkey $B/certs/
  export PATH=$CLANG/bin:$PATH
  M="make -C $SRC O=$B ARCH=arm64 LLVM=1 LLVM_IAS=1 HOSTLDFLAGS=-fuse-ld=lld -s"
  $M gki_defconfig
  $SRC/scripts/kconfig/merge_config.sh -m -O $B $B/.config /repo/targets/native/config/gki/*.config \
    /repo/targets/android/kernel/config/containers.config > /dev/null
  $M olddefconfig
  for c in $(grep -h "^CONFIG_" /repo/targets/android/kernel/config/containers.config); do
    grep -qx "$c" $B/.config || { echo "ERROR: $c did not stay" >&2; exit 1; }
  done
  # Nothing else may change against the running kernel: only our options and what nf_tables pulls in (=m, or
  # its own NF_TABLES_*/NFT_* sub-options).
  extra=$(diff <(grep "^CONFIG" $BASEB/.config | sort) <(grep "^CONFIG" $B/.config | sort) | grep "^[<>]" |
    grep -vxF -f <(grep -h "^CONFIG_" /repo/targets/android/kernel/config/containers.config | sed "s/^/> /") |
    grep -vE "^> CONFIG_(NFT_[A-Z0-9_]+|NF_TABLES_[A-Z0-9_]+)=(m|y)$" || true)
  [ -z "$extra" ] || { echo "ERROR: unexpected config changes:" >&2; echo "$extra" >&2; exit 1; }
  $M -j$JOBS Image Image.gz modules
  O=/repo/targets/android/kernel/out
  rm -rf $O/modules && mkdir -p $O/modules
  cp $B/arch/arm64/boot/Image $B/arch/arm64/boot/Image.gz $B/Module.symvers $O/
  cp $B/.config $O/config
  $M -s kernelrelease > $O/kernel-version
  # The netfilter modules nftables needs (stripped, then signed by modules_install), and their insmod order.
  S=$(mktemp -d)
  $M INSTALL_MOD_PATH=$S INSTALL_MOD_STRIP=1 modules_install
  find $S/lib/modules -name "*.ko" | grep -E "/(nf_tables|nft_[a-z0-9_]+|nf_log_syslog)\.ko$" | xargs -I{} cp {} $O/modules/
  python3 - $O/modules <<"PY"
import os, subprocess, sys
d = sys.argv[1]
mods = {f[:-3] for f in os.listdir(d) if f.endswith(".ko")}
dep = {m: [x for x in subprocess.run(["modinfo", "-F", "depends", f"{d}/{m}.ko"], capture_output=True, text=True)
           .stdout.strip().split(",") if x] for m in mods}
order, seen = [], set()
def visit(m):
    if m in seen: return
    seen.add(m)
    for x in dep[m]:
        if x in mods: visit(x)
        else: sys.exit(f"{m} needs {x}, which is neither built in nor here")
    order.append(m)
for m in sorted(mods): visit(m)
open(f"{d}/load-order.txt", "w").write("".join(f"{m}.ko\n" for m in order))
print(f"{len(order)} modules, insmod order in modules/load-order.txt")
PY
  # Struct layouts against the running kernel (BTF in both vmlinux): every type both have must be identical.
  # Allowed: struct cfs_bandwidth (empty in the base and only reached through tg_cfs_bandwidth() now).
  pahole -F btf $BASEB/vmlinux > /tmp/base.pahole
  pahole -F btf $B/vmlinux > /tmp/new.pahole
  python3 /repo/targets/android/kernel/tools/layout-diff.py /tmp/base.pahole /tmp/new.pahole \
    "struct cfs_bandwidth" > $O/layout-diff.txt || true
  echo "kernel $(cat $O/kernel-version)"
'
cat out/layout-diff.txt | tail -1
grep -q "^OK" out/layout-diff.txt || { echo "layout check failed: out/layout-diff.txt" >&2; exit 1; }
# Symbol CRCs: would the phone's vendor modules (and the new ones) load on this kernel?
python3 "$NATIVE/tools/kmi-check.py" out/Module.symvers $VMODS/vendor_boot $VMODS/vendor_dlkm out/modules | tee out/kmi-check.txt
# fastboot boot image: the stock boot_b (header v4, kernel only - ramdisk is init_boot, DTB is vendor_boot)
# with this kernel; header, OS version and patch level from stock.
echo "$STOCK_BOOT_SHA  $STOCK_BOOT" | shasum -a 256 -c - > /dev/null || { echo "$STOCK_BOOT is not the stock boot" >&2; exit 1; }
T=$NATIVE/out/tools/mkbootimg
[ -f $T/mkbootimg.py ] || git clone -q --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg $T
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
args=$(python3 $T/unpack_bootimg.py --boot_img "$STOCK_BOOT" --out "$W/s" --format mkbootimg)
eval python3 $T/mkbootimg.py "$(printf '%s' "$args" | sed "s#--kernel [^ ]*#--kernel out/Image#")" -o out/boot-powos-containers.img
python3 $T/unpack_bootimg.py --boot_img out/boot-powos-containers.img --out "$W/u" > /dev/null
cmp "$W/u/kernel" out/Image && echo "boot image: kernel round-trips"
# RAM-only experiment, never flashed: the same kernel with memory + cpu kept off cgroup v1, so they come up on
# the v2 hierarchy next to pids and podman can apply --memory/--cpus. Android's own /dev/memcg and /dev/cpuctl
# then fail to mount (logged, not fatal) - per-app memcg and the cpuctl boost groups are gone for that boot.
eval python3 $T/mkbootimg.py "$(printf '%s' "$args" | sed -e "s#--kernel [^ ]*#--kernel out/Image#" \
  -e "s#--cmdline ''#--cmdline 'cgroup_no_v1=memory,cpu'#")" -o out/boot-powos-containers-v2test.img
python3 $T/unpack_bootimg.py --boot_img out/boot-powos-containers-v2test.img --out "$W/v" | grep "command line"
(cd out && shasum -a 256 Image Image.gz boot-powos-containers.img boot-powos-containers-v2test.img Module.symvers \
  modules/*.ko > SHA256SUMS)
echo "build took $(( ($(date +%s) - start) / 60 )) min"
cat out/SHA256SUMS | head -4
