#!/bin/sh
# Prints the newest build of each package in a directory of *.pkg.tar.* files, one path per line.
# out/pkgs keeps every build (kwin 3.3 next to 3.4, three fex-emu); pacman -U refuses a set with two builds of
# one package ("duplicate target"), and "ls | head -1" would pick the oldest.
# Usage: newest-pkgs.sh <dir> [package-name]   (with a name: only that package's newest build)
for f in "$1"/*.pkg.tar.*; do
  [ -e "$f" ] || continue
  b=${f##*/}
  # <name>-<pkgver>-<pkgrel>-<arch>.pkg.tar.<ext>; names may contain dashes, the last three fields never do.
  n=$(printf '%s\n' "$b" | sed -E 's/-[^-]+-[^-]+-[^-]+\.pkg\.tar\..*$//')
  v=$(printf '%s\n' "$b" | sed -E 's/^.*-([^-]+-[^-]+)-[^-]+\.pkg\.tar\..*$/\1/')
  [ -z "${2:-}" ] || [ "$n" = "$2" ] || continue
  printf '%s %s %s\n' "$n" "$v" "$f"
done | sort -k1,1 -k2,2V | awk '{last[$1] = $3} END {for (n in last) print last[n]}' | sort
