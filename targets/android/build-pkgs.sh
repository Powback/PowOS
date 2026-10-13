#!/bin/bash
# Builds the Arch packages the Android rootfs needs beyond Arch Linux ARM's repos, natively in an aarch64
# container. Output: targets/android/out/pkgs/*.pkg.tar.*
#   pkgs/<name>/PKGBUILD   ours (kwin with the Anland backend, fex-emu)
#   recipes.list           PowOS packages Arch Linux ARM doesn't build: the upstream Arch/AUR recipe, built
#                          unchanged for aarch64 (makepkg --ignorearch, as Arch Linux ARM does)
# Usage: targets/android/build-pkgs.sh [package...]   (default: everything in pkgs/ and recipes.list)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/out/pkgs
mkdir -p "$OUT"
IMAGE=menci/archlinuxarm:latest
recipe_source() { awk -v n="$1" '$1 == n {print $2}' "$HERE/recipes.list" 2>/dev/null; }
pkgs=("$@")
[ ${#pkgs[@]} -gt 0 ] || pkgs=($(cd "$HERE/pkgs" && ls) $(awk '!/^#/ && NF {print $1}' "$HERE/recipes.list"))

for p in "${pkgs[@]}"; do
  echo "== $p"
  if [ -d "$HERE/pkgs/$p" ]; then src=local; else src=$(recipe_source "$p"); fi
  [ -n "$src" ] || { echo "build-pkgs: $p is neither in pkgs/ nor in recipes.list" >&2; exit 1; }
  # A failed run leaves its scratch volume (set -e exits before the rm below); a stale src/ then
  # re-applies the patches onto an already patched tree. Always start clean, and clean up on exit.
  docker volume rm -f "powos-android-pkg-$p" >/dev/null 2>&1 || true
  trap 'docker volume rm -f "powos-android-pkg-'"$p"'" >/dev/null 2>&1 || true' EXIT
  local_mount=(); [ "$src" = local ] && local_mount=(-v "$HERE/pkgs/$p:/pkg:ro")
  # Resource caps: shares the Colima VM with live services. A volume keeps makepkg's src/ off the
  # macOS bind mount (faster, and keeps Linux ownership).
  docker run --rm --platform linux/arm64 --cpus 8 --memory 16g ${local_mount[@]+"${local_mount[@]}"} \
    -e PKG="$p" -e SRC="$src" -v "$HERE/recipes:/fixups:ro" -v "$OUT:/out" -v "powos-android-pkg-$p:/build" "$IMAGE" bash -c '
      set -euo pipefail
      # HACK: pacman 7 download sandbox (Landlock) is not permitted in Docker.
      grep -q "^DisableSandbox" /etc/pacman.conf || sed -i "/^\[options\]/a DisableSandbox" /etc/pacman.conf
      pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinuxarm >/dev/null 2>&1
      pacman -Syu --noconfirm --needed base-devel git >/dev/null
      id builder >/dev/null 2>&1 || useradd -m builder
      echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
      case $SRC in
        local)    cp -r /pkg/. /build/ ;;
        official) git clone -q --depth 1 "https://gitlab.archlinux.org/archlinux/packaging/packages/$PKG.git" /build/r && cp -r /build/r/. /build/ ;;
        aur)      git clone -q --depth 1 "https://aur.archlinux.org/$PKG.git" /build/r && cp -r /build/r/. /build/ ;;
      esac
      # recipes/<name>.sh: the smallest change that lets an upstream recipe build on aarch64 (each one says why).
      [ -f "/fixups/$PKG.sh" ] && (cd /build && bash "/fixups/$PKG.sh")
      # Our own packages built earlier satisfy dependencies of later ones (e.g. an AUR recipe needing another).
      ls /out/*.pkg.tar.* >/dev/null 2>&1 && pacman -U --noconfirm --needed /out/*.pkg.tar.* >/dev/null 2>&1 || true
      chown -R builder /build && cd /build
      ignorearch=""; [ "$SRC" = local ] || ignorearch=--ignorearch
      sudo -u builder MAKEFLAGS="-j8" makepkg -sf --noconfirm --skippgpcheck --nocheck $ignorearch
      cp /build/*.pkg.tar.* /out/'
  # Scratch only (KWin's build tree is several GB) on the Docker disk shared with live services.
  docker volume rm -f "powos-android-pkg-$p" >/dev/null 2>&1 || true
done
ls -la "$OUT"
