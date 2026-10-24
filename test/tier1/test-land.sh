#!/bin/bash
# test-land.sh: tools/agents/land.sh against a throwaway git repo + bare remote (no real PowOS phone/board
# needed - the board/ship/queue steps are pointed at tiny stub scripts via LAND_AGENTS_CLI/LAND_SHIP/
# LAND_QUEUE). Nothing here touches the real worktree tree, origin, phone or board.
#
# Usage: bash test/tier1/test-land.sh
#
# Deliberately NO pipefail (see test/tier1/run-all.sh's note): `cmd | grep -q` can SIGPIPE the writer once
# grep finds its match, which under pipefail reports the pipeline as failed even though grep matched. Every
# assertion below captures into a variable first, then greps the variable.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LAND="$ROOT/tools/agents/land.sh"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [ -n "${2:-}" ] && echo "         $2"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export LAND_BASE=worktree-powos-multiplatform LAND_REMOTE=origin

if [ ! -x "$LAND" ]; then
  echo "== Results: 0 passed, 1 failed =="
  echo "tools/agents/land.sh missing or not executable"; exit 1
fi

# -- bare remote + the branch land.sh pushes to --------------------------------------------------------
BARE="$TMP/remote.git"; git init -q --bare "$BARE"
SEED="$TMP/seed"; git clone -q "$BARE" "$SEED"
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
git -C "$SEED" checkout -q -b "$LAND_BASE"
echo seed > "$SEED/tracked.txt"; git -C "$SEED" add tracked.txt
git -C "$SEED" commit -q -m seed
git -C "$SEED" push -q origin "$LAND_BASE"

new_worktree() {   # new_worktree <dir>: a clone tracking $LAND_BASE, like a real agent worktree.
  git clone -q "$BARE" "$1" >/dev/null
  git -C "$1" checkout -q "$LAND_BASE"
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
}

stub() {   # stub <path>: a script that logs its argv (one per line) to <path>.log and exits 0.
  cat > "$1" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$0.log"
exit 0
EOF
  chmod +x "$1"
}

# == 1. basic landing: commit, rebase, push, board step, ship, queue ===================================
W1="$TMP/w1"; new_worktree "$W1"
echo change1 > "$W1/tracked.txt"
STUB_CLI="$TMP/cli1"; stub "$STUB_CLI"
STUB_SHIP="$TMP/ship1.sh"; stub "$STUB_SHIP"
STUB_QUEUE="$TMP/queue1.sh"; stub "$STUB_QUEUE"
out=$(cd "$W1" && LAND_AGENTS_CLI="$STUB_CLI" LAND_SHIP="$STUB_SHIP" LAND_QUEUE="$STUB_QUEUE" \
  "$LAND" "test change" -- tracked.txt --task t1 --step "landed" --ship "note to the user" \
  --queue t1 tools/phone/verify/fake.sh --round 1 2>&1)
rc=$?
[ $rc -eq 0 ] && ok "basic land exits 0" || bad "basic land exits 0" "rc=$rc: $out"
grep -q "committed" <<<"$out" && ok "prints a commit summary line" || bad "prints a commit summary line" "$out"
grep -q "pushed to $LAND_BASE" <<<"$out" && ok "prints a push summary line" || bad "prints a push summary line" "$out"
remote_log=$(git -C "$BARE" log "$LAND_BASE" --oneline 2>/dev/null)
grep -q "test change" <<<"$remote_log" \
  && ok "the commit landed on the bare remote's $LAND_BASE" \
  || bad "the commit landed on the bare remote's $LAND_BASE" "$remote_log"
grep -qx "t1" "$STUB_CLI.log" 2>/dev/null && ok "board stub got the task id" || bad "board stub got the task id" "$(cat "$STUB_CLI.log" 2>/dev/null)"
grep -qx "note to the user" "$STUB_SHIP.log" 2>/dev/null && ok "ship stub got the note" || bad "ship stub got the note" "$(cat "$STUB_SHIP.log" 2>/dev/null)"
# --queue args arrive as separate words, not one joined string.
[ "$(cat "$STUB_QUEUE.log" 2>/dev/null)" = "$(printf 'add\nt1\ntools/phone/verify/fake.sh\n--round\n1\n')" ] \
  && ok "--queue args forwarded as separate words" \
  || bad "--queue args forwarded as separate words" "$(cat "$STUB_QUEUE.log" 2>/dev/null)"

# == 2. refuses a path with no uncommitted change =======================================================
W2="$TMP/w2"; new_worktree "$W2"
out=$(cd "$W2" && "$LAND" "nothing changed" -- tracked.txt 2>&1); rc=$?
[ $rc -ne 0 ] && grep -qi "no uncommitted change" <<<"$out" \
  && ok "refuses an unchanged path" || bad "refuses an unchanged path" "rc=$rc: $out"
remote_log=$(git -C "$BARE" log "$LAND_BASE" --oneline)
grep -q "nothing changed" <<<"$remote_log" \
  && bad "an unchanged-path landing must not reach the remote" \
  || ok "an unchanged-path landing never reaches the remote"

# == 3. refuses to run from the shared worktree path, old location =======================================
GUARD="$TMP/.claude/worktrees/powos-multiplatform"; mkdir -p "$(dirname "$GUARD")"
new_worktree "$GUARD"
out=$(cd "$GUARD" && "$LAND" "msg" -- tracked.txt 2>&1); rc=$?
[ $rc -ne 0 ] && grep -qi "shared base worktree" <<<"$out" \
  && ok "refuses to run from .claude/worktrees/powos-multiplatform" \
  || bad "refuses to run from .claude/worktrees/powos-multiplatform" "rc=$rc: $out"

# == 3b. refuses to run from the shared worktree path, new location ($POWOS_RUN_ROOT - wt-move-rest) =====
GUARD2="$TMP/pw/powos-multiplatform"; mkdir -p "$(dirname "$GUARD2")"
new_worktree "$GUARD2"
out=$(cd "$GUARD2" && POWOS_RUN_ROOT="$TMP/pw" "$LAND" "msg" -- tracked.txt 2>&1); rc=$?
[ $rc -ne 0 ] && grep -qi "shared base worktree" <<<"$out" \
  && ok "refuses to run from \$POWOS_RUN_ROOT/powos-multiplatform" \
  || bad "refuses to run from \$POWOS_RUN_ROOT/powos-multiplatform" "rc=$rc: $out"

# == 4. a push race: land.sh fetches, rebases cleanly (its own commit touches a different file than the
# rival's, so no content conflict), and only THEN - between its rebase and its push, simulating real
# concurrency - another worktree lands on origin first. The first push is rejected (non-fast-forward); a
# `git` shim on PATH injects the rival's push at that exact moment so this is a genuine race, not a
# sequenced setup. land.sh must fetch+rebase+push ONE more time and succeed. ========================
W4="$TMP/w4"; new_worktree "$W4"
echo change4 > "$W4/mine.txt"
W4B="$TMP/w4-rival"; new_worktree "$W4B"
echo rival > "$W4B/rival.txt"

REAL_GIT=$(command -v git)
RACE_BIN="$TMP/race-bin"; mkdir -p "$RACE_BIN"
RACE_MARKER="$TMP/race-fired"
cat > "$RACE_BIN/git" <<EOF
#!/bin/bash
if [ "\$1" = push ] && [ ! -e "$RACE_MARKER" ]; then
  touch "$RACE_MARKER"
  ( cd "$W4B" && "$REAL_GIT" add rival.txt && "$REAL_GIT" commit -q -m "rival landed first" \\
      && "$REAL_GIT" push -q origin "$LAND_BASE" ) >/dev/null 2>&1
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$RACE_BIN/git"

out=$(cd "$W4" && PATH="$RACE_BIN:$PATH" "$LAND" "mine, after the rival" -- mine.txt 2>&1); rc=$?
[ $rc -eq 0 ] && ok "a push race is retried once and succeeds" || bad "a push race is retried once and succeeds" "rc=$rc: $out"
grep -q "after one retry" <<<"$out" && ok "reports the retry" || bad "reports the retry" "$out"
log=$(git -C "$BARE" log "$LAND_BASE" --oneline)
grep -q "rival landed first" <<<"$log" && grep -q "mine, after the rival" <<<"$log" \
  && ok "both the rival's and this agent's commits are on $LAND_BASE" \
  || bad "both the rival's and this agent's commits are on $LAND_BASE" "$log"

# == 5. board unreachable: skipped with a note, the landing itself still succeeds =======================
W5="$TMP/w5"; new_worktree "$W5"
echo change5 > "$W5/tracked.txt"
DOWN_CLI="$TMP/cli-down.sh"
cat > "$DOWN_CLI" <<'EOF'
#!/bin/bash
echo "powos agents: the powos-agents module isn't reachable at http://127.0.0.1:3410 (nope)" >&2
exit 1
EOF
chmod +x "$DOWN_CLI"
out=$(cd "$W5" && LAND_AGENTS_CLI="$DOWN_CLI" "$LAND" "board is down" -- tracked.txt --task t5 --step "x" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "an unreachable board does not fail the landing" || bad "an unreachable board does not fail the landing" "rc=$rc: $out"
grep -qi "board unreachable, skipped" <<<"$out" && ok "reports the board was skipped" || bad "reports the board was skipped" "$out"

# == 6. a new file under a gitignored dir (like the real .claude/) still lands - AGENT-HANDBOOK.md's documented
# exception (`git add` refuses it, `git commit -m ... -- <path>` works) ===============================
W6="$TMP/w6"; new_worktree "$W6"
echo '.ignored/' >> "$W6/.gitignore"
mkdir -p "$W6/.ignored"; echo hidden > "$W6/.ignored/new.txt"
out=$(cd "$W6" && "$LAND" "land a gitignored file" -- .ignored/new.txt 2>&1); rc=$?
[ $rc -eq 0 ] && ok "lands a new file under a gitignored dir" || bad "lands a new file under a gitignored dir" "rc=$rc: $out"
remote_log=$(git -C "$BARE" log "$LAND_BASE" --oneline)
grep -q "land a gitignored file" <<<"$remote_log" \
  && ok "the gitignored file's commit reached $LAND_BASE" \
  || bad "the gitignored file's commit reached $LAND_BASE" "$remote_log"

# == 7. warns (without blocking) when origin already changed the SAME lines, in a commit pushed while this
# worktree was working - the two-agents-fixed-the-same-bug case (f115). Both sides make the identical textual
# fix, so git's rebase sees no real conflict (the result the patch wants is already there) and the land still
# succeeds; the warning is the only way either agent would notice they just did the same work twice.
WSETUP7="$TMP/w-setup7"; new_worktree "$WSETUP7"
printf 'l1\nl2\nold\nl4\nl5\n' > "$WSETUP7/shared.txt"
git -C "$WSETUP7" add shared.txt; git -C "$WSETUP7" commit -q -m "add shared.txt"
git -C "$WSETUP7" push -q origin "$LAND_BASE"

W7="$TMP/w7"; new_worktree "$W7"   # branches from the tip that already has shared.txt
sed -i '' 's/^old$/new/' "$W7/shared.txt" 2>/dev/null || sed -i 's/^old$/new/' "$W7/shared.txt"   # edits line 3

W7B="$TMP/w7-rival"; new_worktree "$W7B"   # a rival lands the identical fix first
sed -i '' 's/^old$/new/' "$W7B/shared.txt" 2>/dev/null || sed -i 's/^old$/new/' "$W7B/shared.txt"
git -C "$W7B" add shared.txt
git -C "$W7B" commit -q -m "fix the typo in shared.txt"
git -C "$W7B" push -q origin "$LAND_BASE"

out=$(cd "$W7" && "$LAND" "same fix, done in parallel" -- shared.txt 2>&1); rc=$?
[ $rc -eq 0 ] && ok "lands cleanly even though origin had the identical change" \
  || bad "lands cleanly even though origin had the identical change" "rc=$rc: $out"
grep -qi "origin already changed shared.txt lines 3-3" <<<"$out" \
  && ok "warns about the file and line range origin already changed" \
  || bad "warns about the file and line range origin already changed" "$out"
grep -qi "fix the typo in shared.txt" <<<"$out" && ok "names the overlapping origin commit's subject" \
  || bad "names the overlapping origin commit's subject" "$out"
grep -qi "check you're not duplicating it" <<<"$out" && ok "explains why it's warning" \
  || bad "explains why it's warning" "$out"
final=$(git -C "$BARE" show "$LAND_BASE:shared.txt")
grep -q "^new$" <<<"$final" \
  && ok "the fix is live on $LAND_BASE regardless of which agent's commit carried it" \
  || bad "the fix is live on $LAND_BASE regardless of which agent's commit carried it" "$final"

# == 8. no warning for a commit that changed a DIFFERENT, non-overlapping part of the same file =======================
WSETUP8="$TMP/w-setup8"; new_worktree "$WSETUP8"
printf 'a1\na2\na3\na4\na5\na6\na7\na8\n' > "$WSETUP8/shared2.txt"
git -C "$WSETUP8" add shared2.txt; git -C "$WSETUP8" commit -q -m "add shared2.txt"
git -C "$WSETUP8" push -q origin "$LAND_BASE"

W8="$TMP/w8"; new_worktree "$W8"
sed -i '' 's/^a1$/a1x/' "$W8/shared2.txt" 2>/dev/null || sed -i 's/^a1$/a1x/' "$W8/shared2.txt"   # line 1

W8B="$TMP/w8-rival"; new_worktree "$W8B"
sed -i '' 's/^a8$/a8x/' "$W8B/shared2.txt" 2>/dev/null || sed -i 's/^a8$/a8x/' "$W8B/shared2.txt"   # line 8, no overlap
git -C "$W8B" add shared2.txt; git -C "$W8B" commit -q -m "unrelated fix elsewhere in shared2.txt"
git -C "$W8B" push -q origin "$LAND_BASE"

out=$(cd "$W8" && "$LAND" "a different line, no overlap" -- shared2.txt 2>&1); rc=$?
[ $rc -eq 0 ] && ok "lands cleanly for a non-overlapping change" || bad "lands cleanly for a non-overlapping change" "rc=$rc: $out"
grep -qi "origin already changed" <<<"$out" && bad "a non-overlapping origin commit must not warn" "$out" \
  || ok "no false warning for a non-overlapping origin commit"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[ $FAIL -eq 0 ]
