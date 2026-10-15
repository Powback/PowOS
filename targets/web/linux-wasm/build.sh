#!/bin/bash
# Builds Linux/Wasm (github.com/joelseverin/linux-wasm: the kernel compiled to WebAssembly, every program compiled to
# Wasm too - no CPU emulation) - the research track for PowOS in the browser at near-native speed.
#   targets/web/linux-wasm/build.sh [linux-wasm.sh args, default: all]
# Source: targets/web/reference/linux-wasm (git clone, gitignored). Workspace: a sparse ext4 image on the Mac disk
# (out/linux-wasm/workspace.ext4), loop-mounted in a privileged container - LLVM's build is tens of GB of small files,
# too much for the Docker disk (shared with live services) and slow on a bind mount. Kept between runs (incremental).
# Artifacts: out/linux-wasm/install/ (vmlinux.wasm, initramfs, runtime).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/reference/linux-wasm
OUT=$HERE/out/linux-wasm
[ -x "$SRC/linux-wasm.sh" ] || { echo "clone it first: git clone https://github.com/joelseverin/linux-wasm $SRC" >&2; exit 1; }
mkdir -p "$OUT"
docker build -q -t linux-wasm-base:dev "$SRC/docker/linux-wasm-base" > /dev/null
docker run --rm --privileged -v "$SRC:/linux-wasm" -v "$OUT:/out" -e JOBS="${JOBS:-12}" linux-wasm-base:dev bash -c '
  set -e
  [ -f /out/workspace.ext4 ] || { truncate -s 80G /out/workspace.ext4; mkfs.ext4 -q -F /out/workspace.ext4; }
  mkdir -p /ws && mount -o loop /out/workspace.ext4 /ws
  trap "umount -l /ws" EXIT
  export LW_WORKSPACE=/ws LW_JOBS_LLVM_LINK=4 LW_JOBS_LLVM_COMPILE=$JOBS LW_JOBS_KERNEL_COMPILE=$JOBS \
         LW_JOBS_MUSL_COMPILE=$JOBS LW_JOBS_BUSYBOX_COMPILE=$JOBS
  /linux-wasm/linux-wasm.sh '"${*:-all}"'
  rm -rf /out/install && mkdir -p /out/install && rsync -a --exclude llvm /ws/install/ /out/install/
  ls -la /out/install
'
