#!/usr/bin/env bash
# build-iso.sh - Build a bootable PowOS raw disk image from the Containerfile
#
# PRIMARY STORY: install PowOS to disk as a daily-driver that dual-boots Windows.
# Both build modes produce a RAW DISK IMAGE you flash to a USB; booting it is
# non-destructive (nothing is installed until you run `powos install` and confirm
# a target). Neither mode RAM-boots by default — RAM boot is an opt-in
# (`powos ramboot enable`). Flash the image, boot it, run `powos install`.
#
# This script:
# 1. Builds the PowOS container image
# 2. Uses bootc-image-builder to create a bootable disk image (raw-efi)
# 3. Outputs to build/output/powos.raw
#
# Usage:
#   ./build/build-iso.sh              # Build the PowOS image (default) — boots
#                                     #   normally, run `powos install` to install
#   ./build/build-iso.sh installer-usb # LEAN INSTALLER raw: boots STRAIGHT into
#                                     #   the guided install wizard (fastest path)
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
# Lean installer VARIANT (POWOS_INSTALLER=1): a separate image + raw that boots
# straight into the guided install wizard. This is the fastest path to an
# install-to-disk; the default image installs too, just from a full desktop.
INSTALLER_IMAGE_NAME="localhost/powos-installer:latest"
INSTALLER_RAW_NAME="powos-installer.raw"

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

# The commit this build's source snapshot came from. Baked into the image at
# /var/lib/powos/.powos-src-commit (see Containerfile) so `powos self pull` knows
# its TRUE base and never has to blindly reset to master. "unknown" when not in a
# git checkout (e.g. a tarball build).
powos_src_commit() {
    git -C "$POWOS_ROOT" rev-parse HEAD 2>/dev/null || echo unknown
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

    # Ensure the vendored upstream bazzite/ (system_files) is present — the
    # Containerfile COPYs it and the handheld device overlays read from it.
    # bazzite/ is gitignored, so a fresh checkout needs this bootstrap.
    log_step "Vendoring upstream bazzite (system_files)"
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vendor-bazzite.sh"
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
        --build-arg "POWOS_SRC_COMMIT=$(powos_src_commit)" \
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

    # bootc-image-builder writes the fresh image to a known path under the
    # output dir (image/disk.raw). Do NOT use a recursive find here - it can
    # pick up a stale artifact from a previous run.
    local raw_file="${OUTPUT_DIR}/image/disk.raw"

    if [[ -f "$raw_file" ]]; then
        mv "$raw_file" "${OUTPUT_DIR}/${RAW_NAME}"
        log_success "Raw image ready: ${OUTPUT_DIR}/${RAW_NAME}"
    else
        log_error "Expected raw image not found: $raw_file"
        log_error "Check ${OUTPUT_DIR}/raw-build.log for details"
        exit 1
    fi
}

# NOTE: The Anaconda installer-ISO path (bootc-image-builder --type anaconda-iso,
# which auto-wipes the target disk) was REMOVED in the scope-B streamline. The
# canonical install path is `powos install` → install-system, booted from the
# image built here. The git history retains the old build_installer_iso() if it
# is ever needed again.

# ─────────────────────────────────────────────────────────────────
# Lean installer VARIANT (POWOS_INSTALLER=1)
# Builds a container that does NOT ramboot and boots straight into the guided
# install wizard (powos.install=1), then a raw-efi disk image from it. Flashed
# to a USB, it boots → wizard on tty1 → install to disk. No live-USB apparatus,
# no first-boot self-completion. Keeps the default live path untouched.
# ─────────────────────────────────────────────────────────────────
build_installer_container() {
    log_step "Step 1/3: Building LEAN INSTALLER container image (POWOS_INSTALLER=1)"

    cd "$POWOS_ROOT"

    log "Building installer variant from Containerfile..."
    log "This image has NO ramboot kargs and boots straight to the wizard"

    local base_arg=()
    if [[ -n "${POWOS_BASE_IMAGE:-}" ]]; then
        log "Using custom base image: ${POWOS_BASE_IMAGE}"
        base_arg=(--build-arg "BASE_IMAGE=${POWOS_BASE_IMAGE}")
    fi

    if podman build \
        -f Containerfile \
        -t "$INSTALLER_IMAGE_NAME" \
        --layers \
        --build-arg "POWOS_INSTALLER=1" \
        --build-arg "POWOS_SRC_COMMIT=$(powos_src_commit)" \
        "${base_arg[@]}" \
        . 2>&1 | tee "${OUTPUT_DIR}/installer-build.log"; then
        log_success "Installer container image built: $INSTALLER_IMAGE_NAME"
    else
        log_error "Installer container build failed - see ${OUTPUT_DIR}/installer-build.log"
        exit 1
    fi
}

build_installer_raw() {
    log_step "Step 2/3: Building lean installer raw disk image (raw-efi)"

    mkdir -p "$OUTPUT_DIR"

    log "Using bootc-image-builder to create the installer raw image..."
    log "Output: ${OUTPUT_DIR}/${INSTALLER_RAW_NAME}"

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
        "$INSTALLER_IMAGE_NAME" 2>&1 | tee "${OUTPUT_DIR}/installer-raw-build.log"; then
        log_success "Installer raw disk image built successfully"
    else
        log_error "Installer raw image build failed - see ${OUTPUT_DIR}/installer-raw-build.log"
        exit 1
    fi

    # bib writes to the same well-known path (image/disk.raw); move it to the
    # installer name immediately so it never collides with a live build.
    local raw_file="${OUTPUT_DIR}/image/disk.raw"

    if [[ -f "$raw_file" ]]; then
        mv "$raw_file" "${OUTPUT_DIR}/${INSTALLER_RAW_NAME}"
        log_success "Installer image ready: ${OUTPUT_DIR}/${INSTALLER_RAW_NAME}"
    else
        log_error "Expected installer raw image not found: $raw_file"
        log_error "Check ${OUTPUT_DIR}/installer-raw-build.log for details"
        exit 1
    fi
}

show_installer_variant_results() {
    log_step "Step 3/3: Build Complete"

    local raw_path="${OUTPUT_DIR}/${INSTALLER_RAW_NAME}"
    local raw_size
    raw_size=$(du -h "$raw_path" 2>/dev/null | cut -f1 || echo "unknown")

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  PowOS Lean Installer Image Built Successfully              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Image File: $raw_path"
    echo "  Size:       $raw_size"
    echo ""
    echo "  This variant boots with NO ramboot straight into the guided install"
    echo "  wizard (powos.install=1). Flash it and boot to install PowOS to disk:"
    echo ""
    echo "    sudo dd if=${raw_path} of=/dev/sdX bs=4M status=progress conv=fsync"
    echo ""
    echo "  Differences from the default image:"
    echo "    • powos.install=1 + systemd.unit=multi-user.target (wizard on tty1)"
    echo "    • powos-firstboot-disk.service masked (no self-completion)"
    echo "  (Neither image RAM-boots by default — that is a `powos ramboot enable` opt-in.)"
    echo ""
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
    echo -e "${GREEN}║  PowOS Image Built Successfully                             ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Image File: $raw_path"
    echo "  Size:       $raw_size"
    echo ""
    echo "  PRIMARY PATH — install PowOS to disk (dual-boot Windows):"
    echo "    1. Flash this image to a USB (below), boot it (non-destructive)"
    echo "    2. Run:  sudo powos install"
    echo "  Nothing is installed unless you run 'powos install' and confirm a target."
    echo ""
    echo "  The image boots a normal desktop (no RAM boot by default). RAM boot is"
    echo "  an opt-in: 'powos ramboot enable'. For a build that jumps STRAIGHT to the"
    echo "  install wizard on boot, use:  ./build/build-iso.sh installer-usb"
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
            --build-arg "BASE_IMAGE=$img" \
            --build-arg "POWOS_SRC_COMMIT=$(powos_src_commit)" --layers . \
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
        --build-arg "POWOS_SRC_COMMIT=$(powos_src_commit)" \
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
        live-usb|full|usb|default|desktop)
            # Default: build the PowOS raw image (raw-efi). Boots a normal desktop
            # (no RAM boot); install to disk with `powos install`.
            check_requirements
            build_container_image
            build_live_usb
            show_live_results
            ;;
        installer|iso)
            # The Anaconda installer-ISO path was removed (scope-B streamline).
            # Use 'installer-usb' for a boot-straight-to-wizard raw image, or the
            # default mode + `powos install`.
            log_error "The Anaconda installer-ISO mode was removed."
            log_error "Use './build/build-iso.sh installer-usb' (boots to the wizard)"
            log_error "or the default mode + 'powos install' after booting."
            exit 1
            ;;
        installer-usb|lean-installer)
            # Lean installer VARIANT: raw image that boots (no ramboot) straight
            # into the guided install wizard. Output: powos-installer.raw
            check_requirements
            build_installer_container
            build_installer_raw
            show_installer_variant_results
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
            echo "  (default)  - Build the PowOS image (raw-efi). Boots a normal"
            echo "               desktop; install to disk with 'powos install'."
            echo "               Output: build/output/powos.raw"
            echo ""
            echo "  installer-usb - Build LEAN INSTALLER raw image (SAFE to flash)"
            echo "               Boots STRAIGHT into the guided install wizard on"
            echo "               tty1. Nothing wiped without confirming a target."
            echo "               Output: build/output/powos-installer.raw"
            echo ""
            echo "  test       - Build container image only (for testing)"
            echo ""
            echo "  PRIMARY workflow (install to disk, dual-boot Windows):"
            echo "    ./build/build-iso.sh              # or: installer-usb"
            echo "    sudo ./build/install-to-usb.sh /dev/sdX"
            echo "    # boot the USB, then:  sudo powos install"
            exit 1
            ;;
    esac
}

main "$@"
