#!/bin/bash
# Builds native qemu-system-aarch64 from the SAME source as the browser build (build-qemu.sh: pinned qemu-wasm +
# targets/web/qemu/ + patches), so a VM snapshot made natively loads in the browser (same QEMU version, devices
# and machine type). Its chunked disk reads the published disk directory as files. Output: out/qemu-native/
#
# Uses build-qemu.sh's source copy in the powos-web-qemu-build volume (run build-qemu.sh first).
# Usage: targets/web/build-qemu-native.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/out/qemu-native}
mkdir -p "$OUT"
IMAGE=powos-web-qemu-native
docker build -q -t "$IMAGE" - >/dev/null <<'EOF'
FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends build-essential ninja-build meson python3 \
    python3-venv pkg-config libglib2.0-dev libpixman-1-dev zlib1g-dev libfdt-dev flex bison git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
EOF
docker run --rm --cpus 8 --memory 12g -v "$HERE/qemu:/powos:ro" -v powos-web-qemu-build:/vol -v "$OUT:/out" \
  "$IMAGE" bash -c '
    set -euo pipefail
    cp -a /powos/. /vol/src/   # our sources may have changed since build-qemu.sh
    mkdir -p /vol/native && cd /vol/native
    [ -f build.ninja ] || /vol/src/configure --target-list=aarch64-softmmu --without-default-features \
      --enable-system --enable-tcg --with-coroutine=ucontext --disable-docs --disable-werror
    make -j"$(nproc)" qemu-system-aarch64
    cp qemu-system-aarch64 /out/
    ls -la /out'
