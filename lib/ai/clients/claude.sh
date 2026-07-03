#!/bin/bash
# claude.sh - Claude CLI client for PowOS AI
#
# Wraps the 'claude' CLI tool (Claude Code).
# Supports one-shot prompts, interactive sessions, and session management.
#
# Claude CLI session args:
#   --session-id <uuid>  Use specific session
#   --continue / -c      Continue most recent
#   --resume <id> / -r   Resume by session ID
#   --output-format json Get structured output with session_id

# Source base interface
source "$(dirname "${BASH_SOURCE[0]}")/base.sh"

# ═══════════════════════════════════════════════════════════════════
# Claude Client Implementation
# ═══════════════════════════════════════════════════════════════════

# Temp file for session ID communication across subshells
# Use cross-platform temp directory
_claude_get_tmp_dir() {
    if [[ -n "${TMPDIR:-}" ]]; then
        echo "$TMPDIR"
    elif [[ -d "/tmp" ]]; then
        echo "/tmp"
    elif [[ -n "${TEMP:-}" ]]; then
        echo "$TEMP"
    elif [[ -n "${TMP:-}" ]]; then
        echo "$TMP"
    else
        echo "."
    fi
}
CLAUDE_SESSION_ID_FILE="$(_claude_get_tmp_dir)/.claude_session_id.$$"

# Send a prompt and get a response
# Returns: response text (and stores session_id in temp file for retrieval)
client_call() {
    local prompt="$1"
    local system_prompt="${2:-}"
    local session_id="${3:-}"

    local cmd="${CLIENT_CMD:-claude}"
    local args=("--print")

    # Check if user wants JSON output
    local user_wants_json="${CLAUDE_JSON_OUTPUT:-false}"

    # Always use JSON internally to capture session ID
    args+=("--output-format" "json")

    # Add system prompt if provided
    if [[ -n "$system_prompt" ]]; then
        args+=("--system-prompt" "$system_prompt")
    fi

    # Session handling
    if [[ -n "$session_id" ]]; then
        # Check if it's a UUID (existing session) or name (resume search)
        if [[ "$session_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            # Valid UUID - use directly
            args+=("--session-id" "$session_id")
        else
            # Name/search term - use resume
            args+=("--resume" "$session_id")
        fi
    fi

    _debug "Running: $cmd ${args[*]} \"${prompt:0:50}...\""

    # Run claude
    local output
    output=$("$cmd" "${args[@]}" "$prompt" 2>/dev/null)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        # Parse JSON to extract result and session_id
        if command -v jq &>/dev/null; then
            # Extract session ID and store in temp file for retrieval
            local new_session_id
            new_session_id=$(echo "$output" | jq -r '.session_id // empty' 2>/dev/null)
            if [[ -n "$new_session_id" ]]; then
                echo "$new_session_id" > "$CLAUDE_SESSION_ID_FILE"
            fi

            if [[ "$user_wants_json" == "true" ]]; then
                # User wants full JSON output
                echo "$output"
            else
                # Return just the result text
                echo "$output" | jq -r '.result // .message.content[0].text // empty' 2>/dev/null
            fi
        else
            # No jq - just output raw
            echo "$output"
        fi
    else
        echo "$output"
    fi

    return $exit_code
}

# Send prompt and get full JSON response (for detailed info)
client_call_json() {
    local prompt="$1"
    local system_prompt="${2:-}"
    local session_id="${3:-}"

    local cmd="${CLIENT_CMD:-claude}"
    local args=("--print" "--output-format" "json")

    if [[ -n "$system_prompt" ]]; then
        args+=("--system-prompt" "$system_prompt")
    fi

    if [[ -n "$session_id" ]]; then
        if [[ "$session_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            args+=("--session-id" "$session_id")
        else
            args+=("--resume" "$session_id")
        fi
    fi

    "$cmd" "${args[@]}" "$prompt" 2>/dev/null
}

# Send prompt with verbose output (shows tool use, etc.)
client_call_verbose() {
    local prompt="$1"
    local system_prompt="${2:-}"
    local session_id="${3:-}"

    local cmd="${CLIENT_CMD:-claude}"
    local args=("--print" "--output-format" "json" "--verbose")

    if [[ -n "$system_prompt" ]]; then
        args+=("--system-prompt" "$system_prompt")
    fi

    if [[ -n "$session_id" ]]; then
        if [[ "$session_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            args+=("--session-id" "$session_id")
        else
            args+=("--resume" "$session_id")
        fi
    fi

    "$cmd" "${args[@]}" "$prompt" 2>/dev/null
}

# Continue the most recent conversation
client_continue() {
    local prompt="$1"
    local cmd="${CLIENT_CMD:-claude}"

    "$cmd" --print --continue "$prompt" 2>/dev/null
}

# Resume a specific session
client_resume() {
    local session_id="$1"
    local prompt="${2:-}"
    local cmd="${CLIENT_CMD:-claude}"

    if [[ -n "$prompt" ]]; then
        "$cmd" --print --resume "$session_id" "$prompt" 2>/dev/null
    else
        # Interactive resume
        "$cmd" --resume "$session_id"
    fi
}

# Start an interactive session
client_interactive() {
    local system_prompt="${1:-}"
    local session_id="${2:-}"

    local cmd="${CLIENT_CMD:-claude}"
    local args=()

    # Add system prompt
    if [[ -n "$system_prompt" ]]; then
        args+=("--system-prompt" "$system_prompt")
    fi

    # Add session
    if [[ -n "$session_id" ]]; then
        if [[ "$session_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            args+=("--session-id" "$session_id")
        else
            args+=("--resume" "$session_id")
        fi
    fi

    _debug "Running interactive: $cmd ${args[*]}"

    # Run claude interactively (no --print)
    "$cmd" "${args[@]}"
}

# Check if claude is available
client_available() {
    command -v "${CLIENT_CMD:-claude}" &>/dev/null
}

# Get last session ID (after any client_call)
client_get_session_id() {
    if [[ -f "$CLAUDE_SESSION_ID_FILE" ]]; then
        cat "$CLAUDE_SESSION_ID_FILE"
    fi
}

# Cleanup temp file on exit
_claude_cleanup() {
    rm -f "$CLAUDE_SESSION_ID_FILE" 2>/dev/null || true
}
trap _claude_cleanup EXIT
