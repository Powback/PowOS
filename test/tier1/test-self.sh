#!/bin/bash
# test-self.sh - unit tests for `powos self` (the edit → test → push dev loop).
#
# Pure/mockable coverage — no real git remote, no /usr writes:
#   • self_safe_pull NEVER discards local edits and NEVER runs `checkout -f`
#     over a dirty tree (stash/pop path is taken instead).
#   • self_baked_sha reads the baked commit marker.
#   • self_status prints the baked SHA from a fixture marker.
#   • self_push with a failing `git push` prints the helpful auth hint and
#     returns non-zero.
#   • the baked-SHA image wiring (Containerfile ARG + build-arg) is present.
#
# Uses a fake `git` on PATH so nothing touches a real repo or network.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="/usr/lib/powos/self.sh"
[[ -f "$LIB" ]] || LIB="$REPO/lib/self.sh"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

# ── Fake git: logs every invocation, returns programmed exit codes ──
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
GIT_LOG="$WORK/git.log"; : > "$GIT_LOG"

cat > "$FAKEBIN/git" <<'FAKE'
#!/bin/bash
echo "$*" >> "$GIT_LOG"
a=("$@")
if [[ "${a[0]:-}" == "-C" ]]; then sub="${a[2]:-}"; else sub="${a[0]:-}"; fi
case "$sub" in
    status)   [[ "${FAKE_GIT_DIRTY:-0}" == 1 ]] && echo " M bin/powos"; exit 0 ;;
    diff)     exit "${FAKE_GIT_DIFF_RC:-1}" ;;   # --cached --quiet: 1 = staged changes
    push)     [[ -n "${FAKE_GIT_PUSH_ERR:-}" ]] && echo "$FAKE_GIT_PUSH_ERR" >&2
              exit "${FAKE_GIT_PUSH_RC:-0}" ;;
    log)      echo "abc1234 fake head"; exit 0 ;;
    rev-list) printf '0\t0\n'; exit 0 ;;
    cat-file) exit "${FAKE_GIT_CATFILE_RC:-0}" ;;
    *)        exit 0 ;;   # init/remote/fetch/reset/stash/pull/add/commit/checkout
esac
FAKE
chmod +x "$FAKEBIN/git"
export GIT_LOG
PATH="$FAKEBIN:$PATH"

# shellcheck disable=SC1090
source "$LIB"

# ═══════════════════════════════════════════════════════════════════
echo "== self_safe_pull: dirty checkout is stashed, never force-nuked =="
SRC="$WORK/checkout"; mkdir -p "$SRC/.git"
: > "$GIT_LOG"
FAKE_GIT_DIRTY=1 self_safe_pull "$SRC" >/dev/null 2>&1
rc=$?
grep -q "stash push" "$GIT_LOG"                 && ok "dirty tree → git stash push taken" || bad "no stash push logged"
grep -q "stash pop"  "$GIT_LOG"                 && ok "edits restored → git stash pop taken" || bad "no stash pop logged"
grep -q "pull --rebase" "$GIT_LOG"              && ok "pull uses --rebase" || bad "no pull --rebase"
! grep -q "checkout -f" "$GIT_LOG"              && ok "checkout -f NEVER invoked" || bad "checkout -f was invoked over dirty tree!"
[[ $rc -eq 0 ]] && ok "returns success" || bad "unexpected rc=$rc"

echo "== self_safe_pull: bundled snapshot, baked SHA unknown + dirty → REFUSE, no force =="
SNAP="$WORK/snapshot"; mkdir -p "$SNAP"        # no .git → bundled path
: > "$GIT_LOG"
SELF_MARKER="$WORK/nonexistent-marker"          # → baked SHA "unknown"
FAKE_GIT_DIRTY=1 self_safe_pull "$SNAP" >/dev/null 2>&1
rc=$?
[[ $rc -ne 0 ]] && ok "refuses (non-zero) when base unknown and tree dirty" || bad "did not refuse (rc=$rc)"
! grep -q "checkout -f" "$GIT_LOG"              && ok "no checkout -f in refuse path" || bad "checkout -f invoked in refuse path!"
! grep -qE '^(-C [^ ]+ )?checkout' "$GIT_LOG"   && ok "no checkout at all when refusing" || bad "a checkout ran despite refusing"

# ═══════════════════════════════════════════════════════════════════
echo "== self_baked_sha / self_status: read baked marker =="
MARK="$WORK/marker"; printf 'deadbeefcafe1234\n' > "$MARK"
SELF_MARKER="$MARK"
[[ "$(self_baked_sha)" == "deadbeefcafe1234" ]] && ok "self_baked_sha reads the marker" || bad "self_baked_sha wrong: $(self_baked_sha)"
SELF_MARKER="$WORK/missing"
[[ "$(self_baked_sha)" == "unknown" ]] && ok "missing marker → 'unknown'" || bad "missing marker not 'unknown'"

SELF_MARKER="$MARK"
out="$(self_status "$WORK/snapshot" 2>&1)"
grep -q "deadbeefcafe1234" <<<"$out" && ok "self_status prints baked SHA" || bad "self_status missing baked SHA"
grep -qi "not attached" <<<"$out" && ok "self_status flags snapshot as not-attached" || bad "self_status attach state wrong"

# ═══════════════════════════════════════════════════════════════════
echo "== self_push: failing push → helpful auth hint, non-zero =="
PUSHSRC="$WORK/pushsrc"; mkdir -p "$PUSHSRC/.git"
: > "$GIT_LOG"
out="$(FAKE_GIT_PUSH_RC=1 FAKE_GIT_PUSH_ERR="fatal: no configured push destination" \
       self_push "$PUSHSRC" "msg" 2>&1)"
rc=$?
[[ $rc -ne 0 ]] && ok "returns non-zero when push fails" || bad "push failure returned 0"
grep -qi "gh auth login" <<<"$out" && ok "prints 'gh auth login' hint" || bad "no auth hint in output"
grep -q "commit -m" "$GIT_LOG" && ok "commits staged changes before push" || bad "did not commit"

echo "== self_push: no .git attached → refuse with guidance =="
NOGIT="$WORK/nogit"; mkdir -p "$NOGIT"
out="$(self_push "$NOGIT" "" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "refuses when no git attached" || bad "did not refuse without .git"
grep -qi "self pull" <<<"$out" && ok "tells user to run 'self pull' first" || bad "no attach guidance"

# ═══════════════════════════════════════════════════════════════════
echo "== baked-SHA image wiring present =="
grep -q 'ARG POWOS_SRC_COMMIT' "$REPO/Containerfile" && ok "Containerfile declares ARG POWOS_SRC_COMMIT" || bad "Containerfile ARG missing"
grep -q '.powos-src-commit' "$REPO/Containerfile" && ok "Containerfile writes the marker file" || bad "Containerfile marker RUN missing"
grep -q 'POWOS_SRC_COMMIT=' "$REPO/build/build-iso.sh" && ok "build-iso.sh passes the build-arg" || bad "build-iso.sh build-arg missing"

# ═══════════════════════════════════════════════════════════════════
echo "== dev-sudoers: no unrestricted file-ops rules =="
# The sudoers drop-in must NEVER contain NOPASSWD rules for raw cp, mv,
# chmod, or mkdir — those are unrestricted root file operations that
# defeat the scoping purpose entirely. `powos update self` already runs
# as root and handles its own deploy internally.
SETUP_SH="$REPO/lib/setup.sh"
for dangerous in "/usr/bin/cp " "/usr/bin/mv " "/usr/bin/chmod " "/usr/bin/mkdir "; do
    if grep -q "NOPASSWD:.*${dangerous}" "$SETUP_SH" 2>/dev/null; then
        bad "setup.sh contains unrestricted NOPASSWD rule for ${dangerous%% *}"
    else
        ok "no NOPASSWD rule for ${dangerous%% *}"
    fi
done

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
