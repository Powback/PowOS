#!/usr/bin/env bash
# ai-healer.sh - AI-powered self-healing for PowOS
#
# Uses Ollama for:
#   - Patch/merge conflict resolution
#   - Error diagnosis and suggestions
#   - Configuration troubleshooting
#   - Automated fix application
#
# Usage:
#   ai-healer.sh diagnose [log-file]     - Analyze errors and suggest fixes
#   ai-healer.sh resolve [conflict-file] - Resolve merge/patch conflicts
#   ai-healer.sh fix [error-message]     - Get fix suggestion for error
#   ai-healer.sh status                  - Check Ollama connection
#   ai-healer.sh models                  - List available models

set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────

OLLAMA_HOST="${OLLAMA_HOST:-http://powos-ollama:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:3b}"
POWOS_ROOT="${POWOS_ROOT:-/var/lib/powos}"
STATE_DIR="${POWOS_ROOT}/state"
LOG_PREFIX="[ai-healer]"

# Fallback to localhost if container name doesn't resolve
if ! curl -s --connect-timeout 2 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
    OLLAMA_HOST="${OLLAMA_HOST_FALLBACK:-http://localhost:11434}"
fi

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' NC=''
fi

# ─────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────

log_info() { echo -e "${BLUE}${LOG_PREFIX}${NC} $*"; }
log_success() { echo -e "${GREEN}${LOG_PREFIX}${NC} $*"; }
log_warn() { echo -e "${YELLOW}${LOG_PREFIX}${NC} $*"; }
log_error() { echo -e "${RED}${LOG_PREFIX}${NC} $*" >&2; }
log_ai() { echo -e "${MAGENTA}${LOG_PREFIX}${NC} $*"; }

# ─────────────────────────────────────────────────────────────────
# Ollama API Functions
# ─────────────────────────────────────────────────────────────────

ollama_available() {
    curl -s --connect-timeout 5 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1
}

ollama_generate() {
    local prompt="$1"
    local model="${2:-$OLLAMA_MODEL}"

    curl -s "${OLLAMA_HOST}/api/generate" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg model "$model" \
            --arg prompt "$prompt" \
            '{model: $model, prompt: $prompt, stream: false}')" \
        | jq -r '.response // empty'
}

ollama_chat() {
    local system="$1"
    local user="$2"
    local model="${3:-$OLLAMA_MODEL}"

    curl -s "${OLLAMA_HOST}/api/chat" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg model "$model" \
            --arg system "$system" \
            --arg user "$user" \
            '{model: $model, messages: [{role: "system", content: $system}, {role: "user", content: $user}], stream: false}')" \
        | jq -r '.message.content // empty'
}

ensure_model() {
    local model="${1:-$OLLAMA_MODEL}"

    if ! curl -s "${OLLAMA_HOST}/api/tags" | jq -e --arg model "$model" '.models[] | select(.name == $model)' >/dev/null 2>&1; then
        log_info "Pulling model: $model (this may take a while)..."
        curl -s "${OLLAMA_HOST}/api/pull" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg name "$model" '{name: $name}')" \
            | while read -r line; do
                status=$(echo "$line" | jq -r '.status // empty')
                [[ -n "$status" ]] && echo -ne "\r${CYAN}${LOG_PREFIX}${NC} $status                    "
            done
        echo ""
        log_success "Model ready: $model"
    fi
}

# ─────────────────────────────────────────────────────────────────
# Self-Healing Functions
# ─────────────────────────────────────────────────────────────────

diagnose_logs() {
    local log_file="${1:-}"
    local log_content=""

    if [[ -n "$log_file" && -f "$log_file" ]]; then
        log_content=$(tail -100 "$log_file")
    else
        # Collect recent system errors
        log_content=$(journalctl -p err -n 50 --no-pager 2>/dev/null || echo "No journald available")

        # Add dmesg errors if available
        if command -v dmesg &>/dev/null; then
            log_content+=$'\n\n--- dmesg errors ---\n'
            log_content+=$(dmesg -l err,warn 2>/dev/null | tail -20 || echo "No dmesg available")
        fi
    fi

    if [[ -z "$log_content" ]]; then
        log_success "No errors found to diagnose"
        return 0
    fi

    local system_prompt="You are a Linux system administrator AI assistant for PowOS, an immutable Fedora-based workstation OS.
Your job is to analyze error logs and provide:
1. A brief diagnosis (what went wrong)
2. Likely root cause
3. Specific fix commands that can be run
Keep responses concise and actionable. Format fix commands in code blocks."

    local user_prompt="Analyze these error logs and provide diagnosis and fixes:

$log_content"

    log_info "Analyzing logs with AI..."
    ensure_model

    local response
    response=$(ollama_chat "$system_prompt" "$user_prompt")

    if [[ -n "$response" ]]; then
        echo ""
        echo -e "${MAGENTA}═══ AI Diagnosis ═══${NC}"
        echo "$response"
        echo -e "${MAGENTA}════════════════════${NC}"
        echo ""

        # Save diagnosis
        mkdir -p "$STATE_DIR"
        echo "$response" > "$STATE_DIR/last-diagnosis.txt"
        log_info "Diagnosis saved to $STATE_DIR/last-diagnosis.txt"
    else
        log_error "Failed to get AI response"
        return 1
    fi
}

resolve_conflict() {
    local conflict_file="$1"

    if [[ ! -f "$conflict_file" ]]; then
        log_error "File not found: $conflict_file"
        return 1
    fi

    local content
    content=$(cat "$conflict_file")

    # Check if file has conflict markers
    if ! grep -q "^<<<<<<< " "$conflict_file"; then
        log_warn "No conflict markers found in file"
        return 1
    fi

    local system_prompt="You are a merge conflict resolver for PowOS configuration files.
Given a file with Git-style conflict markers (<<<<<<< ======= >>>>>>>), output ONLY the resolved file content.
Choose the best resolution based on:
1. Preferring newer/updated code when clear
2. Combining both sides when they're complementary
3. Using PowOS conventions and best practices
Output ONLY the resolved file content, no explanations."

    local user_prompt="Resolve the conflicts in this file:

$content"

    log_info "Resolving conflicts with AI..."
    ensure_model

    local resolved
    resolved=$(ollama_chat "$system_prompt" "$user_prompt")

    if [[ -n "$resolved" ]]; then
        # Backup original
        cp "$conflict_file" "${conflict_file}.conflict"

        # Write resolved
        echo "$resolved" > "$conflict_file"

        log_success "Conflict resolved: $conflict_file"
        log_info "Original backed up to: ${conflict_file}.conflict"

        # Show diff
        echo ""
        echo -e "${CYAN}═══ Resolution Preview ═══${NC}"
        diff --color=auto "${conflict_file}.conflict" "$conflict_file" || true
        echo -e "${CYAN}═══════════════════════════${NC}"
    else
        log_error "Failed to resolve conflict"
        return 1
    fi
}

fix_error() {
    local error_message="$1"

    local system_prompt="You are a PowOS troubleshooting assistant.
PowOS is an immutable Fedora-based workstation OS that uses:
- systemd-sysext for overlays
- podman/distrobox for containers
- git for state tracking
- pinstall/premove for package management

Given an error message, provide:
1. What the error means
2. The exact command(s) to fix it
Keep responses concise. Format commands in code blocks."

    local user_prompt="How do I fix this error?

$error_message"

    log_info "Getting fix suggestion..."
    ensure_model

    local response
    response=$(ollama_chat "$system_prompt" "$user_prompt")

    if [[ -n "$response" ]]; then
        echo ""
        echo -e "${MAGENTA}═══ AI Fix Suggestion ═══${NC}"
        echo "$response"
        echo -e "${MAGENTA}═════════════════════════${NC}"
        echo ""
    else
        log_error "Failed to get AI response"
        return 1
    fi
}

auto_heal() {
    # Automatic healing routine
    log_info "Running automatic healing scan..."

    local issues_found=0
    local fixes_applied=0

    # Check 1: Broken symlinks in /var/lib/powos
    log_info "Checking for broken symlinks..."
    while IFS= read -r -d '' broken_link; do
        log_warn "Broken symlink: $broken_link"
        ((issues_found++)) || true
    done < <(find "$POWOS_ROOT" -xtype l -print0 2>/dev/null || true)

    # Check 2: Failed systemd services
    log_info "Checking systemd services..."
    if command -v systemctl &>/dev/null; then
        local failed_services
        failed_services=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$failed_services" ]]; then
            log_warn "Failed services found:"
            echo "$failed_services"
            ((issues_found++)) || true
        fi
    fi

    # Check 3: Disk space
    log_info "Checking disk space..."
    local disk_usage
    disk_usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    if [[ "$disk_usage" -gt 90 ]]; then
        log_warn "Disk usage critical: ${disk_usage}%"
        ((issues_found++)) || true
    fi

    # Check 4: Git state
    if [[ -d "${POWOS_ROOT}/.git" ]]; then
        log_info "Checking git state..."
        cd "$POWOS_ROOT"
        if ! git diff --quiet HEAD 2>/dev/null; then
            log_warn "Uncommitted changes in PowOS state"
            ((issues_found++)) || true
        fi
    fi

    # Summary
    echo ""
    if [[ $issues_found -eq 0 ]]; then
        log_success "System healthy - no issues found"
    else
        log_warn "Found $issues_found potential issue(s)"
        echo ""
        read -p "Run AI diagnosis on issues? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            diagnose_logs
        fi
    fi
}

show_status() {
    echo -e "${CYAN}═══ AI Healer Status ═══${NC}"
    echo ""
    echo "Ollama Host: $OLLAMA_HOST"
    echo "Model: $OLLAMA_MODEL"
    echo ""

    if ollama_available; then
        log_success "Ollama: Connected"

        # List models
        echo ""
        echo "Available models:"
        curl -s "${OLLAMA_HOST}/api/tags" | jq -r '.models[].name' 2>/dev/null | while read -r model; do
            echo "  - $model"
        done
    else
        log_error "Ollama: Not available"
        echo ""
        echo "To start Ollama:"
        echo "  docker compose --profile ai up -d"
        echo ""
        echo "Or connect to external Ollama:"
        echo "  export OLLAMA_HOST=http://your-ollama:11434"
    fi
    echo ""
    echo -e "${CYAN}════════════════════════${NC}"
}

list_models() {
    if ! ollama_available; then
        log_error "Ollama not available"
        return 1
    fi

    echo -e "${CYAN}═══ Available Models ═══${NC}"
    curl -s "${OLLAMA_HOST}/api/tags" | jq -r '.models[] | "\(.name)\t\(.size / 1024 / 1024 / 1024 | floor)GB"' 2>/dev/null | column -t
    echo -e "${CYAN}════════════════════════${NC}"
    echo ""
    echo "Pull a new model:"
    echo "  curl ${OLLAMA_HOST}/api/pull -d '{\"name\": \"llama3.2:3b\"}'"
}

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
PowOS AI Self-Healing System

Usage: $(basename "$0") <command> [args]

Commands:
  diagnose [log-file]     Analyze errors and suggest fixes
  resolve <conflict-file> Resolve merge/patch conflicts using AI
  fix <error-message>     Get fix suggestion for an error
  heal                    Run automatic healing scan
  status                  Check Ollama connection status
  models                  List available AI models

Environment:
  OLLAMA_HOST   Ollama API URL (default: http://powos-ollama:11434)
  OLLAMA_MODEL  Model to use (default: llama3.2:3b)

Examples:
  $(basename "$0") diagnose                    # Analyze system logs
  $(basename "$0") diagnose /var/log/boot.log  # Analyze specific log
  $(basename "$0") resolve config.yaml         # Resolve conflicts in file
  $(basename "$0") fix "permission denied"     # Get fix for error
  $(basename "$0") heal                        # Run automatic healing
EOF
}

main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        diagnose)
            diagnose_logs "${1:-}"
            ;;
        resolve)
            if [[ -z "${1:-}" ]]; then
                log_error "Missing conflict file argument"
                usage
                exit 1
            fi
            resolve_conflict "$1"
            ;;
        fix)
            if [[ -z "${1:-}" ]]; then
                log_error "Missing error message argument"
                usage
                exit 1
            fi
            fix_error "$*"
            ;;
        heal|auto)
            auto_heal
            ;;
        status)
            show_status
            ;;
        models)
            list_models
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
