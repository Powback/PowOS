#!/usr/bin/env bash
# build-iso.sh - Build the CANONICAL PowOS installer: an Anaconda GUI ISO.
#
# CANONICAL FLOW (hardware-validated):
#   1. Build the PowOS container image from the Containerfile.
#   2. bootc-image-builder --type anaconda-iso turns it into a proper Anaconda
#      GUI installer ISO.
#   3. Flash the ISO to a USB (Balena Etcher / Rufus / dd), boot it, and the
#      Anaconda graphical installer walks you through disk selection + install
#      (it handles GPU and disks itself, with its own confirmations).
#   4. Reboot into the installed system, then `powos backup pull` to restore
#      your config.
#
# The installer ISO lands at build/output/bootiso/install.iso (and is copied to
# build/output/powos-installer.iso for convenience).
#
# Usage:
#   ./build/build-iso.sh              # DEFAULT: build the Anaconda installer ISO
#   ./build/build-iso.sh installer    # Same (explicit)
#   ./build/build-iso.sh test         # Build the container image only (testing)
#
#   Legacy / experimental modes (NOT the supported install path — see below):
#   ./build/build-iso.sh live-usb        # raw-efi live/RAM-boot USB image
#   ./build/build-iso.sh installer-raw   # lean boots-to-custom-wizard raw image
#   ./build/build-iso.sh variants        # multi-variant base rootfs (live USB)
#
# Requirements:
# - podman (not docker - bootc needs podman)
# - Sufficient disk space (~20GB)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWOS_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${POWOS_ROOT}/build/output"
IMAGE_NAME="localhost/powos:latest"
ISO_NAME="powos-installer.iso"
RAW_NAME="powos.raw"
# LEGACY lean installer VARIANT (POWOS_INSTALLER=1): a separate image + raw that
# boots straight into the custom guided install wizard. Superseded by the
# Anaconda ISO above; kept only as an experimental, opt-in mode.
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
# /usr/lib/powos/.powos-src-commit (see Containerfile) so `powos self pull` knows
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
# Step 2: Build the Anaconda installer ISO (CANONICAL, hardware-validated)
# A proper Anaconda GUI installer: it lets the user pick the target disk and
# confirms before writing — the normal, safe way to install an OS. Nothing is
# touched until the user drives the graphical installer and confirms.
# ─────────────────────────────────────────────────────────────────
build_installer_iso() {
    log_step "Step 2/3: Building Anaconda installer ISO"

    mkdir -p "$OUTPUT_DIR"

    log "Using bootc-image-builder to create the Anaconda GUI installer ISO..."
    log "Output: ${OUTPUT_DIR}/bootiso/install.iso"

    # Matches the hardware-validated invocation exactly: a plain --type
    # anaconda-iso build. Anaconda supplies its own disk selection + install
    # confirmations, so no kickstart/auto-wipe config is layered on.
    if podman run \
        --rm \
        -it \
        --privileged \
        --pull=newer \
        --security-opt label=type:unconfined_t \
        -v "${OUTPUT_DIR}:/output" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        quay.io/centos-bootc/bootc-image-builder:latest \
        --type anaconda-iso \
        --rootfs btrfs \
        --local \
        "$IMAGE_NAME" 2>&1 | tee "${OUTPUT_DIR}/iso-build.log"; then
        log_success "Installer ISO built successfully"
    else
        log_error "ISO build failed - see ${OUTPUT_DIR}/iso-build.log"
        log ""
        log "Common fixes:"
        log "  - Run with sudo/root"
        log "  - Ensure SELinux allows container builds"
        log "  - Check available disk space"
        exit 1
    fi

    # bootc-image-builder writes the ISO to a known path (bootiso/install.iso).
    # Keep it there (canonical), and also COPY it to a friendly name. Avoid a
    # recursive find - it can pick up a stale artifact from a previous run.
    local iso_file="${OUTPUT_DIR}/bootiso/install.iso"

    if [[ -f "$iso_file" ]]; then
        cp -f "$iso_file" "${OUTPUT_DIR}/${ISO_NAME}"
        log_success "Installer ISO ready: $iso_file"
        log_success "Also copied to: ${OUTPUT_DIR}/${ISO_NAME}"
    else
        log_error "Expected installer ISO not found: $iso_file"
        log_error "Check ${OUTPUT_DIR}/iso-build.log for details"
        exit 1
    fi
}

show_installer_results() {
    log_step "Step 3/3: Build Complete"

    local iso_path="${OUTPUT_DIR}/bootiso/install.iso"
    local iso_size
    iso_size=$(du -h "$iso_path" 2>/dev/null | cut -f1 || echo "unknown")

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  PowOS Anaconda Installer ISO Built Successfully           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  ISO File: $iso_path"
    echo "  Copy of:  ${OUTPUT_DIR}/${ISO_NAME}"
    echo "  Size:     $iso_size"
    echo ""
    echo "  Install PowOS to disk:"
    echo "    1. Flash the ISO to a USB (Balena Etcher / Rufus DD mode / dd):"
    echo "         sudo dd if=${iso_path} of=/dev/sdX bs=4M status=progress conv=fsync"
    echo "    2. Boot the USB → the Anaconda GUI installer starts"
    echo "    3. Pick your target disk, confirm, install → reboot"
    echo "    4. In the installed system:  powos backup pull   (restore your config)"
    echo ""
    echo "  Anaconda handles disk selection + GPU itself and confirms before"
    echo "  writing — nothing is touched until you drive the graphical installer."
    echo ""
}

# ─────────────────────────────────────────────────────────────────
# LEGACY: live USB raw disk image (raw-efi)
# Boots a normal disk root (RAM boot is a `powos ramboot enable` opt-in). This
# was the old default; the Anaconda ISO above is now the canonical installer.
# Kept as an experimental, opt-in mode.
# ─────────────────────────────────────────────────────────────────
build_live_usb() {
    log_step "Building live USB disk image (raw-efi) — LEGACY/experimental"

    mkdir -p "$OUTPUT_DIR"

    log "Using bootc-image-builder to create raw disk image..."
    log "This creates a pre-installed bootable image (NOT the Anaconda installer)"
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

# ─────────────────────────────────────────────────────────────────
# LEGACY lean installer VARIANT (POWOS_INSTALLER=1) — EXPERIMENTAL
# Builds a container that does NOT ramboot and boots straight into the custom
# guided install wizard (powos.install=1), then a raw-efi disk image from it.
# Superseded by the Anaconda ISO (the custom wizard has a blind TUI and stalls
# on the GPU). Kept only as an opt-in mode; not the supported install path.
# ─────────────────────────────────────────────────────────────────
build_installer_container() {
    log_step "Building LEAN INSTALLER container image (POWOS_INSTALLER=1) — LEGACY"

    cd "$POWOS_ROOT"

    log "Building installer variant from Containerfile..."
    log "This image has NO ramboot kargs and boots straight to the custom wizard"

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
    log_step "Building lean installer raw disk image (raw-efi) — LEGACY"

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
    log_step "Build Complete"

    local raw_path="${OUTPUT_DIR}/${INSTALLER_RAW_NAME}"
    local raw_size
    raw_size=$(du -h "$raw_path" 2>/dev/null | cut -f1 || echo "unknown")

    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  PowOS Lean Installer Image Built (LEGACY / experimental)   ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Image File: $raw_path"
    echo "  Size:       $raw_size"
    echo ""
    echo "  NOTE: This is the SUPERSEDED custom-wizard path (blind TUI, stalls on"
    echo "  the GPU). The supported installer is the Anaconda ISO:"
    echo "    ./build/build-iso.sh          # → build/output/bootiso/install.iso"
    echo ""
    echo "  This variant boots with NO ramboot straight into the custom install"
    echo "  wizard (powos.install=1). Flash it and boot to install PowOS to disk:"
    echo ""
    echo "    sudo dd if=${raw_path} of=/dev/sdX bs=4M status=progress conv=fsync"
    echo ""
}

# ─────────────────────────────────────────────────────────────────
# LEGACY: Show live-USB results and next steps
# ─────────────────────────────────────────────────────────────────
show_live_results() {
    log_step "Build Complete"

    local raw_path="${OUTPUT_DIR}/${RAW_NAME}"
    local raw_size
    raw_size=$(du -h "$raw_path" 2>/dev/null | cut -f1 || echo "unknown")

    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  PowOS Live USB Image Built (LEGACY / experimental)        ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Image File: $raw_path"
    echo "  Size:       $raw_size"
    echo ""
    echo "  NOTE: The supported way to install PowOS is the Anaconda ISO:"
    echo "    ./build/build-iso.sh          # → build/output/bootiso/install.iso"
    echo ""
    echo "  This raw image boots a normal desktop (no RAM boot by default; RAM boot"
    echo "  is a 'powos ramboot enable' opt-in). Write to USB:"
    echo "    sudo ./build/install-to-usb.sh /dev/sdX"
    echo "  Or manually:"
    echo "    sudo dd if=${raw_path} of=/dev/sdX bs=4M status=progress conv=fsync"
    echo ""
}

# ─────────────────────────────────────────────────────────────────
# LEGACY multi-variant build: produce a base rootfs per GPU variant so ONE USB
# can auto-select the right stack at boot (see docs/MULTI-VARIANT-USB.md).
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
    log_step "Building multiple base variants for one-USB-many-GPUs — LEGACY"
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
    local mode="${1:-installer}"

    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  PowOS Image Builder                                       ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"

    mkdir -p "$OUTPUT_DIR"

    case "$mode" in
        installer|iso|anaconda|default)
            # CANONICAL: build the PowOS image, then the Anaconda GUI installer
            # ISO. Output: build/output/bootiso/install.iso
            check_requirements
            build_container_image
            build_installer_iso
            show_installer_results
            ;;
        live-usb|raw|usb|desktop)
            # LEGACY / experimental: raw-efi live image. Boots a normal desktop
            # (no RAM boot); install to disk with `powos install`.
            check_requirements
            build_container_image
            build_live_usb
            show_live_results
            ;;
        installer-raw|installer-usb|lean-installer)
            # LEGACY / experimental: lean raw image that boots straight into the
            # SUPERSEDED custom install wizard. Output: powos-installer.raw
            check_requirements
            build_installer_container
            build_installer_raw
            show_installer_variant_results
            ;;
        variants|multi)
            # LEGACY / experimental: base rootfs per GPU variant (multi-variant USB).
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
            echo "  (default)  - Build the Anaconda GUI installer ISO (CANONICAL)"
            echo "               Flash it, boot, and Anaconda installs PowOS to disk."
            echo "               Output: build/output/bootiso/install.iso"
            echo "                       build/output/powos-installer.iso (copy)"
            echo ""
            echo "  test       - Build the container image only (for testing)"
            echo ""
            echo "  Legacy / experimental (NOT the supported install path):"
            echo "    live-usb        - raw-efi live/RAM-boot USB image (powos.raw)"
            echo "    installer-raw   - lean boots-to-custom-wizard raw image"
            echo "    variants        - multi-variant base rootfs for a live USB"
            echo ""
            echo "  CANONICAL workflow (install to disk):"
            echo "    ./build/build-iso.sh                       # → install.iso"
            echo "    # flash install.iso → boot → Anaconda GUI installs PowOS"
            echo "    powos backup pull                          # restore your config"
            exit 1
            ;;
    esac
}

main "$@"
