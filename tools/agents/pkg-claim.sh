#!/usr/bin/env bash
# tools/agents/pkg-claim.sh: reserves the next free patch number or pkgrel for a targets/*/pkgs/<name> package,
# so two agents working in separate worktrees at once don't both pick patch 0025 / pkgrel 3.29 (friction f111:
# that happened - two worktrees each added pkgs/kwin/0025-*.patch and pkgrel 3.29, discovered only at rebase).
# Looks at THREE sources and reserves one past the highest of them: this worktree's own pkgdir, origin's (another
# agent's landed work you haven't fetched yet), and a shared claims ledger (another agent's reservation that
# hasn't landed yet either). land.sh separately refuses a push whose patch number or pkgrel doesn't clear
# origin's, as a backstop for a reservation skipped or a claim that's gone stale - this script is the one-call
# way to never hit that refusal in the first place.
#
#   pkg-claim.sh reserve-patch <pkgdir>    next free NNNN for a new pkgdir/NNNN-*.patch; reserves and prints it.
#   pkg-claim.sh reserve-pkgrel <pkgdir>   next free pkgrel for pkgdir/PKGBUILD's scheme (X or X.Y); reserves and
#        prints it - it's the number to put in PKGBUILD's pkgrel=, not a confirmation of one already written.
#   pkg-claim.sh claims <pkgdir>           the ledger's reservations for this pkgdir (never pruned - a stale one
#        only pushes the next number a little higher, never lower, so there is nothing unsafe about keeping it).
#
# CLAIMS=${POWOS_PKG_CLAIMS:-~/.cache/powos-pkg-claims}. BASE=${LAND_BASE:-worktree-powos-multiplatform}.
set -euo pipefail
CLAIMS=${POWOS_PKG_CLAIMS:-$HOME/.cache/powos-pkg-claims}
BASE=${LAND_BASE:-worktree-powos-multiplatform}
mkdir -p "$CLAIMS"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

# patch_max <pkgdir> <repo>: the highest NNNN among pkgdir/NNNN-*.patch, on disk here AND on origin/$BASE
# (another agent's landed patch this worktree hasn't fetched); 0 if none either place.
patch_max() {
  local pkgdir=$1 repo=$2 m=0 n f
  for f in "$pkgdir"/[0-9][0-9][0-9][0-9]-*.patch; do
    [ -e "$f" ] || continue
    n=$((10#$(basename "$f" | cut -c1-4))); [ "$n" -gt "$m" ] && m=$n
  done
  if [ -n "$repo" ]; then
    local rel=${pkgdir#"$repo"/}
    git -C "$repo" fetch -q origin "$BASE" 2>/dev/null || true
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      n=$((10#$(basename "$f" | cut -c1-4))); [ "$n" -gt "$m" ] && m=$n
    done < <(git -C "$repo" ls-tree -r --name-only "origin/$BASE" -- "$rel" 2>/dev/null | grep -E "^${rel}/[0-9]{4}-.*\.patch\$" || true)
  fi
  echo "$m"
}
claims_patch_max() { awk '{if ($1+0>m)m=$1} END{print m+0}' "$CLAIMS/$1-patch.claims" 2>/dev/null || echo 0; }

# pkgrel_of <PKGBUILD>: its pkgrel= value, read as text (never sourced: a PKGBUILD can carry arbitrary bash and
# this only needs one line of it).
pkgrel_of() { [ -f "$1" ] && sed -n 's/^pkgrel=//p' "$1" | head -1 || echo 0; }
pkgrel_max() {  # pkgrel_max <pkgdir> <repo>: the higher of this worktree's PKGBUILD and origin's.
  local pkgdir=$1 repo=$2 local_rel origin_rel=0
  local_rel=$(pkgrel_of "$pkgdir/PKGBUILD"); local_rel=${local_rel:-0}
  if [ -n "$repo" ]; then
    git -C "$repo" fetch -q origin "$BASE" 2>/dev/null || true
    origin_rel=$(git -C "$repo" show "origin/$BASE:${pkgdir#"$repo"/}/PKGBUILD" 2>/dev/null | sed -n 's/^pkgrel=//p' | head -1)
    origin_rel=${origin_rel:-0}
  fi
  printf '%s\n%s\n' "$local_rel" "$origin_rel" | sort -V | tail -1
}
claims_pkgrel_max() { [ -f "$CLAIMS/$1-pkgrel.claims" ] && sort -V "$CLAIMS/$1-pkgrel.claims" | awk '{v=$1} END{print v}' || echo 0; }
bump_pkgrel() {  # bump_pkgrel X or X.Y -> X+1 or X.(Y+1); anything else: append .1 rather than guess.
  case "$1" in
    *.*) printf '%s.%s\n' "${1%.*}" "$(( ${1##*.} + 1 ))" ;;
    ''|*[!0-9]*) printf '%s.1\n' "$1" ;;
    *) printf '%s\n' "$(( 10#$1 + 1 ))" ;;
  esac
}
# claim_lock <key>: a short-lived mkdir mutex (atomic on APFS and friends) so two simultaneous reserves for the
# same package don't both read the claims file before either appends to it.
claim_lock() {
  local lock=$CLAIMS/.lock-$1 i=0
  until mkdir "$lock" 2>/dev/null; do
    i=$((i + 1)); [ $i -lt 100 ] || { echo "pkg-claim.sh: lock $lock held too long - stale? remove it by hand if so" >&2; exit 1; }
    sleep 0.1
  done
  trap 'rmdir "'"$lock"'" 2>/dev/null || true' EXIT
}

[ $# -ge 2 ] || { usage >&2; exit 2; }
cmd=$1; pkgdir=${2%/}
[ -d "$pkgdir" ] || { echo "pkg-claim.sh: no such package dir: $pkgdir" >&2; exit 2; }
pkg=$(basename "$pkgdir")
repo=$(git -C "$pkgdir" rev-parse --show-toplevel 2>/dev/null || true)

case "$cmd" in
reserve-patch)
  claim_lock "$pkg-patch"
  m1=$(patch_max "$pkgdir" "$repo"); m2=$(claims_patch_max "$pkg")
  next=$(( (m1 > m2 ? m1 : m2) + 1 ))
  printf '%04d %s %s\n' "$next" "${repo:+$(basename "$repo")}" "$(date +%s)" >> "$CLAIMS/$pkg-patch.claims"
  printf '%04d\n' "$next" ;;
reserve-pkgrel)
  claim_lock "$pkg-pkgrel"
  m1=$(pkgrel_max "$pkgdir" "$repo"); m2=$(claims_pkgrel_max "$pkg")
  hi=$(printf '%s\n%s\n' "$m1" "${m2:-0}" | sort -V | tail -1)
  next=$(bump_pkgrel "$hi")
  printf '%s %s\n' "$next" "$(date +%s)" >> "$CLAIMS/$pkg-pkgrel.claims"
  printf '%s\n' "$next" ;;
claims)
  for f in "$CLAIMS/$pkg"-*.claims; do [ -e "$f" ] && { echo "== $(basename "$f")"; cat "$f"; }; done ;;
*) usage; exit 2 ;;
esac
