#!/bin/bash
# dev-commands.sh - Unified development system for PowOS
#
# Commands:
#   powos dev list              - List all projects
#   powos dev new <name>        - Create new project
#   powos dev fork <upstream>   - Fork existing app (e.g., kde:dolphin)
#   powos dev build <name>      - Build project
#   powos dev enable <name>     - Install to system
#   powos dev disable <name>    - Remove from system
#   powos dev update <name>     - Pull upstream changes (forks only)

PROJECTS_DIR="${POWOS_ROOT:-/var/lib/powos}/projects"
EXTENSIONS_DIR="${POWOS_ROOT:-/var/lib/powos}/extensions"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

cmd_dev() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        list|ls)
            dev_list "$@"
            ;;
        new)
            dev_new "$@"
            ;;
        fork)
            dev_fork "$@"
            ;;
        build)
            dev_build "$@"
            ;;
        enable)
            dev_enable "$@"
            ;;
        disable)
            dev_disable "$@"
            ;;
        update)
            dev_update "$@"
            ;;
        *)
            dev_help
            ;;
    esac
}

dev_help() {
    cat << 'EOF'
PowOS Development System

Usage: powos dev <command> [options]

Commands:
  list                  List all projects
  new <name>            Create a new project from scratch
  fork <upstream>       Fork an existing app to modify
                        Examples: kde:dolphin, kde:konsole, github:user/repo
  build <name>          Build a project
  enable <name>         Install project to system (as overlay)
  disable <name>        Remove project from system
  update <name>         Pull upstream changes (forks only)

Examples:
  # Create a new app
  powos dev new myapp
  cd /var/lib/powos/projects/myapp/src
  # write your code
  powos dev build myapp
  powos dev enable myapp

  # Fork and customize Dolphin
  powos dev fork kde:dolphin
  cd /var/lib/powos/projects/dolphin/src
  # edit files
  powos dev build dolphin
  powos dev enable dolphin

  # Update forked app with upstream changes
  powos dev update dolphin
EOF
}

dev_list() {
    echo -e "${BOLD}${CYAN}Projects${NC}"
    echo "════════════════════════════════════════"
    echo ""

    mkdir -p "$PROJECTS_DIR"

    local found=0
    for proj in "$PROJECTS_DIR"/*/; do
        local name=$(basename "$proj")
        [[ "$name" == "*" ]] && continue
        found=1

        local conf="$proj/project.conf"
        local type="custom"
        local upstream=""

        if [[ -f "$conf" ]]; then
            source "$conf" 2>/dev/null || true
            type="${PROJECT_TYPE:-custom}"
            upstream="${UPSTREAM_URL:-}"
        fi

        # Check status
        local status="${YELLOW}○${NC}"
        local status_text="not built"
        if [[ -d "$EXTENSIONS_DIR/$name" ]]; then
            status="${GREEN}●${NC}"
            status_text="built"
        fi

        # Check if enabled
        if [[ -L "/var/lib/extensions/$name" ]]; then
            status="${GREEN}★${NC}"
            status_text="enabled"
        fi

        echo -e "  $status $name ($type)"
        [[ -n "$upstream" ]] && echo "      ↳ $upstream"
    done

    if [[ $found -eq 0 ]]; then
        echo "  No projects yet."
        echo ""
        echo "  Create one with:"
        echo "    powos dev new myapp"
        echo "    powos dev fork kde:dolphin"
    fi

    echo ""
    echo "Legend: ${GREEN}★${NC} enabled  ${GREEN}●${NC} built  ${YELLOW}○${NC} not built"
}

dev_new() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        echo "Usage: powos dev new <name>"
        echo ""
        echo "Create a new project from scratch."
        return 1
    fi

    local proj_dir="$PROJECTS_DIR/$name"

    if [[ -d "$proj_dir" ]]; then
        echo -e "${YELLOW}Project '$name' already exists${NC}"
        return 1
    fi

    echo -e "${CYAN}Creating project: $name${NC}"

    mkdir -p "$proj_dir/src"

    # Create project.conf
    cat > "$proj_dir/project.conf" << EOF
# Project configuration
PROJECT_TYPE="custom"
DESCRIPTION="My custom project"
BUILD_DEPS=""
EOF

    # Create default build.sh
    cat > "$proj_dir/build.sh" << 'BUILDEOF'
#!/bin/bash
# Build script for this project
set -euo pipefail

SRC_DIR="$(dirname "$0")/src"
OUTPUT_DIR="${1:-/var/lib/powos/extensions/$(basename $(dirname "$0"))}"

echo "Building from: $SRC_DIR"
echo "Output to: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR/usr/bin"

# TODO: Add your build commands here
# Example for a simple binary:
#   gcc -o "$OUTPUT_DIR/usr/bin/myapp" "$SRC_DIR/main.c"
# Example for cmake:
#   cd "$SRC_DIR" && mkdir -p build && cd build
#   cmake .. -DCMAKE_INSTALL_PREFIX=/usr
#   make && make install DESTDIR="$OUTPUT_DIR"

echo "Build complete!"
BUILDEOF
    chmod +x "$proj_dir/build.sh"

    # Create example source file
    cat > "$proj_dir/src/README.md" << EOF
# $name

Your project source code goes here.

Edit build.sh to define how to compile your project.
EOF

    echo ""
    echo -e "${GREEN}✓ Project created${NC}"
    echo "  Location: $proj_dir"
    echo ""
    echo "Next steps:"
    echo "  1. cd $proj_dir/src"
    echo "  2. Write your code"
    echo "  3. Edit build.sh if needed"
    echo "  4. powos dev build $name"
    echo "  5. powos dev enable $name"
}

dev_fork() {
    local upstream="${1:-}"

    if [[ -z "$upstream" ]]; then
        echo "Usage: powos dev fork <upstream>"
        echo ""
        echo "Fork an existing app to customize it."
        echo ""
        echo "Examples:"
        echo "  powos dev fork kde:dolphin"
        echo "  powos dev fork kde:konsole"
        echo "  powos dev fork https://github.com/user/repo"
        return 1
    fi

    # Parse upstream format
    local name=""
    local url=""
    local type=""

    if [[ "$upstream" == kde:* ]]; then
        # KDE app
        local app="${upstream#kde:}"
        name="$app"
        type="kde"

        # Load KDE config
        local kde_conf="${POWOS_ROOT:-/var/lib/powos}/sources/kde/dev.conf"
        if [[ -f "$kde_conf" ]]; then
            source "$kde_conf"
        fi

        # Determine category
        local category="${KDE_APP_CATEGORIES[$app]:-system}"
        url="${KDE_INVENT_URL:-https://invent.kde.org}/$category/$app.git"

    elif [[ "$upstream" == https://* ]] || [[ "$upstream" == git@* ]]; then
        # Direct URL
        url="$upstream"
        name=$(basename "$upstream" .git)
        type="git"
    else
        echo -e "${RED}Unknown upstream format: $upstream${NC}"
        echo "Use: kde:<app> or https://github.com/..."
        return 1
    fi

    local proj_dir="$PROJECTS_DIR/$name"

    if [[ -d "$proj_dir" ]]; then
        echo -e "${YELLOW}Project '$name' already exists${NC}"
        return 1
    fi

    echo -e "${CYAN}Forking: $upstream${NC}"
    echo "  Name: $name"
    echo "  URL:  $url"
    echo ""

    mkdir -p "$proj_dir"

    # Clone upstream (read-only reference)
    echo "Cloning upstream..."
    git clone --depth 1 "$url" "$proj_dir/upstream"

    # Create src as a copy of upstream
    echo "Creating editable copy..."
    cp -r "$proj_dir/upstream" "$proj_dir/src"
    rm -rf "$proj_dir/src/.git"  # Remove git from src - it's your copy now

    # Create project.conf
    cat > "$proj_dir/project.conf" << EOF
# Project configuration
PROJECT_TYPE="fork"
UPSTREAM_URL="$url"
UPSTREAM_TYPE="$type"
DESCRIPTION="Forked from $upstream"
EOF

    # Add KDE build deps if applicable
    if [[ "$type" == "kde" ]] && [[ -n "${BUILD_DEPS:-}" ]]; then
        echo "BUILD_DEPS=\"$BUILD_DEPS\"" >> "$proj_dir/project.conf"
    fi

    # Create build.sh for KDE apps
    if [[ "$type" == "kde" ]]; then
        cat > "$proj_dir/build.sh" << 'BUILDEOF'
#!/bin/bash
# Build script for KDE app
set -euo pipefail

SRC_DIR="$(dirname "$0")/src"
OUTPUT_DIR="${1:-/var/lib/powos/extensions/$(basename $(dirname "$0"))}"

echo "Building from: $SRC_DIR"
echo "Output to: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR/usr/bin"
mkdir -p "$OUTPUT_DIR/usr/lib64"
mkdir -p "$OUTPUT_DIR/usr/share/applications"

cd "$SRC_DIR"
rm -rf build && mkdir -p build && cd build

cmake .. \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF

make -j$(nproc)
make install DESTDIR="$OUTPUT_DIR"

echo "Build complete!"
BUILDEOF
    else
        # Generic build.sh
        cat > "$proj_dir/build.sh" << 'BUILDEOF'
#!/bin/bash
set -euo pipefail

SRC_DIR="$(dirname "$0")/src"
OUTPUT_DIR="${1:-/var/lib/powos/extensions/$(basename $(dirname "$0"))}"

echo "Building from: $SRC_DIR"
echo "Output to: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR/usr/bin"

cd "$SRC_DIR"

# Try common build systems
if [[ -f "CMakeLists.txt" ]]; then
    rm -rf build && mkdir -p build && cd build
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr
    make -j$(nproc)
    make install DESTDIR="$OUTPUT_DIR"
elif [[ -f "Makefile" ]]; then
    make
    make install PREFIX=/usr DESTDIR="$OUTPUT_DIR"
elif [[ -f "configure" ]]; then
    ./configure --prefix=/usr
    make
    make install DESTDIR="$OUTPUT_DIR"
else
    echo "No recognized build system. Edit build.sh manually."
    exit 1
fi

echo "Build complete!"
BUILDEOF
    fi
    chmod +x "$proj_dir/build.sh"

    echo ""
    echo -e "${GREEN}✓ Project forked${NC}"
    echo "  Location: $proj_dir"
    echo "  Source:   $proj_dir/src (edit this)"
    echo "  Upstream: $proj_dir/upstream (reference only)"
    echo ""
    echo "Next steps:"
    echo "  1. cd $proj_dir/src"
    echo "  2. Make your changes"
    echo "  3. powos dev build $name"
    echo "  4. powos dev enable $name"
}

dev_build() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        echo "Usage: powos dev build <name>"
        return 1
    fi

    local proj_dir="$PROJECTS_DIR/$name"

    if [[ ! -d "$proj_dir" ]]; then
        echo -e "${RED}Project '$name' not found${NC}"
        echo "Create it with: powos dev new $name"
        echo "Or fork with:   powos dev fork kde:$name"
        return 1
    fi

    local conf="$proj_dir/project.conf"
    local build_script="$proj_dir/build.sh"

    if [[ ! -f "$build_script" ]]; then
        echo -e "${RED}No build.sh found${NC}"
        return 1
    fi

    echo -e "${CYAN}Building: $name${NC}"

    # Install build deps
    if [[ -f "$conf" ]]; then
        source "$conf"
        if [[ -n "${BUILD_DEPS:-}" ]]; then
            echo "Installing build dependencies..."
            if command -v dnf &>/dev/null; then
                sudo dnf install -y --skip-unavailable $BUILD_DEPS 2>&1 | tail -3
            fi
            echo ""
        fi
    fi

    # Build
    local output_dir="$EXTENSIONS_DIR/$name"
    mkdir -p "$output_dir"

    bash "$build_script" "$output_dir"

    # Create extension-release for systemd-sysext
    local release_dir="$output_dir/usr/lib/extension-release.d"
    mkdir -p "$release_dir"
    echo "ID=fedora" > "$release_dir/extension-release.$name"

    echo ""
    echo -e "${GREEN}✓ Build complete${NC}"
    echo "  Output: $output_dir"
    echo ""
    echo "Enable with: powos dev enable $name"
}

dev_enable() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        echo "Usage: powos dev enable <name>"
        return 1
    fi

    local ext_dir="$EXTENSIONS_DIR/$name"

    if [[ ! -d "$ext_dir" ]]; then
        echo -e "${RED}Project '$name' not built${NC}"
        echo "Build it first: powos dev build $name"
        return 1
    fi

    echo -e "${CYAN}Enabling: $name${NC}"

    sudo ln -sf "$ext_dir" "/var/lib/extensions/$name" 2>/dev/null || \
        ln -sf "$ext_dir" "/var/lib/extensions/$name"

    if command -v systemd-sysext &>/dev/null; then
        sudo systemd-sysext refresh 2>/dev/null || true
    fi

    echo -e "${GREEN}✓ Enabled${NC}"
    echo "  $name now overrides system version"
}

dev_disable() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        echo "Usage: powos dev disable <name>"
        return 1
    fi

    echo -e "${CYAN}Disabling: $name${NC}"

    sudo rm -f "/var/lib/extensions/$name" 2>/dev/null || \
        rm -f "/var/lib/extensions/$name"

    if command -v systemd-sysext &>/dev/null; then
        sudo systemd-sysext refresh 2>/dev/null || true
    fi

    echo -e "${GREEN}✓ Disabled${NC}"
    echo "  System version restored"
}

dev_update() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        echo "Usage: powos dev update <name>"
        return 1
    fi

    local proj_dir="$PROJECTS_DIR/$name"
    local upstream_dir="$proj_dir/upstream"
    local src_dir="$proj_dir/src"
    local conf="$proj_dir/project.conf"

    if [[ ! -d "$proj_dir" ]]; then
        echo -e "${RED}Project '$name' not found${NC}"
        return 1
    fi

    if [[ ! -d "$upstream_dir" ]]; then
        echo -e "${YELLOW}Project '$name' has no upstream (not a fork)${NC}"
        return 1
    fi

    echo -e "${CYAN}Updating: $name${NC}"

    # Save current changes
    echo "Saving your changes..."
    local backup_dir="$proj_dir/.backup-$(date +%Y%m%d-%H%M%S)"
    cp -r "$src_dir" "$backup_dir"

    # Update upstream
    echo "Fetching upstream changes..."
    cd "$upstream_dir"
    git pull

    # Try to merge
    echo "Applying your changes to new upstream..."
    rm -rf "$src_dir"
    cp -r "$upstream_dir" "$src_dir"
    rm -rf "$src_dir/.git"

    # Try to apply differences
    # (This is simplified - a real implementation might use git merge)
    echo ""
    echo -e "${GREEN}✓ Updated${NC}"
    echo "  Your backup: $backup_dir"
    echo "  New source:  $src_dir"
    echo ""
    echo "If you had changes, you may need to reapply them manually."
    echo "Compare: diff -r $backup_dir $src_dir"
}
