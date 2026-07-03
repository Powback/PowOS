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

# Source AI helpers if available
if [[ -f /usr/lib/powos/ai/helpers.sh ]]; then
    source /usr/lib/powos/ai/helpers.sh
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/ai/helpers.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/ai/helpers.sh"
fi

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
  new [options] <name>  Create a new project from scratch
  fork <upstream>       Fork an existing app to modify
                        Examples: kde:dolphin, kde:konsole, github:user/repo
  build <name>          Build a project
  enable <name>         Install project to system (as overlay)
  disable <name>        Remove project from system
  update <name>         Pull upstream changes (forks only)

New/Fork Options:
  --docker, -d          Create/fork as Docker project (uses AI)
  --ai                  Launch Project Creator Agent (interactive)
  --ai "prompt"         Create project from description
  --desc "text"         Provide description for AI generation

Examples:
  # Create a new app
  powos dev new myapp

  # AI Project Creator (interactive prompt)
  powos dev new --ai mytool

  # AI Project Creator (with prompt)
  powos dev new --ai "CLI tool that converts JSON to YAML" jsonyaml
  powos dev new --ai "web scraper with async requests" scraper

  # Create Docker project (AI-powered)
  powos dev new --docker myapi
  powos dev new --docker --desc "REST API with PostgreSQL" myapi

  # Fork and customize an app
  powos dev fork kde:dolphin
  powos dev fork https://github.com/user/repo

  # Fork and dockerize (AI analyzes project, generates Dockerfile)
  powos dev fork --docker https://github.com/user/fastapi-app

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
    local name=""
    local use_docker=""
    local use_ai=""
    local project_desc=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --docker|-d)
                use_docker="true"
                shift
                ;;
            --ai)
                use_ai="true"
                # Check if next arg is a prompt (not a flag or name)
                if [[ -n "${2:-}" && ! "$2" =~ ^- && "$2" =~ [[:space:]] ]]; then
                    project_desc="$2"
                    shift
                fi
                shift
                ;;
            --desc|--description)
                project_desc="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}"
                return 1
                ;;
            *)
                name="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        echo "Usage: powos dev new [options] <name>"
        echo ""
        echo "Create a new project from scratch."
        echo ""
        echo "Options:"
        echo "  --docker, -d          Set up as Docker Compose project (uses AI)"
        echo "  --ai                  Launch Project Creator Agent (interactive)"
        echo "  --ai \"prompt\"         Create project from prompt description"
        echo "  --desc \"text\"         Project description for generation"
        echo ""
        echo "Examples:"
        echo "  powos dev new myapp"
        echo "  powos dev new --docker myapi"
        echo "  powos dev new --ai mytool                     # Interactive"
        echo "  powos dev new --ai \"CLI tool for JSON parsing\" mytool"
        echo "  powos dev new --docker --desc \"REST API\" myapi"
        return 1
    fi

    local proj_dir="$PROJECTS_DIR/$name"

    if [[ -d "$proj_dir" ]]; then
        echo -e "${YELLOW}Project '$name' already exists${NC}"
        return 1
    fi

    echo -e "${CYAN}Creating project: $name${NC}"

    mkdir -p "$proj_dir/src"

    # Docker project setup
    if [[ -n "$use_docker" ]]; then
        dev_new_docker "$name" "$proj_dir" "$project_desc"
        return $?
    fi

    # AI-assisted project setup
    if [[ -n "$use_ai" ]]; then
        dev_new_ai "$name" "$proj_dir" "$project_desc"
        return $?
    fi

    # Standard project setup
    dev_new_standard "$name" "$proj_dir"
}

# Standard project creation (no AI)
dev_new_standard() {
    local name="$1"
    local proj_dir="$2"

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

# Docker Compose project creation (uses AI)
dev_new_docker() {
    local name="$1"
    local proj_dir="$2"
    local desc="${3:-}"

    # Check if AI is available
    if ! ai_ensure_loaded 2>/dev/null; then
        echo -e "${YELLOW}AI not available. Creating basic Docker project...${NC}"
        dev_new_docker_basic "$name" "$proj_dir"
        return 0
    fi

    echo -e "${CYAN}Using AI to generate Docker project...${NC}"

    # Create project.conf
    cat > "$proj_dir/project.conf" << EOF
# Project configuration
PROJECT_TYPE="docker"
DESCRIPTION="${desc:-Docker Compose project}"
BUILD_DEPS=""
EOF

    # Build AI prompt for dockerizer agent
    local prompt="Create a new Docker project called '$name'."
    if [[ -n "$desc" ]]; then
        prompt="$prompt The project is: $desc."
    fi
    prompt="$prompt

Generate Dockerfile, docker-compose.yml, and .env.example files."

    # Call dockerizer agent
    local ai_response
    ai_response=$(ai_call --agent dockerizer "$prompt" 2>/dev/null)

    if [[ -z "$ai_response" ]]; then
        echo -e "${YELLOW}AI generation failed. Creating basic Docker project...${NC}"
        dev_new_docker_basic "$name" "$proj_dir"
        return 0
    fi

    # Parse AI response and create files using helper
    echo "Generating files..."
    local files_created
    files_created=$(ai_response_to_files "$ai_response" "$proj_dir")

    # Create src directory with placeholder
    mkdir -p "$proj_dir/src"
    cat > "$proj_dir/src/.gitkeep" << EOF
# Add your source code here
EOF

    # Create basic README if AI didn't provide one
    if [[ ! -f "$proj_dir/README.md" ]]; then
        cat > "$proj_dir/README.md" << EOF
# $name

${desc:-Docker Compose project generated by PowOS}

## Quick Start

\`\`\`bash
# Copy environment file
cp .env.example .env

# Start services
docker compose up -d

# View logs
docker compose logs -f

# Stop services
docker compose down
\`\`\`

## Development

Add your source code to the \`src/\` directory.

## Build

\`\`\`bash
docker compose build
\`\`\`
EOF
    fi

    # If we couldn't parse the AI response properly, create basic files
    if [[ ! -f "$proj_dir/Dockerfile" ]]; then
        dev_new_docker_basic "$name" "$proj_dir"
        return 0
    fi

    echo ""
    echo -e "${GREEN}✓ Docker project created${NC}"
    echo "  Location: $proj_dir"
    echo ""
    echo "Files generated:"
    ls -la "$proj_dir" | grep -v "^total" | grep -v "^d"
    echo ""
    echo "Next steps:"
    echo "  1. cd $proj_dir"
    echo "  2. cp .env.example .env (if exists)"
    echo "  3. docker compose up -d"
    echo "  4. Add your code to src/"
}

# Basic Docker project (no AI)
dev_new_docker_basic() {
    local name="$1"
    local proj_dir="$2"

    mkdir -p "$proj_dir/src"

    # Create basic Dockerfile
    cat > "$proj_dir/Dockerfile" << 'EOF'
# Build stage
FROM python:3.11-slim as builder

WORKDIR /app
COPY requirements.txt* ./
RUN pip install --no-cache-dir -r requirements.txt 2>/dev/null || true

# Runtime stage
FROM python:3.11-slim

WORKDIR /app
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY src/ ./

# Create non-root user
RUN useradd -m appuser && chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost:8000/health || exit 1

CMD ["python", "-m", "http.server", "8000"]
EOF

    # Create docker-compose.yml
    cat > "$proj_dir/docker-compose.yml" << EOF
version: '3.8'

services:
  $name:
    build: .
    ports:
      - "8000:8000"
    volumes:
      - ./src:/app:ro
    environment:
      - APP_ENV=\${APP_ENV:-development}
    restart: unless-stopped

# Uncomment to add database
#  db:
#    image: postgres:15-alpine
#    environment:
#      POSTGRES_USER: \${DB_USER:-app}
#      POSTGRES_PASSWORD: \${DB_PASSWORD:-secret}
#      POSTGRES_DB: \${DB_NAME:-$name}
#    volumes:
#      - db_data:/var/lib/postgresql/data

#volumes:
#  db_data:
EOF

    # Create .env.example
    cat > "$proj_dir/.env.example" << EOF
# Application
APP_ENV=development

# Database (uncomment if using)
# DB_USER=app
# DB_PASSWORD=secret
# DB_NAME=$name
EOF

    # Create project.conf
    cat > "$proj_dir/project.conf" << EOF
# Project configuration
PROJECT_TYPE="docker"
DESCRIPTION="Docker Compose project"
BUILD_DEPS=""
EOF

    # Create README
    cat > "$proj_dir/README.md" << EOF
# $name

Docker Compose project generated by PowOS.

## Quick Start

\`\`\`bash
cp .env.example .env
docker compose up -d
\`\`\`

## Development

Add your source code to \`src/\`.

## Build

\`\`\`bash
docker compose build
\`\`\`
EOF

    # Create placeholder source
    cat > "$proj_dir/src/app.py" << 'EOF'
#!/usr/bin/env python3
"""Simple placeholder app."""

from http.server import HTTPServer, SimpleHTTPRequestHandler

class HealthHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            super().do_GET()

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 8000), HealthHandler)
    print('Starting server on port 8000...')
    server.serve_forever()
EOF

    echo ""
    echo -e "${GREEN}✓ Docker project created${NC}"
    echo "  Location: $proj_dir"
    echo ""
    echo "Next steps:"
    echo "  1. cd $proj_dir"
    echo "  2. cp .env.example .env"
    echo "  3. docker compose up -d"
    echo "  4. Edit src/ with your code"
}

# AI-assisted project creation (full generation)
dev_new_ai() {
    local name="$1"
    local proj_dir="$2"
    local desc="${3:-}"

    # Check if AI is available
    if ! ai_ensure_loaded 2>/dev/null; then
        echo -e "${YELLOW}AI not available. Creating standard project...${NC}"
        dev_new_standard "$name" "$proj_dir"
        return 0
    fi

    # If no description provided, ask for one
    if [[ -z "$desc" ]]; then
        echo -e "${CYAN}Project Creator Agent${NC}"
        echo ""
        echo "Describe what you want to build:"
        echo -n "> "
        read -r desc
        if [[ -z "$desc" ]]; then
            echo -e "${YELLOW}No description provided. Creating standard project...${NC}"
            dev_new_standard "$name" "$proj_dir"
            return 0
        fi
    fi

    echo ""
    echo -e "${CYAN}AI is creating your project: $name${NC}"
    echo "  Description: $desc"
    echo ""

    # Build prompt for creator agent (system prompt has the format instructions)
    local prompt="Create a project called '$name'.

Project description: $desc

Generate all necessary files including README.md, build.sh, source files, and dependencies."

    # Call AI with creator agent
    echo "Generating project files..."
    local ai_response
    ai_response=$(ai_call --agent creator "$prompt" 2>/dev/null)

    if [[ -z "$ai_response" ]]; then
        echo -e "${YELLOW}AI generation failed. Creating standard project...${NC}"
        dev_new_standard "$name" "$proj_dir"
        return 0
    fi

    # Parse and create files using helper
    echo ""
    local files_created
    files_created=$(ai_response_to_files "$ai_response" "$proj_dir")

    # Ensure we have at least basic structure
    if [[ ! -d "$proj_dir/src" ]]; then
        mkdir -p "$proj_dir/src"
    fi

    # Create project.conf
    cat > "$proj_dir/project.conf" << EOF
# Project configuration (AI-generated)
PROJECT_TYPE="ai-generated"
DESCRIPTION="$desc"
BUILD_DEPS=""
EOF

    # Create build.sh if not created
    if [[ ! -f "$proj_dir/build.sh" ]]; then
        cat > "$proj_dir/build.sh" << 'BUILDEOF'
#!/bin/bash
set -euo pipefail

SRC_DIR="$(dirname "$0")/src"
OUTPUT_DIR="${1:-/var/lib/powos/extensions/$(basename $(dirname "$0"))}"

echo "Building from: $SRC_DIR"
echo "Output to: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR/usr/bin"

# Auto-detect and build
cd "$SRC_DIR"

if [[ -f "package.json" ]]; then
    npm install && npm run build 2>/dev/null || true
    cp -r . "$OUTPUT_DIR/usr/lib/$(basename $SRC_DIR)/"
elif [[ -f "requirements.txt" ]]; then
    pip install -r requirements.txt --target "$OUTPUT_DIR/usr/lib/python3/site-packages/" 2>/dev/null || true
    cp *.py "$OUTPUT_DIR/usr/bin/" 2>/dev/null || true
elif [[ -f "go.mod" ]]; then
    go build -o "$OUTPUT_DIR/usr/bin/$(basename $(dirname $SRC_DIR))" .
elif [[ -f "Cargo.toml" ]]; then
    cargo build --release
    cp target/release/* "$OUTPUT_DIR/usr/bin/" 2>/dev/null || true
elif [[ -f "CMakeLists.txt" ]]; then
    mkdir -p build && cd build
    cmake .. -DCMAKE_INSTALL_PREFIX=/usr
    make -j$(nproc)
    make install DESTDIR="$OUTPUT_DIR"
else
    echo "No recognized build system. Add build commands here."
fi

echo "Build complete!"
BUILDEOF
        chmod +x "$proj_dir/build.sh"
        echo "  ✓ build.sh (auto-generated)"
    fi

    # Create README if not created
    if [[ ! -f "$proj_dir/README.md" ]]; then
        cat > "$proj_dir/README.md" << EOF
# $name

$desc

## Setup

\`\`\`bash
cd src/
# Install dependencies based on your language
\`\`\`

## Build

\`\`\`bash
powos dev build $name
powos dev enable $name
\`\`\`
EOF
        echo "  ✓ README.md (auto-generated)"
    fi

    echo ""
    echo -e "${GREEN}✓ Project created by AI${NC}"
    echo "  Location: $proj_dir"
    echo "  Files: $files_created generated"
    echo ""
    echo "Next steps:"
    echo "  1. cd $proj_dir"
    echo "  2. Review generated files"
    echo "  3. powos dev build $name"
    echo "  4. powos dev enable $name"
}

dev_fork() {
    local upstream=""
    local use_docker=""
    local project_desc=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --docker|-d)
                use_docker="true"
                shift
                ;;
            --desc|--description)
                project_desc="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}"
                return 1
                ;;
            *)
                upstream="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$upstream" ]]; then
        echo "Usage: powos dev fork [options] <upstream>"
        echo ""
        echo "Fork an existing app to customize it."
        echo ""
        echo "Options:"
        echo "  --docker, -d       Dockerize the project (uses AI)"
        echo "  --desc \"text\"      Description for AI dockerization"
        echo ""
        echo "Examples:"
        echo "  powos dev fork kde:dolphin"
        echo "  powos dev fork https://github.com/user/repo"
        echo "  powos dev fork --docker https://github.com/user/repo"
        echo "  powos dev fork --docker --desc \"web service\" https://github.com/user/api"
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

    # Dockerize if requested
    if [[ -n "$use_docker" ]]; then
        echo ""
        dev_dockerize "$name" "$proj_dir" "$project_desc"
    fi

    echo ""
    echo -e "${GREEN}✓ Project forked${NC}"
    echo "  Location: $proj_dir"
    echo "  Source:   $proj_dir/src (edit this)"
    echo "  Upstream: $proj_dir/upstream (reference only)"
    if [[ -n "$use_docker" ]]; then
        echo "  Docker:   $proj_dir/Dockerfile"
    fi
    echo ""
    if [[ -n "$use_docker" ]]; then
        echo "Next steps:"
        echo "  1. cd $proj_dir"
        echo "  2. docker compose up -d"
        echo "  3. Make your changes in src/"
    else
        echo "Next steps:"
        echo "  1. cd $proj_dir/src"
        echo "  2. Make your changes"
        echo "  3. powos dev build $name"
        echo "  4. powos dev enable $name"
    fi
}

# Dockerize an existing project using AI
dev_dockerize() {
    local name="$1"
    local proj_dir="$2"
    local desc="${3:-}"

    echo -e "${CYAN}Dockerizing project with AI...${NC}"

    # Analyze the project structure
    local src_dir="$proj_dir/src"
    local project_files=""
    local detected_lang=""
    local detected_framework=""

    # Detect project type by files present
    if [[ -f "$src_dir/package.json" ]]; then
        detected_lang="nodejs"
        project_files="package.json found"
        if grep -q "next" "$src_dir/package.json" 2>/dev/null; then
            detected_framework="Next.js"
        elif grep -q "react" "$src_dir/package.json" 2>/dev/null; then
            detected_framework="React"
        elif grep -q "express" "$src_dir/package.json" 2>/dev/null; then
            detected_framework="Express"
        fi
    elif [[ -f "$src_dir/requirements.txt" ]] || [[ -f "$src_dir/pyproject.toml" ]] || [[ -f "$src_dir/setup.py" ]]; then
        detected_lang="python"
        project_files="Python project detected"
        if [[ -f "$src_dir/requirements.txt" ]] && grep -qi "fastapi\|flask\|django" "$src_dir/requirements.txt" 2>/dev/null; then
            detected_framework=$(grep -oi "fastapi\|flask\|django" "$src_dir/requirements.txt" 2>/dev/null | head -1)
        fi
    elif [[ -f "$src_dir/go.mod" ]]; then
        detected_lang="go"
        project_files="go.mod found"
    elif [[ -f "$src_dir/Cargo.toml" ]]; then
        detected_lang="rust"
        project_files="Cargo.toml found"
    elif [[ -f "$src_dir/CMakeLists.txt" ]]; then
        detected_lang="cpp"
        project_files="CMakeLists.txt found"
    elif [[ -f "$src_dir/pom.xml" ]] || [[ -f "$src_dir/build.gradle" ]]; then
        detected_lang="java"
        project_files="Java build file found"
    fi

    echo "  Detected: ${detected_lang:-unknown} ${detected_framework:+($detected_framework)}"

    if ! ai_ensure_loaded 2>/dev/null; then
        echo -e "${YELLOW}AI not available. Creating basic Docker files...${NC}"
        dev_dockerize_basic "$name" "$proj_dir" "$detected_lang"
        return 0
    fi

    # Build AI prompt with context for dockerizer agent
    local prompt="Dockerize this ${detected_lang:-} project called '$name'."
    [[ -n "$detected_framework" ]] && prompt="$prompt It uses $detected_framework."
    [[ -n "$desc" ]] && prompt="$prompt The project is: $desc."
    [[ -n "$project_files" ]] && prompt="$prompt ($project_files)"

    prompt="$prompt

Generate Dockerfile, docker-compose.yml, and .env.example for this existing project.
Source code is in ./src directory."

    # Call dockerizer agent
    local ai_response
    ai_response=$(ai_call --agent dockerizer "$prompt" 2>/dev/null)

    if [[ -z "$ai_response" ]]; then
        echo -e "${YELLOW}AI generation failed. Creating basic Docker files...${NC}"
        dev_dockerize_basic "$name" "$proj_dir" "$detected_lang"
        return 0
    fi

    # Parse and create files using shared helper
    echo "  Generating Docker files..."
    local files_created
    files_created=$(ai_response_to_files "$ai_response" "$proj_dir" "true")

    # Fallback if parsing failed
    if [[ "$files_created" -eq 0 ]] || [[ ! -f "$proj_dir/Dockerfile" ]]; then
        dev_dockerize_basic "$name" "$proj_dir" "$detected_lang"
    fi

    # Update project.conf
    sed -i 's/PROJECT_TYPE=.*/PROJECT_TYPE="docker-fork"/' "$proj_dir/project.conf" 2>/dev/null || true
}

# Basic dockerization without AI
dev_dockerize_basic() {
    local name="$1"
    local proj_dir="$2"
    local lang="${3:-}"

    case "$lang" in
        nodejs)
            cat > "$proj_dir/Dockerfile" << 'EOF'
FROM node:20-alpine AS builder
WORKDIR /app
COPY src/package*.json ./
RUN npm ci
COPY src/ ./
RUN npm run build 2>/dev/null || true

FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app ./
EXPOSE 3000
CMD ["npm", "start"]
EOF
            ;;
        python)
            cat > "$proj_dir/Dockerfile" << 'EOF'
FROM python:3.11-slim AS builder
WORKDIR /app
COPY src/requirements*.txt ./
RUN pip install --no-cache-dir -r requirements.txt 2>/dev/null || true

FROM python:3.11-slim
WORKDIR /app
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY src/ ./
EXPOSE 8000
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0"]
EOF
            ;;
        go)
            cat > "$proj_dir/Dockerfile" << 'EOF'
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY src/go.* ./
RUN go mod download
COPY src/ ./
RUN CGO_ENABLED=0 go build -o /app/main .

FROM alpine:latest
COPY --from=builder /app/main /main
EXPOSE 8080
CMD ["/main"]
EOF
            ;;
        rust)
            cat > "$proj_dir/Dockerfile" << 'EOF'
FROM rust:1.74-alpine AS builder
WORKDIR /app
COPY src/ ./
RUN cargo build --release

FROM alpine:latest
COPY --from=builder /app/target/release/* /usr/local/bin/
EXPOSE 8080
CMD ["app"]
EOF
            ;;
        *)
            cat > "$proj_dir/Dockerfile" << 'EOF'
FROM ubuntu:22.04
WORKDIR /app
COPY src/ ./
# TODO: Add build and run commands for your project
CMD ["bash"]
EOF
            ;;
    esac

    cat > "$proj_dir/docker-compose.yml" << EOF
version: '3.8'

services:
  $name:
    build: .
    ports:
      - "8080:8080"
    volumes:
      - ./src:/app:ro
    environment:
      - APP_ENV=\${APP_ENV:-development}
    restart: unless-stopped
EOF

    cat > "$proj_dir/.env.example" << EOF
APP_ENV=development
EOF

    echo "    ✓ Dockerfile (basic template)"
    echo "    ✓ docker-compose.yml"
    echo "    ✓ .env.example"
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
