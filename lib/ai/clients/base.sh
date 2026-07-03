#!/bin/bash
# base.sh - Base client interface for PowOS AI
#
# All client implementations must provide these functions:
#   client_call()        - Send a prompt, get a response
#   client_interactive() - Start interactive session (optional)
#   client_available()   - Check if client is available
#
# Clients are loaded by agent.sh after sourcing the client config.
# The config provides: CLIENT_CMD, CLIENT_*_ARGS, etc.

# ═══════════════════════════════════════════════════════════════════
# Interface Definition (override in implementations)
# ═══════════════════════════════════════════════════════════════════

# Send a prompt and get a response
# Arguments:
#   $1 - prompt (required)
#   $2 - system prompt (optional)
#   $3 - session ID (optional)
# Output: Response text to stdout
client_call() {
    echo "Error: client_call not implemented" >&2
    return 1
}

# Start an interactive session
# Arguments:
#   $1 - system prompt (optional)
#   $2 - session ID (optional)
# Note: This function should not return until the session ends
client_interactive() {
    # Default: not supported, agent.sh will use fallback loop
    return 1
}

# Check if client is available
client_available() {
    command -v "${CLIENT_CMD:-unknown}" &>/dev/null
}

# ═══════════════════════════════════════════════════════════════════
# Utility Functions (shared by all clients)
# ═══════════════════════════════════════════════════════════════════

# Escape a string for shell command
_escape_for_shell() {
    local str="$1"
    printf '%q' "$str"
}

# Create a temporary file with content
_create_temp_file() {
    local content="$1"
    local tmp=$(mktemp)
    echo "$content" > "$tmp"
    echo "$tmp"
}

# Read from stdin if available
_read_stdin_if_available() {
    if [[ ! -t 0 ]]; then
        cat
    fi
}

# Format a system prompt for the client
_format_system_prompt() {
    local prompt="$1"
    if [[ -n "$prompt" ]]; then
        echo "$prompt"
    fi
}

# Log debug info (if AI_DEBUG is set)
_debug() {
    if [[ "${AI_DEBUG:-}" == "true" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}
