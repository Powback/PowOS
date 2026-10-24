#!/usr/bin/env bash
# tools/agents/land.sh "msg" -- <paths> [--task <id> --step "..."] [--ship "note"] [--queue <check args>]
#
# ONE call that replaces the landing recipe (docs/AGENT-HANDBOOK.md used to spell out commit -> rebase ->
# push -> task set -> ship request -> queue as five+ separate calls, 122 git-sync calls + 73 commit/push in
# 4h measured by tools/agents/efficiency.py). It:
#   1. checks every path is actually changed in THIS worktree (refuses an unchanged path or one outside the
#      repo - never lands something that isn't yours by accident);
#   2. commits those paths ONLY, by pathspec (never -a, never -A: other agents' uncommitted work can be in
#      the same tree - docs/AGENT-HANDBOOK.md, Shared checkouts); then WARNS (never blocks) when origin already
#      got a commit, since this worktree's merge-base, touching the same files AND overlapping line ranges as
#      this landing's own diff - "origin already changed <file> lines X-Y in <sha> <subject>: check you're not
#      duplicating it" (friction f115: two agents fixed the same bug in parallel, found only at rebase);
#   3. fetches origin/worktree-powos-multiplatform, refuses a package patch number or pkgrel that's a duplicate
#      of what's already there (friction f111: two agents landed pkgs/kwin/0025-*.patch and pkgrel 3.29 at the
#      same time - different filenames, no git conflict, so it merged silently), then rebases ONCE, right
#      before the push - tools/agents/pkg-claim.sh reserves a free one ahead of time so this never fires;
#   4. pushes to origin/worktree-powos-multiplatform (never main, never --force); on a push race (someone
#      landed meanwhile) it fetches + rebases + pushes ONE more time, then gives up rather than loop;
#   5. sets the board task's step (python3 lib/ai/agents/powos-agents-cli task set), skipped with a note if
#      the board isn't reachable - never fails the landing over that;
#   6. requests a ship (tools/phone/ship.sh request), if asked;
#   7. queues phone/emulator checks (tools/phone/verify/queue.sh add), if asked - arguments after --queue are
#      passed on as separate words, not one quoted string.
# Prints ONE summary line per step it ran. Never touches the shared base worktree (powos-multiplatform; old
# path .claude/worktrees/powos-multiplatform, new $POWOS_RUN_ROOT/powos-multiplatform) directly - this is a
# per-agent worktree tool (tools/agents/worktree.sh new <name>).
#
# Usage:
#   tools/agents/land.sh "shorten the drawer's fade" -- shell/ui/drawer.tsx shell/ui/drawer.css
#   tools/agents/land.sh "fix widget preview crash" -- shell/ui/owl.tsx \
#       --task widget-preview-crash --step "shipped, queued a check" \
#       --ship "widget preview no longer crashes on empty data" \
#       --queue widget-preview-crash tools/phone/verify/widget-check.sh --round 1
#
# Env overrides (tests): LAND_BASE (default worktree-powos-multiplatform), LAND_AGENTS_CLI, LAND_SHIP,
# LAND_QUEUE, LAND_REMOTE (default origin).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
BASE=${LAND_BASE:-worktree-powos-multiplatform}
REMOTE=${LAND_REMOTE:-origin}
RUN_ROOT=${POWOS_RUN_ROOT:-$HOME/pw}   # powos-multiplatform's new home (wt-move-rest); old path still matched below
# Resolved the same way `git rev-parse --show-toplevel` resolves $top below (symlink components, e.g. macOS's
# /var -> /private/var) - an unresolved RUN_ROOT would never match a resolved $top.
[ -d "$RUN_ROOT" ] && RUN_ROOT=$(cd "$RUN_ROOT" && pwd -P)

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }
[ $# -ge 1 ] || { usage >&2; exit 2; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
msg=$1; shift
[ "${1:-}" = -- ] || { echo "land.sh: expected -- after the message, then the paths" >&2; exit 2; }
shift

paths=()
task_id= step_text= ship_note= ship_set=0 queue_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --task) task_id=${2:?--task needs an id}; shift 2 ;;
    --step) step_text=${2:?--step needs text}; shift 2 ;;
    --ship) ship_note=${2-}; ship_set=1; shift 2 ;;
    --queue) shift; queue_args=("$@"); set -- ;;
    --) echo "land.sh: unexpected extra --" >&2; exit 2 ;;
    -*) echo "land.sh: unknown flag $1" >&2; exit 2 ;;
    *) paths+=("$1"); shift ;;
  esac
done
[ ${#paths[@]} -gt 0 ] || { echo "land.sh: no paths given after --" >&2; exit 2; }
if { [ -n "$task_id" ] && [ -z "$step_text" ]; } || { [ -z "$task_id" ] && [ -n "$step_text" ]; }; then
  echo "land.sh: --task and --step go together" >&2; exit 2
fi

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "land.sh: run it inside a PowOS git worktree" >&2; exit 2; }
case "$top" in */.claude/worktrees/powos-multiplatform|"$RUN_ROOT"/powos-multiplatform) echo "land.sh: refused - that is the shared base worktree, never land from it (tools/agents/worktree.sh new <name>)" >&2; exit 2 ;; esac
# A runner's own checkout (verify-runner, ship-runner, ship-runner-apk): marked by .powos-runner-checkout when the
# runner creates it (friction f57 - an agent launched with its cwd pointed at one of these got reset/overwritten
# under it mid-edit). Only the runner that owns it ever touches it.
[ -f "$top/.powos-runner-checkout" ] && { echo "land.sh: refused - $(cat "$top/.powos-runner-checkout") owns this checkout, never land from it (tools/agents/worktree.sh new <name>)" >&2; exit 2; }
cd "$top"

# 1. every path is a real, relative, in-repo change - never an untouched file, never one that escapes the repo.
# --ignored=matching also catches a new file under the gitignored .claude/ (skills, hooks: AGENT-HANDBOOK.md,
# Rules) that plain --porcelain would hide and this script would then wrongly refuse as "not yours".
for p in "${paths[@]}"; do
  case "$p" in /*|../*|*/../*) echo "land.sh: refused - '$p' isn't a repo-relative path" >&2; exit 2 ;; esac
  [ -n "$(git status --porcelain --ignored=matching -- "$p" 2>/dev/null)" ] || {
    echo "land.sh: refused - '$p' has no uncommitted change in this worktree (not yours to land)" >&2; exit 3; }
done
echo "land: ${#paths[@]} path(s) are this worktree's own changes"

# 2. commit by pathspec only. -f: a path under the gitignored .claude/ that's meant to be tracked (settings.json,
# hooks, skills) needs it once to enter the index; already-tracked paths are unaffected either way.
git add -f -- "${paths[@]}" || { echo "land.sh: git add failed" >&2; exit 3; }
if ! git commit -q -m "$msg" -- "${paths[@]}"; then
  echo "land.sh: nothing to commit for those paths (already committed?)" >&2; exit 3
fi
sha=$(git rev-parse --short HEAD)
echo "land: committed $sha \"$msg\" (${#paths[@]} path(s))"

# 2.5. Warn (never block - friction f115: two agents fixed the same bug in parallel, found only at rebase) when
# origin picked up a commit, since this worktree's merge-base with it, that touches the same files AND overlapping
# line ranges as this landing's own diff. "Overlapping" is new-side (+) line ranges from `git diff -U0`, which
# catches two agents converging on the identical fix (no textual rebase conflict at all) as well as a real one.
hunk_ranges() {   # hunk_ranges REFA REFB -- PATH...: "file:start-end" per added/changed hunk, new-side line numbers
  local a=$1 b=$2; shift 2
  local f=
  git diff -U0 "$a" "$b" -- "$@" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      '+++ '*) f=${line#+++ b/} ;;
      '@@ '*)
        plus=$(printf '%s' "$line" | sed -n 's/^@@ -[0-9,]* +\([0-9][0-9]*\)\(,[0-9]*\)\{0,1\} @@.*/\1\2/p')
        [ -n "$plus" ] || continue
        start=${plus%%,*}
        if [ "$plus" = "$start" ]; then cnt=1; else cnt=${plus#*,}; fi
        [ "$cnt" -gt 0 ] || continue   # a pure deletion adds nothing on the new side
        printf '%s:%s-%s\n' "$f" "$start" "$((start + cnt - 1))"
        ;;
    esac
  done
}
range_overlap() {   # range_overlap file:s1-e1 file:s2-e2 -> 0 iff same file and the ranges overlap
  local f1=${1%%:*} r1=${1#*:} f2=${2%%:*} r2=${2#*:}
  [ "$f1" = "$f2" ] || return 1
  local s1=${r1%-*} e1=${r1#*-} s2=${r2%-*} e2=${r2#*-}
  [ "$s1" -le "$e2" ] && [ "$s2" -le "$e1" ]
}
warn_overlap() {
  git fetch -q "$REMOTE" "$BASE" >/dev/null 2>&1 || return 0
  local mb; mb=$(git merge-base HEAD "$REMOTE/$BASE" 2>/dev/null) || return 0
  [ -n "$mb" ] || return 0
  local ours; ours=$(hunk_ranges "$mb" HEAD -- "${paths[@]}")
  [ -n "$ours" ] || return 0
  local c subj theirs o r
  for c in $(git rev-list --reverse "$mb..$REMOTE/$BASE" -- "${paths[@]}" 2>/dev/null); do
    theirs=$(hunk_ranges "$c~1" "$c" -- "${paths[@]}")
    [ -n "$theirs" ] || continue
    subj=$(git log -1 --format=%s "$c" 2>/dev/null)
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        range_overlap "$o" "$r" || continue
        echo "land: origin already changed ${r%%:*} lines ${r#*:} in ${c:0:9} $subj: check you're not duplicating it"
      done <<< "$theirs"
    done <<< "$ours"
  done
}
warn_overlap

# Package patch number / pkgrel collision (friction f111): a NEW patch file whose NNNN prefix origin/$BASE
# already has under a DIFFERENT name (same number, different patch - no git conflict, since they're different
# filenames), or a PKGBUILD whose pkgrel doesn't come out strictly ahead of origin's. Checked against whatever
# $REMOTE/$BASE is at the moment of the fetch inside try_land, so a late check (right before each push attempt,
# including the retry) catches a collision that landed between this worktree's last fetch and now.
check_pkg_dupes() {
  local f dir num existing newrel oldrel
  for f in "${paths[@]}"; do
    case "$f" in
    */pkgs/*/[0-9][0-9][0-9][0-9]-*.patch)
      dir=$(dirname "$f"); num=$(basename "$f" | cut -c1-4)
      existing=$(git ls-tree -r --name-only "$REMOTE/$BASE" -- "$dir" 2>/dev/null | grep -E "^${dir}/${num}-" || true)
      if [ -n "$existing" ] && [ "$existing" != "$f" ]; then
        echo "land.sh: refused - $dir already has patch $num on $REMOTE/$BASE as $(basename "$existing") (you have $(basename "$f")) - reserve a free number: tools/agents/pkg-claim.sh reserve-patch $dir" >&2
        return 1
      fi ;;
    */pkgs/*/PKGBUILD)
      dir=$(dirname "$f")
      newrel=$(sed -n 's/^pkgrel=//p' "$f" | head -1)
      oldrel=$(git show "$REMOTE/$BASE:$f" 2>/dev/null | sed -n 's/^pkgrel=//p' | head -1)
      [ -n "$newrel" ] && [ -n "$oldrel" ] || continue
      if [ "$(printf '%s\n%s\n' "$newrel" "$oldrel" | sort -V | tail -1)" != "$newrel" ] || [ "$newrel" = "$oldrel" ]; then
        echo "land.sh: refused - $f's pkgrel=$newrel doesn't clear $REMOTE/$BASE's pkgrel=$oldrel - reserve a free one: tools/agents/pkg-claim.sh reserve-pkgrel $dir" >&2
        return 1
      fi ;;
    esac
  done
  return 0
}

# 3+4. fetch, check for a package number/pkgrel collision, rebase once, push - one retry on a race (someone else
# landed between fetch and push).
try_land() {
  git fetch -q "$REMOTE" "$BASE" || { echo "land.sh: fetch failed" >&2; return 1; }
  check_pkg_dupes || return 3
  if ! git rebase -q "$REMOTE/$BASE" >/tmp/land-rebase.$$ 2>&1; then
    git rebase --abort >/dev/null 2>&1
    echo "land.sh: rebase onto $REMOTE/$BASE conflicts - resolve by hand, your commit is still local ($sha)" >&2
    cat /tmp/land-rebase.$$ >&2; rm -f /tmp/land-rebase.$$
    return 2
  fi
  rm -f /tmp/land-rebase.$$
  git push -q "$REMOTE" "HEAD:$BASE"
}
if try_land; then
  echo "land: rebased onto $REMOTE/$BASE and pushed to $BASE"
else
  rc=$?
  [ $rc -eq 2 ] && exit 3
  [ $rc -eq 3 ] && exit 3   # a real duplicate (check_pkg_dupes) - not a push race, retrying won't help
  echo "land: push raced - fetching and rebasing once more"
  if try_land; then
    echo "land: rebased onto $REMOTE/$BASE and pushed to $BASE (after one retry)"
  else
    echo "land.sh: push failed twice - not retrying again (commit is still local: $sha)" >&2
    exit 3
  fi
fi

# After the push succeeds, capture and print the final SHA (after rebase) and subject
final_sha=$(git rev-parse --short HEAD)
final_subj=$(git log -1 --format=%s)
echo "land: pushed $final_sha $final_subj"

# 4.5. warn about untracked files left in the worktree (excluding gitignored and symlinks)
untracked=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  # Skip gitignored files
  if git check-ignore -q "$f" 2>/dev/null; then continue; fi
  # Skip symlinks (e.g., shell/node_modules)
  [ -L "$f" ] && continue
  untracked+=("$f")
done < <(git status --porcelain | grep '^??' | sed 's/^?? //')
if [ ${#untracked[@]} -gt 0 ]; then
  echo "land: ${#untracked[@]} untracked file(s) left: ${untracked[*]} - commit them (tests belong in test/tier1/test-*.sh) or delete them"
fi

# 5. board task step - never fails the landing; the board can be unreachable.
if [ -n "$task_id" ]; then
  cli=${LAND_AGENTS_CLI:-"$top/lib/ai/agents/powos-agents-cli"}
  if out=$("$cli" task set "$task_id" --step "$step_text" 2>&1); then
    echo "land: board task $task_id step set: \"$step_text\""
  else
    echo "land: board unreachable, skipped task step (reason: $(echo "$out" | tail -1))"
  fi
fi

# 6. ship request.
if [ "$ship_set" = 1 ]; then
  ship=${LAND_SHIP:-"$top/tools/phone/ship.sh"}
  if [ -n "$ship_note" ]; then shipargs=(--note "$ship_note"); else shipargs=(--silent); fi
  if out=$(bash "$ship" request "${shipargs[@]}" 2>&1); then
    echo "land: ship requested: ${ship_note:-(silent)}"
  else
    echo "land: ship request FAILED: $(echo "$out" | tail -1)" >&2
  fi
fi

# 7. queue phone/emulator checks - args forwarded as separate words.
if [ ${#queue_args[@]} -gt 0 ]; then
  queue=${LAND_QUEUE:-"$top/tools/phone/verify/queue.sh"}
  if out=$(bash "$queue" add "${queue_args[@]}" 2>&1); then
    echo "land: queued check: ${queue_args[*]}"
  else
    echo "land: queue FAILED: $(echo "$out" | tail -1)" >&2
  fi
fi
exit 0
