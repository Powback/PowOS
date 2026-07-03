#!/bin/bash
# agent.sh - PowOS AI Agent System
#
# Main entry point for the AI agent system. Can be:
# 1. Sourced by other scripts: source /usr/lib/powos/ai/agent.sh
# 2. Called via CLI: powos ai [options] "prompt"
#
# Usage:
#   powos ai "prompt"                    # Simple one-shot
#   powos ai --agent coder "prompt"      # Use specific agent
#   powos ai --client ollama "prompt"    # Use specific client
#   powos ai -i                          # Interactive mode
#   powos ai --session myproject "prompt" # Use/resume session

# Strict mode only when executed directly. This file is SOURCED by
# bin/powos and other scripts — setting -u/pipefail here would flip the
# entire calling shell into strict mode retroactively.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# ═══════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════

AI_LIB_DIR="${AI_LIB_DIR:-/usr/lib/powos/ai}"
AI_CONFIG_DIR="${AI_CONFIG_DIR:-/etc/powos/ai}"
AI_STATE_DIR="${AI_STATE_DIR:-/var/lib/powos/state/ai}"

# Allow local development paths
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/session.sh" ]]; then
    AI_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
fi
if [[ -d "$(dirname "${BASH_SOURCE[0]}")/../../config/ai" ]]; then
    AI_CONFIG_DIR="$(dirname "${BASH_SOURCE[0]}")/../../config/ai"
fi

# Source session management
if [[ -f "$AI_LIB_DIR/session.sh" ]]; then
    source "$AI_LIB_DIR/session.sh"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ═══════════════════════════════════════════════════════════════════
# Load Configuration
# ═══════════════════════════════════════════════════════════════════

_ai_load_config() {
    # Load global config
    if [[ -f "$AI_CONFIG_DIR/agent.conf" ]]; then
        source "$AI_CONFIG_DIR/agent.conf"
    fi

    # Set defaults if not configured
    AI_DEFAULT_CLIENT="${AI_DEFAULT_CLIENT:-claude}"
    AI_DEFAULT_AGENT="${AI_DEFAULT_AGENT:-assistant}"
    AI_FALLBACK_CLIENT="${AI_FALLBACK_CLIENT:-ollama}"
    AI_SESSION_DIR="${AI_SESSION_DIR:-$AI_STATE_DIR/sessions}"
    AI_ENABLED="${AI_ENABLED:-true}"

    _AI_CONFIG_LOADED=1
}

# Lazily ensure the config has been loaded. Public ai_* entry points call
# this so library consumers (which only `source` this file) get sane
# defaults without having to call _ai_load_config themselves.
_ai_ensure_config() {
    if [[ -z "${_AI_CONFIG_LOADED:-}" ]]; then
        _ai_load_config
    fi
}

# Validate an agent/flavor/client/session name before it is used in a
# filesystem path (these names select files that get SOURCED — a name like
# '../../tmp/evil' would execute arbitrary code).
_ai_validate_name() {
    local kind="$1"
    local name="$2"
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo -e "${RED}Error: invalid $kind name '$name' (allowed: letters, digits, '-', '_')${NC}" >&2
        return 1
    fi
}

_ai_resolve_agent_alias() {
    local requested="$1"

    # First check if there's a direct agent directory
    if [[ -d "$AI_CONFIG_DIR/agents/${requested}" ]]; then
        echo "$requested"
        return 0
    fi

    # Search for alias in all agent configs
    for agent_dir in "$AI_CONFIG_DIR/agents"/*/; do
        [[ -d "$agent_dir" ]] || continue
        local conf="$agent_dir/agent.conf"
        [[ -f "$conf" ]] || continue
        local name=$(basename "$agent_dir")

        # Check if this config has the requested name as an alias
        local aliases=""
        aliases=$(grep "^AGENT_ALIASES=" "$conf" 2>/dev/null | cut -d'"' -f2 || true)

        if [[ -n "$aliases" ]]; then
            for alias in $aliases; do
                if [[ "$alias" == "$requested" ]]; then
                    echo "$name"
                    return 0
                fi
            done
        fi
    done

    # Not found, return original (will trigger warning)
    echo "$requested"
}

_ai_load_flavor() {
    local agent="$1"
    local flavor="$2"

    _ai_validate_name "flavor" "$flavor" || return 1

    local flavor_conf="$AI_CONFIG_DIR/agents/${agent}/${flavor}.conf"

    if [[ -f "$flavor_conf" ]]; then
        source "$flavor_conf"
        # Append flavor prompt to system prompt
        if [[ -n "${FLAVOR_PROMPT:-}" ]]; then
            AGENT_SYSTEM_PROMPT="${AGENT_SYSTEM_PROMPT}

${FLAVOR_PROMPT}"
        fi
        return 0
    else
        echo -e "${YELLOW}Warning: Flavor '$flavor' not found for agent '$agent'${NC}" >&2
        return 1
    fi
}

_ai_list_flavors() {
    local agent="$1"
    local agent_dir="$AI_CONFIG_DIR/agents/${agent}"

    if [[ -d "$agent_dir" ]]; then
        for conf in "$agent_dir"/*.conf; do
            [[ -f "$conf" ]] || continue
            local name=$(basename "$conf" .conf)
            # Skip agent.conf (main config)
            [[ "$name" == "agent" ]] && continue
            (
                source "$conf"
                printf "      :%s - %s\n" "$name" "${FLAVOR_DESCRIPTION:-No description}"
            )
        done
    fi
}

_ai_load_agent() {
    local agent_spec="$1"

    # Parse agent:flavor syntax
    local base_agent="${agent_spec%%:*}"
    local flavor=""
    if [[ "$agent_spec" == *":"* ]]; then
        flavor="${agent_spec#*:}"
    fi

    # Validate before any path use — agent configs are sourced.
    _ai_validate_name "agent" "$base_agent" || return 1
    if [[ -n "$flavor" ]]; then
        _ai_validate_name "flavor" "$flavor" || return 1
    fi

    # Reset all agent vars so a previously loaded agent doesn't bleed
    # through when the next agent.conf doesn't set every variable.
    AGENT_NAME=""
    AGENT_DESCRIPTION=""
    AGENT_SYSTEM_PROMPT=""
    AGENT_CLIENT=""
    AGENT_TOOLS=""
    AGENT_ALIASES=""
    AGENT_CONTEXT_CMD=""
    FLAVOR_NAME=""
    FLAVOR_DESCRIPTION=""
    FLAVOR_PROMPT=""

    # Resolve alias to actual agent name
    local resolved_agent
    resolved_agent=$(_ai_resolve_agent_alias "$base_agent")
    _ai_validate_name "agent" "$resolved_agent" || return 1

    local agent_conf="$AI_CONFIG_DIR/agents/${resolved_agent}/agent.conf"

    if [[ -f "$agent_conf" ]]; then
        source "$agent_conf"

        # Show alias resolution if different
        if [[ "$base_agent" != "$resolved_agent" ]]; then
            echo -e "${CYAN}(using '$resolved_agent' agent for '$base_agent')${NC}" >&2
        fi

        # Load flavor if specified
        if [[ -n "$flavor" ]]; then
            _ai_load_flavor "$resolved_agent" "$flavor"
        fi
    else
        echo -e "${YELLOW}Warning: Agent '$base_agent' not found, using defaults${NC}" >&2
        AGENT_NAME="$base_agent"
        AGENT_SYSTEM_PROMPT=""
        AGENT_CLIENT=""
        AGENT_TOOLS=""
    fi
}

_ai_load_client() {
    local client="$1"

    _ai_validate_name "client" "$client" || return 1

    local client_conf="$AI_CONFIG_DIR/clients/${client}.conf"

    if [[ -f "$client_conf" ]]; then
        source "$client_conf"
    else
        echo -e "${RED}Error: Client '$client' not configured${NC}" >&2
        return 1
    fi

    # Source client implementation
    local client_impl="$AI_LIB_DIR/clients/${client}.sh"
    if [[ -f "$client_impl" ]]; then
        source "$client_impl"
    else
        echo -e "${RED}Error: Client implementation '$client' not found${NC}" >&2
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Core Functions (Library API)
# ═══════════════════════════════════════════════════════════════════

# Check if AI is available
ai_available() {
    _ai_ensure_config

    if [[ "$AI_ENABLED" != "true" ]]; then
        return 1
    fi

    # Check if any client is available
    for client in "$AI_DEFAULT_CLIENT" "$AI_FALLBACK_CLIENT" claude gemini ollama; do
        if _ai_client_available "$client" 2>/dev/null; then
            return 0
        fi
    done

    return 1
}

# Check if specific client is available
_ai_client_available() {
    local client="$1"

    _ai_validate_name "client" "$client" 2>/dev/null || return 1

    local client_conf="$AI_CONFIG_DIR/clients/${client}.conf"

    if [[ ! -f "$client_conf" ]]; then
        return 1
    fi

    source "$client_conf"
    command -v "${CLIENT_CMD:-$client}" &>/dev/null
}

# List available agents
ai_list_agents() {
    _ai_ensure_config

    echo -e "${BOLD}${CYAN}Available Agents${NC}"
    echo "════════════════════════════════════════"

    for agent_dir in "$AI_CONFIG_DIR/agents"/*/; do
        [[ -d "$agent_dir" ]] || continue
        local name=$(basename "$agent_dir")
        local conf="$agent_dir/agent.conf"
        [[ -f "$conf" ]] || continue

        # Source to get description and aliases
        (
            source "$conf"
            local desc="${AGENT_DESCRIPTION:-No description}"
            local aliases="${AGENT_ALIASES:-}"

            printf "  %-14s %s\n" "$name" "$desc"
            if [[ -n "$aliases" ]]; then
                printf "                ${CYAN}aliases: %s${NC}\n" "$aliases"
            fi
        )

        # List flavors if they exist
        _ai_list_flavors "$name"
    done

    echo ""
    echo -e "${CYAN}Flavor syntax:${NC} --agent name:flavor (e.g., health:sync)"
}

# List available clients
ai_list_clients() {
    _ai_ensure_config

    echo -e "${BOLD}${CYAN}Available Clients${NC}"
    echo "════════════════════════════════════════"

    for conf in "$AI_CONFIG_DIR/clients"/*.conf; do
        [[ -f "$conf" ]] || continue
        local name=$(basename "$conf" .conf)

        # Check if available
        local status="${RED}not installed${NC}"
        if _ai_client_available "$name"; then
            status="${GREEN}available${NC}"
        fi

        printf "  %-12s %b\n" "$name" "$status"
    done
}

# Main call function
ai_call() {
    _ai_ensure_config

    local opt_agent=""
    local opt_client=""
    local opt_session=""
    local opt_continue=""
    local opt_new_session=""
    local opt_interactive=""
    local opt_json=""
    local opt_verbose=""
    local opt_stream=""   # "", "true", or "false"; default resolved after parsing
    local prompt=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent|-a)
                opt_agent="$2"
                shift 2
                ;;
            --client|-c)
                opt_client="$2"
                shift 2
                ;;
            --session|-s)
                opt_session="$2"
                shift 2
                ;;
            --continue)
                opt_continue="true"
                shift
                ;;
            --new-session)
                opt_new_session="true"
                shift
                ;;
            --interactive|-i)
                opt_interactive="true"
                shift
                ;;
            --json)
                opt_json="true"
                shift
                ;;
            --verbose)
                opt_verbose="true"
                shift
                ;;
            --stream)
                opt_stream="true"
                shift
                ;;
            --no-stream)
                opt_stream="false"
                shift
                ;;
            --yolo|--dangerously-skip-permissions)
                # Pass through to the underlying CLI (skips its permission prompts).
                export POWOS_AI_SKIP_PERMS=1
                shift
                ;;
            --help|-h)
                ai_help
                return 0
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                # Join all positional args into the prompt so unquoted
                # multi-word prompts work: `powos ai how do I sync`
                if [[ -n "$prompt" ]]; then
                    prompt="$prompt $1"
                else
                    prompt="$1"
                fi
                shift
                ;;
        esac
    done

    # Read from stdin if no prompt and not interactive
    if [[ -z "$prompt" && -z "$opt_interactive" && ! -t 0 ]]; then
        prompt=$(cat)
    fi

    # Resolve agent
    local agent="${opt_agent:-$AI_DEFAULT_AGENT}"
    _ai_load_agent "$agent" || return 1

    # Resolve client (CLI override > agent preference > default)
    local client="${opt_client:-${AGENT_CLIENT:-$AI_DEFAULT_CLIENT}}"

    # Try fallback if primary not available
    if ! _ai_client_available "$client"; then
        if _ai_client_available "$AI_FALLBACK_CLIENT"; then
            echo -e "${YELLOW}Client '$client' not available, using fallback '$AI_FALLBACK_CLIENT'${NC}" >&2
            client="$AI_FALLBACK_CLIENT"
        else
            echo -e "${RED}No AI client available${NC}" >&2
            return 1
        fi
    fi

    # Load client
    _ai_load_client "$client" || return 1

    # Resolve session. Only pass the client a STORED client session ID (a
    # real UUID from a previous call). On first use of a named session we
    # start fresh and store the client's returned session ID afterwards —
    # passing the PowOS session NAME as --resume breaks the claude CLI.
    local resolved_session=""
    if [[ -n "$opt_session" ]]; then
        # Auto-create the PowOS session file on first use
        if declare -f ai_session_start &>/dev/null && \
           [[ ! -f "${AI_SESSION_DIR}/${opt_session}.json" ]]; then
            ai_session_start "$opt_session" "$agent" "$client" >/dev/null || return 1
        fi

        if [[ -n "$opt_new_session" ]]; then
            # --new-session: discard any stored client session, start fresh
            if declare -f ai_session_set_client_id &>/dev/null; then
                ai_session_set_client_id "$opt_session" "" 2>/dev/null || true
            fi
        elif declare -f ai_session_get_client_id &>/dev/null; then
            resolved_session=$(ai_session_get_client_id "$opt_session" 2>/dev/null || true)
        fi
    fi

    # Interactive mode
    if [[ -n "$opt_interactive" ]]; then
        ai_interactive "$agent" "$client" "$opt_session"
        return $?
    fi

    # Need a prompt for non-interactive
    if [[ -z "$prompt" ]]; then
        echo -e "${RED}Error: No prompt provided${NC}" >&2
        echo "Usage: powos ai [options] \"prompt\"" >&2
        return 1
    fi

    # Gather context if agent has context command
    local context=""
    if [[ -n "${AGENT_CONTEXT_CMD:-}" ]]; then
        context=$(eval "$AGENT_CONTEXT_CMD" 2>/dev/null || true)
    fi

    # Build full prompt with context
    local full_prompt="$prompt"
    if [[ -n "$context" ]]; then
        full_prompt="Current system state:
\`\`\`
$context
\`\`\`

User request: $prompt"
    fi

    # Handle --continue (use client's continue feature).
    # Pass the agent system prompt through, same as the one-shot path.
    if [[ -n "$opt_continue" ]]; then
        if declare -f client_continue &>/dev/null; then
            client_continue "$full_prompt" "${AGENT_SYSTEM_PROMPT:-}"
            return $?
        else
            echo -e "${YELLOW}Client doesn't support --continue, using regular call${NC}" >&2
        fi
    fi

    # Set JSON output mode if requested
    if [[ -n "$opt_json" ]]; then
        export CLAUDE_JSON_OUTPUT="true"
    fi

    # Stream live by DEFAULT for a normal interactive prompt (so you see tool-use
    # and progress, not just the final answer). Off for --json (machine output),
    # --verbose, or when stdout isn't a TTY (piped/scripted). Force with --stream,
    # disable with --no-stream.
    if [[ -z "$opt_stream" ]]; then
        if [[ -t 1 && -z "$opt_json" && -z "$opt_verbose" ]]; then
            opt_stream="true"
        else
            opt_stream="false"
        fi
    fi

    # Call client with appropriate function. Capture the exit code
    # explicitly — an `x=$(...)` assignment would trip errexit in strict
    # shells before any error handling could run.
    local result=""
    local exit_code=0
    if [[ "$opt_stream" == "true" ]] && declare -f client_call_stream &>/dev/null; then
        # Stream live — NOT captured (command substitution would buffer it all
        # and defeat the whole point). Output goes straight to the terminal.
        client_call_stream "$full_prompt" "${AGENT_SYSTEM_PROMPT:-}" "$resolved_session" || exit_code=$?
    elif [[ -n "$opt_verbose" ]] && declare -f client_call_verbose &>/dev/null; then
        result=$(client_call_verbose "$full_prompt" "${AGENT_SYSTEM_PROMPT:-}" "$resolved_session") || exit_code=$?
    elif [[ -n "$opt_json" ]] && declare -f client_call_json &>/dev/null; then
        result=$(client_call_json "$full_prompt" "${AGENT_SYSTEM_PROMPT:-}" "$resolved_session") || exit_code=$?
    else
        result=$(client_call "$full_prompt" "${AGENT_SYSTEM_PROMPT:-}" "$resolved_session") || exit_code=$?
    fi

    if [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}Error: AI client '$client' failed (exit code $exit_code)${NC}" >&2
        [[ -n "$result" ]] && echo "$result" >&2
        return $exit_code
    fi

    # Output result (streaming mode already printed it live).
    [[ "$opt_stream" == "true" ]] || echo "$result"

    # Record the exchange in the PowOS session file (used by session export)
    if [[ -n "$opt_session" ]] && declare -f ai_session_add_message &>/dev/null; then
        ai_session_add_message "$opt_session" "user" "$prompt" 2>/dev/null || true
        ai_session_add_message "$opt_session" "assistant" "$result" 2>/dev/null || true
    fi

    # Save session ID mapping if we got a new one from the client
    if [[ -n "$opt_session" ]] && declare -f client_get_session_id &>/dev/null; then
        local new_client_id
        new_client_id=$(client_get_session_id 2>/dev/null || true)
        if [[ -n "$new_client_id" ]] && declare -f ai_session_set_client_id &>/dev/null; then
            ai_session_set_client_id "$opt_session" "$new_client_id" 2>/dev/null || true
        fi
    fi

    return 0
}

# Interactive mode
ai_interactive() {
    _ai_ensure_config

    local agent=""
    local client=""
    local session=""
    local context=""

    # Parse arguments (support both flags and positional for backward compat)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent|-a)
                agent="$2"
                shift 2
                ;;
            --client|-c)
                client="$2"
                shift 2
                ;;
            --session|-s)
                session="$2"
                shift 2
                ;;
            --context)
                context="$2"
                shift 2
                ;;
            -*)
                shift
                ;;
            *)
                # Positional args for backward compat
                if [[ -z "$agent" ]]; then
                    agent="$1"
                elif [[ -z "$client" ]]; then
                    client="$1"
                elif [[ -z "$session" ]]; then
                    session="$1"
                fi
                shift
                ;;
        esac
    done

    # Apply defaults
    agent="${agent:-$AI_DEFAULT_AGENT}"

    _ai_load_agent "$agent" || return 1

    # Resolve client (CLI flag > agent preference > default) — same
    # precedence as the one-shot path.
    if [[ -z "$client" ]]; then
        client="${AGENT_CLIENT:-$AI_DEFAULT_CLIENT}"
    fi

    _ai_load_client "$client" || return 1

    # Generate a PowOS session name if not provided
    if [[ -z "$session" ]]; then
        session="session-$(date +%Y%m%d-%H%M%S)"
    fi

    # Only hand the client a STORED client session ID (UUID from a previous
    # run). A fabricated/first-use name must NOT be passed as --resume —
    # the client starts a fresh conversation instead.
    local client_session_id=""
    if declare -f ai_session_get_client_id &>/dev/null; then
        client_session_id=$(ai_session_get_client_id "$session" 2>/dev/null || true)
    fi

    # Header
    echo -e "${CYAN}╭─ PowOS AI ─────────────────────────────────────────╮${NC}"
    echo -e "${CYAN}│${NC} Agent: ${BOLD}$agent${NC} | Client: ${BOLD}$client${NC} | Session: ${BOLD}$session${NC}"
    echo -e "${CYAN}╰────────────────────────────────────────────────────╯${NC}"
    echo ""

    # Show context if provided (for conflict resolution, etc.)
    if [[ -n "$context" ]]; then
        echo -e "${YELLOW}Context loaded. The AI has information about your current situation.${NC}"
        echo ""
    fi

    echo -e "Type ${BOLD}/help${NC} for commands, ${BOLD}/exit${NC} to quit"
    echo ""

    # Build system prompt with context if provided
    local full_system_prompt="${AGENT_SYSTEM_PROMPT:-}"
    if [[ -n "$context" ]]; then
        full_system_prompt="${full_system_prompt}

## Current Context (provided at session start)

${context}"
    fi

    # Check if client supports interactive
    if declare -f client_interactive &>/dev/null; then
        client_interactive "$full_system_prompt" "$client_session_id"
    else
        # Fallback to manual loop (pass context via env for the loop)
        export _AI_CONTEXT="$context"
        _ai_interactive_loop "$agent" "$client" "$client_session_id"
    fi
}

_ai_interactive_loop() {
    local agent="$1"
    local client="$2"
    local session="${3:-}"

    while true; do
        echo -ne "${GREEN}You:${NC} "
        read -r input

        case "$input" in
            /exit|/quit|/q)
                echo "Goodbye!"
                break
                ;;
            /help|/h)
                echo ""
                echo "Commands:"
                echo "  /exit, /quit, /q  - Exit interactive mode"
                echo "  /agent <name>     - Switch agent"
                echo "  /client <name>    - Switch client"
                echo "  /agents           - List available agents"
                echo "  /clients          - List available clients"
                echo "  /clear            - Clear screen"
                echo ""
                ;;
            /agent\ *)
                local new_agent="${input#/agent }"
                _ai_load_agent "$new_agent"
                agent="$new_agent"
                echo -e "Switched to agent: ${BOLD}$agent${NC}"
                ;;
            /client\ *)
                local new_client="${input#/client }"
                if _ai_load_client "$new_client"; then
                    client="$new_client"
                    echo -e "Switched to client: ${BOLD}$client${NC}"
                fi
                ;;
            /agents)
                ai_list_agents
                ;;
            /clients)
                ai_list_clients
                ;;
            /clear)
                clear
                ;;
            "")
                continue
                ;;
            *)
                echo -ne "${CYAN}AI:${NC} "
                client_call "$input" "${AGENT_SYSTEM_PROMPT:-}" "$session" || \
                    echo -e "${RED}(client call failed)${NC}"
                # Chain the conversation: pick up the client's session ID
                # after the first call so following turns resume it.
                if [[ -z "$session" ]] && declare -f client_get_session_id &>/dev/null; then
                    session=$(client_get_session_id 2>/dev/null || true)
                fi
                echo ""
                ;;
        esac
    done
}

# Help
ai_help() {
    cat << 'EOF'
PowOS AI Agent System

Usage: powos ai [options] "prompt"
       powos ai session <command>

Options:
  --agent, -a <name>     Use specific agent (coder, devops, health, assistant)
  --client, -c <name>    Use specific client (claude, gemini, ollama)
  --session, -s <name>   Use/resume specific session by name or ID
  --continue             Continue most recent conversation
  --new-session          Start new session (don't resume)
  --interactive, -i      Interactive chat mode
  --json                 Output JSON with session info
  --verbose              Verbose JSON output (shows tool use)
  --stream               Stream the reply live — text + tool-use as they happen
                         (default on a terminal; use --no-stream to disable)
  --no-stream            Buffer and print only the final answer
  --yolo                 Skip the client's permission prompts
                         (alias: --dangerously-skip-permissions)
  --help, -h             Show this help

Session Commands:
  powos ai sessions                     List all sessions
  powos ai session new [name]           Create new session
  powos ai session delete <name>        Delete a session
  powos ai session export <name> [fmt]  Export session (text/json/markdown|md)
  powos ai session clear                Delete all sessions

Examples:
  powos ai "help me set up this project"
  powos ai --agent coder "review this function"
  powos ai --agent health "is my system healthy?"
  powos ai --client ollama "explain this locally"
  powos ai -i                           # Interactive mode
  powos ai --continue "what next?"      # Continue last conversation
  powos ai --session myproject "hello"  # Use named session
  powos ai --json "hello"               # Get JSON with session_id

Session Workflow:
  powos ai session new myproject        # Create named session
  powos ai -s myproject "start work"    # Use session
  powos ai -s myproject "continue..."   # Session remembered
  powos ai session export myproject md  # Export as markdown

Library Usage (in scripts):
  source /usr/lib/powos/ai/agent.sh
  ai_call "what should I do?"
  ai_call --agent devops "diagnose this"
  ai_call --session myproject "continue"

EOF
    ai_list_agents
    echo ""
    ai_list_clients
}

# ═══════════════════════════════════════════════════════════════════
# CLI Entry Point
# ═══════════════════════════════════════════════════════════════════

# List sessions
ai_sessions() {
    _ai_ensure_config
    if declare -f ai_session_list &>/dev/null; then
        ai_session_list
    else
        echo "Session management not available" >&2
        return 1
    fi
}

# Create new named session
ai_new_session() {
    _ai_ensure_config
    local name="${1:-}"
    local agent="${2:-${AI_DEFAULT_AGENT:-assistant}}"
    local client="${3:-${AI_DEFAULT_CLIENT:-claude}}"

    if declare -f ai_session_start &>/dev/null; then
        local session_id
        session_id=$(ai_session_start "$name" "$agent" "$client") || return 1
        echo -e "${GREEN}Created session: ${BOLD}$session_id${NC}"
        echo "$session_id"
    else
        echo "Session management not available" >&2
        return 1
    fi
}

# Delete a session
ai_delete_session() {
    _ai_ensure_config
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo -e "${RED}Usage: powos ai session delete <name>${NC}" >&2
        return 1
    fi

    if declare -f ai_session_delete &>/dev/null; then
        ai_session_delete "$name"
    else
        echo "Session management not available" >&2
        return 1
    fi
}

# Export a session
ai_export_session() {
    _ai_ensure_config
    local name="${1:-}"
    local format="${2:-text}"

    if [[ -z "$name" ]]; then
        echo -e "${RED}Usage: powos ai session export <name> [format]${NC}" >&2
        return 1
    fi

    if declare -f ai_session_export &>/dev/null; then
        ai_session_export "$name" "$format"
    else
        echo "Session management not available" >&2
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════
# CLI Entry Point
# ═══════════════════════════════════════════════════════════════════

# Only run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _ai_load_config

    if [[ $# -eq 0 ]]; then
        ai_help
        exit 0
    fi

    case "$1" in
        list|agents)
            ai_list_agents
            ;;
        clients)
            ai_list_clients
            ;;
        sessions)
            ai_sessions
            ;;
        session)
            shift
            case "${1:-list}" in
                list)
                    ai_sessions
                    ;;
                new|create)
                    shift
                    ai_new_session "$@"
                    ;;
                delete|rm)
                    shift
                    ai_delete_session "${1:-}"
                    ;;
                export)
                    shift
                    ai_export_session "$@"
                    ;;
                clear)
                    if declare -f ai_session_clear_all &>/dev/null; then
                        ai_session_clear_all
                    fi
                    ;;
                *)
                    echo -e "${RED}Unknown session command: $1${NC}" >&2
                    echo "Usage: powos ai session {list|new|delete|export|clear}" >&2
                    exit 1
                    ;;
            esac
            ;;
        help|--help|-h)
            ai_help
            ;;
        *)
            ai_call "$@"
            ;;
    esac
fi
