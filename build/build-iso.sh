#!/usr/bin/env bash
# build-iso.sh - Build bootable PowOS live USB image from Containerfile
#
# IMPORTANT: PowOS uses a RAW DISK IMAGE (not an installer ISO) by default.
# The raw image is written directly to a USB drive and boots as a live system.
# NO INSTALLATION OCCURS - the OS runs from RAM, internal drives are untouched.
#
# This script:
# 1. Builds the PowOS container image
# 2. Uses bootc-image-builder to create a bootable disk image (raw-efi)
# 3. Outputs to build/output/powos.raw
#
# Usage:
#   ./build/build-iso.sh              # Build live USB image (default, safe)
#   ./build/build-iso.sh live-usb     # Same as above
#   ./build/build-iso.sh installer    # Build Anaconda installer ISO (ERASES TARGET DISK!)
#   ./build/build-iso.sh test         # Build container only (for testing)
#
# Requirements:
# - podman (not docker - bootc needs podman)
# - Sufficient disk space (~20GB)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWOS_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${POWOS_ROOT}/build/output"
IMAGE_NAME="localhost/powos:latest"
RAW_NAME="powos.raw"
ISO_NAME="powos-installer.iso"

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

    log "Building from Containerfile..."
    log "This pulls bazzite-nvidia (~5GB) and adds PowOS components"

    # Base image is overridable for non-NVIDIA GPUs (see Containerfile ARG).
    local base_arg=()
    if [[ -n "${POWOS_BASE_IMAGE:-}" ]]; then
        log "Using custom base image: ${POWOS_BASE_IMAGE}"
        base_arg=(--build-arg "BASE_IMAGE=${POWOS_BASE_IMAGE}")
    fi

    if podman build \
        -f Containerfile \
        -t "$IMAGE_NAME" \
        --layers \
        "${base_arg[@]}" \
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
# Step 2a: Build live USB raw disk image (DEFAULT - SAFE)
# Creates a pre-installed bootable disk image.
# When written to USB: boots directly, NO installation, internal drives untouched.
# ─────────────────────────────────────────────────────────────────
build_live_usb() {
    log_step "Step 2/3: Building live USB disk image (raw-efi)"

    mkdir -p "$OUTPUT_DIR"

    log "Using bootc-image-builder to create raw disk image..."
    log "This creates a pre-installed bootable image (NOT an installer)"
    log "Output: ${OUTPUT_DIR}/${RAW_NAME}"

    if podman run \
        --rm \
        -it \
        --privileged \
        --pull=newer \
        --security-opt label=type:unconfined_t \
        -v "${OUTPUT_DIR}:/output" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        quay.io/centos-bootc/bootc-image-builder:latest \
        --type raw-efi \
        --rootfs btrfs \
        --local \
        "$IMAGE_NAME" 2>&1 | tee "${OUTPUT_DIR}/raw-build.log"; then
        log_success "Raw disk image built successfully"
    else
        log_error "Raw image build failed - see ${OUTPUT_DIR}/raw-build.log"
        log ""
        log "Common fixes:"
        log "  - Run with sudo/root"
        log "  - Ensure SELinux allows container builds"
        log "  - Check available disk space"
        exit 1
    fi

    # Find the output raw file (bootc-image-builder names it based on image)
    local raw_file
    raw_file=$(find "$OUTPUT_DIR" -name "*.raw" -type f | head -1)

    if [[ -n "$raw_file" ]]; then
        mv "$raw_file" "${OUTPUT_DIR}/${RAW_NAME}"
        log_success "Raw image ready: ${OUTPUT_DIR}/${RAW_NAME}"
    else
        log_error "Raw image file not found in output directory"
        log_error "Check ${OUTPUT_DIR}/raw-build.log for details"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────
# Step 2b: Build Anaconda installer ISO (DANGEROUS - WIPES TARGET DISK)
# WARNING: This creates an installer that will ERASE the target drive!
# The installer auto-runs on boot and wipes ALL PARTITIONS.
# Only use this if you intend to install PowOS permanently to a drive.
# ─────────────────────────────────────────────────────────────────
build_installer_iso() {
    log_step "Step 2/3: Building Anaconda installer ISO"

    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  DANGER: INSTALLER ISO MODE                                ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}║  This creates an INSTALLER, not a live boot image.         ║${NC}"
    echo -e "${RED}║  When booted, it will ERASE the target drive.              ║${NC}"
    echo -e "${RED}║                                                            ║${NC}"
    echo -e "${RED}║  For a safe live USB (recommended), use:                   ║${NC}"
    echo -e "${RED}║    ./build/build-iso.sh live-usb                           ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    read -p "Type 'INSTALL' to confirm you want an installer ISO: " confirm
    if [[ "$confirm" != "INSTALL" ]]; then
        log "Aborted. Use 'live-usb' mode for safe live boot image."
        exit 0
    fi

    mkdir -p "$OUTPUT_DIR"

    log "Using bootc-image-builder to create installer ISO..."
    log "Output: ${OUTPUT_DIR}/${ISO_NAME}"

    if podman run \
        --rm \
        -it \
        --privileged \
        --pull=newer \
        --security-opt label=type:unconfined_t \
        -v "${OUTPUT_DIR}:/output" \
        -v "./build/bootc-config.toml:/config.toml:ro" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        quay.io/centos-bootc/bootc-image-builder:latest \
        --type anaconda-iso \
        --rootfs btrfs \
        --local \
        --config /config.toml \
        "$IMAGE_NAME" 2>&1 | tee "${OUTPUT_DIR}/iso-build.log"; then
        log_success "Installer ISO built successfully"
    else
        log_error "ISO build failed - see ${OUTPUT_DIR}/iso-build.log"
        exit 1
    fi

    # Find the output ISO
    local iso_file
    iso_file=$(find "$OUTPUT_DIR" -name "*.iso" -type f | head -1)

    if [[ -n "$iso_file" ]]; then
        mv "$iso_file" "${OUTPUT_DIR}/${ISO_NAME}"
        log_success "Installer ISO ready: ${OUTPUT_DIR}/${ISO_NAME}"
    else
        log_error "ISO file not found in output directory"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────
# Step 3: Show results and next steps
# ─────────────────────────────────────────────────────────────────
show_live_results() {
    log_step "Step 3/3: Build Complete"

    local raw_path="${OUTPUT_DIR}/${RAW_NAME}"
    local raw_size
    raw_size=$(du -h "$raw_path" 2>/dev/null | cut -f1 || echo "unknown")

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  PowOS Live USB Image Built Successfully                    ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Image File: $raw_path"
    echo "  Size:       $raw_size"
    echo ""
    echo "  SAFE: Booting is non-destructive. The USB boot menu offers:"
    echo "    • PowOS Live         - run from RAM, internal drives untouched (default)"
    echo "    • Install PowOS      - interactive installer (pick disk, dual-boot Windows)"
    echo "  Nothing is installed unless you choose 'Install' and confirm a target."
    echo ""
    echo "  Write to USB drive:"
    echo "    sudo ./build/install-to-usb.sh /dev/sdX"
    echo ""
    echo "  Or manually:"
    echo "    sudo dd if=${raw_path} of=/dev/sdX bs=4M status=progress conv=fsync"
    echo "    sudo ./build/install-to-usb.sh --setup-data-only /dev/sdX"
    echo ""
    echo "  Boot from the USB drive (select in BIOS/UEFI boot menu)"
    echo ""
}

show_installer_results() {
    log_step "Step 3/3: Build Complete"

    local iso_path="${OUTPUT_DIR}/${ISO_NAME}"
    local iso_size
    iso_size=$(du -h "$iso_path" 2>/dev/null | cut -f1 || echo "unknown")

    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  PowOS Installer ISO Built                                 ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  ISO File: $iso_path"
    echo "  Size:     $iso_size"
    echo ""
    echo -e "  ${RED}WARNING: This installer ERASES the target drive when booted!${NC}"
    echo "  Internal drives, SD cards, and other storage will be wiped."
    echo ""
    echo "  Write to USB drive:"
    echo "    sudo dd if=${iso_path} of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "  When booted, Anaconda will install PowOS to the target drive."
    echo ""
}

# ─────────────────────────────────────────────────────────────────
# Multi-variant build: produce a base rootfs per GPU variant so ONE USB can
# auto-select the right stack at boot (see docs/MULTI-VARIANT-USB.md).
# Output: build/output/base-<variant>/  (extracted rootfs, consumed by
# install-to-usb.sh which places them under the USB's layers/base-<variant>/).
#
# Variants default to "nvidia-open main"; override with POWOS_VARIANTS.
# TODO(hw): boot-critical + heavy — validate the produced layout in a VM before
# trusting it. Extracting a bootc rootfs this way is experimental.
# ─────────────────────────────────────────────────────────────────
variant_base_image() {
    case "$1" in
        nvidia-open) echo "ghcr.io/ublue-os/bazzite-nvidia-open:stable" ;;
        nvidia)      echo "ghcr.io/ublue-os/bazzite-nvidia:stable" ;;
        main)        echo "ghcr.io/ublue-os/bazzite:stable" ;;
        *)           return 1 ;;
    esac
}

build_variants() {
    log_step "Building multiple base variants for one-USB-many-GPUs"
    mkdir -p "$OUTPUT_DIR"

    local variants="${POWOS_VARIANTS:-nvidia-open main}"
    log "Variants: $variants"

    local v img cid dest
    for v in $variants; do
        img=$(variant_base_image "$v") || { log_error "Unknown variant: $v"; return 1; }
        log_step "Variant '$v' (base: $img)"

        if ! podman build -f Containerfile -t "localhost/powos-$v" \
            --build-arg "BASE_IMAGE=$img" --layers . \
            2>&1 | tee "${OUTPUT_DIR}/build-$v.log"; then
            log_error "Build failed for variant '$v' — see build-$v.log"
            return 1
        fi

        # Export the built image's rootfs into base-<variant>/.
        dest="${OUTPUT_DIR}/base-$v"
        rm -rf "$dest"; mkdir -p "$dest"
        log "Exporting rootfs → $dest"
        cid=$(podman create "localhost/powos-$v") || { log_error "podman create failed ($v)"; return 1; }
        if podman export "$cid" | tar -x -C "$dest"; then
            log_success "Variant '$v' rootfs ready: $dest"
        else
            log_error "rootfs export failed for '$v'"
            podman rm "$cid" >/dev/null 2>&1 || true
            return 1
        fi
        podman rm "$cid" >/dev/null 2>&1 || true
    done

    echo ""
    log_success "Built variants: $variants"
    echo "  Base rootfs dirs: ${OUTPUT_DIR}/base-*"
    echo "  Write a multi-variant USB with:"
    echo "    sudo ./build/install-to-usb.sh --variants /dev/sdX"
    echo ""
}

# ─────────────────────────────────────────────────────────────────
# Alternative: Build without bootc (for testing)
# ─────────────────────────────────────────────────────────────────
build_test_image() {
    log_step "Building test image (no disk image, container only)"

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
    local mode="${1:-live-usb}"

    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  PowOS Image Builder                                       ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"

    mkdir -p "$OUTPUT_DIR"

    case "$mode" in
        live-usb|full|usb)
            # Default: build a safe live USB image (raw-efi)
            check_requirements
            build_container_image
            build_live_usb
            show_live_results
            ;;
        installer|iso)
            # Dangerous: build an Anaconda installer ISO
            check_requirements
            build_container_image
            build_installer_iso
            show_installer_results
            ;;
        variants|multi)
            # Build a base rootfs per GPU variant for a multi-variant USB.
            check_requirements
            build_variants
            ;;
        test|container)
            check_requirements
            build_test_image
            ;;
        *)
            echo ""
            echo "Usage: $0 [mode]"
            echo ""
            echo "  live-usb   - Build live USB image (DEFAULT, SAFE)"
            echo "               Boots directly, internal drives untouched"
            echo "               Output: build/output/powos.raw"
            echo ""
            echo "  installer  - Build Anaconda installer ISO (DANGEROUS)"
            echo "               WARNING: ERASES target drive on boot!"
            echo "               Output: build/output/powos-installer.iso"
            echo ""
            echo "  test       - Build container image only (for testing)"
            echo ""
            echo "  Recommended workflow:"
            echo "    ./build/build-iso.sh live-usb"
            echo "    sudo ./build/install-to-usb.sh /dev/sdX"
            exit 1
            ;;
    esac
}

main "$@"
