#!/bin/bash
# targets/android/pkgs/kwin/src-tree.sh [OUT_DIR]: a patched KWin source tree to diff the NEXT patch from, in one
# call instead of ~10 (download kwin-6.7.5.tar.xz, extract, apply 0001..00NN by hand - friction f86, f98).
#
# Reads PKGBUILD itself (pkgver, _patches, sha256sums) so it never drifts from the real patch set. Downloads the
# pristine kwin-$pkgver.tar.xz once, through the shared Mac-side cache (tools/agents/build-inputs-cache.sh,
# content-addressed, never pruned) so a second worktree's run or a second call here doesn't refetch 70+ MB. Verifies
# it against PKGBUILD's own sha256sums[0] before trusting it.
#
# Output: OUT_DIR/kwin-$pkgver, a git repo: one commit "pristine kwin-$pkgver", then one commit per existing patch
# (named after the patch file), so the tree's HEAD is exactly what `prepare()` leaves makepkg with. To write the
# next patch: edit files in the tree, then `git -C OUT_DIR/kwin-$pkgver diff > .../00NN-your-change.patch` (or
# `git format-patch -1 HEAD` after committing, and rename/renumber it) - never hand-apply patches again to get here.
# Prints the tree path and the next free patch number (see also tools/agents/pkg-claim.sh to reserve it).
#
# OUT_DIR default: targets/android/pkgs/kwin/out/src-tree (gitignored by targets/android/.gitignore's out/).
# Re-running with the same pkgver/patches is a fast no-op check, not a rebuild: it skips straight to printing the
# path if the tree's HEAD already matches the patch count PKGBUILD expects.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$here/../../../.." && pwd)
OUT=${1:-$here/out/src-tree}
PKGBUILD=$here/PKGBUILD

# Read PKGBUILD's own variables (array assignments only - prepare()/build()/package() are defined, never called).
pkgname= pkgver= _patches=() sha256sums=()
# shellcheck disable=SC1090
source "$PKGBUILD"
_dirver=$(echo "$pkgver" | cut -d. -f1-3)
tree=$OUT/$pkgname-$pkgver
n=${#_patches[@]}
next=$(printf '%04d' $((n + 1)))

if [ -d "$tree/.git" ] && [ "$(git -C "$tree" log --oneline | wc -l | tr -d ' ')" = $((n + 1)) ]; then
  echo "$tree (already has all $n patches - nothing to do)"
  echo "next free patch number: $next"
  exit 0
fi
rm -rf "$tree"
mkdir -p "$OUT"

bic=$REPO/tools/agents/build-inputs-cache.sh
tarball=$OUT/$pkgname-$pkgver.tar.xz
got=0
if [ -x "$bic" ]; then
  "$bic" get "kwin-src/$pkgname-$pkgver.tar.xz" "$tarball" >/dev/null 2>&1 && got=1 || true
fi
if [ "$got" != 1 ]; then
  echo "downloading $pkgname-$pkgver.tar.xz (not in the shared cache yet)..."
  curl -fsSL "https://download.kde.org/stable/plasma/$_dirver/$pkgname-$pkgver.tar.xz" -o "$tarball"
  [ -x "$bic" ] && "$bic" put "$tarball" "kwin-src/$pkgname-$pkgver.tar.xz" >/dev/null || true
fi
got_sum=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
[ "$got_sum" = "${sha256sums[0]}" ] || { echo "src-tree.sh: $tarball doesn't match PKGBUILD's sha256sums[0] ($got_sum != ${sha256sums[0]}) - refusing a bad source tree" >&2; exit 1; }

tar -xf "$tarball" -C "$OUT"
git -C "$tree" init -q
git -C "$tree" -c user.email=agent@powos -c user.name=powos-agent add -A
git -C "$tree" -c user.email=agent@powos -c user.name=powos-agent commit -q -m "pristine $pkgname-$pkgver"

for p in "${_patches[@]}"; do
  patch -d "$tree" -p1 -N < "$here/$p"
  git -C "$tree" -c user.email=agent@powos -c user.name=powos-agent add -A
  git -C "$tree" -c user.email=agent@powos -c user.name=powos-agent commit -q -m "$p"
done

echo "$tree"
echo "next free patch number: $next (tools/agents/pkg-claim.sh reserve kwin-patch to take it)"
