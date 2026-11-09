#!/bin/bash
# test-offload.sh - Tier-1 tests for tools/agents/offload.sh (run a command on .58 in a copy of this tree).
#
# A fake `ssh` on PATH runs the "remote" side locally, with $HOME = a temp dir, so the real git push and rsync
# go through it too. Checks: usage/unreachable exit codes, two concurrent runs get separate slots (f466), the command's own rc comes back, the copy has tracked
# + untracked files but not ignored ones, deleted files vanish on the next run, and a TERM kills the remote side.
#
# Usage:  bash test/tier1/test-offload.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLOAD="$SCRIPT_DIR/../../tools/agents/offload.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
for t in git rsync setsid taskset; do
  command -v "$t" >/dev/null || { echo "  skip - no $t (tools/agents/tier1.sh --rebuild)"; echo "== Results: 0 passed, 0 failed, 1 skipped =="; exit 0; }
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/remote" "$T/repo"
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
# fake ssh: drop -o options, then the host; run the rest in $FAKE_REMOTE as $HOME.
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
[ -n "${FAKE_SSH_DOWN:-}" ] && { echo "ssh: connect: Connection refused" >&2; exit 255; }
shift
cd "$FAKE_REMOTE" && HOME=$FAKE_REMOTE exec bash -c "$*"
EOF
chmod +x "$T/bin/ssh"
export PATH="$T/bin:$PATH" FAKE_REMOTE="$T/remote" OFFLOAD_HOST=fake OFFLOAD_CPUS=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
cd "$T/repo" && git init -q && echo 'ignored.txt' > .gitignore && echo a > tracked.txt &&
  git add . && git commit -qm init && echo u > untracked.txt && echo i > ignored.txt
R="$T/remote/offload/repo"

bash "$OFFLOAD" >/dev/null 2>&1; rc=$?
[ $rc = 2 ] && ok "no command -> rc 2 (usage)" || bad "no command -> rc 2, got $rc"

FAKE_SSH_DOWN=1 bash "$OFFLOAD" true >/dev/null 2>&1; rc=$?
[ $rc = 255 ] && ok "host unreachable -> rc 255" || bad "host unreachable -> rc 255, got $rc"

out=$(bash "$OFFLOAD" bash -c 'pwd; exit 7' 2>/dev/null); rc=$?
[ $rc = 7 ] && ok "command's rc comes back (7)" || bad "command's rc 7, got $rc"
[ "$(cd "$R" && pwd -P)" = "$(cd "$out" 2>/dev/null && pwd -P)" ] && ok "runs in ~/offload/<worktree name>" ||
  bad "ran in '$out', want $R"
[ -f "$R/tracked.txt" ] && [ -f "$R/untracked.txt" ] && ok "tracked + untracked files copied" ||
  bad "tracked/untracked files missing"
[ ! -e "$R/ignored.txt" ] && ok "gitignored file not copied" || bad "gitignored file copied"

out=$(bash "$OFFLOAD" printf '%s|' 'a b' "c'd" 2>/dev/null)
[ "$out" = "a b|c'd|" ] && ok "arguments with spaces/quotes survive" || bad "arguments mangled: '$out'"

rm tracked.txt untracked.txt
out=$(bash "$OFFLOAD" git status --short 2>/dev/null)
[ ! -e "$R/tracked.txt" ] && [ ! -e "$R/untracked.txt" ] && ok "deleted files vanish on the next run" ||
  bad "deleted files still on the remote"
[ "$out" = "$(git status --short)" ] && ok "remote git status matches local" || bad "git status: '$out'"

bash "$OFFLOAD" sleep 300 2>/dev/null & lp=$!
for _ in $(seq 50); do [ -s "$R.pid" ] && break; sleep 0.1; done
rp=$(cat "$R.pid" 2>/dev/null)
kill -TERM $lp; wait $lp; rc=$?
sleep 0.3
[ -n "$rp" ] && ! kill -0 "$rp" 2>/dev/null && ok "TERM kills the remote command (rc $rc)" ||
  { bad "remote pid '$rp' survived a TERM"; [ -n "$rp" ] && kill -- -"$rp" 2>/dev/null; }

# f466: two offloads from the same worktree at once must not share a ref or a dir. Each writes a marker into its
# copy, waits until both are running, then checks its marker is still the only one there.
git add -A >/dev/null 2>&1; git commit -qm two >/dev/null 2>&1
mkdir -p "$T/sync"
race='echo "$1" > who.txt; touch "$2/$1"; for _ in $(seq 100); do [ -e "$2/a" ] && [ -e "$2/b" ] && break; sleep 0.1; done; sleep 0.3; [ "$(cat who.txt)" = "$1" ] && pwd'
bash "$OFFLOAD" bash -c "$race" _ a "$T/sync" > "$T/a.out" 2> "$T/a.err" & pa=$!
bash "$OFFLOAD" bash -c "$race" _ b "$T/sync" > "$T/b.out" 2> "$T/b.err" & pb=$!
wait $pa; ra=$?; wait $pb; rb=$?
[ $ra = 0 ] && [ $rb = 0 ] && ok "two concurrent offloads both succeed" ||
  bad "concurrent offloads: rc $ra/$rb: $(tail -n2 "$T/a.err" "$T/b.err" | tr '\n' ' ')"
da=$(cat "$T/a.out"); db=$(cat "$T/b.out")
[ -n "$da" ] && [ -n "$db" ] && [ "$da" != "$db" ] && ok "they ran in separate dirs (${da##*/}, ${db##*/})" ||
  bad "concurrent offloads shared a dir: '$da' '$db'"
out=$(bash "$OFFLOAD" pwd 2>/dev/null)
[ "$(cd "$R" && pwd -P)" = "$(cd "$out" 2>/dev/null && pwd -P)" ] && ok "slot 1 (~/offload/<name>) free again afterwards" ||
  bad "after the race, ran in '$out', want $R"

# Stale extra slots are swept: age repo@2's lock past the TTL, then any run removes it.
touch -d '10 days ago' "$T/remote/offload/repo@2.lock" 2>/dev/null
bash "$OFFLOAD" true 2>/dev/null
[ ! -e "$T/remote/offload/repo@2" ] && [ ! -e "$T/remote/offload/repo@2.lock" ] && ok "stale extra slot swept" ||
  bad "stale slot repo@2 still there"

# All slots busy -> one-line reason, rc 97.
bash "$OFFLOAD" sleep 3 >/dev/null 2>&1 & ph=$!
for _ in $(seq 50); do [ -s "$R.pid" ] && [ "$(cat "$R.pid")" != "$rp" ] && break; sleep 0.1; done
err=$(OFFLOAD_SLOTS=1 bash "$OFFLOAD" true 2>&1 >/dev/null); rc=$?
[ $rc = 97 ] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ] && grep -q busy <<<"$err" &&
  ok "all slots busy -> rc 97 + one-line reason" || bad "slots busy: rc $rc, '$err'"
wait $ph

echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
[ $FAIL = 0 ]
