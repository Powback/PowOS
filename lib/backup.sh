#!/bin/bash
# sync.sh - PowOS State Synchronization System
#
# Manages syncing user state between local USB and remote git repository.
# Supports multi-machine setups with machine-specific branches.
#
# Commands:
#   powos backup status     - Show sync status
#   powos backup push       - Push local changes to remote
#   powos backup pull       - Pull remote changes
#   powos backup setup      - Configure remote repository
#   powos backup export     - Export state to tarball
#   powos backup import     - Import state from tarball
#   powos backup machine    - Machine-specific branch management

set -euo pipefail

POWOS_ROOT="${POWOS_ROOT:-/var/lib/powos}"
POWOS_STATE_DIR="${POWOS_ROOT}/git"
POWOS_CONFIG_DIR="${HOME}/.config/powos"
SYNC_CONFIG="${POWOS_CONFIG_DIR}/sync.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Lock file for safe operations
SYNC_LOCK_FILE="/run/powos/sync.lock"
SYNC_LOCK_TIMEOUT=300  # 5 minutes

# ═══════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════

# Defaults (overridden by sync.conf)
POWOS_SYNC_REMOTE=""
POWOS_SYNC_STRATEGY="single"  # single, machine, manual
POWOS_SYNC_AUTO_PUSH=false
POWOS_SYNC_AUTO_PULL=true
POWOS_SYNC_SOURCES=true
POWOS_SYNC_PROJECTS=true
POWOS_SYNC_CONTAINERS=true
POWOS_SYNC_CONFIG=true
POWOS_SYNC_SESSIONS=false
POWOS_MACHINE_ID=""

load_sync_config() {
    if [[ -f "$SYNC_CONFIG" ]]; then
        source "$SYNC_CONFIG"
    fi

    # Also check system config
    if [[ -f "/etc/powos/sync.conf" ]]; then
        source "/etc/powos/sync.conf"
    fi

    # Auto-detect machine ID if not set
    if [[ -z "$POWOS_MACHINE_ID" ]]; then
        POWOS_MACHINE_ID=$(hostname -s 2>/dev/null || echo "unknown")
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Lock File Safety
# ═══════════════════════════════════════════════════════════════════

# Acquire lock before critical operations
# Returns 0 if lock acquired, 1 if already locked
sync_lock_acquire() {
    local operation="${1:-sync}"
    local lock_dir
    lock_dir=$(dirname "$SYNC_LOCK_FILE")

    mkdir -p "$lock_dir" 2>/dev/null || true

    # Check for stale lock
    if [[ -f "$SYNC_LOCK_FILE" ]]; then
        local lock_time lock_age
        lock_time=$(cat "$SYNC_LOCK_FILE" 2>/dev/null | head -1)
        if [[ -n "$lock_time" ]]; then
            lock_age=$(( $(date +%s) - lock_time ))
            if [[ "$lock_age" -gt "$SYNC_LOCK_TIMEOUT" ]]; then
                echo -e "${YELLOW}Warning: Removing stale lock (${lock_age}s old)${NC}"
                rm -f "$SYNC_LOCK_FILE"
            else
                local lock_op
                lock_op=$(cat "$SYNC_LOCK_FILE" 2>/dev/null | tail -1)
                echo -e "${RED}Error: Another sync operation is in progress${NC}"
                echo "  Operation: $lock_op"
                echo "  Started: ${lock_age}s ago"
                echo ""
                echo "If you're sure no sync is running, remove the lock:"
                echo "  rm $SYNC_LOCK_FILE"
                return 1
            fi
        fi
    fi

    # Create lock file
    echo "$(date +%s)" > "$SYNC_LOCK_FILE"
    echo "$operation" >> "$SYNC_LOCK_FILE"

    # Set trap to release lock on exit
    trap 'sync_lock_release' EXIT INT TERM

    return 0
}

# Release lock after operation completes
sync_lock_release() {
    rm -f "$SYNC_LOCK_FILE" 2>/dev/null || true
    trap - EXIT INT TERM
}

# Check if a previous sync was interrupted (call on boot)
sync_lock_check_stale() {
    if [[ -f "$SYNC_LOCK_FILE" ]]; then
        local lock_time lock_op
        lock_time=$(cat "$SYNC_LOCK_FILE" 2>/dev/null | head -1)
        lock_op=$(cat "$SYNC_LOCK_FILE" 2>/dev/null | tail -1)

        echo -e "${YELLOW}╭─ Warning ─────────────────────────────────────────────╮${NC}"
        echo -e "${YELLOW}│ Previous sync operation may have been interrupted!    │${NC}"
        echo -e "${YELLOW}╰───────────────────────────────────────────────────────╯${NC}"
        echo ""
        echo "  Operation: $lock_op"
        echo "  Lock file: $SYNC_LOCK_FILE"
        echo ""
        echo "This could indicate:"
        echo "  - USB was unplugged during sync"
        echo "  - System crashed during sync"
        echo "  - Power loss during sync"
        echo ""
        echo "Recommended actions:"
        echo "  1. Run 'powos backup status' to check state"
        echo "  2. Run 'powos backup doctor' to verify integrity"
        echo "  3. If everything looks OK, remove the lock:"
        echo "     rm $SYNC_LOCK_FILE"
        echo ""

        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════
# Git Helpers
# ═══════════════════════════════════════════════════════════════════

ensure_git_repo() {
    if [[ ! -d "${POWOS_STATE_DIR}/.git" ]]; then
        echo -e "${YELLOW}Initializing state repository...${NC}"
        mkdir -p "$POWOS_STATE_DIR"
        cd "$POWOS_STATE_DIR"
        git init -q
        git config user.email "powos@$(hostname)"
        git config user.name "PowOS ($(hostname))"

        # Create initial structure
        mkdir -p sources projects containers config

        # Create .syncignore (user-editable)
        create_default_syncignore

        # Generate .gitignore from .syncignore
        generate_gitignore_from_syncignore

        git add -A
        git commit -q -m "Initial PowOS state repository"
        echo -e "${GREEN}State repository initialized${NC}"
    fi

    cd "$POWOS_STATE_DIR"
}

# Create default .syncignore if it doesn't exist
create_default_syncignore() {
    local syncignore="${POWOS_STATE_DIR}/.syncignore"

    [[ -f "$syncignore" ]] && return 0

    cat > "$syncignore" << 'EOF'
# PowOS Sync Ignore
# ─────────────────────────────────────────────────────────────
# Files and directories listed here will NOT be synced to remote.
# Edit this file to customize what gets synced.
#
# Syntax: Same as .gitignore
#   - Lines starting with # are comments
#   - Use * for wildcards
#   - Use ** for recursive matching
#   - Use ! to negate (force include)
# ─────────────────────────────────────────────────────────────

# ══════════════════════════════════════════════════════════════
# SECRETS (never sync these!)
# ══════════════════════════════════════════════════════════════
**/.env
**/.env.*
**/.env.local
**/secrets/
*.key
*.pem
*.p12
*.pfx
**/credentials*
**/*secret*
**/*password*
**/token*
**/.npmrc
**/.pypirc

# ══════════════════════════════════════════════════════════════
# PACKAGE MANAGERS (huge, easily regenerated)
# ══════════════════════════════════════════════════════════════
**/node_modules/
**/bower_components/
**/.pnpm-store/
**/vendor/
**/.bundle/
**/Pods/

# ══════════════════════════════════════════════════════════════
# BUILD ARTIFACTS (regenerated on build)
# ══════════════════════════════════════════════════════════════
**/dist/
**/build/
**/out/
**/target/
**/_build/
**/release/
**/*.o
**/*.so
**/*.dylib
**/*.dll
**/*.a
**/*.lib
**/*.exe
**/*.pyc
**/*.pyo
**/__pycache__/
**/*.class
**/*.jar

# ══════════════════════════════════════════════════════════════
# FRAMEWORK CACHES
# ══════════════════════════════════════════════════════════════
**/.next/
**/.nuxt/
**/.output/
**/.svelte-kit/
**/.vite/
**/.turbo/
**/.parcel-cache/
**/.cache/
**/.sass-cache/
**/.eslintcache
**/.stylelintcache

# ══════════════════════════════════════════════════════════════
# VIRTUAL ENVIRONMENTS
# ══════════════════════════════════════════════════════════════
**/.venv/
**/venv/
**/env/
**/.conda/
**/virtualenv/

# ══════════════════════════════════════════════════════════════
# IDE & EDITOR
# ══════════════════════════════════════════════════════════════
**/.idea/
**/.vscode/
**/*.swp
**/*.swo
**/*~
**/.project
**/.classpath
**/.settings/

# ══════════════════════════════════════════════════════════════
# OS & SYSTEM
# ══════════════════════════════════════════════════════════════
**/.DS_Store
**/Thumbs.db
**/*.tmp
**/*.temp
**/*.log

# ══════════════════════════════════════════════════════════════
# LARGE BINARY FILES
# ══════════════════════════════════════════════════════════════
*.iso
*.img
*.dmg
*.vmdk
*.vdi
*.qcow2
*.ova
*.box
*.tar.gz
*.tar.bz2
*.tar.xz
*.zip
*.rar
*.7z

# ══════════════════════════════════════════════════════════════
# BROWSER PROFILES (huge, constantly changing)
# ══════════════════════════════════════════════════════════════
**/.mozilla/
**/.config/google-chrome/
**/.config/chromium/
**/.config/BraveSoftware/
**/.config/vivaldi/

# ══════════════════════════════════════════════════════════════
# POWOS INTERNAL
# ══════════════════════════════════════════════════════════════
extensions/
state/ai/sessions/

# ══════════════════════════════════════════════════════════════
# YOUR CUSTOM IGNORES (add below)
# ══════════════════════════════════════════════════════════════

EOF
}

# Generate .gitignore from .syncignore
generate_gitignore_from_syncignore() {
    local syncignore="${POWOS_STATE_DIR}/.syncignore"
    local gitignore="${POWOS_STATE_DIR}/.gitignore"

    if [[ -f "$syncignore" ]]; then
        # Copy syncignore to gitignore, add header
        {
            echo "# Auto-generated from .syncignore - do not edit directly"
            echo "# Edit .syncignore instead, then run: powos backup refresh"
            echo ""
            cat "$syncignore"
        } > "$gitignore"
    fi
}

# Refresh .gitignore from .syncignore (called by user)
sync_refresh_ignore() {
    load_sync_config
    ensure_git_repo

    if [[ ! -f "${POWOS_STATE_DIR}/.syncignore" ]]; then
        echo "Creating default .syncignore..."
        create_default_syncignore
    fi

    echo "Regenerating .gitignore from .syncignore..."
    generate_gitignore_from_syncignore

    cd "$POWOS_STATE_DIR"
    git add .gitignore .syncignore
    git commit -m "Update sync ignore rules" 2>/dev/null || true

    echo -e "${GREEN}✓ Ignore rules updated${NC}"
    echo "  Edit: ${POWOS_STATE_DIR}/.syncignore"
}

# Edit .syncignore (opens in editor)
sync_edit_ignore() {
    load_sync_config
    ensure_git_repo

    local syncignore="${POWOS_STATE_DIR}/.syncignore"

    # Create default if doesn't exist
    if [[ ! -f "$syncignore" ]]; then
        echo "Creating default .syncignore..."
        create_default_syncignore
    fi

    # Determine editor
    local editor="${EDITOR:-${VISUAL:-nano}}"

    # If argument provided, add it to .syncignore instead of opening editor
    if [[ -n "${1:-}" ]]; then
        local pattern="$1"
        echo "" >> "$syncignore"
        echo "# Added $(date +%Y-%m-%d)" >> "$syncignore"
        echo "$pattern" >> "$syncignore"
        echo -e "${GREEN}✓ Added to .syncignore:${NC} $pattern"

        # Regenerate gitignore
        generate_gitignore_from_syncignore
        return 0
    fi

    echo -e "${CYAN}Opening .syncignore in $editor...${NC}"
    echo "  File: $syncignore"
    echo ""
    echo "After editing, run 'powos backup refresh' to apply changes."
    echo ""

    # Open editor
    "$editor" "$syncignore"

    # Ask if they want to refresh now
    echo ""
    read -p "Refresh ignore rules now? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        sync_refresh_ignore
    fi
}

get_current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main"
}

get_machine_branch() {
    echo "machine/${POWOS_MACHINE_ID}"
}

has_remote() {
    git remote get-url origin &>/dev/null
}

has_uncommitted() {
    ! git diff --quiet 2>/dev/null || ! git diff --staged --quiet 2>/dev/null
}

has_untracked() {
    [[ -n $(git ls-files --others --exclude-standard 2>/dev/null) ]]
}

local_ahead_count() {
    if has_remote; then
        git rev-list --count origin/$(get_current_branch)..HEAD 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

remote_ahead_count() {
    if has_remote; then
        git rev-list --count HEAD..origin/$(get_current_branch) 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Sync Commands
# ═══════════════════════════════════════════════════════════════════

sync_status() {
    load_sync_config
    ensure_git_repo

    echo -e "${BOLD}╭─ PowOS Sync Status ────────────────────────────────────╮${NC}"
    echo ""

    # Repository info
    echo -e "${CYAN}Repository:${NC}"
    echo "  Location: $POWOS_STATE_DIR"
    echo "  Branch:   $(get_current_branch)"
    echo "  Machine:  $POWOS_MACHINE_ID"
    echo ""

    # Remote status
    echo -e "${CYAN}Remote:${NC}"
    if has_remote; then
        local remote_url
        remote_url=$(git remote get-url origin)
        echo "  URL: $remote_url"

        # Fetch to check remote state
        git fetch -q origin 2>/dev/null || true

        local ahead behind
        ahead=$(local_ahead_count)
        behind=$(remote_ahead_count)

        if [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
            echo -e "  Status: ${GREEN}Up to date${NC}"
        elif [[ "$ahead" -gt 0 && "$behind" -eq 0 ]]; then
            echo -e "  Status: ${YELLOW}$ahead commit(s) to push${NC}"
        elif [[ "$ahead" -eq 0 && "$behind" -gt 0 ]]; then
            echo -e "  Status: ${YELLOW}$behind commit(s) to pull${NC}"
        else
            echo -e "  Status: ${RED}Diverged${NC} ($ahead ahead, $behind behind)"
        fi
    else
        echo -e "  ${YELLOW}No remote configured${NC}"
        echo "  Run: powos backup setup <remote-url>"
    fi
    echo ""

    # Local changes
    echo -e "${CYAN}Local Changes:${NC}"
    if has_uncommitted; then
        echo -e "  ${YELLOW}Uncommitted changes present${NC}"
        git status --short | head -10 | sed 's/^/  /'
    elif has_untracked; then
        echo -e "  ${YELLOW}Untracked files present${NC}"
        git ls-files --others --exclude-standard | head -5 | sed 's/^/  /'
    else
        echo -e "  ${GREEN}Working tree clean${NC}"
    fi
    echo ""

    # Recent commits
    echo -e "${CYAN}Recent Commits:${NC}"
    git log --oneline -5 2>/dev/null | sed 's/^/  /' || echo "  (no commits)"

    echo ""
    echo -e "${BOLD}╰────────────────────────────────────────────────────────╯${NC}"
}

sync_push() {
    load_sync_config
    ensure_git_repo

    local force=false
    local message=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force) force=true; shift ;;
            -m|--message) message="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Acquire lock for safe operation
    if ! sync_lock_acquire "push"; then
        return 1
    fi

    # Check for remote
    if ! has_remote; then
        echo -e "${RED}No remote configured.${NC}"
        echo "Run: powos backup setup <remote-url>"
        sync_lock_release
        return 1
    fi

    # Commit any uncommitted changes
    if has_uncommitted || has_untracked; then
        echo "Committing local changes..."
        git add -A
        local commit_msg="${message:-Auto-sync from $POWOS_MACHINE_ID at $(date -Iseconds)}"
        git commit -m "$commit_msg" || true
    fi

    # Check for divergence
    git fetch -q origin 2>/dev/null || true
    local behind
    behind=$(remote_ahead_count)

    if [[ "$behind" -gt 0 && "$force" != "true" ]]; then
        echo -e "${YELLOW}Remote has $behind new commit(s).${NC}"
        echo "Options:"
        echo "  1. Pull first: powos backup pull"
        echo "  2. Force push: powos backup push --force (loses remote changes!)"
        sync_lock_release
        return 1
    fi

    # Push
    echo "Pushing to remote..."
    local branch
    branch=$(get_current_branch)

    if [[ "$force" == "true" ]]; then
        git push -f origin "$branch"
    else
        git push origin "$branch"
    fi

    sync_lock_release
    echo -e "${GREEN}✓ Pushed successfully${NC}"
}

sync_pull() {
    load_sync_config
    ensure_git_repo

    local strategy="merge"  # merge, rebase, theirs, ours

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --merge) strategy="merge"; shift ;;
            --rebase) strategy="rebase"; shift ;;
            --theirs) strategy="theirs"; shift ;;
            --ours) strategy="ours"; shift ;;
            *) shift ;;
        esac
    done

    # Acquire lock for safe operation
    if ! sync_lock_acquire "pull"; then
        return 1
    fi

    # Check for remote
    if ! has_remote; then
        echo -e "${RED}No remote configured.${NC}"
        sync_lock_release
        return 1
    fi

    # Stash local changes if any
    local had_changes=false
    if has_uncommitted; then
        echo "Stashing local changes..."
        git stash -q
        had_changes=true
    fi

    echo "Fetching from remote..."
    git fetch origin

    local branch
    branch=$(get_current_branch)

    echo "Pulling changes (strategy: $strategy)..."
    case "$strategy" in
        merge)
            git merge "origin/$branch" --no-edit || {
                echo -e "${RED}Merge conflict! Resolve manually.${NC}"
                sync_lock_release
                return 1
            }
            ;;
        rebase)
            git rebase "origin/$branch" || {
                echo -e "${RED}Rebase conflict! Run 'git rebase --abort' to cancel.${NC}"
                sync_lock_release
                return 1
            }
            ;;
        theirs)
            git reset --hard "origin/$branch"
            ;;
        ours)
            echo "Keeping local changes, ignoring remote."
            ;;
    esac

    # Restore stashed changes
    if [[ "$had_changes" == "true" ]]; then
        echo "Restoring local changes..."
        git stash pop -q || {
            echo -e "${YELLOW}Stash conflict - check git stash list${NC}"
        }
    fi

    # Sync to working directories
    sync_to_working_dirs

    sync_lock_release
    echo -e "${GREEN}✓ Pull complete${NC}"
}

sync_to_working_dirs() {
    echo "Syncing to working directories..."

    # Sync sources
    if [[ -d "${POWOS_STATE_DIR}/sources" && "$POWOS_SYNC_SOURCES" == "true" ]]; then
        mkdir -p "${POWOS_ROOT}/sources"
        rsync -a --delete "${POWOS_STATE_DIR}/sources/" "${POWOS_ROOT}/sources/" 2>/dev/null || \
            cp -a "${POWOS_STATE_DIR}/sources/"* "${POWOS_ROOT}/sources/" 2>/dev/null || true
        echo "  ✓ sources"
    fi

    # Sync projects
    if [[ -d "${POWOS_STATE_DIR}/projects" && "$POWOS_SYNC_PROJECTS" == "true" ]]; then
        mkdir -p "${POWOS_ROOT}/projects"
        rsync -a --delete "${POWOS_STATE_DIR}/projects/" "${POWOS_ROOT}/projects/" 2>/dev/null || \
            cp -a "${POWOS_STATE_DIR}/projects/"* "${POWOS_ROOT}/projects/" 2>/dev/null || true
        echo "  ✓ projects"
    fi

    # Sync containers
    if [[ -d "${POWOS_STATE_DIR}/containers" && "$POWOS_SYNC_CONTAINERS" == "true" ]]; then
        mkdir -p "${POWOS_ROOT}/containers"
        rsync -a "${POWOS_STATE_DIR}/containers/" "${POWOS_ROOT}/containers/" 2>/dev/null || \
            cp -a "${POWOS_STATE_DIR}/containers/"* "${POWOS_ROOT}/containers/" 2>/dev/null || true
        echo "  ✓ containers"
    fi

    # Sync config
    if [[ -d "${POWOS_STATE_DIR}/config" && "$POWOS_SYNC_CONFIG" == "true" ]]; then
        mkdir -p "${POWOS_CONFIG_DIR}"
        rsync -a "${POWOS_STATE_DIR}/config/" "${POWOS_CONFIG_DIR}/" 2>/dev/null || \
            cp -a "${POWOS_STATE_DIR}/config/"* "${POWOS_CONFIG_DIR}/" 2>/dev/null || true
        echo "  ✓ config"
    fi
}

sync_from_working_dirs() {
    echo "Collecting from working directories..."

    # Collect sources
    if [[ -d "${POWOS_ROOT}/sources" && "$POWOS_SYNC_SOURCES" == "true" ]]; then
        mkdir -p "${POWOS_STATE_DIR}/sources"
        rsync -a --delete "${POWOS_ROOT}/sources/" "${POWOS_STATE_DIR}/sources/" 2>/dev/null || \
            cp -a "${POWOS_ROOT}/sources/"* "${POWOS_STATE_DIR}/sources/" 2>/dev/null || true
        echo "  ✓ sources"
    fi

    # Collect projects
    if [[ -d "${POWOS_ROOT}/projects" && "$POWOS_SYNC_PROJECTS" == "true" ]]; then
        mkdir -p "${POWOS_STATE_DIR}/projects"
        rsync -a --delete "${POWOS_ROOT}/projects/" "${POWOS_STATE_DIR}/projects/" 2>/dev/null || \
            cp -a "${POWOS_ROOT}/projects/"* "${POWOS_STATE_DIR}/projects/" 2>/dev/null || true
        echo "  ✓ projects"
    fi

    # Collect containers
    if [[ -d "${POWOS_ROOT}/containers" && "$POWOS_SYNC_CONTAINERS" == "true" ]]; then
        mkdir -p "${POWOS_STATE_DIR}/containers"
        rsync -a "${POWOS_ROOT}/containers/" "${POWOS_STATE_DIR}/containers/" 2>/dev/null || \
            cp -a "${POWOS_ROOT}/containers/"* "${POWOS_STATE_DIR}/containers/" 2>/dev/null || true
        echo "  ✓ containers"
    fi

    # Collect config
    if [[ -d "${POWOS_CONFIG_DIR}" && "$POWOS_SYNC_CONFIG" == "true" ]]; then
        mkdir -p "${POWOS_STATE_DIR}/config"
        rsync -a "${POWOS_CONFIG_DIR}/" "${POWOS_STATE_DIR}/config/" 2>/dev/null || \
            cp -a "${POWOS_CONFIG_DIR}/"* "${POWOS_STATE_DIR}/config/" 2>/dev/null || true
        echo "  ✓ config"
    fi
}

sync_setup() {
    local remote_url="${1:-}"

    if [[ -z "$remote_url" ]]; then
        echo "Usage: powos backup setup <remote-url>"
        echo ""
        echo "Example:"
        echo "  powos backup setup git@github.com:username/powos-state.git"
        echo "  powos backup setup https://github.com/username/powos-state.git"
        return 1
    fi

    load_sync_config
    ensure_git_repo

    # Set remote
    if has_remote; then
        echo "Updating remote URL..."
        git remote set-url origin "$remote_url"
    else
        echo "Adding remote..."
        git remote add origin "$remote_url"
    fi

    # Save to config
    mkdir -p "$POWOS_CONFIG_DIR"
    cat > "$SYNC_CONFIG" << EOF
# PowOS Sync Configuration
# Generated: $(date -Iseconds)

# Remote repository
POWOS_SYNC_REMOTE="$remote_url"

# Strategy: single (one branch), machine (per-machine branches), manual
POWOS_SYNC_STRATEGY="single"

# Auto-sync settings
POWOS_SYNC_AUTO_PUSH=false
POWOS_SYNC_AUTO_PULL=true

# What to sync
POWOS_SYNC_SOURCES=true
POWOS_SYNC_PROJECTS=true
POWOS_SYNC_CONTAINERS=true
POWOS_SYNC_CONFIG=true
POWOS_SYNC_SESSIONS=false

# Machine identifier
POWOS_MACHINE_ID="$POWOS_MACHINE_ID"
EOF

    echo -e "${GREEN}✓ Remote configured: $remote_url${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Push initial state:  powos backup push"
    echo "  2. Or pull from remote: powos backup pull --theirs"

    # Try to fetch
    echo ""
    echo "Testing connection..."
    if git fetch origin 2>/dev/null; then
        echo -e "${GREEN}✓ Connection successful${NC}"
    else
        echo -e "${YELLOW}Could not connect to remote.${NC}"
        echo "Check your SSH keys or credentials."
    fi
}

sync_export() {
    local output="${1:-powos-state-$(date +%Y%m%d-%H%M%S).tar.gz}"

    load_sync_config
    ensure_git_repo

    # Collect latest state
    sync_from_working_dirs

    echo "Exporting state to: $output"

    cd "$POWOS_STATE_DIR"
    tar -czf "$output" \
        --exclude='.git' \
        --exclude='*.tmp' \
        .

    local size
    size=$(du -h "$output" | cut -f1)
    echo -e "${GREEN}✓ Exported $size to $output${NC}"
}

sync_import() {
    local input="${1:-}"

    if [[ -z "$input" || ! -f "$input" ]]; then
        echo "Usage: powos backup import <tarball>"
        return 1
    fi

    load_sync_config
    ensure_git_repo

    echo "Importing state from: $input"
    echo -e "${YELLOW}Warning: This will overwrite local state!${NC}"
    read -p "Continue? [y/N] " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        return 0
    fi

    # Extract to state dir
    cd "$POWOS_STATE_DIR"
    tar -xzf "$input"

    # Commit the import
    git add -A
    git commit -m "Import from $(basename "$input")" || true

    # Sync to working dirs
    sync_to_working_dirs

    echo -e "${GREEN}✓ Import complete${NC}"
}

# ═══════════════════════════════════════════════════════════════════
# Machine Management
# ═══════════════════════════════════════════════════════════════════

sync_machine() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        init)
            machine_init "$@"
            ;;
        share)
            machine_share "$@"
            ;;
        pull)
            machine_pull "$@"
            ;;
        *)
            echo "Machine branch management"
            echo ""
            echo "Usage: powos backup machine <command>"
            echo ""
            echo "Commands:"
            echo "  init   Create a branch for this machine"
            echo "  share  Merge current branch to main (share with other machines)"
            echo "  pull   Pull shared changes from main"
            ;;
    esac
}

machine_init() {
    load_sync_config
    ensure_git_repo

    local branch
    branch=$(get_machine_branch)

    echo "Creating machine branch: $branch"

    # Create branch from main
    if git show-ref --verify --quiet "refs/heads/main"; then
        git checkout -b "$branch" main 2>/dev/null || git checkout "$branch"
    elif git show-ref --verify --quiet "refs/heads/master"; then
        git checkout -b "$branch" master 2>/dev/null || git checkout "$branch"
    else
        git checkout -b "$branch" 2>/dev/null || git checkout "$branch"
    fi

    echo -e "${GREEN}✓ Now on branch: $branch${NC}"

    # Update config
    sed -i "s/POWOS_SYNC_STRATEGY=.*/POWOS_SYNC_STRATEGY=\"machine\"/" "$SYNC_CONFIG" 2>/dev/null || true
}

machine_share() {
    load_sync_config
    ensure_git_repo

    local current_branch
    current_branch=$(get_current_branch)

    echo "Sharing changes from $current_branch to main..."

    # Commit any uncommitted changes
    if has_uncommitted || has_untracked; then
        git add -A
        git commit -m "Changes from $POWOS_MACHINE_ID"
    fi

    # Switch to main and merge
    git checkout main 2>/dev/null || git checkout master
    git merge "$current_branch" --no-edit

    # Switch back
    git checkout "$current_branch"

    echo -e "${GREEN}✓ Changes shared to main${NC}"
    echo "Run 'powos backup push' to push main to remote"
}

machine_pull() {
    load_sync_config
    ensure_git_repo

    local current_branch
    current_branch=$(get_current_branch)

    echo "Pulling shared changes from main..."

    # Fetch latest
    if has_remote; then
        git fetch origin
        git checkout main 2>/dev/null || git checkout master
        git pull origin main --no-edit 2>/dev/null || git pull origin master --no-edit || true
    fi

    # Switch back and rebase
    git checkout "$current_branch"
    git rebase main 2>/dev/null || git rebase master || {
        echo -e "${RED}Rebase conflict! Resolve manually.${NC}"
        return 1
    }

    echo -e "${GREEN}✓ Pulled shared changes${NC}"

    # Sync to working dirs
    sync_to_working_dirs
}

# ═══════════════════════════════════════════════════════════════════
# Main Dispatcher
# ═══════════════════════════════════════════════════════════════════

cmd_backup() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        status|st)
            sync_status "$@"
            ;;
        push)
            sync_push "$@"
            ;;
        pull)
            sync_pull "$@"
            ;;
        setup)
            sync_setup "$@"
            ;;
        export)
            sync_export "$@"
            ;;
        import)
            sync_import "$@"
            ;;
        machine)
            sync_machine "$@"
            ;;
        collect)
            load_sync_config
            ensure_git_repo
            sync_from_working_dirs
            ;;
        ignore)
            sync_edit_ignore "$@"
            ;;
        refresh)
            sync_refresh_ignore
            ;;
        help|--help|-h)
            echo "PowOS State Synchronization"
            echo ""
            echo "Usage: powos backup <command> [options]"
            echo ""
            echo "Sync your projects, configs, and state to a git remote for backup"
            echo "and multi-machine access."
            echo ""
            echo "Commands:"
            echo "  status        Show sync status (default)"
            echo "  push          Push local changes to remote"
            echo "  pull          Pull remote changes"
            echo "  setup <url>   Configure remote repository"
            echo "  ignore [pat]  Edit .syncignore (or add pattern)"
            echo "  refresh       Regenerate ignore rules"
            echo "  export [file] Export state to tarball"
            echo "  import <file> Import state from tarball"
            echo "  machine       Machine-specific branch management"
            echo ""
            echo "Push options:"
            echo "  -f, --force   Force push (overwrites remote)"
            echo "  -m, --message Commit message"
            echo ""
            echo "Pull options:"
            echo "  --merge       Merge strategy (default)"
            echo "  --rebase      Rebase strategy"
            echo "  --theirs      Discard local, use remote"
            echo "  --ours        Keep local, ignore remote"
            echo ""
            echo "Examples:"
            echo "  powos backup setup git@github.com:user/state.git"
            echo "  powos backup push -m 'Added neovim config'"
            echo "  powos backup pull --theirs"
            echo "  powos backup ignore 'my-huge-folder/'"
            echo "  powos backup ignore     # Opens editor"
            ;;
        *)
            echo "Unknown command: $action"
            echo "Run 'powos backup help' for usage"
            return 1
            ;;
    esac
}

# Legacy alias for backward compatibility
cmd_sync() {
    cmd_backup "$@"
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_sync "$@"
fi
