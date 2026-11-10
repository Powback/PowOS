# 45-powos-claude-endpoint.sh - a `claude` typed in any login shell uses this device's Anthropic endpoint.
#
# /etc/powos/ai/endpoint.conf (lib/config.sh cfg_endpoint_write: `powos config claude-endpoint`, or enrollment's
# `powos devices ai-apply` = the fleet authority claude-auth.pow + this device's own token) is read by PowOS's own
# agents (lib/ai/agent.sh) and the manager. A plain `claude` in a terminal read only the environment: the PC gets it
# from environment.d (systemd), but the phone's Linux has no systemd, so there `claude` ran its OWN login - a second
# refresher of a fleet grant, which revokes the whole token family (CLAUDE.md, "the one rule").
#
# Parsed, never sourced (a stray line must not run in every shell). The environment wins: an exported value is a
# deliberate override. No endpoint.conf (a sellable install, not one of the owner's devices): nothing is set and
# Claude Code's own sign-in is used (the 11-04 decision).

_powos_claude_endpoint() {
  local f=${POWOS_AI_ENDPOINT_FILE:-/etc/powos/ai/endpoint.conf} k v
  [ -r "$f" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      ANTHROPIC_BASE_URL) [ -n "${ANTHROPIC_BASE_URL:-}" ] || [ -z "$v" ] || export ANTHROPIC_BASE_URL="$v" ;;
      ANTHROPIC_AUTH_TOKEN) [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] || [ -z "$v" ] || export ANTHROPIC_AUTH_TOKEN="$v" ;;
    esac
  done < "$f"
}
_powos_claude_endpoint
unset -f _powos_claude_endpoint
