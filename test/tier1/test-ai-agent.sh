#!/usr/bin/env bash
# test-ai-agent.sh - Test the AI agent system
#
# Tests:
# 1. Agent loading and sourcing
# 2. Session management
# 3. Client detection
# 4. Helper functions
# 5. Agent configuration loading

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWOS_ROOT="${POWOS_ROOT:-$(dirname "$(dirname "$SCRIPT_DIR")")}"
# setup() repoints POWOS_ROOT at the sandbox; keep the real repo root around
REPO_ROOT="$POWOS_ROOT"
TEST_DIR="/tmp/powos-ai-test-$$"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ─────────────────────────────────────────────────────────────────
# Test Helpers
# ─────────────────────────────────────────────────────────────────

setup() {
    echo "Setting up test environment..."
    mkdir -p "$TEST_DIR/lib/ai/clients"
    mkdir -p "$TEST_DIR/config/ai/agents"
    mkdir -p "$TEST_DIR/config/ai/clients"
    mkdir -p "$TEST_DIR/state/ai/sessions"

    # Copy AI system files
    cp "$POWOS_ROOT/lib/ai/agent.sh" "$TEST_DIR/lib/ai/" 2>/dev/null || true
    cp "$POWOS_ROOT/lib/ai/session.sh" "$TEST_DIR/lib/ai/" 2>/dev/null || true
    cp "$POWOS_ROOT/lib/ai/helpers.sh" "$TEST_DIR/lib/ai/" 2>/dev/null || true
    cp "$POWOS_ROOT/lib/ai/clients/"*.sh "$TEST_DIR/lib/ai/clients/" 2>/dev/null || true
    cp "$POWOS_ROOT/config/ai/agent.conf" "$TEST_DIR/config/ai/" 2>/dev/null || true
    # Copy agent directories (structure: agents/{name}/agent.conf)
    cp -r "$POWOS_ROOT/config/ai/agents/"* "$TEST_DIR/config/ai/agents/" 2>/dev/null || true
    cp "$POWOS_ROOT/config/ai/clients/"*.conf "$TEST_DIR/config/ai/clients/" 2>/dev/null || true

    export POWOS_ROOT="$TEST_DIR"
    export AI_SESSION_DIR="$TEST_DIR/state/ai/sessions"
}

teardown() {
    echo "Cleaning up test environment..."
    rm -rf "$TEST_DIR"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Assertion failed}"

    ((TESTS_RUN++)) || true

    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✓${NC} $message"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        ((TESTS_FAILED++)) || true
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-Assertion failed}"

    ((TESTS_RUN++)) || true

    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}✓${NC} $message"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to contain: $needle"
        ((TESTS_FAILED++)) || true
    fi
}

assert_function_exists() {
    local func_name="$1"
    local message="${2:-Function should exist}"

    ((TESTS_RUN++)) || true

    if declare -f "$func_name" &>/dev/null; then
        echo -e "${GREEN}✓${NC} $message"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Function: $func_name"
        ((TESTS_FAILED++)) || true
    fi
}

assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist}"

    ((TESTS_RUN++)) || true

    if [[ -f "$file" ]]; then
        echo -e "${GREEN}✓${NC} $message"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} $message"
        echo "  File: $file"
        ((TESTS_FAILED++)) || true
    fi
}

# ─────────────────────────────────────────────────────────────────
# Tests: File Structure
# ─────────────────────────────────────────────────────────────────

test_ai_files_exist() {
    echo ""
    echo "Test: AI system files exist"
    assert_file_exists "$TEST_DIR/lib/ai/agent.sh" "agent.sh exists"
    assert_file_exists "$TEST_DIR/lib/ai/session.sh" "session.sh exists"
    assert_file_exists "$TEST_DIR/lib/ai/helpers.sh" "helpers.sh exists"
}

test_client_files_exist() {
    echo ""
    echo "Test: Client implementation files exist"
    assert_file_exists "$TEST_DIR/lib/ai/clients/base.sh" "base.sh exists"
    assert_file_exists "$TEST_DIR/lib/ai/clients/claude.sh" "claude.sh exists"
}

test_config_files_exist() {
    echo ""
    echo "Test: Configuration files exist"
    assert_file_exists "$TEST_DIR/config/ai/agent.conf" "agent.conf exists"
    assert_file_exists "$TEST_DIR/config/ai/agents/coder/agent.conf" "coder agent config exists"
}

# Regression test for the backtick-in-system-prompt bug: every agent.conf must
# source WITHOUT emitting errors. The bug was AGENT_SYSTEM_PROMPT being a
# double-quoted string containing markdown backticks (`cmd <arg>`), which bash
# runs as command substitution at source time — spraying "command substitution:
# syntax error" to stderr and silently corrupting the prompt. That does NOT
# change the exit code, so we assert stderr is EMPTY, not just rc==0.
test_agent_configs_source_cleanly() {
    echo ""
    echo "Test: every agent.conf sources with no stderr (backtick regression)"
    local conf name err
    for conf in "$TEST_DIR"/config/ai/agents/*/agent.conf "$TEST_DIR"/config/ai/agent.conf; do
        [[ -f "$conf" ]] || continue
        name="$(basename "$(dirname "$conf")")/$(basename "$conf")"
        ((TESTS_RUN++)) || true
        # Source in a clean subshell; capture only stderr.
        err="$(bash -c 'source "$1" 2>&1 >/dev/null' _ "$conf")"
        if [[ -z "$err" ]]; then
            echo -e "${GREEN}✓${NC} $name sources cleanly"
            ((TESTS_PASSED++)) || true
        else
            echo -e "${RED}✗${NC} $name emitted errors on source:"
            printf '      %s\n' "$err" | head -4
            ((TESTS_FAILED++)) || true
        fi
    done
}

# ─────────────────────────────────────────────────────────────────
# Tests: Helpers Module
# ─────────────────────────────────────────────────────────────────

test_helpers_source() {
    echo ""
    echo "Test: Helpers module can be sourced"

    ((TESTS_RUN++)) || true

    if source "$TEST_DIR/lib/ai/helpers.sh" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} helpers.sh sources without errors"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} helpers.sh failed to source"
        ((TESTS_FAILED++)) || true
    fi
}

test_helpers_functions() {
    echo ""
    echo "Test: Helper functions available"

    source "$TEST_DIR/lib/ai/helpers.sh" 2>/dev/null || true

    assert_function_exists "ai_ensure_loaded" "ai_ensure_loaded exists"
    assert_function_exists "ai_parse_files_to_dir" "ai_parse_files_to_dir exists"
    assert_function_exists "ai_extract_code_block" "ai_extract_code_block exists"
    assert_function_exists "ai_response_to_files" "ai_response_to_files exists"
}

test_file_parsing_structured() {
    echo ""
    echo "Test: Parse structured file format"

    source "$TEST_DIR/lib/ai/helpers.sh" 2>/dev/null || true

    local test_response="Some text before
--- test.txt ---
Hello World
Line 2
--- END ---
Some text after"

    local output_dir="$TEST_DIR/parse-test"
    mkdir -p "$output_dir"

    local files_created
    files_created=$(ai_parse_files_to_dir "$test_response" "$output_dir" "false")

    assert_equals "1" "$files_created" "One file created"
    assert_file_exists "$output_dir/test.txt" "test.txt created"

    if [[ -f "$output_dir/test.txt" ]]; then
        local content
        content=$(cat "$output_dir/test.txt")
        assert_contains "$content" "Hello World" "File contains expected content"
    fi
}

test_file_parsing_multiple() {
    echo ""
    echo "Test: Parse multiple files"

    source "$TEST_DIR/lib/ai/helpers.sh" 2>/dev/null || true

    local test_response="--- file1.txt ---
Content 1
--- END ---
--- file2.txt ---
Content 2
--- END ---"

    local output_dir="$TEST_DIR/parse-multi"
    mkdir -p "$output_dir"

    local files_created
    files_created=$(ai_parse_files_to_dir "$test_response" "$output_dir" "false")

    assert_equals "2" "$files_created" "Two files created"
    assert_file_exists "$output_dir/file1.txt" "file1.txt created"
    assert_file_exists "$output_dir/file2.txt" "file2.txt created"
}

test_code_block_extraction() {
    echo ""
    echo "Test: Extract code from markdown"

    source "$TEST_DIR/lib/ai/helpers.sh" 2>/dev/null || true

    local test_response='Here is some Python:
```python
print("hello")
```
Done'

    local extracted
    extracted=$(ai_extract_code_block "$test_response" "python")

    assert_contains "$extracted" 'print("hello")' "Extracts Python code"
}

# ─────────────────────────────────────────────────────────────────
# Tests: Session Module
# ─────────────────────────────────────────────────────────────────

test_session_source() {
    echo ""
    echo "Test: Session module can be sourced"

    ((TESTS_RUN++)) || true

    if source "$TEST_DIR/lib/ai/session.sh" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} session.sh sources without errors"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} session.sh failed to source"
        ((TESTS_FAILED++)) || true
    fi
}

test_session_functions() {
    echo ""
    echo "Test: Session functions available"

    source "$TEST_DIR/lib/ai/session.sh" 2>/dev/null || true

    assert_function_exists "ai_session_start" "ai_session_start exists"
    assert_function_exists "ai_session_list" "ai_session_list exists"
    assert_function_exists "ai_session_resume" "ai_session_resume exists"
}

test_session_create() {
    echo ""
    echo "Test: Create new session"

    source "$TEST_DIR/lib/ai/session.sh" 2>/dev/null || true

    local session_id
    session_id=$(ai_session_start "test-session" "coder" "claude")

    ((TESTS_RUN++)) || true
    if [[ -n "$session_id" ]]; then
        echo -e "${GREEN}✓${NC} Session created with ID"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Session creation failed"
        ((TESTS_FAILED++)) || true
    fi

    # Verify session file exists
    assert_file_exists "$AI_SESSION_DIR/${session_id}.json" "Session file created"
}

test_session_list() {
    echo ""
    echo "Test: List sessions"

    source "$TEST_DIR/lib/ai/session.sh" 2>/dev/null || true

    # Create a session first
    ai_session_start "list-test" "coder" "claude" >/dev/null

    local sessions
    sessions=$(ai_session_list)

    assert_contains "$sessions" "list-test" "Session appears in list"
}

# ─────────────────────────────────────────────────────────────────
# Tests: Agent Configuration
# ─────────────────────────────────────────────────────────────────

test_agent_config_load() {
    echo ""
    echo "Test: Load agent configuration"

    local agent_conf="$TEST_DIR/config/ai/agents/coder/agent.conf"
    if [[ -f "$agent_conf" ]]; then
        source "$agent_conf"

        assert_equals "coder" "$AGENT_NAME" "Agent name loaded"

        ((TESTS_RUN++)) || true
        if [[ -n "$AGENT_SYSTEM_PROMPT" ]]; then
            echo -e "${GREEN}✓${NC} System prompt loaded"
            ((TESTS_PASSED++)) || true
        else
            echo -e "${RED}✗${NC} System prompt not loaded"
            ((TESTS_FAILED++)) || true
        fi
    else
        ((TESTS_RUN++)) || true
        echo -e "${YELLOW}⊘${NC} Skipping: coder/agent.conf not available"
    fi
}

test_agent_base_config() {
    echo ""
    echo "Test: Base agent configuration"

    local base_conf="$TEST_DIR/config/ai/agents/base/agent.conf"
    if [[ -f "$base_conf" ]]; then
        source "$base_conf"

        ((TESTS_RUN++)) || true
        if [[ -n "$AGENT_BASE_CONTEXT" ]]; then
            echo -e "${GREEN}✓${NC} Base context available"
            ((TESTS_PASSED++)) || true
        else
            echo -e "${RED}✗${NC} Base context not loaded"
            ((TESTS_FAILED++)) || true
        fi

        assert_contains "$AGENT_FILE_OUTPUT_FORMAT" "--- END ---" "File output format defined"
    else
        ((TESTS_RUN++)) || true
        echo -e "${YELLOW}⊘${NC} Skipping: base/agent.conf not available"
    fi
}

# ─────────────────────────────────────────────────────────────────
# Tests: Client Module
# ─────────────────────────────────────────────────────────────────

test_client_base_source() {
    echo ""
    echo "Test: Client base module"

    ((TESTS_RUN++)) || true

    if source "$TEST_DIR/lib/ai/clients/base.sh" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} base.sh sources without errors"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} base.sh failed to source"
        ((TESTS_FAILED++)) || true
    fi
}

test_client_claude_source() {
    echo ""
    echo "Test: Claude client module"

    ((TESTS_RUN++)) || true

    if source "$TEST_DIR/lib/ai/clients/claude.sh" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} claude.sh sources without errors"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} claude.sh failed to source"
        ((TESTS_FAILED++)) || true
    fi

    assert_function_exists "client_call" "client_call exists"
    assert_function_exists "client_available" "client_available exists"
}

# ─────────────────────────────────────────────────────────────────
# Tests: Shell-option Safety
# ─────────────────────────────────────────────────────────────────

test_sourcing_does_not_change_shell_opts() {
    echo ""
    echo "Test: Sourcing agent.sh does not enable strict mode in the caller"

    ((TESTS_RUN++)) || true

    local opts
    opts=$(bash -c "source '$TEST_DIR/lib/ai/agent.sh'; echo \$-" 2>/dev/null || echo "SOURCE_FAILED")

    if [[ "$opts" != "SOURCE_FAILED" && "$opts" != *e* && "$opts" != *u* ]]; then
        echo -e "${GREEN}✓${NC} agent.sh does not set -e/-u when sourced (\$- = $opts)"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} sourcing agent.sh changed shell options (\$- = $opts)"
        ((TESTS_FAILED++)) || true
    fi
}

test_increment_crash_class() {
    echo ""
    echo "Test: ((var++)) crash-class regression"

    # The guarded idiom must survive `set -e` starting from 0
    # (bare ((var++)) returns 1 when var==0 and aborts the shell)
    ((TESTS_RUN++)) || true
    if bash -c 'set -euo pipefail; warnings=0; ((warnings++)) || true; ((warnings++)) || true; [[ $warnings -eq 2 ]]'; then
        echo -e "${GREEN}✓${NC} Guarded increment survives set -e starting from zero"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Guarded increment failed under set -e"
        ((TESTS_FAILED++)) || true
    fi

    # No bare ((var++)) may remain in the CLI / healer
    local offenders
    offenders=$(grep -nE '\(\([A-Za-z_]+\+\+\)\)' \
        "$REPO_ROOT/bin/powos" "$REPO_ROOT/lib/ai-healer.sh" 2>/dev/null \
        | grep -v '|| true' || true)
    assert_equals "" "$offenders" "No bare ((var++)) left in bin/powos / lib/ai-healer.sh"
}

# ─────────────────────────────────────────────────────────────────
# Tests: Name Validation (path traversal)
# ─────────────────────────────────────────────────────────────────

test_agent_name_validation() {
    echo ""
    echo "Test: Agent name validation rejects path traversal"

    # Plant an "evil" agent config outside the agents dir; the traversal
    # name '../../evil-agent' would resolve to it and get SOURCED.
    mkdir -p "$TEST_DIR/evil-agent"
    echo 'EVIL_MARKER=pwned' > "$TEST_DIR/evil-agent/agent.conf"

    ((TESTS_RUN++)) || true
    if bash -c "
        source '$TEST_DIR/lib/ai/agent.sh'
        _ai_ensure_config
        if _ai_load_agent '../../evil-agent' 2>/dev/null; then
            exit 1
        fi
        [[ -z \"\${EVIL_MARKER:-}\" ]] || exit 1
        exit 0
    "; then
        echo -e "${GREEN}✓${NC} _ai_load_agent rejects '../' agent names (nothing sourced)"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} _ai_load_agent accepted a path-traversal agent name"
        ((TESTS_FAILED++)) || true
    fi

    # Flavor part of agent:flavor must be validated too
    ((TESTS_RUN++)) || true
    if bash -c "
        source '$TEST_DIR/lib/ai/agent.sh'
        _ai_ensure_config
        ! _ai_load_agent 'coder:../../../evil-agent/agent' 2>/dev/null
    "; then
        echo -e "${GREEN}✓${NC} _ai_load_agent rejects '../' flavor names"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} _ai_load_agent accepted a path-traversal flavor name"
        ((TESTS_FAILED++)) || true
    fi
}

test_session_name_validation() {
    echo ""
    echo "Test: Session name validation rejects path traversal"

    source "$TEST_DIR/lib/ai/session.sh" 2>/dev/null || true

    ((TESTS_RUN++)) || true
    if ai_session_start "../escape" >/dev/null 2>&1; then
        echo -e "${RED}✗${NC} ai_session_start accepted '../escape'"
        ((TESTS_FAILED++)) || true
    else
        echo -e "${GREEN}✓${NC} ai_session_start rejects '../' session names"
        ((TESTS_PASSED++)) || true
    fi

    ((TESTS_RUN++)) || true
    if [[ ! -f "$TEST_DIR/state/ai/escape.json" ]]; then
        echo -e "${GREEN}✓${NC} No session file written outside the session dir"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Session file escaped the session dir"
        ((TESTS_FAILED++)) || true
    fi

    ((TESTS_RUN++)) || true
    if ai_session_delete "../escape" >/dev/null 2>&1; then
        echo -e "${RED}✗${NC} ai_session_delete accepted '../escape'"
        ((TESTS_FAILED++)) || true
    else
        echo -e "${GREEN}✓${NC} ai_session_delete rejects '../' session names"
        ((TESTS_PASSED++)) || true
    fi
}

# ─────────────────────────────────────────────────────────────────
# Tests: ai_call round-trip with a stubbed claude binary
# ─────────────────────────────────────────────────────────────────

test_claude_stub_roundtrip() {
    echo ""
    echo "Test: ai_call round-trip with stubbed claude client"

    if ! command -v jq &>/dev/null; then
        ((TESTS_RUN++)) || true
        echo -e "${YELLOW}⊘${NC} Skipping: jq not available"
        return 0
    fi

    local stub_uuid="11111111-1111-1111-1111-111111111111"

    # Stub 'claude' binary: records its args, returns fixed JSON
    local stub_dir="$TEST_DIR/stub-bin"
    local args_log="$TEST_DIR/claude-args.log"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/claude" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$args_log"
echo '{"result":"stub response","session_id":"$stub_uuid"}'
EOF
    chmod +x "$stub_dir/claude"

    # Point the global AI config at the sandbox session dir
    cat > "$TEST_DIR/config/ai/agent.conf" << EOF
AI_DEFAULT_CLIENT="claude"
AI_DEFAULT_AGENT="assistant"
AI_FALLBACK_CLIENT="claude"
AI_SESSION_DIR="$TEST_DIR/state/ai/sessions"
AI_ENABLED=true
EOF

    # First call: named session with no stored client id
    local out
    out=$(PATH="$stub_dir:$PATH" bash -c "
        source '$TEST_DIR/lib/ai/agent.sh'
        ai_call --session roundtrip 'hello world'
    " 2>/dev/null || true)

    assert_contains "$out" "stub response" "ai_call returns the stub response"

    ((TESTS_RUN++)) || true
    if [[ -f "$args_log" ]] && ! grep -q -- '--resume' "$args_log"; then
        echo -e "${GREEN}✓${NC} First call does not pass --resume"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} First call passed --resume (or the stub never ran)"
        ((TESTS_FAILED++)) || true
    fi

    local stored
    stored=$(jq -r '.client_session_id // empty' \
        "$TEST_DIR/state/ai/sessions/roundtrip.json" 2>/dev/null || echo "")
    assert_equals "$stub_uuid" "$stored" "Client session_id stored after first call"

    # The exchange is recorded, and 'md' works as an export format alias
    local exported
    exported=$(bash -c "
        source '$TEST_DIR/lib/ai/session.sh'
        ai_session_export roundtrip md
    " 2>/dev/null || echo "")
    assert_contains "$exported" "hello world" "Session export (md) contains the recorded prompt"

    # Second call: must resume with the stored UUID
    : > "$args_log"
    PATH="$stub_dir:$PATH" bash -c "
        source '$TEST_DIR/lib/ai/agent.sh'
        ai_call --session roundtrip 'again'
    " >/dev/null 2>&1 || true

    ((TESTS_RUN++)) || true
    if grep -q -- '--resume' "$args_log" && grep -q "$stub_uuid" "$args_log"; then
        echo -e "${GREEN}✓${NC} Second call resumes with the stored client UUID"
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}✗${NC} Second call did not resume the stored session"
        ((TESTS_FAILED++)) || true
    fi
}

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────

main() {
    echo "═══════════════════════════════════════════════════════════════════"
    echo " PowOS Test Suite: AI Agent System"
    echo "═══════════════════════════════════════════════════════════════════"

    # Setup
    setup

    # File structure tests
    test_ai_files_exist
    test_client_files_exist
    test_config_files_exist

    # Helpers tests
    test_helpers_source
    test_helpers_functions
    test_file_parsing_structured
    test_file_parsing_multiple
    test_code_block_extraction

    # Session tests
    test_session_source
    test_session_functions
    test_session_create
    test_session_list

    # Config tests
    test_agent_config_load
    test_agent_base_config
    test_agent_configs_source_cleanly

    # Client tests
    test_client_base_source
    test_client_claude_source

    # Shell-option safety
    test_sourcing_does_not_change_shell_opts
    test_increment_crash_class

    # Name validation (path traversal)
    test_agent_name_validation
    test_session_name_validation

    # Client round-trip with stubbed claude binary
    test_claude_stub_roundtrip

    # Teardown
    teardown

    # Summary
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo " Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
    echo "═══════════════════════════════════════════════════════════════════"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
