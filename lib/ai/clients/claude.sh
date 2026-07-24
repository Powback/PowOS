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

# Append invocation-wide extra flags to the caller's args array (by nameref).
# Currently: --dangerously-skip-permissions when the user passed --yolo. The
# claude CLI won't run --dangerously-skip-permissions as root unless the guest
# opts in, but that's the CLI's own guard — we just pass the flag through.
_claude_add_common() {
    local -n _a="$1"
    [[ "${POWOS_AI_SKIP_PERMS:-}" == "1" ]] && _a+=("--dangerously-skip-permissions")
}

# Send a prompt and get a response
# Returns: response text (and stores session_id in temp file for retrieval)
client_call() {
    local prompt="$1"
    local system_prompt="${2:-}"
    local session_id="${3:-}"

    local cmd="${CLIENT_CMD:-claude}"
    local args=("--print")
    _claude_add_common args

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
    _claude_add_common args

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
    _claude_add_common args

    if [[ -n "$system_prompt" ]]; then
        args+=("--system-prompt" "$system_prompt")
    fi

    if [[ -n "$session_id" ]] && _claude_is_uuid "$session_id"; then
        args+=("--resume" "$session_id")
    fi

    "$cmd" "${args[@]}" "$prompt"
}

# Render a block of assistant markdown to the terminal. Uses `glow` for real
# styling (headers, bold, code fences, lists) when available; falls back to raw
# text. Honors NO_COLOR and POWOS_AI_NO_MARKDOWN=1 (plain passthrough).
_claude_render_md() {
    local text="$1"
    [[ -z "$text" ]] && return 0
    if [[ -z "${NO_COLOR:-}" && "${POWOS_AI_NO_MARKDOWN:-}" != "1" ]] \
        && command -v glow &>/dev/null; then
        local w; w="$(tput cols 2>/dev/null)"; [[ -n "$w" ]] || w="${COLUMNS:-100}"
        # glow renders on EOF; feeding one block at a time keeps output live.
        # -w matches the terminal; on any glow error, fall back to raw text.
        printf '%s\n' "$text" | glow -w "$w" - 2>/dev/null || printf '%s\n' "$text"
    else
        printf '%s\n' "$text"
    fi
}

# Render a tool_use block as a human-readable "what + why" panel: the tool name,
# its target (file/path/pattern), the model's own plain-text description (WHY),
# and the exact command being run (WHAT). $1 = base64-encoded tool_use JSON.
_claude_render_tool() {
    local json; json="$(printf '%s' "$1" | base64 -d 2>/dev/null)"
    [[ -z "$json" ]] && return 0
    local name desc cmd tgt
    name="$(printf '%s' "$json" | jq -r '.name // "tool"' 2>/dev/null)"
    desc="$(printf '%s' "$json" | jq -r '.input.description // empty' 2>/dev/null)"
    cmd="$(printf '%s'  "$json" | jq -r '.input.command // empty' 2>/dev/null)"
    tgt="$(printf '%s'  "$json" | jq -r '.input.file_path // .input.path // .input.pattern // .input.url // empty' 2>/dev/null)"

    local C_HEAD=$'\033[1;36m' C_DESC=$'\033[0;37m' C_CMD=$'\033[0;33m' C_DIM=$'\033[2m' NC=$'\033[0m'
    if [[ -n "${NO_COLOR:-}" ]]; then C_HEAD=""; C_DESC=""; C_CMD=""; C_DIM=""; NC=""; fi

    # Fallback: if description is empty and this is a Bash call, use a
    # truncated version of the command so the user always sees *what* is running.
    if [[ -z "$desc" && -n "$cmd" ]]; then
        desc="${cmd:0:80}"
        [[ "${#cmd}" -gt 80 ]] && desc="${desc}…"
    fi

    # Header line: "⚙ ToolName — description  target"
    printf '\n%s⚙ %s%s' "$C_HEAD" "$name" "$NC"
    [[ -n "$desc" ]] && printf ' — %s%s%s' "$C_DESC" "$desc" "$NC"
    [[ -n "$tgt"  ]] && printf '  %s%s%s' "$C_DIM" "$tgt" "$NC"
    printf '\n'
    # Command line (only shown when there is an actual command to display)
    [[ -n "$cmd" ]]  && printf '  %s$ %s%s\n' "$C_CMD" "$cmd" "$NC"
}

# Stream the response LIVE — print assistant text and tool-use as they arrive
# (the "intermittent messages"), instead of buffering everything and showing
# only the final result. MUST be called WITHOUT command substitution so output
# reaches the terminal. Stashes the session id from the terminal 'result' event.
client_call_stream() {
    local prompt="$1"
    local system_prompt="${2:-}"
    local session_id="${3:-}"

    local cmd="${CLIENT_CMD:-claude}"
    local args=("--print" "--output-format" "stream-json" "--verbose")
    _claude_add_common args
    [[ -n "$system_prompt" ]] && args+=("--system-prompt" "$system_prompt")
    if [[ -n "$session_id" ]] && _claude_is_uuid "$session_id"; then
        args+=("--resume" "$session_id")
    fi

    # Without jq we can't parse events — stream the raw JSONL (still live).
    if ! command -v jq &>/dev/null; then
        "$cmd" "${args[@]}" "$prompt"
        return "${PIPESTATUS[0]:-$?}"
    fi

    # Parse the event stream line by line: show assistant text + tool calls as
    # they happen; capture the session id from the final 'result' event.
    "$cmd" "${args[@]}" "$prompt" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)" in
            assistant)
                # Split the message into typed content blocks. Each block is
                # emitted as "<type>\t<base64>" (base64 keeps newlines/tabs
                # intact across the read loop). Text -> markdown renderer;
                # tool_use -> the "what + why" panel.
                while IFS=$'\t' read -r _btype _payload; do
                    case "$_btype" in
                        text) _claude_render_md "$(printf '%s' "$_payload" | base64 -d 2>/dev/null)" ;;
                        tool) _claude_render_tool "$_payload" ;;
                    esac
                done < <(printf '%s' "$line" | jq -r '
                    (.message.content // [])[]
                    | if .type=="text" then "text\t" + (.text | @base64)
                      elif .type=="tool_use" then "tool\t" + (. | @base64)
                      else empty end' 2>/dev/null)
                ;;
            result)
                local sid; sid="$(printf '%s' "$line" | jq -r '.session_id // empty' 2>/dev/null)"
                [[ -n "$sid" ]] && printf '%s' "$sid" > "$CLAUDE_SESSION_ID_FILE"
                ;;
        esac
    done
    return "${PIPESTATUS[0]:-0}"
}

# Continue the most recent conversation
# $2 (optional): agent system prompt — passed through like the one-shot path
client_continue() {
    local prompt="$1"
    local system_prompt="${2:-}"
    local cmd="${CLIENT_CMD:-claude}"
    local args=("--print" "--continue")
    _claude_add_common args

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

    # Add system prompt. Use --append-system-prompt (works in interactive
    # AND print mode) rather than --system-prompt (which Claude Code 2.x
    # treats as an implicit --print signal — the interactive TUI then
    # errors with "Input must be provided either through stdin or as a
    # prompt argument when using --print" the moment the user types
    # something).
    if [[ -n "$system_prompt" ]]; then
        args+=("--append-system-prompt" "$system_prompt")
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
