#!/bin/bash
# test-login.sh - `powos login github` device flow + `self push` auto sign-in, with a FAKE gh and git.
# Never signs in, never touches real credentials, ~/.ssh or the network.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export POWOS_LIB="$REPO/lib"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"; LOG="$WORK/log"; : > "$LOG"
# fake gh: "auth status" succeeds only once $WORK/signed exists; "auth login" prints a device code and signs in.
cat > "$BIN/gh" <<'G'
#!/bin/bash
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "auth status") [[ -f "$FAKE_SIGNED" ]]; exit $? ;;
  "auth login")  echo "! First copy your one-time code: ABCD-1234"; echo "- Waiting for approval"
                 [[ "${FAKE_DENY:-}" == 1 ]] && exit 1; : > "$FAKE_SIGNED"; exit 0 ;;
  "auth setup-git") exit 0 ;;
  "api user") echo octo; exit 0 ;;
esac
exit 0
G
# fake git: first push fails with an auth error until signed in.
cat > "$BIN/git" <<'G'
#!/bin/bash
echo "git $*" >> "$FAKE_LOG"
if [[ "$*" == *" push"* ]]; then
  [[ -f "$FAKE_SIGNED" ]] && { echo "ok pushed"; exit 0; }
  echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled"; exit 128
fi
[[ "$*" == *"diff --cached --quiet"* ]] && exit 0
exit 0
G
chmod +x "$BIN/gh" "$BIN/git"
export PATH="$BIN:$PATH" FAKE_LOG="$LOG" FAKE_SIGNED="$WORK/signed" HOME="$WORK/home"; mkdir -p "$HOME"

source "$REPO/lib/common.sh"; source "$REPO/lib/setup.sh"

echo "== powos login github: device flow =="
out="$(cmd_login github 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "login succeeds" || bad "login rc=$rc: $out"
grep -q ">>> GitHub sign-in: open https://github.com/login/device and enter code ABCD-1234" <<<"$out" && ok "prints code + URL line" || bad "no code line: $out"
grep -q "gh auth setup-git" "$LOG" && ok "configures git credential helper" || bad "no setup-git"
grep -q -- "--skip-browser" "$LOG" && ok "headless-safe flags" || bad "no --skip-browser"

echo "== idempotent =="
: > "$LOG"; out="$(cmd_login github 2>&1)"
grep -qi "already signed in" <<<"$out" && ok "says already signed in" || bad "not idempotent: $out"
grep -q "auth login" "$LOG" && bad "re-ran auth login" || ok "no second device flow"

echo "== denied =="
rm -f "$FAKE_SIGNED"; out="$(FAKE_DENY=1 cmd_login github 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "denied -> non-zero" || bad "denied returned 0"

echo "== self push signs in by itself =="
rm -f "$FAKE_SIGNED"; : > "$LOG"
source "$REPO/lib/self.sh"
mkdir -p "$WORK/src/.git"
out="$(self_push "$WORK/src" "msg" bin/powos 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "push succeeds after automatic sign-in" || bad "push rc=$rc: $out"
grep -q "enter code ABCD-1234" <<<"$out" && ok "code shown during push" || bad "no code during push"
[[ "$(grep -c ' push' "$LOG")" -eq 2 ]] && ok "push retried once" || bad "push count wrong"

echo "$PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]
