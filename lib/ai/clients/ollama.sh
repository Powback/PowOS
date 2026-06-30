#!/bin/bash
# ollama.sh - Ollama client for PowOS AI
#
# Wraps the 'ollama' CLI tool for local LLM inference.
# Supports one-shot prompts and interactive sessions.

# Source base interface
source "$(dirname "${BASH_SOURCE[0]}")/base.sh"

# ═══════════════════════════════════════════════════════════════════
# Ollama Client Implementation
# ═══════════════════════════════════════════════════════════════════

# Send a prompt and get a response
client_call() {
    local prompt="$1"
    local system_prompt="${2:-}"
    local session_id="${3:-}"

    local cmd="${CLIENT_CMD:-ollama}"
    local model="${CLIENT_MODEL:-llama3.2}"

    # Build the full prompt with system prompt
    local full_prompt="$prompt"
    if [[ -n "$system_prompt" ]]; then
        full_prompt="$system_prompt

$prompt"
    fi

    _debug "Running: $cmd run $model \"$full_prompt\""

    # Ollama run for one-shot
    # Use echo to pipe prompt to avoid issues with special characters
    echo "$full_prompt" | "$cmd" run "$model" 2>/dev/null
}

# Start an interactive session
client_interactive() {
    local system_prompt="${1:-}"
    local session_id="${2:-}"

    local cmd="${CLIENT_CMD:-ollama}"
    local model="${CLIENT_MODEL:-llama3.2}"

    # For interactive, we can't easily inject system prompt into ollama
    # Just run ollama run which starts interactive mode
    if [[ -n "$system_prompt" ]]; then
        echo "System prompt: $system_prompt"
        echo ""
    fi

    _debug "Running interactive: $cmd run $model"

    # Ollama run without piping starts interactive mode
    "$cmd" run "$model"
}

# Check if ollama is available and running
client_available() {
    # Check command exists
    if ! command -v "${CLIENT_CMD:-ollama}" &>/dev/null; then
        return 1
    fi

    # Optionally check if ollama server is running
    # This makes startup slightly slower but more reliable
    if [[ "${OLLAMA_CHECK_SERVER:-false}" == "true" ]]; then
        local endpoint="${CLIENT_ENDPOINT:-http://localhost:11434}"
        curl -s --connect-timeout 1 "$endpoint/api/tags" &>/dev/null || return 1
    fi

    return 0
}

# List available models (ollama-specific)
ollama_list_models() {
    local cmd="${CLIENT_CMD:-ollama}"
    "$cmd" list 2>/dev/null
}

# Pull a model (ollama-specific)
ollama_pull_model() {
    local model="$1"
    local cmd="${CLIENT_CMD:-ollama}"
    "$cmd" pull "$model"
}
