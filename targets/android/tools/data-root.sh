# Sourced (bash). Where PowOS's write-once bulk lives: the shared NAS folder (PowCDN; ~/Projects/CLAUDE.md "Big
# files"), the same path on the Mac and inside every container. One setting, POWOS_DATA_ROOT; everything else is
# built from it. Build caches, package caches and active scratch (out/work, out/pkgs) stay local in out/.
#   POWOS_IMAGES     this checkout's rootfs images: powos-rootfs.tar.gz (the full build), powos-rootfs-base.tar.gz,
#                    powos-pack-*.tar.gz, each with .sha256, + powos-packs.tsv/-plan.txt. One folder per checkout, so
#                    parallel worktree builds never write the same file.
#   POWOS_PUBLISHED  what http://android.pow/apk/ serves for those names (android-app-dev's nginx maps them here).
# out/powos-rootfs.tar.gz is NOT a build output any more: it is the local build-base rootfs that BUILD_ON_ROOTFS
# packages and plasma-pin.sh build in (the build-inputs cache links it in), and build-rootfs.sh no longer replaces it.
# NAS: ~60 MB/s, no backups; unreachable NAS -> mkdir fails and nothing is written locally.
POWOS_DATA_ROOT=${POWOS_DATA_ROOT:-/mnt/nas/cdn/powos}
_powos_checkout=$(git -C "${HERE:-.}" rev-parse --show-toplevel 2>/dev/null || pwd)
POWOS_IMAGES=${POWOS_IMAGES:-$POWOS_DATA_ROOT/android/images/$(basename "$_powos_checkout")}
POWOS_PUBLISHED=${POWOS_PUBLISHED:-$POWOS_DATA_ROOT/android/published}
unset _powos_checkout
# publish_file <src> <dst>: a hard link when both are on the NAS (instant), else copy beside and rename over, so a
# reader of <dst> sees the whole old or the whole new file, never a half-written one.
publish_file() {
  ln -f "$1" "$2" 2>/dev/null && return 0
  cp "$1" "$(dirname "$2")/.$(basename "$2").new" && mv -f "$(dirname "$2")/.$(basename "$2").new" "$2"
}
