#!/bin/bash
# session.sh - AI Session Management for PowOS
#
# Handles conversation persistence and session management.
# Sessions are stored as JSON files for portability.

set -euo pipefail

AI_SESSION_DIR="${AI_SESSION_DIR:-/var/lib/powos/state/ai/sessions}"

# ═══════════════════════════════════════════════════════════════════
# Session Management
# ═══════════════════════════════════════════════════════════════════

# Ensure session directory exists
_session_init() {
    mkdir -p "$AI_SESSION_DIR"
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
        python3 << PYEOF
import json
from datetime import datetime

with open('$session_file', 'r') as f:
    data = json.load(f)

data['client_session_id'] = '$client_id'
data['updated'] = datetime.now().isoformat()

with open('$session_file', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
    fi
}

# Get the client's native session ID
ai_session_get_client_id() {
    local session="$1"
    local session_file="$AI_SESSION_DIR/${session}.json"

    if [[ ! -f "$session_file" ]]; then
        return 1
    fi

    if command -v jq &>/dev/null; then
        jq -r '.client_session_id // empty' "$session_file"
    elif command -v python3 &>/dev/null; then
        python3 << PYEOF
import json
with open('$session_file', 'r') as f:
    data = json.load(f)
print(data.get('client_session_id', ''))
PYEOF
    fi
}

# Resume an existing session
ai_session_resume() {
    local name="$1"

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
        python3 << PYEOF
import json
from datetime import datetime

with open('$session_file', 'r') as f:
    data = json.load(f)

data['messages'].append({
    'role': '$role',
    'content': '''$content''',
    'timestamp': datetime.now().isoformat()
})
data['updated'] = datetime.now().isoformat()

with open('$session_file', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
    else
        echo "Warning: Cannot update session (need jq or python3)" >&2
    fi
}

# Get session messages
ai_session_get_messages() {
    local session="$1"
    local session_file="$AI_SESSION_DIR/${session}.json"

    if [[ ! -f "$session_file" ]]; then
        return 1
    fi

    if command -v jq &>/dev/null; then
        jq -r '.messages[] | "\(.role): \(.content)"' "$session_file"
    elif command -v python3 &>/dev/null; then
        python3 << PYEOF
import json
with open('$session_file', 'r') as f:
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
        markdown)
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
