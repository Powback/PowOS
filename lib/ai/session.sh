#!/bin/bash
# session.sh - AI Session Management for PowOS
#
# Handles conversation persistence and session management.
# Sessions are stored as JSON files for portability.

# NOTE: no `set -euo pipefail` here — this file is only ever SOURCED
# (by agent.sh / bin/powos) and must not change the caller's shell options.

# Default under the user's XDG state home (always writable). agent.sh normally
# sets AI_STATE_DIR before sourcing us; fall back to the same XDG location if
# session.sh is sourced standalone. (Was /var/lib/powos/state — root-owned on a
# fresh install, which silently broke all session persistence.)
AI_SESSION_DIR="${AI_SESSION_DIR:-${AI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/powos/ai}/sessions}"

# ═══════════════════════════════════════════════════════════════════
# Session Management
# ═══════════════════════════════════════════════════════════════════

# Ensure session directory exists. If the configured dir can't be created
# (e.g. AI_STATE_DIR was pointed at a root-owned system path), fall back to a
# guaranteed user-writable XDG location so session persistence NEVER silently
# breaks the way it did on fresh installs.
_session_init() {
    if mkdir -p "$AI_SESSION_DIR" 2>/dev/null; then
        return 0
    fi
    AI_SESSION_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/powos/ai/sessions"
    mkdir -p "$AI_SESSION_DIR" 2>/dev/null
}

# Validate a session name before it is used in a filesystem path.
# Session names become "$AI_SESSION_DIR/<name>.json" — a name like
# '../../etc/foo' would read/write/delete files outside the session dir.
_session_validate_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "Error: invalid session name '$name' (allowed: letters, digits, '-', '_')" >&2
        return 1
    fi
}

# Generate a session ID
session_generate_id() {
    echo "session-$(date +%Y%m%d-%H%M%S)-$(head -c 4 /dev/urandom | xxd -p)"
}

# Create a new session
ai_session_start() {
    local name="${1:-$(session_generate_id)}"
    local agent="${2:-assistant}"
    local client="${3:-claude}"

    _session_validate_name "$name" || return 1

    _session_init

    local session_file="$AI_SESSION_DIR/${name}.json"

    # Create session metadata
    cat > "$session_file" << EOF
{
  "id": "$name",
  "agent": "$agent",
  "client": "$client",
  "client_session_id": "",
  "created": "$(date -Iseconds)",
  "updated": "$(date -Iseconds)",
  "messages": []
}
EOF

    # Set as current session
    ln -sf "$session_file" "$AI_SESSION_DIR/current"

    echo "$name"
}

# Store the client's native session ID (e.g., Claude's UUID)
ai_session_set_client_id() {
    local session="$1"
    local client_id="$2"

    _session_validate_name "$session" || return 1

    local session_file="$AI_SESSION_DIR/${session}.json"

    if [[ ! -f "$session_file" ]]; then
        return 1
    fi

    if command -v jq &>/dev/null; then
        local tmp=$(mktemp)
        jq --arg client_id "$client_id" \
           '.client_session_id = $client_id | .updated = (now | todate)' \
           "$session_file" > "$tmp" && mv "$tmp" "$session_file"
    elif command -v python3 &>/dev/null; then
        # Pass data via environment — never interpolate into Python source
        POWOS_SESSION_FILE="$session_file" POWOS_CLIENT_ID="$client_id" \
        python3 << 'PYEOF'
import json, os
from datetime import datetime

path = os.environ['POWOS_SESSION_FILE']
with open(path, 'r') as f:
    data = json.load(f)

data['client_session_id'] = os.environ['POWOS_CLIENT_ID']
data['updated'] = datetime.now().isoformat()

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
    fi
}

# Get the client's native session ID
ai_session_get_client_id() {
    local session="$1"

    _session_validate_name "$session" || return 1

    local session_file="$AI_SESSION_DIR/${session}.json"

    if [[ ! -f "$session_file" ]]; then
        return 1
    fi

    if command -v jq &>/dev/null; then
        jq -r '.client_session_id // empty' "$session_file"
    elif command -v python3 &>/dev/null; then
        POWOS_SESSION_FILE="$session_file" python3 << 'PYEOF'
import json, os
with open(os.environ['POWOS_SESSION_FILE'], 'r') as f:
    data = json.load(f)
print(data.get('client_session_id', ''))
PYEOF
    fi
}

# Resume an existing session
ai_session_resume() {
    local name="$1"

    _session_validate_name "$name" || return 1

    _session_init

    local session_file="$AI_SESSION_DIR/${name}.json"

    if [[ ! -f "$session_file" ]]; then
        echo "Session '$name' not found" >&2
        return 1
    fi

    # Set as current session
    ln -sf "$session_file" "$AI_SESSION_DIR/current"

    echo "$name"
}

# Get current session
ai_session_current() {
    if [[ -L "$AI_SESSION_DIR/current" ]]; then
        local target=$(readlink "$AI_SESSION_DIR/current")
        basename "$target" .json
    else
        echo ""
    fi
}

# Add message to session
ai_session_add_message() {
    local session="$1"
    local role="$2"  # user or assistant
    local content="$3"

    _session_validate_name "$session" || return 1

    _session_init

    local session_file="$AI_SESSION_DIR/${session}.json"

    if [[ ! -f "$session_file" ]]; then
        return 1
    fi

    # Use jq if available, otherwise python
    if command -v jq &>/dev/null; then
        local tmp=$(mktemp)
        jq --arg role "$role" --arg content "$content" \
           '.messages += [{"role": $role, "content": $content, "timestamp": (now | todate)}] | .updated = (now | todate)' \
           "$session_file" > "$tmp" && mv "$tmp" "$session_file"
    elif command -v python3 &>/dev/null; then
        # Pass data via environment — interpolating $content into Python
        # source ('''$content''') is a code injection vector.
        POWOS_SESSION_FILE="$session_file" \
        POWOS_MSG_ROLE="$role" \
        POWOS_MSG_CONTENT="$content" \
        python3 << 'PYEOF'
import json, os
from datetime import datetime

path = os.environ['POWOS_SESSION_FILE']
with open(path, 'r') as f:
    data = json.load(f)

data['messages'].append({
    'role': os.environ['POWOS_MSG_ROLE'],
    'content': os.environ['POWOS_MSG_CONTENT'],
    'timestamp': datetime.now().isoformat()
})
data['updated'] = datetime.now().isoformat()

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
    else
        echo "Warning: Cannot update session (need jq or python3)" >&2
    fi
}

# Get session messages
ai_session_get_messages() {
    local session="$1"

    _session_validate_name "$session" || return 1

    local session_file="$AI_SESSION_DIR/${session}.json"

    if [[ ! -f "$session_file" ]]; then
        return 1
    fi

    if command -v jq &>/dev/null; then
        jq -r '.messages[] | "\(.role): \(.content)"' "$session_file"
    elif command -v python3 &>/dev/null; then
        POWOS_SESSION_FILE="$session_file" python3 << 'PYEOF'
import json, os
with open(os.environ['POWOS_SESSION_FILE'], 'r') as f:
    data = json.load(f)
for msg in data['messages']:
    print(f"{msg['role']}: {msg['content']}")
PYEOF
    else
        cat "$session_file"
    fi
}

# List all sessions
ai_session_list() {
    _session_init

    echo "Sessions"
    echo "════════════════════════════════════════"

    local current=$(ai_session_current)

    for session_file in "$AI_SESSION_DIR"/*.json; do
        [[ -f "$session_file" ]] || continue
        local name=$(basename "$session_file" .json)

        local marker="  "
        if [[ "$name" == "$current" ]]; then
            marker="* "
        fi

        # Get metadata
        if command -v jq &>/dev/null; then
            local agent=$(jq -r '.agent' "$session_file")
            local updated=$(jq -r '.updated' "$session_file")
            local count=$(jq '.messages | length' "$session_file")
            printf "%s%-20s %s (%d messages) %s\n" "$marker" "$name" "$agent" "$count" "$updated"
        else
            printf "%s%s\n" "$marker" "$name"
        fi
    done
}

# Delete a session
ai_session_delete() {
    local name="$1"

    _session_validate_name "$name" || return 1

    local session_file="$AI_SESSION_DIR/${name}.json"

    if [[ -f "$session_file" ]]; then
        rm -f "$session_file"
        echo "Deleted session: $name"

        # Remove current link if it pointed to this session
        if [[ "$(ai_session_current)" == "$name" ]]; then
            rm -f "$AI_SESSION_DIR/current"
        fi
    else
        echo "Session '$name' not found" >&2
        return 1
    fi
}

# Clear all sessions
ai_session_clear_all() {
    _session_init
    rm -f "$AI_SESSION_DIR"/*.json "$AI_SESSION_DIR/current"
    echo "Cleared all sessions"
}

# Export session as text
ai_session_export() {
    local session="$1"
    local format="${2:-text}"

    _session_validate_name "$session" || return 1

    local session_file="$AI_SESSION_DIR/${session}.json"

    if [[ ! -f "$session_file" ]]; then
        echo "Session '$session' not found" >&2
        return 1
    fi

    case "$format" in
        json)
            cat "$session_file"
            ;;
        text)
            ai_session_get_messages "$session"
            ;;
        markdown|md)
            echo "# Session: $session"
            echo ""
            if command -v jq &>/dev/null; then
                jq -r '.messages[] | "## \(.role | ascii_upcase)\n\n\(.content)\n"' "$session_file"
            else
                ai_session_get_messages "$session"
            fi
            ;;
        *)
            echo "Unknown format: $format" >&2
            return 1
            ;;
    esac
}
