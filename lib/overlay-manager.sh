#!/usr/bin/env bash
# overlay-manager.sh - Manage systemd-sysext overlays for PowOS
#
# This script handles building, enabling, and disabling custom binary overlays
# that replace system files without modifying the immutable base OS.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────

# Default POWOS_ROOT to the repo this script lives in (lib/ → repo root).
# When installed to /usr/lib/powos (no sources/ sibling), fall back to the
# bundled source tree. The old $HOME/powos default existed on no known box.
_omgr_self_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -d "$_omgr_self_root/sources" && -d /var/lib/powos/src/sources ]]; then
    _omgr_self_root="/var/lib/powos/src"
fi
POWOS_ROOT="${POWOS_ROOT:-$_omgr_self_root}"
EXTENSIONS_DIR="${POWOS_EXTENSIONS_DIR:-${POWOS_ROOT}/extensions}"
# /var/lib/powos/src is RESET to the baked snapshot on every boot, so built
# extensions there (and the /var/lib/extensions symlinks pointing at them)
# dangle after a reboot. Build into the persistent extension store instead.
if [[ "$EXTENSIONS_DIR" == /var/lib/powos/src/* ]]; then
    EXTENSIONS_DIR="/var/lib/powos/extensions"
fi
SOURCES_DIR="${POWOS_ROOT}/sources"
SYSEXT_DIR="/var/lib/extensions"
LOG_PREFIX="[overlay]"

# OS identification for extension-release file
# Use _any for portable extensions that work across distributions
OS_ID="${POWOS_OS_ID:-_any}"

# Colors
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# ─────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────

log_info() {
    echo -e "${BLUE}${LOG_PREFIX}${NC} $*"
}

log_success() {
    echo -e "${GREEN}${LOG_PREFIX}${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}${LOG_PREFIX}${NC} $*"
}

log_error() {
    echo -e "${RED}${LOG_PREFIX}${NC} $*" >&2
}

log_detail() {
    echo -e "${CYAN}${LOG_PREFIX}${NC}   -> $*" >&2
}

# ─────────────────────────────────────────────────────────────────
# Overlay Building
# ─────────────────────────────────────────────────────────────────

# Create the extension directory structure
create_extension_structure() {
    local name="$1"
    local output_dir="${EXTENSIONS_DIR}/${name}"

    log_detail "Creating extension structure: $output_dir"

    mkdir -p "${output_dir}/usr/bin"
    mkdir -p "${output_dir}/usr/lib"
    mkdir -p "${output_dir}/usr/share"
    mkdir -p "${output_dir}/usr/lib/extension-release.d"

    echo "$output_dir"
}

# Create the extension-release file (required for systemd-sysext)
create_extension_release() {
    local name="$1"
    local output_dir="$2"

    local release_file="${output_dir}/usr/lib/extension-release.d/extension-release.${name}"

    log_detail "Creating extension-release: $release_file"

    cat > "$release_file" << EOF
ID=${OS_ID}
EOF
}

# Build a single overlay component
build_overlay() {
    local name="$1"
    local source_dir="${SOURCES_DIR}/${name}"
    local output_dir

    log_info "Building overlay: $name"

    # Check source exists
    if [[ ! -d "$source_dir" ]]; then
        log_error "Source directory not found: $source_dir"
        return 1
    fi

    # Check for build script
    if [[ ! -f "${source_dir}/build.sh" ]]; then
        log_error "No build.sh found in $source_dir"
        log_detail "Create a build.sh script that compiles your code"
        return 1
    fi

    # Create extension structure
    output_dir=$(create_extension_structure "$name")

    # Run the build script
    log_detail "Running build script..."
    (
        cd "$source_dir"
        export OVERLAY_OUTPUT_DIR="$output_dir"
        export OVERLAY_NAME="$name"
        bash build.sh "$output_dir"
    )

    local build_status=$?

    if [[ $build_status -ne 0 ]]; then
        log_error "Build failed for $name"
        return 1
    fi

    # Create extension-release file
    create_extension_release "$name" "$output_dir"

    # Verify build produced something. Ignore the extension-release file we
    # always create ourselves — a compgen over usr/lib/* would always match
    # extension-release.d and the warning could never fire. (Globs don't
    # expand inside [[ ]], so use find.)
    if [[ -z "$(find "${output_dir}/usr" -type f -not -path '*/extension-release.d/*' -print -quit 2>/dev/null)" ]]; then
        log_warn "Build completed but produced no files under usr/ (empty overlay)"
    fi

    log_success "Built overlay: $name -> $output_dir"
}

# Build all overlays
build_all_overlays() {
    log_info "Building all overlays..."

    local count=0
    local failed=0
    local failed_names=()

    for source_dir in "${SOURCES_DIR}"/*/; do
        if [[ -d "$source_dir" ]]; then
            local name
            name=$(basename "$source_dir")

            if build_overlay "$name"; then
                ((count++)) || true
            else
                ((failed++)) || true
                failed_names+=("$name")
            fi
        fi
    done

    log_info "Built $count overlays, $failed failed"

    # Report which overlays failed and propagate failure
    if [[ $failed -gt 0 ]]; then
        log_warn "Failed overlays:"
        for fname in "${failed_names[@]}"; do
            log_warn "  - $fname"
        done
        log_warn "Check sources/<name>/build.sh and packages.txt for issues"
        # OPTIONAL overlays (Steam Deck / gaming-mode) may fail to build when
        # network / third-party repos are unreachable at build time; the base
        # OS (KDE, login manager, PowOS core) doesn't depend on them, so failing
        # them shouldn't fail the entire image build. Any REQUIRED overlay
        # failing (kde, gpu-*, hello-powos, user-config) still errors out.
        local required=("kde" "gpu-amd" "gpu-intel" "gpu-nvidia" "hello-powos" "user-config" "device-legion-go" "device-rog-ally")
        local required_failed=0 fname r
        for fname in "${failed_names[@]}"; do
            for r in "${required[@]}"; do
                [[ "$fname" == "$r" ]] && required_failed=1 && break
            done
        done
        if (( required_failed )); then
            log_error "One or more REQUIRED overlays failed — aborting build."
            return 1
        fi
        log_warn "All failures were OPTIONAL overlays — continuing."
        return 0
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────
# Overlay Enable/Disable
# ─────────────────────────────────────────────────────────────────

# Enable an overlay (make it active)
enable_overlay() {
    local name="$1"
    local source="${EXTENSIONS_DIR}/${name}"
    local target="${SYSEXT_DIR}/${name}"

    log_info "Enabling overlay: $name"

    # Check if built
    if [[ ! -d "$source" ]]; then
        log_error "Overlay not built: $name"
        log_detail "Run: just build $name"
        return 1
    fi

    # Dev mode simulation
    if [[ "${POWOS_DEV:-}" == "1" ]]; then
        log_detail "(DEV) Would symlink: $source -> $target"
        log_detail "(DEV) Would run: systemd-sysext refresh"
        log_success "Enabled (simulated): $name"
        return 0
    fi

    # Production: create symlink and refresh
    sudo mkdir -p "$SYSEXT_DIR"
    sudo ln -sfn "$source" "$target"

    # Refresh systemd-sysext
    if command -v systemd-sysext &>/dev/null; then
        sudo systemd-sysext refresh
    else
        log_warn "systemd-sysext not available"
    fi

    log_success "Enabled overlay: $name"
}

# Disable an overlay
disable_overlay() {
    local name="$1"
    local target="${SYSEXT_DIR}/${name}"

    log_info "Disabling overlay: $name"

    # Dev mode simulation
    if [[ "${POWOS_DEV:-}" == "1" ]]; then
        log_detail "(DEV) Would remove: $target"
        log_detail "(DEV) Would run: systemd-sysext refresh"
        log_success "Disabled (simulated): $name"
        return 0
    fi

    # Check if enabled
    if [[ ! -e "$target" ]]; then
        log_warn "Overlay not enabled: $name"
        return 0
    fi

    # Remove and refresh
    sudo rm -f "$target"

    if command -v systemd-sysext &>/dev/null; then
        sudo systemd-sysext refresh
    fi

    log_success "Disabled overlay: $name"
}

# Enable all built overlays
enable_all_overlays() {
    log_info "Enabling all overlays..."

    for ext_dir in "${EXTENSIONS_DIR}"/*/; do
        if [[ -d "$ext_dir" ]]; then
            local name
            name=$(basename "$ext_dir")
            enable_overlay "$name"
        fi
    done
}

# Disable all overlays
disable_all_overlays() {
    log_info "Disabling all overlays..."

    if [[ "${POWOS_DEV:-}" == "1" ]]; then
        log_detail "(DEV) Would disable all overlays"
        return 0
    fi

    if [[ -d "$SYSEXT_DIR" ]]; then
        for ext in "${SYSEXT_DIR}"/*/; do
            if [[ -d "$ext" ]] || [[ -L "$ext" ]]; then
                local name
                name=$(basename "$ext")
                disable_overlay "$name"
            fi
        done
    fi
}

# ─────────────────────────────────────────────────────────────────
# Status and Listing
# ─────────────────────────────────────────────────────────────────

# List all overlays with status
list_overlays() {
    echo ""
    echo "PowOS Overlays"
    echo "=============="
    echo ""

    # List sources (available to build)
    echo "Sources (${SOURCES_DIR}):"
    if [[ -d "$SOURCES_DIR" ]]; then
        local has_sources=false
        for source_dir in "${SOURCES_DIR}"/*/; do
            if [[ -d "$source_dir" ]]; then
                has_sources=true
                local name
                name=$(basename "$source_dir")
                local has_build=""
                if [[ -f "${source_dir}/build.sh" ]]; then
                    has_build=" [has build.sh]"
                else
                    has_build=" [missing build.sh]"
                fi
                echo "  - ${name}${has_build}"
            fi
        done
        if [[ "$has_sources" == "false" ]]; then
            echo "  (none)"
        fi
    else
        echo "  (directory not found)"
    fi

    echo ""

    # List built extensions
    echo "Built Extensions (${EXTENSIONS_DIR}):"
    if [[ -d "$EXTENSIONS_DIR" ]]; then
        local has_extensions=false
        for ext_dir in "${EXTENSIONS_DIR}"/*/; do
            if [[ -d "$ext_dir" ]]; then
                has_extensions=true
                local name
                name=$(basename "$ext_dir")

                # Check if enabled
                local status="disabled"
                if [[ -e "${SYSEXT_DIR}/${name}" ]]; then
                    status="enabled"
                fi

                echo "  - ${name} [${status}]"
            fi
        done
        if [[ "$has_extensions" == "false" ]]; then
            echo "  (none built)"
        fi
    else
        echo "  (directory not found)"
    fi

    echo ""

    # Show systemd-sysext status if available
    if command -v systemd-sysext &>/dev/null && [[ "${POWOS_DEV:-}" != "1" ]]; then
        echo "System Extension Status:"
        systemd-sysext status 2>/dev/null || echo "  (not available)"
        echo ""
    fi
}

# Show detailed status of a single overlay
overlay_status() {
    local name="$1"

    echo ""
    echo "Overlay: $name"
    echo "=============="

    # Source status
    local source_dir="${SOURCES_DIR}/${name}"
    if [[ -d "$source_dir" ]]; then
        echo "Source: $source_dir"
        if [[ -f "${source_dir}/build.sh" ]]; then
            echo "Build script: Found"
        else
            echo "Build script: Missing"
        fi
    else
        echo "Source: Not found"
    fi

    # Extension status
    local ext_dir="${EXTENSIONS_DIR}/${name}"
    if [[ -d "$ext_dir" ]]; then
        echo "Extension: $ext_dir"
        echo "Files:"
        find "$ext_dir" -type f | head -20 | while read -r f; do
            echo "  - ${f#${ext_dir}/}"
        done
    else
        echo "Extension: Not built"
    fi

    # Enabled status
    if [[ -e "${SYSEXT_DIR}/${name}" ]]; then
        echo "Status: ENABLED"
    else
        echo "Status: DISABLED"
    fi

    echo ""
}

# ─────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────

# Clean built extensions
clean_overlay() {
    local name="$1"
    local ext_dir="${EXTENSIONS_DIR}/${name}"

    log_info "Cleaning overlay: $name"

    # Disable first if enabled
    if [[ -e "${SYSEXT_DIR}/${name}" ]]; then
        disable_overlay "$name"
    fi

    # Remove built extension
    if [[ -d "$ext_dir" ]]; then
        rm -rf "$ext_dir"
        log_success "Cleaned: $name"
    else
        log_warn "Nothing to clean: $name"
    fi
}

# Clean all built extensions
clean_all_overlays() {
    log_info "Cleaning all overlays..."

    disable_all_overlays

    if [[ -d "$EXTENSIONS_DIR" ]]; then
        rm -rf "${EXTENSIONS_DIR:?}"/*
        log_success "All overlays cleaned"
    fi
}

# ─────────────────────────────────────────────────────────────────
# CLI Interface
# ─────────────────────────────────────────────────────────────────

show_help() {
    cat << EOF
Usage: $(basename "$0") <command> [arguments]

Commands:
    build <name>       Build a single overlay from sources
    build-all          Build all overlays
    enable <name>      Enable an overlay (make active)
    disable <name>     Disable an overlay
    enable-all         Enable all built overlays
    disable-all        Disable all overlays
    list               List all overlays with status
    status <name>      Show detailed status of an overlay
    clean <name>       Remove a built overlay
    clean-all          Remove all built overlays

Environment Variables:
    POWOS_ROOT         PowOS root directory (default: \$HOME/powos)
    POWOS_DEV          Set to 1 for development mode (no actual sysext changes)
    POWOS_OS_ID        OS ID for extension-release (default: _any)

Examples:
    $(basename "$0") build dolphin         # Build dolphin overlay
    $(basename "$0") enable dolphin        # Enable dolphin overlay
    $(basename "$0") list                  # Show all overlays
    $(basename "$0") disable-all           # Disable all overlays

Creating a New Overlay:
    1. Create directory: sources/<name>/
    2. Add your source code and patches
    3. Create build.sh that compiles to \$OVERLAY_OUTPUT_DIR/usr/bin/
    4. Run: $(basename "$0") build <name>
    5. Run: $(basename "$0") enable <name>

EOF
}

# ─────────────────────────────────────────────────────────────────
# Entry Point
# ─────────────────────────────────────────────────────────────────

main() {
    local command="${1:-help}"

    case "$command" in
        build)
            if [[ -z "${2:-}" ]]; then
                log_error "Component name required"
                exit 1
            fi
            build_overlay "$2"
            ;;
        build-all)
            build_all_overlays
            ;;
        enable)
            if [[ -z "${2:-}" ]]; then
                log_error "Component name required"
                exit 1
            fi
            enable_overlay "$2"
            ;;
        disable)
            if [[ -z "${2:-}" ]]; then
                log_error "Component name required"
                exit 1
            fi
            disable_overlay "$2"
            ;;
        enable-all)
            enable_all_overlays
            ;;
        disable-all)
            disable_all_overlays
            ;;
        list)
            list_overlays
            ;;
        status)
            if [[ -z "${2:-}" ]]; then
                log_error "Component name required"
                exit 1
            fi
            overlay_status "$2"
            ;;
        clean)
            if [[ -z "${2:-}" ]]; then
                log_error "Component name required"
                exit 1
            fi
            clean_overlay "$2"
            ;;
        clean-all)
            clean_all_overlays
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
