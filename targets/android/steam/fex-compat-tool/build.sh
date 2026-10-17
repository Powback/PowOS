#!/bin/bash
# Builds FEX at the exact commit Valve's Steam FEX tool ships (steamapps/common/FEX-Emu/VERSIONS.txt), plus our
# futex_waitv probe (0001-*.patch), natively for aarch64. Output: out/usr/bin/{FEX,FEXServer,FEXServerManager}, out/VERSION.
# Meant to replace only usr/bin/FEX in a copy of Valve's tool (see README.md); Valve's thunks/RootFS stay.
# Usage: targets/android/steam/fex-compat-tool/build.sh   (COMMIT=<sha> to follow a newer Valve tool)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
COMMIT=${COMMIT:-37265b109a4bba9e10241972dfcb3d1fdb8f3f9a}   # FEX-2607-76-g37265b1, Valve's FEX tool 2026-10
IMAGE=menci/archlinuxarm:latest
mkdir -p "$HERE/out"
docker run --rm --platform linux/arm64 -e COMMIT="$COMMIT" -v powos-fex-compat-src:/src -v "$HERE:/tool" \
  "$IMAGE" bash -euo pipefail -c '
  # HACK: pacman 7 download sandbox (Landlock) is not permitted in Docker (same as build-pkgs.sh).
  grep -q "^DisableSandbox" /etc/pacman.conf || sed -i "/^\[options\]/a DisableSandbox" /etc/pacman.conf
  pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinuxarm >/dev/null 2>&1
  # gcc: the static libstdc++/libgcc the link below uses (gcc-libs only has the shared ones).
  pacman -Syu --noconfirm --needed git cmake ninja clang lld llvm gcc python openssl file >/dev/null
  S=/src/FEX
  if [ ! -d $S/.git ]; then git clone -q https://github.com/FEX-Emu/FEX.git $S; fi
  git -C $S fetch -q origin "$COMMIT" 2>/dev/null || git -C $S fetch -q origin
  git -C $S checkout -q -f "$COMMIT"
  git -C $S clean -qfdx
  git -C $S submodule update -q --init --recursive --depth 1
  git -C $S apply /tool/0001-futex_waitv-probe-host.patch
  D=$(git -C $S describe --tags)
  # BUILD_STEAM_SUPPORT as Valve builds the tool: FEX/FEXServer behave differently inside Steam'"'"'s container (FEX_STEAM_SUPPORT;
  # without it FEX finds no RootFS there and "Failure to setup client"). Prefix /usr, also as Valve'"'"'s: the global config
  # path (/usr/share/fex-emu) is compiled in, and the container provides it there. Release, no thunks (Valve'"'"'s own stay in the tool), no tests. libstdc++/libgcc linked in: the tool may run FEX
  # inside the Steam Runtime container (emulator.json container_argv), whose libstdc++ can be older than Arch'"'"'s.
  # Same switches as pkgs/fex-emu (generic armv8.2-a tuning) minus thunks.
  cmake -S $S -B $S/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DUSE_LINKER=lld -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++ -static-libgcc" \
    -DENABLE_LTO=TRUE -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=FALSE -DENABLE_CCACHE=FALSE \
    -DTUNE_CPU=generic -DTUNE_ARCH=armv8.2-a -DBUILD_THUNKS=FALSE -DENABLE_ASSERTIONS=FALSE \
    -DBUILD_STEAM_SUPPORT=TRUE -DCMAKE_INSTALL_PREFIX=/usr > /dev/null
  ninja -C $S/build FEX FEXServer FEXServerManager > /tmp/ninja.log 2>&1 || { tail -30 /tmp/ninja.log; exit 1; }
  mkdir -p /tool/out/usr/bin
  for b in FEX FEXServer FEXServerManager; do install -m 755 $(find $S/build -type f -name $b -perm -u+x | head -1) /tool/out/usr/bin/$b; done
  {
    echo "describe: $D (+0001-futex_waitv-probe-host.patch)"
    for b in FEX FEXServer; do echo "$b: $(stat -c %s /tool/out/usr/bin/$b) bytes, $(file -b /tool/out/usr/bin/$b | cut -d, -f1-2)"; done
    # The newest glibc symbol version the binary needs: must be <= the glibc it runs against (host or Steam Runtime).
    echo "max GLIBC symbol: $(objdump -T /tool/out/usr/bin/FEX | grep -o "GLIBC_[0-9.]*" | sort -uV | tail -1)"
  } > /tool/out/VERSION
  cat /tool/out/VERSION
'
