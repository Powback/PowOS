#!/usr/bin/env bash
# One worktree per task, removed when it is pushed.
#   worktree.sh new <name>   worktree at $POWOS_WT_ROOT/<name> (default ~/pw/<name>, OUTSIDE the repo - an agent
#                            in it never picks up ~/Projects/CLAUDE.md or any ancestor .claude/ skill catalog) on
#                            branch agent/<name>, from origin's tip, shell/node_modules linked from
#                            powos-multiplatform (no per-worktree install)
#   worktree.sh done <name>  remove it; refuses while it has uncommitted or unpushed work; lists the phone checks
#                            queued from it (they run in the verify checkout, so removing it is fine); looks under
#                            $POWOS_WT_ROOT first, then the old .claude/worktrees location (pre-move worktrees)
#   worktree.sh list         name, age of HEAD, commits not on origin (patch-id), dirty files; both locations
set -euo pipefail
BASE=worktree-powos-multiplatform
REPO=$(cd "$(dirname "$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)")" && pwd)
WT=$REPO/.claude/worktrees
# New agent worktrees live outside the repo (default ~/pw) so they have no ancestor CLAUDE.md/.claude/skills to
# load - the old $WT/<name> location put every agent worktree under the repo's own tree, which is also the parent
# of 40+ sibling worktrees' skill catalogs. Runner checkouts (verify-runner, emu-runner, ship-runner*) and the
# shared base checkout (powos-multiplatform) are unaffected - they stay under $WT.
WTR=${POWOS_WT_ROOT:-$HOME/pw}
# A runner's own checkout (verify-runner, ship-runner, ship-runner-apk): marked by .powos-runner-checkout when the
# runner creates it (friction f57). An agent whose cwd landed there (this script resolves its own location, not
# $PWD) must make its own worktree instead of operating on the runner's.
here_top=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null) || here_top=
[ -z "$here_top" ] || [ ! -f "$here_top/.powos-runner-checkout" ] ||
  { echo "worktree.sh: refused - $(cat "$here_top/.powos-runner-checkout") owns $here_top, never run worktree.sh from it (use your own worktree)" >&2; exit 1; }

ahead() { git -C "$1" cherry "origin/$BASE" HEAD 2>/dev/null | grep -c '^+' || true; }
# The node_modules symlink shows as untracked (.gitignore's node_modules/ doesn't match a link); it is not work.
dirty() { git -C "$1" status --porcelain | grep -vc '^?? shell/node_modules$' || true; }

# find_wt <name>: echoes the existing worktree's path (new root first, then the legacy $WT location), or nothing.
find_wt() { [ -e "$WTR/$1/.git" ] && { echo "$WTR/$1"; return; }; [ -e "$WT/$1/.git" ] && echo "$WT/$1"; }

case "${1:-}" in
new)
  n=${2:?name}; d=$WTR/$n
  { [ -e "$d" ] || [ -e "$WT/$n" ]; } && { echo "exists: $(find_wt "$n")" >&2; exit 1; }
  mkdir -p "$WTR"
  git -C "$REPO" fetch -q origin "$BASE"
  git -C "$REPO" worktree add -q --track -b "agent/$n" "$d" "origin/$BASE"
  # Absolute symlink target: $d is no longer a fixed two-levels-deep sibling of powos-multiplatform (it can be
  # anywhere under $WTR), so the old relative "../../powos-multiplatform/..." target would resolve wrong.
  [ -d "$WT/powos-multiplatform/shell/node_modules" ] && ln -s "$WT/powos-multiplatform/shell/node_modules" "$d/shell/node_modules"
  echo "$d" ;;
done)
  n=${2:?name}; d=$(find_wt "$n")
  [ -n "$d" ] && [ -d "$d" ] || { echo "no worktree: $n (looked in $WTR and $WT)" >&2; exit 1; }
  git -C "$d" fetch -q origin "$BASE"
  a=$(ahead "$d"); x=$(dirty "$d")
  [ "$a" = 0 ] && [ "$x" = 0 ] || { echo "refused: $n has $a unpushed commit(s), $x uncommitted file(s)" >&2; exit 1; }
  br=$(git -C "$d" symbolic-ref --short -q HEAD || true)
  q=$(grep -lE "${d//./\\.}([/ )']|\$)" "$HOME"/.cache/powos-verify-queue/*.job 2>/dev/null || true)
  [ -z "$q" ] || echo "queued phone checks from $n (they run from the verify checkout): $(for f in $q; do basename "$f" .job; done | tr '\n' ' ')"
  [ -L "$d/shell/node_modules" ] && rm "$d/shell/node_modules"
  git -C "$REPO" worktree remove "$d"
  [ -n "$br" ] && git -C "$REPO" branch -D "$br" >/dev/null
  echo "removed $n" ;;
list)
  for d in "$WTR"/*/ "$WT"/*/; do d=${d%/}; [ -e "$d/.git" ] || continue
    printf '%-28s %-16s ahead=%-3s dirty=%s\n' "$(basename "$d")" \
      "$(git -C "$d" log -1 --format=%cr | sed 's/ ago//')" "$(ahead "$d")" "$(dirty "$d")"
  done ;;
*) sed -n '2,8p' "$0"; exit 1 ;;
esac
