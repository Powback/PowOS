#!/bin/bash
# tools/agents/build-inputs-cache.sh: a shared, content-addressed Mac-side cache for the Android package build's
# gitignored inputs and its own built packages, so a fresh worktree.sh worktree isn't missing them and a built
# package doesn't need its worktree kept alive to stay findable (friction f76, f87, f116: out/powos-rootfs.tar.gz,
# pkgs/steam/sysvipc-emu.tar.gz and built kwin/steam packages existed only in the hands-off powos-multiplatform tree
# or in a worktree an agent was told to keep around just to hold one file - agents hard-linked them by hand).
#
#   build-inputs-cache.sh put <file> <logical/path>   content-address <file> into blobs/<sha256> (hardlink; a real
#        copy if <file> is on another volume) and point <logical/path> at it. Never touches or removes <file>, and
#        never removes an older blob another logical path or worktree may still reference - NOTHING here deletes.
#        Re-running with identical content is a no-op; new content at the same logical path just repoints it.
#   build-inputs-cache.sh get <logical/path> <dest>   hardlink (or copy) the cached blob to <dest>, making its
#        directory first. Prints <dest> and exits 0; "miss: <logical/path>" to stderr and exit 1 if it isn't cached.
#   build-inputs-cache.sh list                        every logical path this cache knows, its blob's short hash
#        and size.
#
# CACHE=${POWOS_BUILD_INPUTS_CACHE:-~/.cache/powos-build-inputs}. Rule: never prune - a hardlinked blob costs no
# extra space on the Mac's one APFS volume (du -sh is for the content once, not once per logical path), so there is
# no "disk pressure" reason to ever delete one, and this script has no command that does.
set -euo pipefail
CACHE=${POWOS_BUILD_INPUTS_CACHE:-$HOME/.cache/powos-build-inputs}
BLOBS=$CACHE/blobs
mkdir -p "$BLOBS"

# link_or_copy <src> <dst>: hardlink (same volume: free, and survives the source moving) with a real copy fallback
# (the source and $CACHE are on different volumes/filesystems - ln -f then fails EXDEV).
link_or_copy() { ln -f "$1" "$2" 2>/dev/null || cp -p "$1" "$2"; }
realpath_() { python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1"; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
put)
  [ $# -eq 3 ] || { usage >&2; exit 2; }
  src=$2; logical=$3
  [ -f "$src" ] || { echo "build-inputs-cache.sh: no such file: $src" >&2; exit 1; }
  case "$logical" in /*|*..*) echo "build-inputs-cache.sh: logical path must be relative, no '..': $logical" >&2; exit 2 ;; esac
  hash=$(shasum -a 256 "$src" | cut -d' ' -f1)
  blob=$BLOBS/$hash
  [ -e "$blob" ] || link_or_copy "$src" "$blob"
  dest=$CACHE/$logical
  mkdir -p "$(dirname "$dest")"
  ln -sfn "$blob" "$dest"
  echo "$logical -> blobs/${hash:0:12} ($(du -h "$blob" | cut -f1 | tr -d ' '))"
  ;;
get)
  [ $# -eq 3 ] || { usage >&2; exit 2; }
  logical=$2; dest=$3
  src=$CACHE/$logical
  [ -e "$src" ] || { echo "miss: $logical" >&2; exit 1; }
  target=$(realpath_ "$src")
  [ -f "$target" ] || { echo "miss: $logical (blob gone: $target)" >&2; exit 1; }
  mkdir -p "$(dirname "$dest")"
  link_or_copy "$target" "$dest"
  echo "$dest"
  ;;
list)
  [ -d "$CACHE" ] || exit 0
  find "$CACHE" -type l ! -path "$BLOBS/*" 2>/dev/null | sort | while read -r l; do
    rel=${l#"$CACHE"/}
    t=$(realpath_ "$l")
    sz=$([ -f "$t" ] && du -h "$t" 2>/dev/null | cut -f1 | tr -d ' ' || echo '?')
    printf '%-60s %-14s %s\n' "$rel" "$(basename "$t" | cut -c1-12)" "$sz"
  done
  ;;
*) usage; exit 2 ;;
esac
