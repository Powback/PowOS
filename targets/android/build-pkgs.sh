#!/bin/bash
# Builds our Arch packages for the Android rootfs (pkgs/*/PKGBUILD; today: kwin with the Anland backend)
# natively in an aarch64 container. Output: targets/android/out/pkgs/*.pkg.tar.zst
# Usage: targets/android/build-pkgs.sh [package...]   (default: all under pkgs/)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/out/pkgs
mkdir -p "$OUT"
IMAGE=menci/archlinuxarm:latest
pkgs=("$@"); [ ${#pkgs[@]} -gt 0 ] || pkgs=($(cd "$HERE/pkgs" && ls))

for p in "${pkgs[@]}"; do
  echo "== $p"
  # A failed run leaves its scratch volume (set -e exits before the rm below); a stale src/ then
  # re-applies the patches onto an already patched tree. Always start clean, and clean up on exit.
  docker volume rm -f "powos-android-pkg-$p" >/dev/null 2>&1 || true
  trap 'docker volume rm -f "powos-android-pkg-'"$p"'" >/dev/null 2>&1 || true' EXIT
  # Resource caps: shares the Colima VM with live services. A volume keeps makepkg's src/ off the
  # macOS bind mount (faster, and keeps Linux ownership).
  docker run --rm --platform linux/arm64 --cpus 8 --memory 16g \
    -v "$HERE/pkgs/$p:/pkg:ro" -v "$OUT:/out" -v "powos-android-pkg-$p:/build" "$IMAGE" bash -c '
      set -euo pipefail
      # HACK: pacman 7 download sandbox (Landlock) is not permitted in Docker.
      grep -q "^DisableSandbox" /etc/pacman.conf || sed -i "/^\[options\]/a DisableSandbox" /etc/pacman.conf
      pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinuxarm >/dev/null 2>&1
      pacman -Syu --noconfirm --needed base-devel >/dev/null
      id builder >/dev/null 2>&1 || useradd -m builder
      echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
      cp -r /pkg/. /build/ && chown -R builder /build && cd /build
      sudo -u builder MAKEFLAGS="-j8" makepkg -sf --noconfirm --skippgpcheck
      cp /build/*.pkg.tar.* /out/'
  # Scratch only (KWin's build tree is several GB) on the Docker disk shared with live services.
  docker volume rm -f "powos-android-pkg-$p" >/dev/null 2>&1 || true
done
ls -la "$OUT"
