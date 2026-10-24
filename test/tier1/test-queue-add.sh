#!/bin/bash
# test-queue-add.sh: friction f164/f165 - unknown task id refusal and list with no results.
# f164: queue.sh add should refuse unknown task IDs when the board can answer, and allow with a
#       warning when the board is unreachable and there's no cache.
# f165: queue.sh list should exit 0 with "no results yet" when there are no done logs.
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/queue-add-test.XXXXXX")
cleanup() { pkill -f "$T" >/dev/null 2>&1 || true; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"; }
trap cleanup EXIT
export HOME=$T/home GIT_CONFIG_GLOBAL=$T/gitconfig
mkdir -p "$HOME/.cache"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main

fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "       $2"; }

# ============================================= Prepare ======================================
VA="$T/verify-agent"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$VA" 2>/dev/null
(cd "$VA" && git checkout -q -b worktree-powos-multiplatform
  mkdir -p tools/phone/verify lib/ai/agents
  cp "$src/tools/phone/verify/queue.sh" tools/phone/verify/queue.sh
  echo "#!/bin/bash" > lib/ai/agents/powos-agents-cli
  chmod +x lib/ai/agents/powos-agents-cli
  echo "#!/bin/bash" > dummy.sh && chmod +x dummy.sh
  git add -A && git commit -qm seed && git push -q origin worktree-powos-multiplatform 2>/dev/null)

VQ="$T/verify-queue"
mkdir -p "$VQ"

# Fake board CLI that we control
BOARD_STATE="$T/board-state"
echo "up" > "$BOARD_STATE"

cat > "$VA/lib/ai/agents/powos-agents-cli" <<'EOF'
#!/usr/bin/env python3
import sys
import json
import os

state = open(os.environ.get("BOARD_STATE", "/dev/null")).read().strip() if os.environ.get("BOARD_STATE") else "up"

# Handle both 'task list' and 'task list --all' / 'task list --json'
if len(sys.argv) > 2 and sys.argv[1] == 'task' and sys.argv[2] == 'list':
    if state == "down":
        sys.exit(1)
    tasks = [{"id": "t1"}, {"id": "t2"}, {"id": "t3"}]
    print(json.dumps(tasks))
else:
    sys.exit(127)
EOF
chmod +x "$VA/lib/ai/agents/powos-agents-cli"

run_queue() { (cd "$VA" && QUEUE_DIR="$VQ" BOARD_STATE="$BOARD_STATE" bash tools/phone/verify/queue.sh "$@") 2>&1; }

# ============================================= f164: unknown task id =========================
# Test 1: board is up, task doesn't exist - should refuse
echo "up" > "$BOARD_STATE"
out=$(run_queue add no-such-task dummy.sh echo test 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "no board task 'no-such-task'" <<<"$out" && ok "f164: refuses unknown task when board is up" \
  || bad "f164: refuses unknown task when board is up" "rc=$rc: $out"

# Test 2: board is up, task exists - should accept
out=$(run_queue add t1 dummy.sh echo test 2>&1); rc=$?
[ $rc -eq 0 ] && ok "f164: accepts known task when board is up" || bad "f164: accepts known task when board is up" "rc=$rc: $out"

# Test 3: board is down - should allow with warning
echo "down" > "$BOARD_STATE"
out=$(run_queue add unknown-task dummy.sh echo test 2>&1); rc=$?
# When the board is unreachable, it should allow with a warning
if [ $rc -eq 0 ] && grep -q "board not reachable\|offline\|unavailable" <<<"$out"; then
  ok "f164: allows when board is unreachable, with warning"
else
  bad "f164: allows when board is unreachable, with warning" "rc=$rc: $out"
fi

# Test 4: can force with QUEUE_NEW_TASK=1 even when board is up
echo "up" > "$BOARD_STATE"
out=$(run_queue add no-such-task dummy.sh echo test 2>&1); rc=$?
[ $rc -ne 0 ] && ok "f164: refuses without QUEUE_NEW_TASK=1" || bad "f164: refuses without QUEUE_NEW_TASK=1" "rc=$rc"

out=$(cd "$VA" && QUEUE_DIR="$VQ" QUEUE_NEW_TASK=1 bash tools/phone/verify/queue.sh add no-such-task dummy.sh echo test 2>&1); rc=$?
[ $rc -eq 0 ] && ok "f164: QUEUE_NEW_TASK=1 allows unknown task" || bad "f164: QUEUE_NEW_TASK=1 allows unknown task" "rc=$rc: $out"

# ============================================= f165: list with no results ===================
# Clean verify queue
rm -rf "$VQ"
mkdir -p "$VQ"

out=$(run_queue list); rc=$?
[ $rc -eq 0 ] && grep -q "no results yet\|^$" <<<"$out" && ok "f165: list exits 0 when no done logs" \
  || bad "f165: list exits 0 when no done logs" "rc=$rc"

# Test 2: add a done log and list should work
mkdir -p "$VQ/done"
echo "PASS: test log" > "$VQ/done/test.log"
out=$(run_queue list); rc=$?
[ $rc -eq 0 ] && ok "f165: list exits 0 with done logs" || bad "f165: list exits 0 with done logs" "rc=$rc"

# ============================================= f258: stale-need duplicate is replaced ========
rm -rf "$VQ"; mkdir -p "$VQ"; echo "up" > "$BOARD_STATE"
out=$(run_queue add t1 dummy.sh echo dup 2>&1); j1=$(ls "$VQ"/*.job 2>/dev/null | head -1)
out=$(run_queue add t1 dummy.sh echo dup 2>&1)
{ grep -q "already queued" <<<"$out" && [ "$(ls "$VQ"/*.job | wc -l | tr -d " ")" = 1 ]; } && ok "f258: same need is still a duplicate" || bad "f258: same need is still a duplicate" "$out"
(cd "$VA" && echo x > x && git add x && git commit -qm newer)
sleep 1
out=$(run_queue add t1 dummy.sh echo dup 2>&1)
new=$(git -C "$VA" rev-parse HEAD)
{ grep -q "replacing queued" <<<"$out" && [ "$(ls "$VQ"/*.job | wc -l | tr -d " ")" = 1 ] && grep -qx "need=$new" "$VQ"/*.job; } \
  && ok "f258: older-need job replaced by newer add" || bad "f258: older-need job replaced by newer add" "$out"
(cd "$VA" && git reset -q --hard HEAD~1)
out=$(run_queue add t1 dummy.sh echo dup 2>&1)
grep -q "already queued" <<<"$out" && ok "f258: newer-need job kept against an older add" || bad "f258: newer-need job kept against an older add" "$out"

# Final result
echo ""
if [ $fails -eq 0 ]; then
  echo "All tests passed"
  exit 0
else
  echo "$fails tests failed"
  exit 1
fi
