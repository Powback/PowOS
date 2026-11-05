#!/bin/bash
# Proton ARM64's kernelbase.dll with 0001-kernelbase-wow32-direct-open.patch, built from Valve's own wine tag of the
# Proton the phone runs (Proton Experimental (ARM64) experimental-11.0-20261027b-arm64 = ValveSoftware/wine tag
# experimental-wine-11.0-20261027b) with llvm-mingw (arm64ec + aarch64 = an ARM64X dll, like Valve's), in an aarch64
# container. Only wine's tools and dlls/kernelbase are built (~10 min the first time; the tree and build stay in the
# docker volume powos-steam-poll-wine for the next run).
# Output: pkgs/steam/proton-arm64-kernelbase.dll (gitignored; also put into the shared build-inputs cache as
# steam-proton-arm64-kernelbase.dll). Its sha256 and Valve's go into pkgs/steam/arm64-gate-entry OVERLAY and the
# PKGBUILD - a new Proton build (Valve's file changes) means: bump TAG, rebuild, update both hashes.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../../.." && pwd)
TAG=${TAG:-experimental-wine-11.0-20261027b} LLVM_MINGW=${LLVM_MINGW:-20261006}
OUT=$HERE/out; mkdir -p "$OUT"
docker run --rm --platform linux/arm64 --cpus 12 --memory 16g -v powos-steam-poll-wine:/w -v powos-android-llvm-mingw:/tc \
  -v "$HERE:/src:ro" -v "$OUT:/out" -e TAG="$TAG" -e V="$LLVM_MINGW" menci/archlinuxarm:latest bash -euo pipefail -c '
  tc=/tc/llvm-mingw-$V-ucrt-ubuntu-22.04-aarch64
  [ -x $tc/bin/clang ] || curl -fsSL "https://github.com/mstorsjo/llvm-mingw/releases/download/$V/llvm-mingw-$V-ucrt-ubuntu-22.04-aarch64.tar.xz" | tar -xJ -C /tc
  export PATH=$tc/bin:$PATH
  pacman -Sy --disable-sandbox --noconfirm --needed base-devel flex bison git python perl >/dev/null
  cd /w; [ -f wine/.tag ] && [ "$(cat wine/.tag)" = "$TAG" ] || { rm -rf wine build
    git clone -q --depth 1 --branch "$TAG" https://github.com/ValveSoftware/wine.git wine; echo "$TAG" > wine/.tag; }
  cd wine
  # Proton generates these in its own build (no configure / server protocol / vulkan.h in the tree)
  [ -f configure ] || autoreconf -fi >/dev/null 2>&1
  [ -f include/wine/vulkan.h ] || { tools/make_requests; tools/make_specfiles; python3 dlls/winevulkan/make_vulkan >/dev/null; }
  git checkout -q -- dlls/kernelbase; git apply /src/0001-kernelbase-wow32-direct-open.patch
  mkdir -p /w/build && cd /w/build
  [ -f Makefile ] || ../wine/configure -q --enable-archs=arm64ec,aarch64 --without-x --without-freetype \
    --without-gstreamer --without-vulkan --without-wayland --without-alsa --without-pulse --without-cups --without-dbus \
    --without-gnutls --without-sane --without-usb --without-v4l2 --without-krb5 --without-netapi --without-opencl \
    --without-pcap --without-sdl --without-udev --without-unwind --without-fontconfig --without-gphoto --without-capi \
    --without-oss --without-coreaudio --without-inotify --without-ffmpeg
  make -s -j12 __tooldeps__ >/dev/null && make -s -j12 dlls/kernelbase/all 2>&1 | grep -v "warning:" | grep -E "error" || true
  llvm-strip -o /out/kernelbase.dll dlls/kernelbase/aarch64-windows/kernelbase.dll'
cp "$OUT/kernelbase.dll" "$REPO/targets/android/pkgs/steam/proton-arm64-kernelbase.dll"
"$REPO/tools/agents/build-inputs-cache.sh" put "$OUT/kernelbase.dll" steam-proton-arm64-kernelbase.dll >/dev/null || true
shasum -a 256 "$OUT/kernelbase.dll"
