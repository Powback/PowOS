#!/bin/bash
# Plasma at our KWin's version, as a local pacman repo for build-rootfs.sh: out/plasma-pin/powos-plasma.db + packages.
#
# Our KWin (pkgs/kwin, BUILD_ON_ROOTFS) is built inside PowOS's own rootfs (out/powos-rootfs.tar.gz, Plasma 6.7.5) and
# links that Plasma's libraries (kscreenlocker, kdecoration, libplasma, ...). Arch Linux ARM moved Plasma to 6.8.1 in
# 2026-10, so a rootfs built from today's repos put 6.8.1 under kwin 6.7.5: "undefined symbol ScreenLocker::KSldApp::lock",
# KWin never starts, no Linux window on any phone (the 11-04 base). Arch Linux ARM keeps no archive of old builds (the
# tardis archive closed 2026-06-02), so the 6.7.5 packages are taken from the one place they still exist exactly: the
# rootfs our KWin builds against. Every installed package at KWin's Plasma version is repackaged from its installed files
# by tools/repack-installed.py (its files, metadata, dependencies and install script from the local pacman database).
# HACK: repackaged from an installed rootfs, not built from source; the real fix is Plasma built at KWin's version by
# build-pkgs.sh (BUILD_ON_ROOTFS recipes at the 6.7.5 tags) or KWin moved to Arch's current Plasma (pkgs/kwin's patches
# ported to 6.8). Packages whose 6.7.5 build never was in that rootfs (plasma-nm, plasma-pa, bluedevil, ... added to
# PowOS later) are not here; install-powos-android.sh holds them out (see POWOS_PLASMA_HELD there).
#
# Usage: targets/android/tools/plasma-pin.sh     Output: targets/android/out/plasma-pin/ (replaced each run)
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=$HERE/out/plasma-pin
TAR=$HERE/out/powos-rootfs.tar.gz
[ -f "$TAR" ] || { echo "plasma-pin: $TAR is missing (the rootfs pkgs/kwin builds on)" >&2; exit 1; }
VER=$(sed -n 's/^pkgver=//p' "$HERE/pkgs/kwin/PKGBUILD")
IMG=powos-android-rootfs:$(cut -c1-12 "$TAR.sha256")
docker image inspect "$IMG" >/dev/null 2>&1 || docker import --platform linux/arm64 "$TAR" "$IMG" >/dev/null
# Ours (out/pkgs: kwin, kglobalacceld, plasma-desktop, breeze) come from build-pkgs.sh, never from here.
ours=$("$HERE/tools/newest-pkgs.sh" "$HERE/out/pkgs" | xargs -n1 basename | sed -E 's/-[^-]+-[^-]+-[^-]+\.pkg\.tar\..*$//' | tr '\n' ' ')
rm -rf "$OUT" && mkdir -p "$OUT"
docker run --rm --platform linux/arm64 --cpus 4 --memory 4g -e VER="$VER" -e OURS="$ours" -v "$OUT:/out" -v "$HERE/tools:/tools:ro" "$IMG" bash -c '
  set -euo pipefail
  pin=$(for d in /var/lib/pacman/local/*/desc; do
    awk "/^%NAME%/{getline; n=\$0} /^%VERSION%/{getline; v=\$0} END{print n, v}" "$d"
  done | awk -v ver="$VER" -v ours=" $OURS " "{v=\$2; sub(/^[0-9]+:/, \"\", v); sub(/-[^-]*\$/, \"\", v)
    if (v == ver && index(ours, \" \" \$1 \" \") == 0) print \$1}")
  cd /out
  python3 -I /tools/repack-installed.py /out $pin >/dev/null
  repo-add -q powos-plasma.db.tar.gz *.pkg.tar.*
  echo "$pin" | tr "\n" " " > pinned.txt
'
echo "plasma-pin: Plasma $VER, $(wc -w < "$OUT/pinned.txt") packages in ${OUT#$HERE/}: $(cat "$OUT/pinned.txt")"
