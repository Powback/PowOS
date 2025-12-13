#!/usr/bin/env bash
# build-iso.sh - Build bootable PowOS ISO from Containerfile.base
#
# This script:
# 1. Builds the PowOS container image
# 2. Uses bootc-image-builder to create a bootable ISO
# 3. Outputs to build/output/powos.iso
#
# Requirements:
# - podman (not docker - bootc needs podman)
# - Sufficient disk space (~20GB)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWOS_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${POWOS_ROOT}/build/output"
IMAGE_NAME="localhost/powos:latest"
ISO_NAME="powos.iso"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log() { echo -e "${BLUE}[build-iso]${NC} $*"; }
log_success() { echo -e "${GREEN}[build-iso]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[build-iso]${NC} $*"; }
log_error() { echo -e "${RED}[build-iso]${NC} $*" >&2; }

log_step() {
    echo ""
    echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}  $*${NC}"
    echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
}

# ─────────────────────────────────────────────────────────────────
# Check requirements
# ─────────────────────────────────────────────────────────────────
check_requirements() {
    log_step "Checking requirements"

    local missing=()

    if ! command -v podman &>/dev/null; then
        missing+=("podman")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Install with: dnf install ${missing[*]}"
        exit 1
    fi

    # Check disk space (need ~20GB)
    local available_gb
    available_gb=$(df -BG "$POWOS_ROOT" | tail -1 | awk '{print $4}' | tr -d 'G')
    if [[ $available_gb -lt 20 ]]; then
        log_warn "Low disk space: ${available_gb}GB available (20GB recommended)"
    fi

    log_success "Requirements met"
}

# ─────────────────────────────────────────────────────────────────
# Step 1: Build the PowOS container image
# ─────────────────────────────────────────────────────────────────
build_container_image() {
    log_step "Step 1/3: Building PowOS container image"

    cd "$POWOS_ROOT"

    log "Building from Containerfile.base..."
    log "This pulls bazzite-nvidia (~5GB) and adds PowOS components"

    if podman build \
        -f Containerfile \
        -t "$IMAGE_NAME" \
        --layers \
        . 2>&1 | tee "${OUTPUT_DIR}/container-build.log"; then
        log_success "Container image built: $IMAGE_NAME"
    else
        log_error "Container build failed - see ${OUTPUT_DIR}/container-build.log"
        exit 1
    fi

    # Show image size
    local size
    size=$(podman image inspect "$IMAGE_NAME" --format '{{.Size}}' | numfmt --to=iec 2>/dev/null || echo "unknown")
    log "Image size: $size"
}

# ─────────────────────────────────────────────────────────────────
# Step 2: Build bootable ISO using bootc-image-builder
# ─────────────────────────────────────────────────────────────────
build_iso() {
    log_step "Step 2/3: Building bootable ISO"

    mkdir -p "$OUTPUT_DIR"

    log "Using bootc-image-builder to create ISO..."
    log "Output: ${OUTPUT_DIR}/${ISO_NAME}"

    # bootc-image-builder runs as a container itself
    # It takes our container image and produces a bootable ISO
    if podman run \
        --rm \
        -it \
        --privileged \
        --pull=newer \
        --security-opt label=type:unconfined_t \
        -v "${OUTPUT_DIR}:/output" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        quay.io/centos-bootc/bootc-image-builder:latest \
        --type iso \
        --rootfs btrfs \
        --local \
        "$IMAGE_NAME" 2>&1 | tee "${OUTPUT_DIR}/iso-build.log"; then
        log_success "ISO built successfully"
    else
        log_error "ISO build failed - see ${OUTPUT_DIR}/iso-build.log"
        log ""
        log "Common fixes:"
        log "  - Run with sudo/root"
        log "  - Ensure SELinux allows container builds"
        log "  - Check available disk space"
        exit 1
    fi

    # Find the output ISO (bootc-image-builder names it based on image)
    local iso_file
    iso_file=$(find "$OUTPUT_DIR" -name "*.iso" -type f | head -1)

    if [[ -n "$iso_file" ]]; then
        # Rename to our standard name
        mv "$iso_file" "${OUTPUT_DIR}/${ISO_NAME}"
        log_success "ISO ready: ${OUTPUT_DIR}/${ISO_NAME}"
    else
        log_error "ISO file not found in output directory"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────
# Step 3: Show results and next steps
# ─────────────────────────────────────────────────────────────────
show_results() {
    log_step "Step 3/3: Build Complete"

    local iso_path="${OUTPUT_DIR}/${ISO_NAME}"
    local iso_size
    iso_size=$(du -h "$iso_path" 2>/dev/null | cut -f1 || echo "unknown")

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  PowOS ISO Built Successfully                              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  ISO File: $iso_path"
    echo "  Size:     $iso_size"
    echo ""
    echo "  Next steps:"
    echo ""
    echo "  1. Write to USB drive:"
    echo "     sudo dd if=${iso_path} of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "  2. Or use the install script:"
    echo "     sudo ./build/install-to-usb.sh /dev/sdX"
    echo ""
    echo "  3. Boot from the USB drive"
    echo ""
    echo "  WARNING: This will ERASE the target drive!"
    echo ""
}

# ─────────────────────────────────────────────────────────────────
# Alternative: Build without bootc (for testing)
# ─────────────────────────────────────────────────────────────────
build_test_image() {
    log_step "Building test image (no ISO, container only)"

    cd "$POWOS_ROOT"
    mkdir -p "$OUTPUT_DIR"

    log "Building container image for testing..."

    if podman build \
        -f Containerfile \
        -t "$IMAGE_NAME" \
        . 2>&1 | tee "${OUTPUT_DIR}/container-build.log"; then
        log_success "Test image built: $IMAGE_NAME"
        echo ""
        echo "Run with:"
        echo "  podman run -it --rm --privileged $IMAGE_NAME"
    else
        log_error "Build failed"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────
main() {
    local mode="${1:-full}"

    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  PowOS ISO Builder                                         ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"

    mkdir -p "$OUTPUT_DIR"

    case "$mode" in
        full|iso)
            check_requirements
            build_container_image
            build_iso
            show_results
            ;;
        test|container)
            check_requirements
            build_test_image
            ;;
        *)
            echo "Usage: $0 [full|test]"
            echo ""
            echo "  full  - Build complete bootable ISO (default)"
            echo "  test  - Build container image only (for testing)"
            exit 1
            ;;
    esac
}

main "$@"
