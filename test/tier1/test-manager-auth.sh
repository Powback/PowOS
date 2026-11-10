#!/usr/bin/env bash
# test-manager-auth.sh — how the manager's claude is signed in (lib/ai/manager/manager.sh _manager_auth).
#
# The non-root build signs its AI in with the buyer's own Claude account inside the app (11-04); the owner's devices
# keep the fleet endpoint (/etc/powos/ai/endpoint.conf). Pinned here:
#   endpoint present          -> "endpoint", the chat runs as today (the broker starts, no sign-in event)
#   no endpoint, no login     -> "signin", the chat prints {"kind": "signin"}, status 4, the broker never starts
#   Claude Code logged in     -> "login", the chat runs directly
#   --signin / --signout      -> Claude Code's own `claude auth login` / `claude auth logout`
#   claude not installed      -> "install" whatever the sign-in (the endpoint's too), ahead of "signin"; a turn whose
#                                claude can't be had prints {"kind": "install"}, status 4; --install installs it
#   nothing prints a credential's contents.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home"
# A stand-in claude: records its arguments, never a network call.
cat > "$WORK/bin/claude" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$WORK/claude.log"
EOF
# A stand-in broker: says it ran.
printf 'import sys\nprint("BROKER-RAN")\n' > "$WORK/broker.py"
chmod +x "$WORK/bin/claude"
printf 'ANTHROPIC_BASE_URL=http://fixture.pow\nANTHROPIC_AUTH_TOKEN=fixture-tok\n' > "$WORK/endpoint.conf"

RUN_ENV=()
# run <endpoint file> <manager args...> -> its stdout, then "rc=N"
run() {
    local ep="$1"; shift
    env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK/home" TMPDIR="$WORK" ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
        POWOS_AI_ENDPOINT_FILE="$ep" MANAGER_SERVER="$WORK/broker.py" MANAGER_SANDBOX=/nonexistent \
        AI_STATE_DIR="$WORK/state" \
        bash -c 'source "$1/lib/ai/agent.sh" >/dev/null 2>&1
                 _ai_load_agent() { :; }
                 source "$1/lib/ai/manager/manager.sh"
                 shift; manager_run "$@"; echo "rc=$?"' _ "$REPO" "$@" 2>/dev/null
}

echo "== manager auth (endpoint / login / signin) =="
bash -n "$REPO/lib/ai/manager/manager.sh" && ok "manager.sh parses" || bad "manager.sh syntax error"

# --- endpoint present: unchanged ---------------------------------------------
OUT=$(run "$WORK/endpoint.conf" --auth)
[[ "$OUT" == $'endpoint\nrc=0' ]] && ok "endpoint.conf -> endpoint" || bad "endpoint.conf: got '$OUT'"
OUT=$(run "$WORK/endpoint.conf" --once-stdin --json-events </dev/null)
[[ "$OUT" == *BROKER-RAN* && "$OUT" != *signin* && "$OUT" == *rc=0 ]] \
  && ok "endpoint: the chat runs as before (no sign-in)" || bad "endpoint chat: got '$OUT'"
# A login in the image never overrides the owner's endpoint.
mkdir -p "$WORK/home/.claude"; echo '{}' > "$WORK/home/.claude/.credentials.json"
OUT=$(run "$WORK/endpoint.conf" --auth)
[[ "$OUT" == $'endpoint\nrc=0' ]] && ok "endpoint wins over an image login" || bad "endpoint+login: got '$OUT'"
rm -f "$WORK/home/.claude/.credentials.json"

# --- absent, no login: the sign-in state ---------------------------------------
OUT=$(run "$WORK/none.conf" --auth)
[[ "$OUT" == $'signin\nrc=0' ]] && ok "no endpoint, no login -> signin" || bad "signin: got '$OUT'"
OUT=$(run "$WORK/none.conf" --once-stdin --json-events </dev/null)
[[ "$OUT" == $'{"kind": "signin"}\nrc=4' ]] \
  && ok "signin: the chat says so (event + status 4), the broker never starts" || bad "signin chat: got '$OUT'"
OUT=$(run "$WORK/none.conf" --once-inbox --json-events </dev/null)
[[ "$OUT" == *'"kind": "signin"'* && "$OUT" != *BROKER-RAN* ]] && ok "signin: the inbox turn waits too" || bad "inbox: got '$OUT'"

# --- logged in: direct ----------------------------------------------------------
echo '{"claudeAiOauth":{"accessToken":"SECRET-FIXTURE"}}' > "$WORK/home/.claude/.credentials.json"
OUT=$(run "$WORK/none.conf" --auth)
[[ "$OUT" == $'login\nrc=0' ]] && ok "Claude Code login -> login" || bad "login: got '$OUT'"
OUT=$(run "$WORK/none.conf" --once-stdin --json-events </dev/null)
[[ "$OUT" == *BROKER-RAN* && "$OUT" != *signin* ]] && ok "login: the chat runs directly" || bad "login chat: got '$OUT'"
ALL=$(run "$WORK/none.conf" --auth; run "$WORK/none.conf" --signout)
[[ "$ALL" != *SECRET-FIXTURE* ]] && ok "no credential is ever printed" || bad "a credential was printed"

# --- the login / logout are Claude Code's own ----------------------------------
: > "$WORK/claude.log"
run "$WORK/none.conf" --signin >/dev/null
grep -qx "auth login --claudeai" "$WORK/claude.log" && ok "--signin runs claude auth login" || bad "--signin ran: $(cat "$WORK/claude.log")"
run "$WORK/none.conf" --signout >/dev/null
grep -qx "auth logout" "$WORK/claude.log" && ok "--signout runs claude auth logout" || bad "--signout ran: $(cat "$WORK/claude.log")"

# --- claude not installed: the Install Claude state ------------------------------
if PATH=/usr/bin:/bin command -v claude &>/dev/null; then
    echo "  skip: a claude in /usr/bin or /bin on this host - the not-installed cases can't be staged"
else
    rm -f "$WORK/home/.claude/.credentials.json"
    mv "$WORK/bin/claude" "$WORK/claude.real"
    OUT=$(run "$WORK/none.conf" --auth)
    [[ "$OUT" == $'install\nrc=0' ]] && ok "no claude, no login -> install (not signin)" || bad "install: got '$OUT'"
    OUT=$(run "$WORK/endpoint.conf" --auth)
    [[ "$OUT" == $'install\nrc=0' ]] && ok "no claude, endpoint -> install (the manager still needs claude)" || bad "endpoint install: got '$OUT'"
    echo '{}' > "$WORK/home/.claude/.credentials.json"
    OUT=$(run "$WORK/none.conf" --auth)
    [[ "$OUT" == $'install\nrc=0' ]] && ok "no claude, a login -> install" || bad "login install: got '$OUT'"
    rm -f "$WORK/home/.claude/.credentials.json"
    # Its installer's place (~/.local/bin, not on PATH yet) counts as installed.
    mkdir -p "$WORK/home/.local/bin"; cp "$WORK/claude.real" "$WORK/home/.local/bin/claude"
    OUT=$(run "$WORK/none.conf" --auth)
    [[ "$OUT" == $'signin\nrc=0' ]] && ok "claude in ~/.local/bin -> signin" || bad "local bin: got '$OUT'"
    OUT=$(run "$WORK/none.conf" --install)
    [[ "$OUT" == rc=0 ]] && ok "--install with claude there: status 0, nothing installed" || bad "--install present: got '$OUT'"
    rm -f "$WORK/home/.local/bin/claude"
    # MANAGER_CLAUDE_CMD naming a CLI that isn't there: install; its turn says so and never starts the broker (no
    # network: _manager_ensure_claude runs the vendor installer only for claude itself).
    RUN_ENV=(MANAGER_CLAUDE_CMD="no-such-claude --x")
    mv "$WORK/claude.real" "$WORK/bin/claude"
    OUT=$(run "$WORK/none.conf" --auth)
    [[ "$OUT" == $'install\nrc=0' ]] && ok "MANAGER_CLAUDE_CMD missing -> install" || bad "cmd install: got '$OUT'"
    OUT=$(run "$WORK/endpoint.conf" --once-stdin --json-events </dev/null)
    [[ "$OUT" == $'{"kind": "install"}\nrc=4' ]] \
      && ok "install: the turn says so (event + status 4), the broker never starts" || bad "install chat: got '$OUT'"
    OUT=$(run "$WORK/none.conf" --install)
    [[ "$OUT" == rc=1 ]] && ok "--install that can't install: status 1" || bad "--install missing: got '$OUT'"
    RUN_ENV=()
fi

echo "  $pass passed, $fail failed"
(( fail == 0 ))
