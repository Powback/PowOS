#!/usr/bin/env bash
# One worktree per task, removed when it is pushed.
#   worktree.sh new <name>   worktree at .claude/worktrees/<name> on branch agent/<name>, from origin's tip,
#                            shell/node_modules linked from powos-multiplatform (no per-worktree install)
#   worktree.sh done <name>  remove it; refuses while it has uncommitted or unpushed work; lists the phone checks
#                            queued from it (they run in the verify checkout, so removing it is fine)
#   worktree.sh list         name, age of HEAD, commits not on origin (patch-id), dirty files
set -euo pipefail
BASE=worktree-powos-multiplatform
REPO=$(cd "$(dirname "$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)")" && pwd)
WT=$REPO/.claude/worktrees

ahead() { git -C "$1" cherry "origin/$BASE" HEAD 2>/dev/null | grep -c '^+' || true; }
# The node_modules symlink shows as untracked (.gitignore's node_modules/ doesn't match a link); it is not work.
dirty() { git -C "$1" status --porcelain | grep -vc '^?? shell/node_modules$' || true; }

case "${1:-}" in
new)
  n=${2:?name}; d=$WT/$n
  [ -e "$d" ] && { echo "exists: $d" >&2; exit 1; }
  git -C "$REPO" fetch -q origin "$BASE"
  git -C "$REPO" worktree add -q --track -b "agent/$n" "$d" "origin/$BASE"
  [ -d "$WT/powos-multiplatform/shell/node_modules" ] && ln -s ../../powos-multiplatform/shell/node_modules "$d/shell/node_modules"
  echo "$d" ;;
done)
  n=${2:?name}; d=$WT/$n
  [ -d "$d" ] || { echo "no worktree: $d" >&2; exit 1; }
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
  for d in "$WT"/*/; do d=${d%/}; [ -e "$d/.git" ] || continue
    printf '%-28s %-16s ahead=%-3s dirty=%s\n' "$(basename "$d")" \
      "$(git -C "$d" log -1 --format=%cr | sed 's/ ago//')" "$(ahead "$d")" "$(dirty "$d")"
  done ;;
*) sed -n '2,6p' "$0"; exit 1 ;;
esac
