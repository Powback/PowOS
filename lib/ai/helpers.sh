#!/bin/bash
# helpers.sh - Shared AI utilities for PowOS
#
# Common functions used by dev-commands.sh and other AI integrations.
# Source this file to get AI helper functions.

# ═══════════════════════════════════════════════════════════════════
# AI Loading
# ═══════════════════════════════════════════════════════════════════

# Ensure AI system is loaded, source if needed
# Returns 0 if AI is available, 1 if not
ai_ensure_loaded() {
    # Already loaded?
    if declare -f ai_call &>/dev/null; then
        return 0
    fi

    # Try to source it
    if [[ -f /usr/lib/powos/ai/agent.sh ]]; then
        source /usr/lib/powos/ai/agent.sh
        return 0
    elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/agent.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/agent.sh"
        return 0
    elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/../ai/agent.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/../ai/agent.sh"
        return 0
    fi

    return 1
}

# ═══════════════════════════════════════════════════════════════════
# Response Parsing
# ═══════════════════════════════════════════════════════════════════

# Validate an AI-emitted file path before writing under a target dir.
# Rejects absolute paths, Windows drive/UNC forms, and any '..' component
# so a marker like '--- ../../../.bashrc ---' cannot escape the target dir.
_ai_safe_rel_path() {
    local p="$1"

    [[ -n "$p" ]] || return 1
    [[ "$p" == /* ]] && return 1        # absolute
    [[ "$p" == *":"* ]] && return 1     # drive letter / scheme
    [[ "$p" == *"\\"* ]] && return 1    # backslash separators

    local part
    local IFS='/'
    for part in $p; do
        [[ "$part" == ".." ]] && return 1
    done

    return 0
}

# Write one parsed file under target_dir, refusing unsafe paths.
# Usage: _ai_write_parsed_file <target_dir> <rel_path> <content> <verbose>
# Returns 0 if the file was written, 1 if it was skipped.
_ai_write_parsed_file() {
    local target_dir="$1"
    local rel_path="$2"
    local content="$3"
    local verbose="$4"

    if ! _ai_safe_rel_path "$rel_path"; then
        echo "  ✗ Skipped unsafe file path from AI response: $rel_path" >&2
        return 1
    fi

    local file_path="$target_dir/$rel_path"
    mkdir -p "$(dirname "$file_path")"
    echo "$content" > "$file_path"
    [[ "$verbose" == "true" ]] && echo "  ✓ $rel_path"
    return 0
}

# Parse AI response with file markers and create files
# Usage: ai_parse_files_to_dir "$response" "$target_dir"
# Format expected:
#   --- path/to/file.ext ---
#   (content)
#   --- END ---
# Returns: number of files created
ai_parse_files_to_dir() {
    local response="$1"
    local target_dir="$2"
    local verbose="${3:-true}"

    local files_created=0
    local current_file=""
    local current_content=""
    local in_file=false

    # Process line by line
    while IFS= read -r line; do
        if [[ "$line" =~ ^---[[:space:]]+(.*)[[:space:]]+---$ ]]; then
            # Save previous file if any
            if [[ -n "$current_file" && -n "$current_content" ]]; then
                if _ai_write_parsed_file "$target_dir" "$current_file" "$current_content" "$verbose"; then
                    ((files_created++)) || true || true
                fi
            fi

            local match="${BASH_REMATCH[1]}"
            if [[ "$match" == "END" ]]; then
                current_file=""
                current_content=""
                in_file=false
            else
                current_file="$match"
                current_content=""
                in_file=true
            fi
        elif [[ "$in_file" == true ]]; then
            if [[ -n "$current_content" ]]; then
                current_content="$current_content"$'\n'"$line"
            else
                current_content="$line"
            fi
        fi
    done <<< "$response"

    # Save last file if any
    if [[ -n "$current_file" && -n "$current_content" ]]; then
        if _ai_write_parsed_file "$target_dir" "$current_file" "$current_content" "$verbose"; then
            ((files_created++)) || true || true
        fi
    fi

    echo "$files_created"
}

# Extract content between file markers
# Usage: ai_extract_file "$response" "Dockerfile"
ai_extract_file() {
    local response="$1"
    local filename="$2"

    # Try structured format first: --- filename ---
    local content
    content=$(echo "$response" | sed -n "/--- $filename ---/,/--- END ---/p" | sed '1d;$d')

    if [[ -z "$content" ]]; then
        # Try alternate format: --- filename --- ... --- next ---
        content=$(echo "$response" | sed -n "/--- $filename ---/,/--- [a-zA-Z]/p" | sed '1d;$d')
    fi

    echo "$content"
}

# Extract code from markdown code blocks
# Usage: ai_extract_code_block "$response" "python"
ai_extract_code_block() {
    local response="$1"
    local lang="${2:-}"

    if [[ -n "$lang" ]]; then
        echo "$response" | sed -n "/\`\`\`$lang/,/\`\`\`/p" | sed '1d;$d'
    else
        # Any code block
        echo "$response" | sed -n '/```/,/```/p' | sed '1d;$d'
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Fallback Parsing (when structured format fails)
# ═══════════════════════════════════════════════════════════════════

# Try to extract common files from markdown-style response
# Usage: ai_parse_markdown_to_dir "$response" "$target_dir"
ai_parse_markdown_to_dir() {
    local response="$1"
    local target_dir="$2"
    local verbose="${3:-true}"

    local files_created=0

    # Try to extract README
    local readme_content
    readme_content=$(ai_extract_code_block "$response" "markdown")
    if [[ -n "$readme_content" ]]; then
        echo "$readme_content" > "$target_dir/README.md"
        [[ "$verbose" == "true" ]] && echo "  ✓ README.md"
        ((files_created++)) || true
    fi

    # Try to extract Python
    local python_content
    python_content=$(ai_extract_code_block "$response" "python")
    if [[ -n "$python_content" ]]; then
        mkdir -p "$target_dir/src"
        echo "$python_content" > "$target_dir/src/main.py"
        [[ "$verbose" == "true" ]] && echo "  ✓ src/main.py"
        ((files_created++)) || true
    fi

    # Try to extract JavaScript
    local js_content
    js_content=$(ai_extract_code_block "$response" "javascript")
    if [[ -n "$js_content" ]]; then
        mkdir -p "$target_dir/src"
        echo "$js_content" > "$target_dir/src/index.js"
        [[ "$verbose" == "true" ]] && echo "  ✓ src/index.js"
        ((files_created++)) || true
    fi

    # Try to extract Go
    local go_content
    go_content=$(ai_extract_code_block "$response" "go")
    if [[ -n "$go_content" ]]; then
        mkdir -p "$target_dir/src"
        echo "$go_content" > "$target_dir/src/main.go"
        [[ "$verbose" == "true" ]] && echo "  ✓ src/main.go"
        ((files_created++)) || true
    fi

    # Try to extract Dockerfile
    local dockerfile_content
    dockerfile_content=$(ai_extract_code_block "$response" "dockerfile")
    if [[ -n "$dockerfile_content" ]]; then
        echo "$dockerfile_content" > "$target_dir/Dockerfile"
        [[ "$verbose" == "true" ]] && echo "  ✓ Dockerfile"
        ((files_created++)) || true
    fi

    # Try to extract YAML (docker-compose)
    local yaml_content
    yaml_content=$(ai_extract_code_block "$response" "yaml")
    if [[ -z "$yaml_content" ]]; then
        yaml_content=$(ai_extract_code_block "$response" "yml")
    fi
    if [[ -n "$yaml_content" ]]; then
        echo "$yaml_content" > "$target_dir/docker-compose.yml"
        [[ "$verbose" == "true" ]] && echo "  ✓ docker-compose.yml"
        ((files_created++)) || true
    fi

    # Try to extract bash (build.sh)
    local bash_content
    bash_content=$(ai_extract_code_block "$response" "bash")
    if [[ -n "$bash_content" ]] && echo "$bash_content" | grep -q "build\|BUILD\|compile\|OUTPUT_DIR"; then
        echo "$bash_content" > "$target_dir/build.sh"
        chmod +x "$target_dir/build.sh"
        [[ "$verbose" == "true" ]] && echo "  ✓ build.sh"
        ((files_created++)) || true
    fi

    echo "$files_created"
}

# ═══════════════════════════════════════════════════════════════════
# Combined Parser
# ═══════════════════════════════════════════════════════════════════

# Parse AI response, trying structured format first, then markdown fallback
# Usage: ai_response_to_files "$response" "$target_dir"
ai_response_to_files() {
    local response="$1"
    local target_dir="$2"
    local verbose="${3:-true}"

    # Try structured format first
    local files_created
    files_created=$(ai_parse_files_to_dir "$response" "$target_dir" "$verbose")

    # If no files from structured, try markdown fallback
    if [[ "$files_created" -eq 0 ]]; then
        [[ "$verbose" == "true" ]] && echo "  Trying markdown format..."
        files_created=$(ai_parse_markdown_to_dir "$response" "$target_dir" "$verbose")
    fi

    echo "$files_created"
}
