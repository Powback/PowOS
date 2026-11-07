#!/bin/bash
# Proton ARM64's kernelbase.dll with 0001-kernelbase-wow32-direct-open.patch, built from Valve's own wine tag of the
# Proton the phone runs (Proton Experimental (ARM64) experimental-11.0-20261027b-arm64 = ValveSoftware/wine tag
# experimental-wine-11.0-20261027b) with llvm-mingw (arm64ec + aarch64 = an ARM64X dll, like Valve's), in an aarch64
# container. Only wine's tools and dlls/kernelbase are built (~10 min the first time; the tree and build stay in the
# docker volume powos-steam-poll-wine for the next run).
# Output: pkgs/steam/proton-arm64-kernelbase.dll (gitignored; also put into the shared build-inputs cache as
# steam-proton-arm64-kernelbase.dll). Its sha256 and Valve's go into a row of pkgs/steam/powos_steam_tools.py
# OVERLAYS and the PKGBUILD's sha256sums.
# A new Proton build (Steam updated Proton; the launch then says "fix kernelbase-wow32 not applied: ... Make one:
# PROTON_VERSION=<v> targets/android/steam/proton-overlay/build.sh"): run exactly that - the wine tag comes from
# Proton's own version (experimental-11.0-20261027b-arm64 -> experimental-wine-11.0-20261027b, TAG= overrides) - then
# add the printed row (VALVE_SHA= the phone's kernelbase.dll sha256, as the launch logged its first 12 characters).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../../.." && pwd)
PROTON_VERSION=${PROTON_VERSION:-experimental-11.0-20261027b-arm64}
if [ -z "${TAG:-}" ]; then
  TAG=$(python3 -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("t",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.wine_tag(sys.argv[2]) or "")' \
        "$REPO/targets/android/pkgs/steam/powos_steam_tools.py" "$PROTON_VERSION")
  [ -n "$TAG" ] || { echo "no wine tag known for Proton $PROTON_VERSION: set TAG=<ValveSoftware/wine tag>" >&2; exit 1; }
fi
LLVM_MINGW=${LLVM_MINGW:-20261006}
# A patch the tag already has (upstream took it) or that no longer applies stops the build, by name (git apply below).
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
OURS=$(shasum -a 256 "$OUT/kernelbase.dll" | cut -d' ' -f1)
echo "$OURS  kernelbase.dll ($TAG)"
echo "powos_steam_tools.py OVERLAYS row:"
echo "    (\"files/lib/wine/aarch64-windows/kernelbase.dll\", \"${VALVE_SHA:-<the Valve file sha256>}\", \"$OURS\", \"overlay-kernelbase.dll\", \"$PROTON_VERSION\"),"
