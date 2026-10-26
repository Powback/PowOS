#!/bin/bash
# Builds the Arch packages the Android rootfs needs beyond Arch Linux ARM's repos, natively in an aarch64
# container. Output: targets/android/out/pkgs/*.pkg.tar.*
#   pkgs/<name>/PKGBUILD   ours (kwin with the Anland backend, fex-emu)
#   recipes.list           PowOS packages Arch Linux ARM doesn't build: the upstream Arch/AUR recipe, built
#                          unchanged for aarch64 (makepkg --ignorearch, as Arch Linux ARM does)
# Usage: targets/android/build-pkgs.sh [package...]   (default: everything in pkgs/ and recipes.list)
#   pkgs/<name>/FORKS     local git repos the package builds from (a fork of ours that has no remote, e.g. SpacetimeDB):
#                          "<name> <host path>" per line, mounted read-only at /forks/<name>; the PKGBUILD takes
#                          git+file:///forks/<name>#commit=<hash>, pinned, so the build stays reproducible.
#   pkgs/<name>/BUILD_ON_ROOTFS   build in PowOS's own rootfs (out/powos-rootfs.tar.gz), not in today's Arch Linux ARM:
#                          for packages tied to the Plasma version PowOS ships (kwin). Arch Linux ARM moves on (on
#                          2026-10-17 it had half of Plasma at 6.8: kscreenlocker 6.8 broke KWin 6.7.5's build);
#                          the rootfs has exactly what the package will run with.
#   PKG_SCRATCH=<dir in the Colima VM>, e.g. /var/tmp/powos-pkgs: build tree on the VM's root disk instead of
#   a Docker volume, for when the Docker disk (shared with live services) is too full. Must be VM-local, NOT a
#   /Users path: virtiofs reports shifting owners and git then refuses the tree ("dubious ownership").
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
OUT=$HERE/out/pkgs
mkdir -p "$OUT"
IMAGE=menci/archlinuxarm:latest
# This run's own id: the scratch volume is named with it (f70 - two worktrees building the same package
# shared ONE docker volume named only after the package, so one run's start-clean rm deleted the other's
# live build tree mid-build). Different build-pkgs.sh processes always get different pids.
RUN_ID=$$
BIC=$REPO/tools/agents/build-inputs-cache.sh
# PowOS's rootfs as an image (once per rootfs build, named after its checksum), for BUILD_ON_ROOTFS packages.
# A fresh worktree has neither file (friction f87): try the shared build-inputs cache before giving up - another
# worktree's build-rootfs.sh run, or worktree.sh new's own link, may already have put it there.
rootfs_image() {
  local tar=$HERE/out/powos-rootfs.tar.gz img
  if [ ! -f "$tar" ] && [ -x "$BIC" ]; then
    "$BIC" get powos-rootfs.tar.gz "$tar" >/dev/null 2>&1 &&
      "$BIC" get powos-rootfs.tar.gz.sha256 "$tar.sha256" >/dev/null 2>&1 &&
      echo "build-pkgs: $tar filled from the shared cache" >&2 || true
  fi
  [ -f "$tar" ] || { echo "build-pkgs: $tar is missing (targets/android/build-rootfs.sh)" >&2; exit 1; }
  img=powos-android-rootfs:$(cut -c1-12 "$tar.sha256")
  docker image inspect "$img" >/dev/null 2>&1 || docker import --platform linux/arm64 "$tar" "$img" >/dev/null
  echo "$img"
}
recipe_source() { awk -v n="$1" '$1 == n {print $2}' "$HERE/recipes.list" 2>/dev/null; }
# fill_missing_inputs <pkgdir> <name>: a local package's OWN gitignored, non-glob inputs (pkgs/steam's
# sysvipc-emu.tar.gz: friction f76 - it existed only in the hands-off powos-multiplatform tree, agents
# hard-linked it by hand) filled from the shared cache under "<name>-<filename>" (worktree.sh new links the
# well-known ones in at creation time already; this is the fallback for whatever it missed or a worktree older
# than the cache).
fill_missing_inputs() {
  local pkgdir=$1 p=$2 pat
  [ -x "$BIC" ] && [ -f "$pkgdir/.gitignore" ] || return 0
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*|*/*|*'*'*|*'?'*) continue ;; esac   # plain filenames only - no globs, no subpaths
    [ -e "$pkgdir/$pat" ] && continue
    "$BIC" get "$p-$pat" "$pkgdir/$pat" >/dev/null 2>&1 && echo "build-pkgs: $p/$pat filled from the shared cache" >&2 || true
  done < "$pkgdir/.gitignore"
}
# Empties a PKG_SCRATCH dir; it lives in the VM, not on this Mac, hence through a container.
wipe_scratch() { docker run --rm --platform linux/arm64 -v "$scratch:/build" "$IMAGE" find /build -mindepth 1 -delete; }
pkgs=("$@")
[ ${#pkgs[@]} -gt 0 ] || pkgs=($(cd "$HERE/pkgs" && ls) $(awk '!/^#/ && NF {print $1}' "$HERE/recipes.list"))

for p in "${pkgs[@]}"; do
  echo "== $p"
  if [ -d "$HERE/pkgs/$p" ]; then src=local; else src=$(recipe_source "$p"); fi
  [ -n "$src" ] || { echo "build-pkgs: $p is neither in pkgs/ nor in recipes.list" >&2; exit 1; }
  # A failed run leaves its scratch volume (set -e exits before the rm below); a stale src/ then
  # re-applies the patches onto an already patched tree. Always start clean, and clean up on exit.
  # Named with this run's pid (RUN_ID): a volume named only "...-$p" is shared by every concurrent build of
  # that package, so one run's start-clean rm or exit-trap rm deletes another run's live build tree (f70).
  docker volume rm -f "powos-android-pkg-$p-$RUN_ID" >/dev/null 2>&1 || true
  trap 'docker volume rm -f "powos-android-pkg-'"$p-$RUN_ID"'" >/dev/null 2>&1 || true' EXIT
  [ "$src" = local ] && fill_missing_inputs "$HERE/pkgs/$p" "$p"
  local_mount=(); [ "$src" = local ] && local_mount=(-v "$HERE/pkgs/$p:/pkg:ro")
  forks=""
  if [ -f "$HERE/pkgs/$p/FORKS" ]; then
    while read -r fname fpath; do
      case $fname in ''|'#'*) continue ;; esac
      fpath=${fpath/#\~/$HOME}
      [ -d "$fpath/.git" ] || { echo "build-pkgs: $p needs the git repo $fpath (pkgs/$p/FORKS)" >&2; exit 1; }
      local_mount+=(-v "$fpath:/forks/$fname:ro"); forks="$forks /forks/$fname"
    done < "$HERE/pkgs/$p/FORKS"
  fi
  image=$IMAGE base=repo
  if [ -f "$HERE/pkgs/$p/BUILD_ON_ROOTFS" ]; then image=$(rootfs_image) base=rootfs; fi
  scratch="powos-android-pkg-$p-$RUN_ID"
  if [ -n "${PKG_SCRATCH:-}" ]; then
    scratch=$PKG_SCRATCH/$p-$RUN_ID; wipe_scratch
  fi
  # Resource caps: shares the Colima VM with live services. A volume keeps makepkg's src/ off the
  # macOS bind mount (faster, and keeps Linux ownership).
  # Compiler cache across builds (a volume shared by every package): the source tree is fresh each time (a reused
  # one re-applied the patches), so without it a one-file change to KWin recompiled all of it (~20 min).
  before_build=$(ls "$OUT" 2>/dev/null || true)
  # The Mac-wide build slot (tools/agents/build-slot.sh): this is one of the heavy CPU-bound builds that
  # piled up concurrently and starved the shell gate and compile-check (f30, f62/f66-69).
  "$HERE/../../tools/agents/build-slot.sh" "build-pkgs $p ($HERE)" -- \
  docker run --rm --platform linux/arm64 --cpus 8 --memory 16g ${local_mount[@]+"${local_mount[@]}"} \
    -v powos-android-ccache:/ccache \
    -e PKG="$p" -e SRC="$src" -e BASE="$base" -e FORKS="$forks" -v "$HERE/recipes:/fixups:ro" -v "$HERE/tools:/tools:ro" -v "$OUT:/out" -v "$scratch:/build" "$image" bash -c '
      set -euo pipefail
      # HACK: pacman 7 download sandbox (Landlock) is not permitted in Docker.
      grep -q "^DisableSandbox" /etc/pacman.conf || sed -i "/^\[options\]/a DisableSandbox" /etc/pacman.conf
      pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinuxarm >/dev/null 2>&1
      # A build container is no booted system: the hooks that reload D-Bus, refresh PackageKit and load new kernel
      # modules after an install have none of those and failed ("error: command failed to execute correctly"). Masked the way pacman documents it - a
      # same-named hook in /etc/pacman.d/hooks that is /dev/null.
      mkdir -p /etc/pacman.d/hooks
      for h in dbus-reload 90-packagekit-refresh 36-systemd-modules-load; do ln -sf /dev/null "/etc/pacman.d/hooks/$h.hook"; done
      # (--needed says "is up to date -- skipping" for each package already there: not news, filtered.)
      # On the rootfs: no upgrade - its packages are what this one is built against (see BUILD_ON_ROOTFS).
      if [ "$BASE" = rootfs ]; then pacman -Sy --noconfirm --needed base-devel git >/dev/null 2> >(grep -v "is up to date -- skipping" >&2)
      else pacman -Syu --noconfirm --needed base-devel git >/dev/null 2> >(grep -v "is up to date -- skipping" >&2); fi
      pacman -S --noconfirm --needed ccache >/dev/null 2> >(grep -v "is up to date -- skipping" >&2)
      sed -i "s/^BUILDENV=(\(.*\)!ccache/BUILDENV=(\1ccache/" /etc/makepkg.conf
      id builder >/dev/null 2>&1 || useradd -m builder
      # A fork mounted from the Mac is owned by another uid (virtiofs): git refuses to clone it ("dubious ownership")
      # unless it is trusted, by name, for this container only.
      for f in $FORKS; do git config --system --add safe.directory "$f"; git config --system --add safe.directory "$f/.git"; done
      # Base images assign different builder UIDs; each owns its cache subdirectory.
      cache=/ccache/uid-$(id -u builder)
      mkdir -p "$cache" && chown builder "$cache"
      echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
      case $SRC in
        local)    cp -r /pkg/. /build/ ;;
        official) git clone -q --depth 1 "https://gitlab.archlinux.org/archlinux/packaging/packages/$PKG.git" /build/r && cp -r /build/r/. /build/ ;;
        aur)      git clone -q --depth 1 "https://aur.archlinux.org/$PKG.git" /build/r && cp -r /build/r/. /build/ ;;
      esac
      # recipes/<name>.sh: the smallest change that lets an upstream recipe build on aarch64 (each one says why).
      [ -f "/fixups/$PKG.sh" ] && (cd /build && bash "/fixups/$PKG.sh")
      # Our own packages built earlier satisfy dependencies of later ones (e.g. an AUR recipe needing another, kwin
      # our kglobalacceld): a local repository ahead of the distribution repositories, so makepkg takes ours, and
      # only what this build needs - installing all of them pulled in unrelated packages whose install scripts fail
      # in a container (speech-dispatcher: systemctl --global). Ours that are installed already are brought to our
      # newest build. The newest build of each: out/ keeps old ones.
      ours=$(sh /tools/newest-pkgs.sh /out)
      if [ -n "$ours" ]; then
        mkdir -p /ours && cp $ours /ours/ && repo-add -q /ours/ours.db.tar.gz /ours/*.pkg.tar.*
        grep -q "^\[ours\]" /etc/pacman.conf ||
          sed -i "0,/^\[core\]/s//[ours]\nSigLevel = Optional TrustAll\nServer = file:\/\/\/ours\n\n[core]/" /etc/pacman.conf
        pacman -Sy >/dev/null
        installed=$(pacman -Slq ours | while read -r p; do if pacman -Q "$p" >/dev/null 2>&1; then echo "$p"; fi; done)
        [ -z "$installed" ] || pacman -S --noconfirm --needed $installed >/dev/null 2> >(grep -v "is up to date -- skipping" >&2) ||
          echo "build-pkgs: could not update our earlier builds" >&2
      fi
      chown -R builder /build && cd /build
      ignorearch=""; [ "$SRC" = local ] || ignorearch=--ignorearch
      # The real sudo, also for makepkg'"'"'s own (sudo pacman, for the dependencies): PowOS'"'"'s rootfs has a sudo
      # stand-in in /usr/local/bin, first on PATH, which knows neither -u nor VAR=value.
      /usr/bin/sudo -u builder env PATH=/usr/bin:/usr/sbin MAKEFLAGS="-j8" CCACHE_DIR="$cache" CCACHE_MAXSIZE=30G \
        CCACHE_BASEDIR=/build makepkg -sf --noconfirm --skippgpcheck --nocheck $ignorearch
      cp /build/*.pkg.tar.* /out/'
  # Scratch only (KWin's build tree is several GB) on the Docker disk shared with live services.
  docker volume rm -f "powos-android-pkg-$p-$RUN_ID" >/dev/null 2>&1 || true
  [ -z "${PKG_SCRATCH:-}" ] || wipe_scratch
  # Into the shared cache too (never a worktree that must be kept alive just to hold a built package - friction
  # f87, f116, and "keep built packages findable after a worktree is removed"): only what THIS run just produced
  # (a before/after diff of $OUT, not every historical build already sitting there).
  if [ -x "$BIC" ]; then
    comm -13 <(printf '%s\n' "$before_build") <(ls "$OUT" 2>/dev/null) | while IFS= read -r f; do
      [ -n "$f" ] && "$BIC" put "$OUT/$f" "pkgs/$f" || true
    done
  fi
done
ls -la "$OUT"
