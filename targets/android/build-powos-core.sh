#!/bin/bash
# Builds powos-core: PowOS's own code on the phone as one pacman package of the [powos] repo, so a code change reaches
# every installed phone - rooted or not - as a package update (lib/phone-update.sh, at each session start and from
# Settings) instead of a new base image (docs/PHONE-UPDATES.md). Holds exactly what the image build puts there:
#   bin/ -> /usr/bin, lib/ -> /usr/lib/powos (lib/self-phone.sh self_phone_apply: the manager and fleet_login.py,
#   claude-login, the CLI and its libraries) and the phone's session scripts, shims and play/ launchers at the paths
#   install-powos-android.sh installs them (tools/phone-files.sh reads them from there), plus claude-login's module in
#   /usr/lib/claude-login (tools/stage-claude-login.sh; its /usr/bin wrapper is a shims/ file) and the desktop widgets
#   (desktop/plasmoid -> /usr/share/plasma/plasmoids) - the build fails without claude-login,
#   since a phone whose base predates it gets it only from here (razr 11-14: "claude-login isn't installed").
#   claude-login's own changes don't change the version: they reach phones with the next PowOS code change.
#   And the shared composed module, built (apps/build.sh composed: module.wasm + its source stamp + TS bindings) into
#   /usr/lib/powos/apps/composed, where `powos compose` copies it into every composed widget: composing then needs no
#   Rust on the phone (razr 11-14: "no composed module here", CLI and home's compose UI alike). The build fails without it.
# Version: "<commit count>.g<sha9>" of the newest commit that touched those files - monotonic along origin's history
# (a descendant always has more ancestors), and unchanged code keeps its version, so a ship without code changes
# publishes nothing new (repo-merge.sh never replaces a package with an equal or older one).
#
# Usage: targets/android/build-powos-core.sh [--publish]   out: targets/android/out/powos-core/*.pkg.tar.zst
#   --publish   then merge it into the store's [powos] repo (publish-repo.sh); only from origin's history.
#   POWOS_CORE_REF=<commit> build from that commit instead of HEAD; POWOS_CORE_PKGREL=<n> (default 1) a rebuild of the
#   same code that phones still take as an update; PUBLISH_STORE=<dir> another store (a test repo: <dir>/repo).
#   POWOS_CORE_STAGE=<dir> only writes the PKGBUILD and its sources there (no docker, no package): what tests read.
#   POWOS_CORE_COMPOSED=<dir> a composed module already built (module/ + out/module.wasm, out/.module.sha,
#   out/bindings/) instead of building apps/composed here; with POWOS_CORE_STAGE (no docker) it's required.
set -euo pipefail
# macOS tar adds AppleDouble ._* files for xattrs: in composed.tar they changed the module's tree hash (its stamp then
# no longer matched and the phone ignored the prebuilt wasm). None in any of the package's tars.
export COPYFILE_DISABLE=1
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BASE=${POWOS_BASE_BRANCH:-${POWOS_BASE:-main}}
OUT=$HERE/out/powos-core
PATHS=(bin lib targets/android/session targets/android/shims targets/android/play targets/android/install-powos-android.sh targets/android/tools/phone-files.sh
  config/etc/profile.d units/phone targets/android/rootfs-packs.conf targets/android/tools/split-rootfs.py desktop/plasmoid apps/composed)
publish=""; [ "${1:-}" = --publish ] && publish=1
if [ -n "$publish" ] && [ -z "${PUBLISH_ANY_COMMIT:-}" ] && ! git -C "$ROOT" merge-base --is-ancestor HEAD "origin/$BASE" 2>/dev/null; then
  echo "build-powos-core: not published - $(git -C "$ROOT" rev-parse --short HEAD) isn't on origin/$BASE"
  exit 0
fi
REF=${POWOS_CORE_REF:-HEAD}
REL=${POWOS_CORE_PKGREL:-1}
code=$(git -C "$ROOT" log -1 --format=%H "$REF" -- "${PATHS[@]}")
ver="$(git -C "$ROOT" rev-list --count "$code").g${code:0:9}"
mkdir -p "$OUT"
pkg=$(ls "$OUT"/powos-core-"$ver-$REL"-any.pkg.tar.* 2>/dev/null | head -1 || true)
if [ -z "$pkg" ] || [ -n "${POWOS_CORE_STAGE:-}" ]; then
  if [ -n "${POWOS_CORE_STAGE:-}" ]; then W=$POWOS_CORE_STAGE && mkdir -p "$W"; else
    # Under $HOME: Colima shares only the home folder with Docker.
    mkdir -p "$HOME/.cache"
    W=$(mktemp -d "$HOME/.cache/powos-core.XXXXXX")
    trap 'rm -rf "$W"' EXIT
  fi
  # The paths that commit has (an older one may predate a file), and the map reader from this tree.
  have=(); for p in "${PATHS[@]}"; do git -C "$ROOT" cat-file -e "$code:$p" 2>/dev/null && have+=("$p"); done
  git -C "$ROOT" archive --format=tar --prefix=src/ "$code" -- "${have[@]}" > "$W/powos-src.tar"
  cp "$HERE/tools/phone-files.sh" "$W/phone-files.sh"
  rm -rf "$W/claude-login" && "$HERE/tools/stage-claude-login.sh" "$W/claude-login" ||
    { echo "build-powos-core: no claude-login - not built (installed phones would keep lacking the Claude sign-in)" >&2; exit 1; }
  tar -C "$W" -cf "$W/claude-login.tar" claude-login
  # The composed module at this commit, built (or POWOS_CORE_COMPOSED's build): source + wasm + stamp + bindings.
  rm -rf "$W/composed" "$W/c" && mkdir -p "$W/composed"
  if [ -n "${POWOS_CORE_COMPOSED:-}" ]; then cp -R "$POWOS_CORE_COMPOSED/." "$W/composed/"
  elif [ -z "${POWOS_CORE_STAGE:-}" ]; then
    mkdir -p "$W/c" && git -C "$ROOT" archive --format=tar "$code" -- apps/composed | tar -C "$W/c" -xf -
    "$ROOT/apps/build.sh" "$W/c/apps/composed" > "$W/composed.log" 2>&1 ||
      { tail -20 "$W/composed.log" >&2; echo "build-powos-core: apps/build.sh composed failed (above) - not built" >&2; exit 1; }
    cp -R "$W/c/apps/composed/." "$W/composed/" && rm -rf "$W/composed/module/target"
  fi
  for f in module/Cargo.toml out/module.wasm out/.module.sha out/bindings/index.ts; do
    [ -s "$W/composed/$f" ] || { echo "build-powos-core: no composed module build ($f missing) - not built (composing on a phone would need Rust)" >&2; exit 1; }
  done
  # Its stamp must be this source's (powos-app tree_hash), or powos compose on the phone ignores the wasm.
  python3 -I - "$ROOT/lib/apps/powos-app" "$W/composed" <<'PY' || exit 1
import sys
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
l = SourceFileLoader("powos_app", sys.argv[1]); m = module_from_spec(spec_from_loader("powos_app", l)); l.exec_module(m)
want = m.tree_hash(sys.argv[2] + "/module", skip={"target", "Cargo.lock"})
if open(sys.argv[2] + "/out/.module.sha").read().strip() != want:
    sys.exit("build-powos-core: the composed module's out/.module.sha isn't its source's - not built")
PY
  tar -C "$W" -cf "$W/composed.tar" composed
  cat > "$W/PKGBUILD" <<EOF
pkgname=powos-core
pkgver=$ver
pkgrel=$REL
pkgdesc='PowOS on the phone: the powos CLI, its libraries (manager, fleet login, claude-login) and the session scripts'
arch=(any)
url=https://github.com/powback/powos
license=(custom)
depends=(bash python)
source=(powos-src.tar phone-files.sh claude-login.tar composed.tar)
sha256sums=(SKIP SKIP SKIP SKIP)
options=(!strip !debug)

package() {
  cd "\$srcdir/src"
  . lib/self-phone.sh
  self_phone_apply . $code "\$pkgdir"
  sh "\$srcdir/phone-files.sh" targets/android/install-powos-android.sh | while read -r mode src dest; do
    install -Dm "\$mode" "targets/android/\$src" "\$pkgdir\$dest"
  done
  # claude-login's module (the wrapper in /usr/bin came with the shims/ map above).
  install -Dm 644 -t "\$pkgdir/usr/lib/claude-login" "\$srcdir"/claude-login/*.js
  # The shared composed module, prebuilt (powos compose copies it; lib/apps/powos-compose composed_dir).
  mkdir -p "\$pkgdir/usr/lib/powos/apps/composed"
  cp -R "\$srcdir/composed/module" "\$srcdir/composed/out" "\$pkgdir/usr/lib/powos/apps/composed/"
  chmod -R a+rX "\$pkgdir/usr/lib/powos/apps/composed"
  # What the base should hold, for lib/phone-base-sync.py (phone-update.sh's "base" step: an older base catches up).
  if [ -f targets/android/rootfs-packs.conf ]; then install -Dm 644 targets/android/rootfs-packs.conf "\$pkgdir/usr/share/powos/rootfs-packs.conf"; fi
  if [ -f targets/android/tools/split-rootfs.py ]; then install -Dm 755 targets/android/tools/split-rootfs.py "\$pkgdir/usr/lib/powos/split-rootfs.py"; fi
  # PowOS's desktop widgets (QML only), as install-powos-android.sh puts them over the image's: a widget fix reaches an
  # installed phone with the package, not a new base (11-14: the razr's update widget said "not a bootc deployment").
  if [ -d desktop/plasmoid ]; then mkdir -p "\$pkgdir/usr/share/plasma/plasmoids" && cp -r desktop/plasmoid/. "\$pkgdir/usr/share/plasma/plasmoids/"; fi
}
EOF
  [ -n "${POWOS_CORE_STAGE:-}" ] && { echo "staged: $W"; exit 0; }
  # Built in the container's own /b (a macOS-shared folder can't take the builder's ownership), the package copied back.
  docker run --rm --platform linux/arm64 -v "$W:/w" menci/archlinuxarm:latest bash -c '
    command -v fakeroot >/dev/null || pacman -Sy --disable-sandbox --noconfirm --needed fakeroot >/w/pacman.log 2>&1 || { tail -5 /w/pacman.log; exit 1; }
    useradd -m b && mkdir /b && cp /w/PKGBUILD /w/powos-src.tar /w/phone-files.sh /w/claude-login.tar /w/composed.tar /b/ && chown -R b /b &&
      su b -c "cd /b && makepkg -f --noconfirm --nodeps" >/w/makepkg.log 2>&1 || { tail -20 /w/makepkg.log; exit 1; }
    cp /b/powos-core-*.pkg.tar.* /w/ && chmod 644 /w/powos-core-*.pkg.tar.*' 
  cp "$W"/powos-core-"$ver-$REL"-any.pkg.tar.* "$OUT/"
  pkg=$(ls "$OUT"/powos-core-"$ver-$REL"-any.pkg.tar.* | head -1)
  # Older builds go: publish-repo takes the directory, and only the newest of each counts anyway.
  ls -t "$OUT"/powos-core-*.pkg.tar.* | tail -n +3 | xargs rm -f
fi
echo "built: $pkg"
[ -n "$publish" ] && PUBLISH_PKGS="$OUT" "$HERE/publish-repo.sh" ${PUBLISH_STORE:+"$PUBLISH_STORE"}
true
