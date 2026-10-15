#!/bin/bash
# Runs inside the Linux/Wasm build container (build.sh build-kde:<name>): a KDE Frameworks module for PowOS on
# Linux/Wasm, static, against the Qt from build-qt.sh, into the same prefix (/ws/install/qt-wasm32_nommu).
# extra-cmake-modules is CMake files only. Sources: out/linux-wasm/dl/<name>-$KF_VERSION.tar.xz, sha256-checked.
set -euo pipefail
name=$1
KF_VERSION=6.31.0
declare -A SHA256=(
  [extra-cmake-modules]=8f74af329e4c918358bfe54316f8cf4d530c28444595a3e2fb15075f72877f17
  [kirigami]=811a8a150e636216269c0346e62470997fa282113a39e32b2d332bd5969926f0
  [kconfig]=5572e3e098f7cf5d06c78cd941924333c0e84646d2a18aa6b4c9a6f7eae8a5c9
  [kcoreaddons]=d3a843249177a6e51714a7211c73829cb071dbebe4f30404423bbbc57ca5ee95
  [ki18n]=9fa271c7a33b856451de1ed3ff105626c2763fbd3b11d3210b02cb30de43f2ba
  [kwidgetsaddons]=94d1a1ba334a383c38b7f4238d93895ddd2b40f3d6511b16937bc951b542b5a5
  [kcodecs]=2d889f4afd881ae3bc532753c7a2758f45842d4ca828a171d52c8f396128d081
  [karchive]=95acaf5a459593184104e1c157cef415ec59a33e71674186169e0df33cdacaac
  [kguiaddons]=d440bbe350282b03c828d5987a6db1f0a4f5d87a528907bf19e1e5bb76d4b219
  [kwindowsystem]=9968f66ba750432480960e321dd7ec32e2ea19a1596496f39147797684842f57
  [kdbusaddons]=7110f9f07b6cef50a238b01b23f2adcb23552ea1e91e2a9c84f96c5d94a69036
  [kitemviews]=cf0d9bf175619ed76cda99a20b04d349082a7c0e4bd1b2ce1dcf2631131cabcd
  [kitemmodels]=bcd5d95bd300c5b8b6400d087bfbf66efec34d3617aef90878e0c90407f6964c
  [kcrash]=8883c740d5de9aea232060f10c7f3bfdc3f83914b2d91d757ce2c8ed535621a6
  [kpackage]=cdfdc95ccc31f753f30d62918c8098d8544b08c10b70835628839198671c13a3
  [kcolorscheme]=41a8b12a4d9f4fdada70e4853879a2f43a7bf43e870a18c6038eebd956a1f863
  [kservice]=a3e6964ca12aae984f3600fb439c1a906ffe8fecc2111fbfa3fb00052d566e23
  [kglobalaccel]=114f1de1c4e2581f7a371939d7c01d6f836a4e30bb0ec3827c02cddb82209118
  [kiconthemes]=d6558d7dc6ed6de90ef3b5eef905c25fb624147a01d2703329144534a5df58ec
  [kconfigwidgets]=a9aa37565702ac1353c36cf16cc968c8aa336d33bcab9d0ff5419dd0b1dc92df
  [ksvg]=1cacfe9660cdb564edc4c0bf69578776a54001b114ae6fb2a4fa77da25fca2d1
  [kdeclarative]=458eb2b6e15cd368292fb2a9a6c49621d006c306d7c37ca3bd3090520989401e
  [knotifications]=34a9a071585bc3e0993ab19c9a9c7dd4813f5a6104b7b0a470e007f258beaf76
)
# Per-module CMake options. No D-Bus yet (libdbus/dbus-daemon aren't built for Wasm): modules where it's optional
# build without it.
declare -A MODULE_ARGS=(
  [kirigami]="-DUSE_DBUS=OFF"
  # No X11/Wayland platform integrations (linuxfb; see PLASMA-PLAN.md); archive formats beyond zlib off.
  [karchive]="-DWITH_BZIP2=OFF -DWITH_LIBLZMA=OFF -DWITH_OPENSSL=OFF -DWITH_LIBZSTD=OFF"
  [kguiaddons]="-DWITH_WAYLAND=OFF -DWITH_X11=OFF"
  [kwindowsystem]="-DKWINDOWSYSTEM_X11=OFF -DKWINDOWSYSTEM_WAYLAND=OFF"
  [kdbusaddons]="-DWITH_X11=OFF"
  [kcrash]="-DWITH_X11=OFF"
  [kglobalaccel]="-DWITH_X11=OFF"
  [kiconthemes]="-DUSE_BreezeIcons=OFF"
)
PREFIX=/ws/install/qt-wasm32_nommu
TARBALL=/out/dl/$name-$KF_VERSION.tar.xz
SRC=/ws/src/$name-$KF_VERSION
B=/ws/build/kde-$name
JOBS=${JOBS:-12}
export REAL_LLVM=/ws/install/llvm/bin
# HACK: the toolchain's sysroot-only search mode re-roots absolute search hints (pkg-config's include/lib dirs in
# this prefix, which Find modules pass to find_path/find_library) under the musl sysroot, so they are never found.
# Map the re-rooted prefix back with a symlink inside the sysroot. Real fix: install the prefix inside the sysroot.
mkdir -p /ws/install/musl-wasm32_nommu/ws/install
ln -sfn /ws/install/qt-wasm32_nommu /ws/install/musl-wasm32_nommu/ws/install/qt-wasm32_nommu

if [ ! -f "$SRC/CMakeLists.txt" ]; then
  [ -n "${SHA256[$name]:-}" ] || { echo "no sha256 for $name" >&2; exit 1; }
  echo "${SHA256[$name]}  $TARBALL" | sha256sum -c -
  rm -rf "$SRC" && mkdir -p "$SRC"
  tar -xJf "$TARBALL" -C "$SRC" --strip-components=1
fi
# HACK: no translations - compiling a module's poqm/ catalogs needs Qt Linguist's lrelease on the host (qttools),
# not built yet; KDE modules skip them when the directory is absent, so apps run in English. Real fix: build
# qttools' linguist tools in build-qt.sh host-module and drop this.
rm -rf "$SRC/poqm" "$SRC/po"
# PowOS patches over a module (idempotent): patch-<name>.py next to this script, when there is one.
[ ! -f "/powos-lw/patch-$name.py" ] || python3 "/powos-lw/patch-$name.py" "$SRC"
[ "${QT_INCREMENTAL:-}" = 1 ] || rm -rf "$B"
mkdir -p "$B"
# Static, no tests/docs; no RPATHs (static Wasm programs have none - see build-qt.sh). QML modules go where Qt's
# own are (KDE defaults to lib/qml): a static program's qt_import_qml_plugins only finds plugins Qt's scanner sees.
$PREFIX/bin/qt-cmake -G Ninja -S "$SRC" -B "$B" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX \
  -DCMAKE_PREFIX_PATH=$PREFIX -DQT_HOST_PATH=/ws/install/qt-host -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
  -DBUILD_QCH=OFF -DBUILD_DOC=OFF -DKDE_INSTALL_QMLDIR=qml -DCMAKE_SKIP_RPATH=ON -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON ${MODULE_ARGS[$name]:-} ${KDE_ARGS:-}
cmake --build "$B" -j "$JOBS"
cmake --install "$B"
