#!/usr/bin/env bash
# PowOS Manager launcher — resolves the PowOS-native bits (manager persona with
# !cmd expansion, live state context, comms identity + mcp-config: comms and the
# TypeScript sandbox, lib/ai/sandbox) and hands off
# to the streaming broker (manager.py). Sourced by bin/powos.

_MANAGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER_SERVER="${MANAGER_SERVER:-$_MANAGER_DIR/manager.py}"
MANAGER_SANDBOX="${MANAGER_SANDBOX:-$_MANAGER_DIR/../sandbox/sandbox.sh}"

# One --mcp-config from several {"mcpServers":{...}} documents (claude takes one file per flag; one file keeps it simple).
_manager_merge_mcp() {
    python3 -c 'import json,sys
print(json.dumps({"mcpServers": {k: v for a in sys.argv[1:] for k, v in json.loads(a)["mcpServers"].items()}}))' "$@"
}

# The system prompt: the persona, then the live state (AGENT_CONTEXT_CMD) so the manager boots oriented.
_manager_sysprompt() {
    local ctx=""
    [[ -n "${AGENT_CONTEXT_CMD:-}" ]] && ctx="$(eval "$AGENT_CONTEXT_CMD" 2>/dev/null || true)"
    printf '%s' "${AGENT_SYSTEM_PROMPT:-}"
    [[ -z "$ctx" ]] || printf '\n\n## Current system state (at session start)\n%s' "$ctx"
}

# Its MCP servers, as one --mcp-config JSON written to $1 (status 3, nothing written, when it has none; never in a
# subshell: the identity it exports is the session's): comms when enabled, exporting the
# manager's identity (the escalation hub: it reports to the user, everyone else to it; see comms_export_identity),
# and the TypeScript sandbox (lib/ai/sandbox: tools sandbox eval/declarations) when its runtime and in-app deps are
# here (`powos sandbox status`) and POWOS_SANDBOX_ENABLED isn't 0.
_manager_mcp_config() {
    local servers=()
    if declare -f comms_enabled &>/dev/null && comms_enabled; then
        comms_export_identity manager user
        servers+=("$(comms_mcp_config_json)")
    fi
    if [[ -f "$MANAGER_SANDBOX" ]] && source "$MANAGER_SANDBOX" && sandbox_enabled; then
        servers+=("$(sandbox_mcp_config_json manager)")
    fi
    (( ${#servers[@]} )) || return 3
    _manager_merge_mcp "${servers[@]}" > "$1"
}

# powos ai manager [--safe] [--no-sandbox]  — start / resume the persistent manager session (--help: its flags).
manager_run() {
    command -v python3 &>/dev/null || { echo "manager needs python3" >&2; return 1; }
    [[ -f "$MANAGER_SERVER" ]] || { echo "manager.py not found" >&2; return 1; }

    local store="${AI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/powos/ai}/manager"
    mkdir -p "$store"

    # Split our own flags from broker pass-throughs (--once, --json-events, --cwd, ...).
    local passthru=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --safe) export POWOS_MANAGER_SAFE=1 ;;
            --no-sandbox) export POWOS_SANDBOX_ENABLED=0 ;;
            # --help: the broker's own (manager.py), without the persona load below.
            -h|--help) python3 "$MANAGER_SERVER" --help; return ;;
            *) passthru+=("$1") ;;
        esac
        shift
    done

    # Lightweight data query for the widget sidebar — skip the (expensive)
    # persona load / mcp wiring / context gathering the chat path needs.
    if [[ " ${passthru[*]} " == *" --list-json "* ]]; then
        export COMMS_ROOT
        python3 "$MANAGER_SERVER" --agent-id manager --session-store "$store" --list-json
        return
    fi

    # Load the manager persona. _ai_load_agent expands the !cmd lines, so the
    # system prompt carries the CURRENT `powos help` / `powos comms help`.
    if ! declare -f _ai_load_agent &>/dev/null; then
        echo "AI framework not loaded (agent.sh)" >&2; return 1
    fi
    # The AI config, the Anthropic endpoint included (/etc/powos/ai/endpoint.conf: the fleet's auth authority), so the
    # manager's claude uses it wherever it's started - not only from a session whose environment.d already has it
    # (a phone's PowOS session doesn't).
    _ai_ensure_config
    _ai_load_agent manager || return 1

    local mcp_file spf rc=0
    mcp_file="$(mktemp "${TMPDIR:-/tmp}/powos-manager-mcp.XXXXXX")"
    _manager_mcp_config "$mcp_file" || rc=$?
    if (( rc )); then
        rm -f "$mcp_file"; mcp_file=""
        (( rc == 3 )) || return 1
        rc=0
    fi
    spf="$(mktemp "${TMPDIR:-/tmp}/powos-manager-sys.XXXXXX")"
    _manager_sysprompt > "$spf"

    python3 "$MANAGER_SERVER" \
        --agent-id manager \
        --system-prompt-file "$spf" \
        ${mcp_file:+--mcp-config-file "$mcp_file"} \
        --session-store "$store" \
        "${passthru[@]}" || rc=$?

    rm -f "$spf" "$mcp_file" 2>/dev/null
    return $rc
}
