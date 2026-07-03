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

# Temp file for session ID communication across subshells.
# Created securely with mktemp (a predictable /tmp/.claude_session_id.$$
# name is a symlink-attack target). Created once per shell at source time
# so the path is shared between command-substitution subshells (client_call)
# and the parent (client_get_session_id).
if [[ -z "${CLAUDE_SESSION_ID_FILE:-}" ]] || [[ ! -f "${CLAUDE_SESSION_ID_FILE:-}" ]]; then
    CLAUDE_SESSION_ID_FILE="$(mktemp "${TMPDIR:-/tmp}/powos-claude-session.XXXXXX" 2>/dev/null || mktemp)"
fi

# Check whether a string is a client session UUID
_claude_is_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

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

    # Session handling: only resume with a real client UUID. The claude CLI
    # errors on a non-UUID --resume argument (e.g. a PowOS session name), so
    # anything else means "start fresh" — the new session_id is captured
    # below and stored by the caller.
    if [[ -n "$session_id" ]]; then
        if _claude_is_uuid "$session_id"; then
            args+=("--resume" "$session_id")
        else
            _debug "Ignoring non-UUID session id '$session_id' (starting fresh)"
        fi
    fi

    _debug "Running: $cmd ${args[*]} \"${prompt:0:50}...\""

    # Run claude. Don't suppress stderr — on failure the CLI's error message
    # is the only clue the user gets.
    local output
    local exit_code=0
    output=$("$cmd" "${args[@]}" "$prompt") || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "Error: '$cmd' exited with code $exit_code" >&2
        [[ -n "$output" ]] && echo "$output" >&2
        return $exit_code
    fi

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

    return 0
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

    if [[ -n "$session_id" ]] && _claude_is_uuid "$session_id"; then
        args+=("--resume" "$session_id")
    fi

    "$cmd" "${args[@]}" "$prompt"
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

    if [[ -n "$session_id" ]] && _claude_is_uuid "$session_id"; then
        args+=("--resume" "$session_id")
    fi

    "$cmd" "${args[@]}" "$prompt"
}

# Continue the most recent conversation
# $2 (optional): agent system prompt — passed through like the one-shot path
client_continue() {
    local prompt="$1"
    local system_prompt="${2:-}"
    local cmd="${CLIENT_CMD:-claude}"
    local args=("--print" "--continue")

    if [[ -n "$system_prompt" ]]; then
        args+=("--system-prompt" "$system_prompt")
    fi

    "$cmd" "${args[@]}" "$prompt"
}

# Resume a specific session
client_resume() {
    local session_id="$1"
    local prompt="${2:-}"
    local cmd="${CLIENT_CMD:-claude}"

    if [[ -n "$prompt" ]]; then
        "$cmd" --print --resume "$session_id" "$prompt"
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

    # Add session — only resume a real client UUID; anything else (e.g. a
    # fabricated first-use name) starts a new interactive conversation.
    if [[ -n "$session_id" ]] && _claude_is_uuid "$session_id"; then
        args+=("--resume" "$session_id")
    fi

    _debug "Running interactive: $cmd ${args[*]}"

    # Run claude interactively (no --print)
    "$cmd" "${args[@]}"
}

# Check if claude is available
client_available() {
    command -v "${CLIENT_CMD:-claude}" &>/dev/null
}

# Get last session ID (after any client_call).
# The file is truncated after reading — inline cleanup instead of an EXIT
# trap: registering `trap ... EXIT` from a sourced file would clobber any
# EXIT trap already set by the calling shell (e.g. bin/powos).
client_get_session_id() {
    if [[ -f "$CLAUDE_SESSION_ID_FILE" ]]; then
        cat "$CLAUDE_SESSION_ID_FILE"
        : > "$CLAUDE_SESSION_ID_FILE"
    fi
}
