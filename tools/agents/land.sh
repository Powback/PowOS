#!/usr/bin/env bash
# tools/agents/land.sh "msg" -- <paths> [--task <id> --step "..."] [--ship "note"] [--queue <check args>]
#
# ONE call that replaces the landing recipe (docs/AGENT-HANDBOOK.md used to spell out commit -> rebase ->
# push -> task set -> ship request -> queue as five+ separate calls, 122 git-sync calls + 73 commit/push in
# 4h measured by tools/agents/efficiency.py). It:
#   1. checks every path is actually changed in THIS worktree (refuses an unchanged path or one outside the
#      repo - never lands something that isn't yours by accident);
#   2. commits those paths ONLY, by pathspec (never -a, never -A: other agents' uncommitted work can be in
#      the same tree - docs/AGENT-HANDBOOK.md, Shared checkouts);
#   3. fetches origin/worktree-powos-multiplatform and rebases ONCE, right before the push;
#   4. pushes to origin/worktree-powos-multiplatform (never main, never --force); on a push race (someone
#      landed meanwhile) it fetches + rebases + pushes ONE more time, then gives up rather than loop;
#   5. sets the board task's step (python3 lib/ai/agents/powos-agents-cli task set), skipped with a note if
#      the board isn't reachable - never fails the landing over that;
#   6. requests a ship (tools/phone/ship.sh request), if asked;
#   7. queues phone/emulator checks (tools/phone/verify/queue.sh add), if asked - arguments after --queue are
#      passed on as separate words, not one quoted string.
# Prints ONE summary line per step it ran. Never touches .claude/worktrees/powos-multiplatform directly -
# this is a per-agent worktree tool (tools/agents/worktree.sh new <name>).
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

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }
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
case "$top" in */.claude/worktrees/powos-multiplatform) echo "land.sh: refused - that is the shared base worktree, never land from it (tools/agents/worktree.sh new <name>)" >&2; exit 2 ;; esac
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

# 3+4. fetch, rebase once, push - one retry on a race (someone else landed between fetch and push).
try_land() {
  git fetch -q "$REMOTE" "$BASE" || { echo "land.sh: fetch failed" >&2; return 1; }
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
  echo "land: push raced - fetching and rebasing once more"
  if try_land; then
    echo "land: rebased onto $REMOTE/$BASE and pushed to $BASE (after one retry)"
  else
    echo "land.sh: push failed twice - not retrying again (commit is still local: $sha)" >&2
    exit 3
  fi
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
