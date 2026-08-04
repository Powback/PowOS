#!/usr/bin/env bash
# PowOS Manager launcher — resolves the PowOS-native bits (manager persona with
# !cmd expansion, live state context, comms identity + mcp-config) and hands off
# to the streaming broker (manager.py). Sourced by bin/powos.

_MANAGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER_SERVER="${MANAGER_SERVER:-$_MANAGER_DIR/manager.py}"

# powos ai manager [--safe]  — start / resume the persistent manager session.
manager_run() {
    command -v python3 &>/dev/null || { echo "manager needs python3" >&2; return 1; }
    [[ -f "$MANAGER_SERVER" ]] || { echo "manager.py not found" >&2; return 1; }

    # Load the manager persona. _ai_load_agent expands the !cmd lines, so the
    # system prompt carries the CURRENT `powos help` / `powos comms help`.
    if ! declare -f _ai_load_agent &>/dev/null; then
        echo "AI framework not loaded (agent.sh)" >&2; return 1
    fi
    _ai_load_agent manager || return 1

    # Prepend live state (AGENT_CONTEXT_CMD) so the manager boots oriented.
    local ctx=""
    [[ -n "${AGENT_CONTEXT_CMD:-}" ]] && ctx="$(eval "$AGENT_CONTEXT_CMD" 2>/dev/null || true)"
    local sysprompt="${AGENT_SYSTEM_PROMPT:-}"
    [[ -n "$ctx" ]] && sysprompt="$sysprompt

## Current system state (at session start)
$ctx"

    # Identity + comms mailbox. The manager is the escalation hub: it reports to
    # the user, everyone else reports to it (see comms_export_identity).
    local mcp_file="" spf=""
    if declare -f comms_enabled &>/dev/null && comms_enabled; then
        comms_export_identity manager user
        mcp_file="$(mktemp "${TMPDIR:-/tmp}/powos-manager-mcp.XXXXXX")"
        comms_mcp_config_json > "$mcp_file"
    fi
    spf="$(mktemp "${TMPDIR:-/tmp}/powos-manager-sys.XXXXXX")"
    printf '%s' "$sysprompt" > "$spf"

    local store="${AI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/powos/ai}/manager"
    mkdir -p "$store"

    # --safe: keep permission prompts (no --dangerously-skip-permissions).
    [[ "${1:-}" == "--safe" ]] && export POWOS_MANAGER_SAFE=1

    local rc=0
    python3 "$MANAGER_SERVER" \
        --agent-id manager \
        --system-prompt-file "$spf" \
        ${mcp_file:+--mcp-config-file "$mcp_file"} \
        --session-store "$store" || rc=$?

    rm -f "$spf" "$mcp_file" 2>/dev/null
    return $rc
}
