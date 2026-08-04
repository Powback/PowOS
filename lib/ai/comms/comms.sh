#!/usr/bin/env bash
# PowOS inter-agent comms — launch-side wiring for the mailbox MCP.
#
# Sourced by lib/ai/agent.sh. Provides:
#   comms_enabled            — is the comms mailbox turned on?
#   comms_mcp_config_json     — the --mcp-config JSON for the comms server
#   comms_export_identity ID  — export COMMS_* env for a launched agent
#   comms_pending_note ID     — a short "you have N messages" line for the prompt
#
# The store is a plain spool dir (default /var/lib/powos/comms); see comms-mcp.py.
# There is no daemon: enabling comms just wires the stdio server into the agent.

# Resolve the directory this file lives in (repo: lib/ai/comms, installed:
# /usr/lib/powos/ai/comms) so the Python server is found in either layout.
_COMMS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMS_SERVER="${COMMS_SERVER:-$_COMMS_DIR/comms-mcp.py}"
# Spool lives under the user's XDG state — NOT /var/lib/powos, which is
# root-owned on a fresh install (same trap that once broke AI session saving).
# Single interactive user ⇒ all `powos ai` runs share one writable spool.
COMMS_ROOT="${COMMS_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/powos/comms}"

# Enabled by default; opt out with POWOS_COMMS_ENABLED=0 (env or /etc/powos/config).
# Requires python3 and the server file to actually be present.
comms_enabled() {
    [[ "${POWOS_COMMS_ENABLED:-1}" != "0" ]] || return 1
    [[ -f "$COMMS_SERVER" ]] || return 1
    command -v python3 &>/dev/null || return 1
    return 0
}

# Emit the MCP config JSON that launches the comms server over stdio. The agent
# identity is passed through the environment (see comms_export_identity), which
# the claude CLI inherits into the spawned MCP process — so one static config
# serves every agent.
comms_mcp_config_json() {
    local py; py="$(command -v python3)"
    cat <<JSON
{"mcpServers":{"comms":{"command":"$py","args":["$COMMS_SERVER"],"env":{"COMMS_ROOT":"$COMMS_ROOT"}}}}
JSON
}

# Export the identity env for the about-to-launch agent. The MCP process inherits
# these from the claude CLI's environment.
#   $1 — this agent's role/identity (e.g. "devops")
#   $2 — parent role for escalate() (optional; default "user")
comms_export_identity() {
    local id="$1" parent="${2:-}"
    export COMMS_AGENT_ID="$id"
    export COMMS_ROOT
    # Escalation hub: the manager reports to the user; every other agent reports
    # UP to the manager (its inbox is durable, so this works whether or not a
    # manager session is live). An explicit parent ($2) always wins.
    if [[ -z "$parent" ]]; then
        case "$id" in
            manager|"") parent="user" ;;
            *)          parent="manager" ;;
        esac
    fi
    export COMMS_PARENT_ID="$parent"
    # Who may ping the user directly vs must escalate. The manager and the
    # top-level system agents may; specialist workers escalate instead.
    case "$id" in
        manager|assistant|health|devops|"") export COMMS_CAN_NOTIFY=1 ;;
        *) export COMMS_CAN_NOTIFY=0 ;;
    esac
}

# Count messages waiting in an agent's inbox (0 if none / not initialized).
comms_pending_count() {
    local id="$1" d="$COMMS_ROOT/agents/$id/inbox"
    [[ -d "$d" ]] || { echo 0; return; }
    local n; n=$(find "$d" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
    echo "${n:-0}"
}

# A one-line nudge to append to a launched agent's prompt so a fresh one-shot
# invocation notices mail left for its role. Non-consuming — the agent decides
# whether to read_inbox. Prints nothing when the inbox is empty.
comms_pending_note() {
    local id="$1"; local n; n="$(comms_pending_count "$id")"
    [[ "$n" -gt 0 ]] || return 0
    printf 'You have %s unread message(s) in your PowOS comms inbox. Call the "read_inbox" tool to see them.' "$n"
}

comms_help() {
    cat <<'EOF'
powos comms — inter-agent mailbox (talk between PowOS AI agents)

Agents run as roles (health, coder, devops, containerizer, ...). Mail addressed
to a role lands in that role's durable inbox and is read by whoever next runs as
that role — or by a live agent of that role waiting on it. No daemon; the store
is a spool dir (POWOS_COMMS_ROOT, default /var/lib/powos/comms).

Every `powos ai` agent is auto-wired with the comms MCP, exposing these tools to
the model: send_message, notify_user, escalate, read_inbox, wait_for_message,
list_agents. wait_for_message BLOCKS until mail arrives (yield-while-idle, no
polling); the model can also Monitor the inbox path directly.

Usage:
  powos comms send <to> <message...> [--priority low|normal|high|urgent]
                                     Send to an agent role's inbox.
  powos comms notify <message...>    Notify the human user (+ desktop toast).
  powos comms inbox [--agent R] [--peek]
                                     Show (and clear, unless --peek) an inbox.
                                     Default agent: $COMMS_AGENT_ID or 'user'.
  powos comms watch [--agent R] [--timeout N]
                                     Block until a message arrives, then print it.
  powos comms agents                 List known inboxes and their unread depth.

Examples:
  powos comms send devops "CI is green, digest changed" --priority high
  powos comms watch --agent devops         # park until devops gets mail
  powos ai --agent devops "check your inbox and act on it"

Disable wiring with POWOS_COMMS_ENABLED=0.
EOF
}

# `powos comms ...` — human/script entry point. Delegates to the same Python
# store the MCP uses (comms-mcp.py in CLI mode).
cmd_comms() {
    case "${1:-help}" in
        help|--help|-h|"")
            comms_help ;;
        *)
            COMMS_ROOT="$COMMS_ROOT" python3 "$COMMS_SERVER" "$@" ;;
    esac
}
