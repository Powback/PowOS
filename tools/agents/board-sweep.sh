#!/bin/bash
# tools/agents/board-sweep.sh (Mac): the work board's orphan sweeper - the launchd agent com.powos.board-sweep runs it
# every 10 min (tools/agents/board-sweep-deploy.sh; unit units/mac/board-sweep-mac.json). Why (the user, 2026-10-23:
# "fix it all properly permanently" - 30 tasks said "working" with 4 agents running, several had no phone check):
#   1. the verify queue as it is (~/.cache/powos-verify-queue: queued jobs, results, whether each one's commit is on
#      the phone) -> the board's work_check rows (`powos agents check sync`): the facts the truthful state and the
#      done rule read;
#   2. `powos agents sweep` on the phone: each task's true state from those facts and the live agents; the orphans
#      (stalled, no-check: FAILs nobody picked up), the user's asks with no task and new/recurring friction - and ONE
#      mail to the coordinator ("coder") with only what is new or changed since the last pass.
# One adb call (tools/phone/user.sh: as the session user). The scan runs origin's current CLI (fetched, not a
# checkout that may lag). Usage: board-sweep.sh [--dry-run] (no mail; the digest printed). Log: <dir>/sweep.log.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P); R=$(cd "$here/../.." && pwd -P)
BASE=worktree-powos-multiplatform
S=${SWEEP_DIR:-$HOME/.cache/powos-board-sweep}; mkdir -p "$S"
dry=; [ "${1:-}" = --dry-run ] && dry=--dry-run
# One at a time (a pass stuck on adb must not stack up under launchd): a lock dir with its pid.
if ! mkdir "$S/lock" 2>/dev/null; then
  p=$(cat "$S/lock/pid" 2>/dev/null); if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "$(date '+%F %T') a sweep runs (pid $p)"; exit 0; fi
  rm -rf "$S/lock"; mkdir "$S/lock" || exit 1
fi
echo $$ > "$S/lock/pid"; trap 'rm -rf "$S/lock"' EXIT
# The CLI at origin's tip (what the phone will run after the next deploy); this checkout's own if git can't.
git -C "$R" fetch -q origin "$BASE" 2>/dev/null
cli=$S/powos-agents-cli
git -C "$R" show "origin/$BASE:lib/ai/agents/powos-agents-cli" > "$cli.tmp" 2>/dev/null && mv "$cli.tmp" "$cli" || cp "$R/lib/ai/agents/powos-agents-cli" "$cli"
POWOS_VERIFY_REPO=${POWOS_VERIFY_REPO:-$(cd "$R" && cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" && pwd -P)/.claude/worktrees/verify-runner} \
  python3 "$cli" check scan > "$S/checks.json" || { echo "$(date '+%F %T') check scan failed"; exit 1; }
{ echo 'set -u; f=$(mktemp); cat > "$f" <<'"'"'POWOS_CHECKS_JSON'"'"
  cat "$S/checks.json"; echo; echo 'POWOS_CHECKS_JSON'
  echo 'powos agents check sync "$f"; rm -f "$f"'
  echo "powos agents sweep $dry"; } > "$S/run.sh"
out=$(perl -e 'alarm 180; exec @ARGV' "$R/tools/phone/user.sh" "$S/run.sh" 2>&1); rc=$?
{ echo "== $(date '+%F %T') rc=$rc$([ -n "$dry" ] && echo ' (dry run)')"; printf '%s\n' "$out" | grep -v 'file pushed'; } >> "$S/sweep.log"
tail -c 2000000 "$S/sweep.log" > "$S/sweep.log.tmp" && mv "$S/sweep.log.tmp" "$S/sweep.log"
printf '%s\n' "$out" | grep -v 'file pushed'
exit $rc
