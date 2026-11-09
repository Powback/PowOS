#!/usr/bin/env bash
# publish-repo.sh's merge (targets/android/tools/repo-merge.sh): publishing from one worktree's out/pkgs must ADD to
# the [powos] repo, never replace it (2026-11-04: a publish left the repo holding one package). Two publishes from
# two directories ->
#   1. both packages are in powos.db, with their files,
#   2. a newer version replaces an older one (and the older file goes),
#   3. an older version never replaces a newer one,
#   4. the db copies (powos.db, powos.files) are plain files, and a hard-linked source package is never written to.
# Needs repo-add/vercmp/bsdtar (Arch): here, else menci/archlinuxarm through docker; SKIP without either.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
MERGE=$HERE/targets/android/tools/repo-merge.sh

if [ "${PUBLISH_REPO_INNER:-}" != 1 ]; then
  if command -v repo-add >/dev/null && command -v vercmp >/dev/null; then
    PUBLISH_REPO_INNER=1 exec bash "$0"
  elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    # Without arm64 emulation (an x86 CI runner, no binfmt/qemu) the image can't start: rc 255, no output (issue #10).
    docker run --rm --platform linux/arm64 menci/archlinuxarm:latest true >/dev/null 2>&1 || {
      echo "SKIP test-publish-repo: docker can't run linux/arm64 here (no qemu binfmt)"; exit 0; }
    # label=disable: on an SELinux-enforcing engine (.58's podman) container_t may not read a $HOME bind mount
    # (bash: Permission denied, rc=126); a no-op on Colima. Never :z - that would relabel the checkout.
    # HACK: --user nobody - on an SELinux host every file carries security.selinux, repo-add's bsdtar archives it into
    # powos.db and, as root, restores it on the next repo-add, which fails ("Cannot restore extended attributes",
    # .58). Non-root bsdtar skips xattr restore. Real fix: repo-merge.sh drops xattrs itself if publishing ever runs
    # on an SELinux host (today it runs in archlinuxarm on the Mac). Registry: docs/REMOTE-POWOS.md section 4.
    exec docker run --rm --platform linux/arm64 --security-opt label=disable --user 65534:65534 -e PUBLISH_REPO_INNER=1 -v "$HERE:$HERE:ro" menci/archlinuxarm:latest \
      bash "$HERE/test/tier1/test-publish-repo.sh"
  fi
  echo "SKIP test-publish-repo: no repo-add (Arch) and no docker"
  exit 0
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL test-publish-repo: $*"; exit 1; }

# A minimal package: repo-add reads only .PKGINFO.
mkpkg() { # <dir> <name> <ver-rel>
  local d=$W/build-$2-$3
  mkdir -p "$d" "$1"
  printf 'pkgname = %s\npkgbase = %s\npkgver = %s\npkgdesc = test\narch = aarch64\nsize = 1\n' "$2" "$2" "$3" > "$d/.PKGINFO"
  (cd "$d" && bsdtar -czf "$1/$2-$3-aarch64.pkg.tar.gz" .PKGINFO)
}
db() { bsdtar -xOf "$W/repo/powos.db.tar.gz" '*/desc' | awk '/^%NAME%$/{getline n} /^%VERSION%$/{getline v; print n, v}' | sort; }

mkpkg "$W/a" kwin 6.7.5-3.63
mkpkg "$W/a" kwin 6.7.5-3.2          # an older build beside it in the same out/pkgs
mkpkg "$W/b" vulkan-freedreno-kgsl 27.0.0_devel.20261029.geb3e7fd4-1
bash "$MERGE" "$W/repo" "$W/a" >/dev/null
bash "$MERGE" "$W/repo" "$W/b" >/dev/null
got=$(db)
[ "$got" = "kwin 6.7.5-3.63
vulkan-freedreno-kgsl 27.0.0_devel.20261029.geb3e7fd4-1" ] || fail "two publishes: want both packages, got: $got"
[ -e "$W/repo/kwin-6.7.5-3.63-aarch64.pkg.tar.gz" ] || fail "kwin's file missing"
[ -e "$W/repo/vulkan-freedreno-kgsl-27.0.0_devel.20261029.geb3e7fd4-1-aarch64.pkg.tar.gz" ] || fail "turnip's file missing"

# Older never replaces newer: a tree with an older turnip and an older kwin.
mkpkg "$W/c" vulkan-freedreno-kgsl 26.3.0-2
mkpkg "$W/c" kwin 6.7.5-3.9
out=$(bash "$MERGE" "$W/repo" "$W/c")
got=$(db)
[ "$got" = "kwin 6.7.5-3.63
vulkan-freedreno-kgsl 27.0.0_devel.20261029.geb3e7fd4-1" ] || fail "older publish downgraded: $got"
[ ! -e "$W/repo/vulkan-freedreno-kgsl-26.3.0-2-aarch64.pkg.tar.gz" ] || fail "older file was copied in"
echo "$out" | grep -q '^kept vulkan-freedreno-kgsl' || fail "no 'kept' line for the older turnip: $out"

# Newer replaces older; the source file is hard-linked (as across worktrees) and must stay untouched.
mkpkg "$W/d" kwin 6.7.5-3.64
ln "$W/d/kwin-6.7.5-3.64-aarch64.pkg.tar.gz" "$W/link"
sum=$(sha256sum < "$W/link")
bash "$MERGE" "$W/repo" "$W/d" >/dev/null
got=$(db)
[ "$got" = "kwin 6.7.5-3.64
vulkan-freedreno-kgsl 27.0.0_devel.20261029.geb3e7fd4-1" ] || fail "newer kwin didn't replace: $got"
[ ! -e "$W/repo/kwin-6.7.5-3.63-aarch64.pkg.tar.gz" ] || fail "superseded kwin file left behind"
[ "$(sha256sum < "$W/link")" = "$sum" ] || fail "hard-linked source package changed"
[ "$(stat -c %h "$W/repo/kwin-6.7.5-3.64-aarch64.pkg.tar.gz")" = 1 ] || fail "repo file shares an inode with the source"

# --remove takes a package out; its file is held beside the repo, not deleted; the rest stays.
bash "$MERGE" "$W/repo" --remove kwin >/dev/null
got=$(db)
[ "$got" = "vulkan-freedreno-kgsl 27.0.0_devel.20261029.geb3e7fd4-1" ] || fail "--remove kwin: $got"
[ -e "$W/repo-held/kwin-6.7.5-3.64-aarch64.pkg.tar.gz" ] && [ ! -e "$W/repo/kwin-6.7.5-3.64-aarch64.pkg.tar.gz" ] ||
  fail "--remove: kwin's file not moved to repo-held"

for f in powos.db powos.files; do
  [ -f "$W/repo/$f" ] && [ ! -L "$W/repo/$f" ] || fail "$f isn't a plain file"
done
[ -z "$(ls -A "$W/repo" | grep '^\.')" ] || fail "staging/lock left behind: $(ls -A "$W/repo")"
echo "PASS test-publish-repo"
