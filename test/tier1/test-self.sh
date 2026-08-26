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

# NOTE: deliberately NO `pipefail`. These harnesses assert with
# `echo "$out" | grep -q ...`, and `grep -q` exits on its first match — which
# SIGPIPEs the writer, making the pipeline return 141 under pipefail depending
# on scheduling. That produced random failures (test-windows.sh swung between 4
# and 11 "failures" on identical runs). Last-command status is the correct
# semantics for an assertion anyway.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Prefer the WORKING TREE over the installed copy. This used to be the other
# way round, which meant running the suite inside a PowOS image silently
# tested /usr/lib/powos (the baked, possibly months-old code) instead of the
# changes under test — failures then looked like real regressions when the
# working tree was never loaded at all.
LIB=$REPO/lib/self.sh
[[ -f "$LIB" ]] || LIB="/usr/lib/powos/self.sh"

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
    # These default to 0, i.e. to what the catch-all below already did — they
    # exist so the attach phases' failure paths are reachable.
    fetch)    exit "${FAKE_GIT_FETCH_RC:-0}" ;;
    checkout) exit "${FAKE_GIT_CHECKOUT_RC:-0}" ;;
    init)     exit "${FAKE_GIT_INIT_RC:-0}" ;;
    stash)    case "${a[3]:-${a[1]:-}}" in
                  push) exit "${FAKE_GIT_STASH_PUSH_RC:-0}" ;;
                  pop)  exit "${FAKE_GIT_STASH_POP_RC:-0}" ;;
              esac; exit 0 ;;
    *)        exit 0 ;;   # remote/reset/pull/add/commit
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

# ═══════════════════════════════════════════════════════════════════
echo "== OCI hook integrity: binary + JSON must ship together =="
# Incident 2026-07-14: the hook JSON shipped without its binary, breaking
# EVERY container start with an opaque crun error. Both-or-neither must be
# true in the source tree at all times — the Containerfile build guard
# catches it at build time, this test catches it in CI/pre-commit.
HOOK_JSON="$REPO/config/etc/containers/oci/hooks.d/pow-collision-check.json"
HOOK_BIN="$REPO/bin/pow-collision-check"
json_present=false; bin_present=false
[[ -f "$HOOK_JSON" ]] && json_present=true
[[ -f "$HOOK_BIN" ]] && bin_present=true
if [[ "$json_present" == "true" ]] && [[ "$bin_present" == "true" ]]; then
    ok "hook JSON and binary both present in source tree"
    [[ -x "$HOOK_BIN" ]] && ok "hook binary is executable in source tree" \
                          || bad "bin/pow-collision-check is NOT executable — chmod +x it"
elif [[ "$json_present" == "false" ]] && [[ "$bin_present" == "false" ]]; then
    ok "neither hook JSON nor binary (consistent — both removed)"
elif [[ "$json_present" == "true" ]] && [[ "$bin_present" == "false" ]]; then
    bad "hook JSON present but bin/pow-collision-check MISSING — this breaks every container start"
else
    bad "bin/pow-collision-check present but hook JSON MISSING — hook will never fire"
fi
# When running inside a built image (Docker tier), also verify installed paths.
if [[ -f /etc/containers/oci/hooks.d/pow-collision-check.json ]]; then
    if [[ -x /usr/bin/pow-collision-check ]]; then
        ok "installed: /usr/bin/pow-collision-check present and executable"
    else
        bad "installed: hook JSON at /etc/containers/oci/hooks.d/pow-collision-check.json exists but /usr/bin/pow-collision-check is MISSING or not executable"
    fi
fi

# ── reload: desktop widgets, and the overlay-permission trap ─────────
# `powos reload` must ship plasmoids, or a one-line QML fix needs a full image
# build and looks like it "didn't work" when it simply was not deployed.
RELOAD_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/reload.sh"
if [[ -f "$RELOAD_SH" ]]; then
    if grep -q 'desktop/plasmoid' "$RELOAD_SH"; then
        ok "reload deploys desktop/plasmoid (QML changes are hot-applicable)"
    else
        bad "reload does not deploy plasmoids — widget edits need a full image build"
    fi

    # For a directory present in BOTH layers, overlayfs takes the UPPER layer's
    # mode. A bare `mkdir -p` in the sysext builder runs under the root shell's
    # umask, so /usr/share and /usr/share/plasma came out 0700 and masked every
    # Plasma file from the session — the desktop lost all its widgets.
    if grep -qE 'mkdir -p "\$ext/usr/share' "$RELOAD_SH"; then
        bad "sysext builder uses bare 'mkdir -p' under /usr/share — will mask it at 0700"
    else
        ok "sysext builder does not create /usr/share dirs with an inherited umask"
    fi
    if grep -q 'install -d -m755 "\$ext/usr/share"' "$RELOAD_SH"; then
        ok "shared dirs are created with an explicit 0755 mode"
    else
        bad "no explicit mode on the extension's /usr/share dirs"
    fi
fi

# ═══════════════════════════════════════════════════════════════════
echo "== self_safe_pull phases (the extracted seams, contract level) =="
# ═══════════════════════════════════════════════════════════════════
# self_safe_pull is an orchestrator over named phases. The end-to-end checks
# above pin the promise the command makes ("NEVER discards local edits");
# these pin each phase's own contract — what it publishes and what it refuses
# — so a phase cannot stop refusing while the orchestrator still looks right.
# Asserted on return codes, published globals and the recorded git calls, not
# on wording.

PH="$WORK/phase"; mkdir -p "$PH"
PHRO="$WORK/phase-ro"; mkdir -p "$PHRO"; chmod 500 "$PHRO"
BAKED=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
printf '%s\n' "$BAKED" > "$WORK/phase-marker"

# ── self_pull_existing: Case A, the plain safe pull ───────────────
: > "$GIT_LOG"
FAKE_GIT_DIRTY=1 FAKE_GIT_STASH_PUSH_RC=1 self_pull_existing "$PH" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "existing: a failed stash means NO pull (edits untouched)" \
  || bad "existing: pulled anyway after the stash failed (rc=$rc)"
! grep -qE '(^| )pull( |$)' "$GIT_LOG" && ok "existing: no pull ran once the stash failed" \
  || bad "existing: a pull ran over unstashed edits"

: > "$GIT_LOG"
FAKE_GIT_DIRTY=1 FAKE_GIT_STASH_POP_RC=1 self_pull_existing "$PH" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "existing: a conflicting stash pop reports rc=2, not success" \
  || bad "existing: conflicted pop returned $rc (the edits are in the stash!)"

# ── self_pull_attach: turn a bundle into a checkout ───────────────
SELF_MARKER="$WORK/phase-marker"
: > "$GIT_LOG"
self_pull_attach "$PHRO" https://example.invalid/x.git >/dev/null 2>&1; rc=$?
if [[ $EUID -eq 0 ]]; then
    ok "attach: (skipped writability refusal — running as root)"
else
    [[ $rc -ne 0 ]] && ok "attach: refuses a read-only bundled source" \
      || bad "attach: tried to init a git repo it cannot write to"
fi

: > "$GIT_LOG"
FAKE_GIT_INIT_RC=1 self_pull_attach "$PH" https://example.invalid/x.git >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "attach: a failed git init aborts" || bad "attach: continued after init failed"

: > "$GIT_LOG"
self_pull_attach "$PH" https://example.invalid/x.git >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && "$SELF_PULL_BAKED" == "$BAKED" ]] \
  && ok "attach: publishes the baked base SHA" \
  || bad "attach: SELF_PULL_BAKED is '$SELF_PULL_BAKED' (rc=$rc)"
[[ "$SELF_PULL_HAVE_MASTER" == 1 ]] && ok "attach: records that origin/master arrived" \
  || bad "attach: did not record the master fetch"

# A failed fetch is normal (offline) — the FALLBACK reports it with the right
# message. If the trailing `&&` escaped as the return value, attach would abort
# every offline run before the fallback ever got a chance.
: > "$GIT_LOG"
FAKE_GIT_FETCH_RC=1 self_pull_attach "$PH" https://example.invalid/x.git >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "attach: an offline fetch is not an attach failure" \
  || bad "attach: returned $rc because the fetch failed (the && leaked)"
[[ "$SELF_PULL_HAVE_MASTER" == 0 ]] && ok "attach: records that master did NOT arrive" \
  || bad "attach: claimed master arrived after a failed fetch"

# ── self_pull_have_base: is the TRUE base usable? ─────────────────
SELF_PULL_HAVE_MASTER=1
self_pull_have_base "$PH" unknown 2>/dev/null \
  && bad "have_base: accepted the literal 'unknown' as a commit" \
  || ok "have_base: an unknown baked SHA is not a base"
self_pull_have_base "$PH" "" 2>/dev/null \
  && bad "have_base: accepted an empty baked SHA" \
  || ok "have_base: an empty baked SHA is not a base"
FAKE_GIT_CATFILE_RC=1 self_pull_have_base "$PH" "$BAKED" 2>/dev/null \
  && bad "have_base: accepted a commit git cannot resolve" \
  || ok "have_base: an unresolvable baked commit is not a base"
SELF_PULL_HAVE_MASTER=0
self_pull_have_base "$PH" "$BAKED" 2>/dev/null \
  && bad "have_base: accepted a base with no origin/master to align onto" \
  || ok "have_base: needs origin/master as well as the base"
SELF_PULL_HAVE_MASTER=1
self_pull_have_base "$PH" "$BAKED" 2>/dev/null \
  && ok "have_base: base present + master fetched → usable" \
  || bad "have_base: rejected a perfectly good base"

# ── self_pull_align_baked ─────────────────────────────────────────
SELF_PULL_HAVE_MASTER=1
self_pull_align_baked "$PH" unknown >/dev/null 2>&1; rc=$?
[[ $rc -eq $SELF_PULL_SKIP ]] \
  && ok "align_baked: hands back SKIP so the caller falls through" \
  || bad "align_baked: returned $rc instead of the SKIP sentinel"

: > "$GIT_LOG"
FAKE_GIT_DIRTY=1 self_pull_align_baked "$PH" "$BAKED" >/dev/null 2>&1; rc=$?
grep -q "stash push" "$GIT_LOG" && ok "align_baked: a dirty bundle is stashed before checkout" \
  || bad "align_baked: checked out over local edits without stashing"
grep -q "stash pop" "$GIT_LOG" && ok "align_baked: the edits are popped back afterwards" \
  || bad "align_baked: edits left in the stash"
[[ $rc -eq 0 ]] && ok "align_baked: succeeds with edits preserved" || bad "align_baked rc=$rc"

: > "$GIT_LOG"
FAKE_GIT_DIRTY=1 FAKE_GIT_CHECKOUT_RC=1 self_pull_align_baked "$PH" "$BAKED" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "align_baked: a failed checkout is a failure" || bad "align_baked hid a failed checkout"
grep -q "stash pop" "$GIT_LOG" \
  && ok "align_baked: the stash is restored even when the checkout fails" \
  || bad "align_baked: left the user's edits stashed after a failed checkout"

: > "$GIT_LOG"
FAKE_GIT_DIRTY=1 FAKE_GIT_STASH_POP_RC=1 self_pull_align_baked "$PH" "$BAKED" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "align_baked: a conflicting pop reports rc=2 (edits are in the stash)" \
  || bad "align_baked: conflicted pop returned $rc"

# ── self_pull_align_master: the no-true-base fallback ─────────────
# This is the load-bearing refusal: without the baked base we cannot tell a
# pristine bundle from an edited one, so a dirty tree must NEVER be reset.
SELF_PULL_HAVE_MASTER=0
: > "$GIT_LOG"
self_pull_align_master "$PH" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "align_master: refuses when upstream never arrived" || bad "align_master rc=$rc offline"
! grep -qE '(^| )checkout' "$GIT_LOG" && ok "align_master: no checkout when upstream is missing" \
  || bad "align_master: checked out with no upstream"

SELF_PULL_HAVE_MASTER=1
: > "$GIT_LOG"
FAKE_GIT_DIRTY=1 self_pull_align_master "$PH" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "align_master: REFUSES a dirty tree with no known base" \
  || bad "align_master: would have reset over local edits"
! grep -qE '(^| )checkout' "$GIT_LOG" \
  && ok "align_master: nothing is checked out when it refuses" \
  || bad "align_master: ran a checkout in the refuse path"

: > "$GIT_LOG"
self_pull_align_master "$PH" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "align_master: a clean tree is safe to align" || bad "align_master rc=$rc on a clean tree"
grep -q "checkout -B master origin/master" "$GIT_LOG" \
  && ok "align_master: aligns onto origin/master (never checkout -f)" \
  || bad "align_master: did not align a clean tree"
! grep -q "checkout -f" "$GIT_LOG" && ok "align_master: never uses checkout -f" || bad "checkout -f used!"

: > "$GIT_LOG"
FAKE_GIT_CHECKOUT_RC=1 self_pull_align_master "$PH" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "align_master: a failed checkout is reported" || bad "align_master hid a failed checkout"

unset FAKE_GIT_DIRTY FAKE_GIT_FETCH_RC FAKE_GIT_CHECKOUT_RC FAKE_GIT_INIT_RC \
      FAKE_GIT_STASH_PUSH_RC FAKE_GIT_STASH_POP_RC FAKE_GIT_CATFILE_RC
SELF_MARKER="$WORK/missing"


echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
