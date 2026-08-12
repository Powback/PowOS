#!/usr/bin/env bash
# test-ai-endpoint.sh — the ONE source of truth for the Anthropic endpoint.
#
# The endpoint used to live only in the environment, in five uncoordinated
# copies (~/.bashrc, environment.d, the systemd user env, the dbus activation
# env, each container's compose file). When the authority moved off-box only the
# shell copy was updated, so `powos ai` worked in a terminal while the desktop
# widget — which inherits plasmashell's environment from session start — kept
# calling a proxy that no longer existed and failed with connection refused.
#
# These tests pin the contract that replaced it: `powos config claude-endpoint`
# writes one file, lib/ai/agent.sh reads it at call time, and an explicit
# environment variable still wins so nothing that works today can break.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
AGENT="$REPO/lib/ai/agent.sh"
CONFIG="$REPO/lib/config.sh"
for f in "$AGENT" "$CONFIG"; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CONF="$WORK/endpoint.conf"
printf 'ANTHROPIC_BASE_URL=http://fixture.pow\nANTHROPIC_AUTH_TOKEN=fixture-tok\n' > "$CONF"

echo "== ai endpoint (single source of truth) =="

bash -n "$AGENT"  && ok "agent.sh parses"  || bad "agent.sh syntax error"
bash -n "$CONFIG" && ok "config.sh parses" || bad "config.sh syntax error"

# --- the two halves must agree on WHERE the file is ------------------------
# A mismatch means `powos config` writes one path while the agents read another,
# and the symptom is silence: the setting appears to save and changes nothing.
A_PATH=$(grep -oE 'POWOS_AI_ENDPOINT_FILE:-[^}]+' "$AGENT"  | head -1 | cut -d- -f2-)
C_PATH=$(grep -oE 'POWOS_AI_ENDPOINT_FILE:-[^}]+' "$CONFIG" | head -1 | cut -d- -f2-)
if [ -n "$A_PATH" ] && [ "$A_PATH" = "$C_PATH" ]; then
  ok "writer and reader agree on the path ($A_PATH)"
else
  bad "path mismatch — writer='$C_PATH' reader='$A_PATH'"
fi

# --- resolution order ------------------------------------------------------
run_agent() {  # run_agent <env assignments...> -> prints URL|TOKEN
  env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN "$@" \
      POWOS_AI_ENDPOINT_FILE="$CONF" \
      bash -c 'source "'"$AGENT"'" >/dev/null 2>&1
               _ai_load_endpoint
               echo "${ANTHROPIC_BASE_URL:-<unset>}|${ANTHROPIC_AUTH_TOKEN:-<unset>}"' 2>/dev/null
}

OUT=$(run_agent)
[ "$OUT" = "http://fixture.pow|fixture-tok" ] \
  && ok "reads both values from the file when the env is empty" \
  || bad "file not read: got '$OUT'"

OUT=$(env ANTHROPIC_BASE_URL=http://explicit.example POWOS_AI_ENDPOINT_FILE="$CONF" \
      bash -c 'source "'"$AGENT"'" >/dev/null 2>&1; _ai_load_endpoint; echo "$ANTHROPIC_BASE_URL"' 2>/dev/null)
[ "$OUT" = "http://explicit.example" ] \
  && ok "an explicit env value wins (overrides + containers keep working)" \
  || bad "env was clobbered by the file: got '$OUT'"

OUT=$(env -u ANTHROPIC_BASE_URL POWOS_AI_ENDPOINT_FILE=/nonexistent/x.conf \
      bash -c 'source "'"$AGENT"'" >/dev/null 2>&1; _ai_load_endpoint; echo "rc=$?"' 2>/dev/null)
[ "$OUT" = "rc=0" ] && ok "a missing file is harmless (never breaks an agent)" \
  || bad "missing file returned '$OUT'"

# --- the file must be PARSED, never sourced --------------------------------
# It is root-written, but sourcing turns one stray line into arbitrary code
# inside every agent process on the box.
printf 'ANTHROPIC_BASE_URL=http://ok.pow\ntouch %s/PWNED\n' "$WORK" > "$WORK/evil.conf"
env -u ANTHROPIC_BASE_URL POWOS_AI_ENDPOINT_FILE="$WORK/evil.conf" \
    bash -c 'source "'"$AGENT"'" >/dev/null 2>&1; _ai_load_endpoint' >/dev/null 2>&1
[ -e "$WORK/PWNED" ] && bad "endpoint file is SOURCED — arbitrary code executed" \
  || ok "endpoint file is parsed, not sourced"

# --- config.sh front door --------------------------------------------------
grep -q '^claude-endpoint|' "$CONFIG" && ok "claude-endpoint is in the registry" \
  || bad "claude-endpoint missing from the registry (invisible to 'powos config')"
grep -q '^claude-token|' "$CONFIG" && ok "claude-token is in the registry" \
  || bad "claude-token missing from the registry"

for fn in get_claude_endpoint set_claude_endpoint validate_claude_endpoint \
          get_claude_token set_claude_token validate_claude_token; do
  grep -q "^$fn()" "$CONFIG" || { bad "missing $fn()"; continue; }
done
grep -q '^get_claude_endpoint()' "$CONFIG" && grep -q '^set_claude_endpoint()' "$CONFIG" \
  && ok "get/set/validate pairs exist for both settings" || true

# --- validation ------------------------------------------------------------
# bash -c '<script>' <$0> <$1> — the value lands in $1, not $2.
val() {
  local fn="$1" v="$2"
  bash -c "source '$CONFIG' >/dev/null 2>&1; validate_$fn \"\$1\" && echo yes || echo no" _ "$v"
}
[ "$(val claude_endpoint 'http://claude-auth.pow')" = yes ] && ok "accepts a valid http URL" || bad "rejected a valid URL"
[ "$(val claude_endpoint 'not a url')" = no ] && ok "rejects a non-URL" || bad "accepted 'not a url'"
[ "$(val claude_token 'proxy-managed')" = yes ] && ok "accepts a non-empty token" || bad "rejected a valid token"
[ "$(val claude_token '')" = no ] \
  && ok "rejects an empty token (empty = CLI forks the OAuth grant)" \
  || bad "accepted an empty token"

# --- both keys are written together ----------------------------------------
# The file is regenerated, not patched, so writing one key must carry the other
# or setting the token would silently erase the URL.
grep -q 'cfg_endpoint_write "\$url" "\$1"' "$CONFIG" \
  && grep -q 'cfg_endpoint_write "\$1" "\$token"' "$CONFIG" \
  && ok "each setter carries the other key through the rewrite" \
  || bad "a setter rewrites the file without preserving the other key"

echo
echo "ai-endpoint: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
