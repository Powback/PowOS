#!/bin/bash
# Builds Linux/Wasm (github.com/joelseverin/linux-wasm: the kernel compiled to WebAssembly, every program compiled to
# Wasm too - no CPU emulation) - the research track for PowOS in the browser at near-native speed.
#   targets/web/linux-wasm/build.sh [linux-wasm.sh targets, run in order; default: all]
#   e.g. build.sh fetch-kernel fetch-musl fetch-busybox build
# Source: targets/web/reference/linux-wasm (git clone, gitignored). Workspace: a sparse ext4 image on the Mac disk
# (out/linux-wasm/workspace.ext4), loop-mounted in a privileged container - LLVM's build is tens of GB of small files,
# too much for the Docker disk (shared with live services) and slow on a bind mount. Kept between runs (incremental).
# Artifacts: out/linux-wasm/install/ (vmlinux.wasm, initramfs, runtime). After build-initramfs, run powos-initramfs.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/reference/linux-wasm
OUT=$HERE/out/linux-wasm
[ -x "$SRC/linux-wasm.sh" ] || { echo "clone it first: git clone https://github.com/joelseverin/linux-wasm $SRC" >&2; exit 1; }
mkdir -p "$OUT"
docker build -q -t linux-wasm-base:dev "$SRC/docker/linux-wasm-base" > /dev/null
docker run --rm --privileged -v "$SRC:/linux-wasm" -v "$OUT:/out" -v "$HERE/linux-wasm:/powos-lw:ro" -e JOBS="${JOBS:-12}" linux-wasm-base:dev bash -c '
  set -e
  [ -f /out/workspace.ext4 ] || { truncate -s 80G /out/workspace.ext4; mkfs.ext4 -q -F /out/workspace.ext4; }
  mkdir -p /ws && mount -o loop /out/workspace.ext4 /ws
  trap "umount -l /ws" EXIT
  export LW_WORKSPACE=/ws LW_JOBS_LLVM_LINK=4 LW_JOBS_LLVM_COMPILE=$JOBS LW_JOBS_KERNEL_COMPILE=$JOBS \
         LW_JOBS_MUSL_COMPILE=$JOBS LW_JOBS_BUSYBOX_COMPILE=$JOBS
  # Each argument is a linux-wasm.sh target, run in order. Fetches are big git clones that sometimes drop
  # ("remote end hung up"): retried, the partial clone removed first.
  for cmd in '"${*:-all}"'; do
    case $cmd in
      # The upstream kernel clone (--shallow-exclude=v7.0: a history cut GitHub computes per request) dropped three
      # times in a row, and the retries got us rate-limited (HTTP 429). The build only needs the files: a plain depth-1
      # clone of the branch is the cheapest thing GitHub serves.
      fetch-kernel)
        for try in 1 2 3; do
          rm -rf /ws/src/kernel
          git clone -q --depth 1 -b wasm-7.0 --single-branch --no-tags https://github.com/joelseverin/linux.git /ws/src/kernel \
            && python3 /powos-lw/patch-kernel.py /ws/src/kernel && break
          [ $try = 3 ] && exit 1; echo "kernel clone failed, retrying in 60 s"; sleep 60
        done ;;
      # PowOS patches over upstream (also applied right after fetch-busybox): hush command substitution via clone().
      patch-busybox) python3 /powos-lw/patch-hush-cmdsubst.py /ws/src/busybox/shell/hush.c ;;
      # musl: threads get a real Wasm TLS block (patch-musl-threads.py). Also applied right after fetch-musl.
      patch-musl) python3 /powos-lw/patch-musl-threads.py /ws/src/musl ;;
      # C++ runtime for PowOS programs (Qt, KDE, ...): libc++ + libc++abi, static (build-libcxx.sh).
      build-libcxx) bash /powos-lw/build-libcxx.sh ;;
      # libpowos-wasm-support.a: what C++ programs need that musl and libc++abi lack (build-support.sh).
      build-support) bash /powos-lw/build-support.sh ;;
      # Qt (qtbase): host tools, then static wasm32 linuxfb + evdev (build-qt.sh).
      build-qt-host) bash /powos-lw/build-qt.sh host ;;
      build-qt) bash /powos-lw/build-qt.sh target ;;
      # PowOS kernel additions: the streamed disk driver + EROFS (patch-kernel.py). Also run right after fetch-kernel.
      patch-kernel) python3 /powos-lw/patch-kernel.py /ws/src/kernel ;;
      # PowOS layer over upstream initramfs: our files (linux-wasm/initramfs/) appended to the archive; the kernel
      # unpacks entries in order, so ours replace upstream ones (e.g. /init).
      powos-initramfs)
        I=/ws/install/initramfs-wasm32_nommu
        gunzip -f $I/initramfs.cpio.gz
        (cd /powos-lw/initramfs && find . -mindepth 1 | cpio -o --format=newc -A -O $I/initramfs.cpio)
        gzip -f $I/initramfs.cpio ;;
      fetch-*) n=${cmd#fetch-}
               for try in 1 2 3; do
                 rm -rf "/ws/src/$n"
                 /linux-wasm/linux-wasm.sh "$cmd" && { [ "$n" != busybox ] || python3 /powos-lw/patch-hush-cmdsubst.py /ws/src/busybox/shell/hush.c; } \
                   && { [ "$n" != musl ] || python3 /powos-lw/patch-musl-threads.py /ws/src/musl; } && break
                 [ $try = 3 ] && exit 1; echo "fetch $n failed, retrying"; sleep 10
               done ;;
      *) /linux-wasm/linux-wasm.sh "$cmd" ;;
    esac
  done
  rm -rf /out/install && mkdir -p /out/install && rsync -a --exclude llvm /ws/install/ /out/install/
  ls -la /out/install
'
