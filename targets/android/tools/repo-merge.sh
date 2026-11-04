#!/bin/bash
# Merges a directory of built packages into the [powos] pacman repo (publish-repo.sh runs it in an Arch Linux ARM
# container: it needs repo-add, vercmp and bsdtar).
#   repo-merge.sh <repo-dir> <pkgs-dir>
# ADDS, never replaces the repo: every agent worktree has its own out/pkgs, and the old publish (rm -f the repo,
# copy in out/pkgs) left the phone's repo holding one worktree's single package (2026-11-04: just
# vulkan-freedreno-kgsl; kwin, xwayland-kgsl and every other PowOS package were gone). Rules:
#   - a package the repo doesn't have is added; one it has is replaced only by a NEWER version (vercmp), never by
#     an older or equal one; packages not in <pkgs-dir> stay as they are. Only the newest build of each package
#     in <pkgs-dir> counts (out/pkgs keeps every build).
#   - atomic for readers: new package files are renamed in first, then the new database (built on a copy in a
#     staging dir beside it, renamed over the old one), and only then the superseded package files go. Nothing is
#     written in place: out/pkgs files are hard-linked across worktrees, so an in-place write would change them all.
#   - one publish at a time (a mkdir lock in the repo dir; two agents publishing at once would lose one's adds).
set -euo pipefail
REPO=${1:?usage: repo-merge.sh <repo-dir> <pkgs-dir>}
PKGS=${2:?usage: repo-merge.sh <repo-dir> <pkgs-dir>}
DB=powos.db.tar.gz
FILES=powos.files.tar.gz
mkdir -p "$REPO"

lock=$REPO/.publish.lock
for i in $(seq 900); do
  mkdir "$lock" 2>/dev/null && break
  # A publish killed mid-way leaves its lock; one older than 15 minutes is stale (a merge takes seconds).
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then rm -rf "$lock"; continue; fi
  [ "$i" = 900 ] && { echo "repo-merge: $lock held for 15 min - another publish is stuck" >&2; exit 1; }
  sleep 1
done
stage=$(mktemp -d "$REPO/.stage.XXXXXX")
trap 'rm -rf "$stage" "$lock"' EXIT

# What the repo holds now, from its database (the files on disk may include leftovers): name -> version, filename.
declare -A have_ver have_file
if [ -e "$REPO/$DB" ]; then
  while read -r n v f; do have_ver[$n]=$v; have_file[$n]=$f; done < <(
    bsdtar -xOf "$REPO/$DB" '*/desc' | awk '
      function out() { if (n != "") print n, v, f; n = v = f = "" }
      /^%FILENAME%$/ { out(); k = "f"; next }
      /^%NAME%$/ { k = "n"; next }
      /^%VERSION%$/ { k = "v"; next }
      /^%/ { k = ""; next }
      /^$/ { k = ""; next }
      k == "f" { f = $0 } k == "n" { n = $0 } k == "v" { v = $0 }
      END { out() }')
  cp "$REPO/$DB" "$stage/$DB"
  [ -e "$REPO/$FILES" ] && cp "$REPO/$FILES" "$stage/$FILES"
fi

# The newest build of each package in <pkgs-dir>, by pacman's own version order.
declare -A new_ver new_path
for p in "$PKGS"/*.pkg.tar.*; do
  [ -e "$p" ] || continue
  case $p in *.sig) continue ;; esac
  info=$(bsdtar -xOf "$p" .PKGINFO)
  n=$(printf '%s\n' "$info" | sed -n 's/^pkgname = //p')
  v=$(printf '%s\n' "$info" | sed -n 's/^pkgver = //p')
  [ -n "$n" ] && [ -n "$v" ] || { echo "repo-merge: $p has no pkgname/pkgver in .PKGINFO - skipped" >&2; continue; }
  if [ -z "${new_ver[$n]:-}" ] || [ "$(vercmp "$v" "${new_ver[$n]}")" -gt 0 ]; then new_ver[$n]=$v; new_path[$n]=$p; fi
done

added=() gone=()
for n in $(printf '%s\n' "${!new_ver[@]}" | sort); do
  v=${new_ver[$n]} old=${have_ver[$n]:-}
  if [ -n "$old" ]; then
    c=$(vercmp "$v" "$old")
    if [ "$c" -lt 0 ]; then echo "kept $n $old (newer than this publish's $v)"; continue; fi
    if [ "$c" -eq 0 ] && [ -e "$REPO/${have_file[$n]}" ]; then echo "unchanged $n $v"; continue; fi
  fi
  b=${new_path[$n]##*/}
  cp "${new_path[$n]}" "$stage/$b"
  added+=("$b")
  [ -n "$old" ] && [ "${have_file[$n]}" != "$b" ] && gone+=("${have_file[$n]}")
  echo "add $n $v${old:+ (was $old)}"
done

if [ "${#added[@]}" -gt 0 ]; then
  # -p: repo-add itself refuses a downgrade too.
  (cd "$stage" && repo-add -q -p "$DB" "${added[@]}")
  for b in "${added[@]}"; do mv -f "$stage/$b" "$REPO/$b"; done
  # nginx serves symlinks as their target only when it can follow them; plain copies are safer.
  for l in powos.db powos.files; do rm -f "$stage/$l"; cp "$stage/$l.tar.gz" "$stage/$l"; done
  for f in "$DB" powos.db "$FILES" powos.files; do mv -f "$stage/$f" "$REPO/$f"; done
  for b in ${gone[@]+"${gone[@]}"}; do rm -f "$REPO/$b"; done
fi
echo "repo: $(bsdtar -tf "$REPO/$DB" 2>/dev/null | grep -c '/$' || true) packages"
