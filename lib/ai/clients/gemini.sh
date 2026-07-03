#!/bin/bash
# gemini.sh - Gemini CLI client for PowOS AI
#
# Wraps the 'gemini' CLI tool.
# Supports one-shot prompts. Interactive mode falls back to loop.

# Source base interface
source "$(dirname "${BASH_SOURCE[0]}")/base.sh"

# ═══════════════════════════════════════════════════════════════════
# Gemini Client Implementation
# ═══════════════════════════════════════════════════════════════════

# Send a prompt and get a response
client_call() {
    local prompt="$1"
    local system_prompt="${2:-}"
    local session_id="${3:-}"

    local cmd="${CLIENT_CMD:-gemini}"
    local args=()

    # One-shot mode args
    if [[ -n "${CLIENT_ONESHOT_ARGS:-}" ]]; then
        read -ra args <<< "$CLIENT_ONESHOT_ARGS"
    fi

    # Gemini CLI typically uses -p for prompt
    # If there's a system prompt, prepend it to the user prompt
    local full_prompt="$prompt"
    if [[ -n "$system_prompt" ]]; then
        full_prompt="System: $system_prompt

User: $prompt"
    fi

    _debug "Running: $cmd ${args[*]} \"$full_prompt\""

    # Run gemini
    # Different gemini CLI tools have different interfaces
    # Try common patterns
    if [[ " ${args[*]} " =~ " -p " ]]; then
        # Uses -p for prompt
        "$cmd" "${args[@]}" "$full_prompt" 2>/dev/null
    else
        # Pipe prompt to stdin
        echo "$full_prompt" | "$cmd" "${args[@]}" 2>/dev/null
    fi
}

# Interactive mode - Gemini CLI may or may not support this
# Fall back to base implementation (agent.sh loop)
client_interactive() {
    local system_prompt="${1:-}"
    local session_id="${2:-}"

    local cmd="${CLIENT_CMD:-gemini}"

    # Check if gemini has an interactive mode
    if [[ -n "${CLIENT_INTERACTIVE_ARGS:-}" ]]; then
        local args=()
        read -ra args <<< "$CLIENT_INTERACTIVE_ARGS"

        _debug "Running interactive: $cmd ${args[*]}"
        "$cmd" "${args[@]}"
    else
        # Return 1 to signal agent.sh to use fallback loop
        return 1
    fi
}

# Check if gemini is available
client_available() {
    command -v "${CLIENT_CMD:-gemini}" &>/dev/null
}
