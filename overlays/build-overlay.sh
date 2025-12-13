#!/usr/bin/bash
# Generic systemd-sysext overlay build script for PowOS
# Usage: ./build-overlay.sh <overlay-name>

set -euo pipefail

OVERLAY_NAME="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="${SCRIPT_DIR}/${OVERLAY_NAME}"
BUILD_DIR="${OVERLAY_DIR}/build"
OUTPUT_DIR="${SCRIPT_DIR}/output"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

function log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

function log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

if [[ -z "$OVERLAY_NAME" ]]; then
    log_error "Usage: $0 <overlay-name>"
    log_error "Available overlays:"
    for dir in "${SCRIPT_DIR}"/*/ ; do
        dirname=$(basename "$dir")
        if [[ -d "$dir" && "$dirname" != "output" ]]; then
            echo "  - $dirname"
        fi
    done
    exit 1
fi

if [[ ! -d "$OVERLAY_DIR" ]]; then
    log_error "Overlay directory not found: $OVERLAY_DIR"
    exit 1
fi

log_info "Building overlay: $OVERLAY_NAME"

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/usr/lib/systemd/system"
mkdir -p "$BUILD_DIR/usr/lib/extension-release.d"
mkdir -p "$BUILD_DIR/usr/bin"
mkdir -p "$BUILD_DIR/usr/lib64"
mkdir -p "$BUILD_DIR/usr/share"
mkdir -p "$OUTPUT_DIR"

# Read overlay metadata
OVERLAY_VERSION="1.0.0"
OS_VERSION="43"  # Fedora 43
OVERLAY_TYPE="device-hardware"

if [[ -f "$OVERLAY_DIR/metadata.env" ]]; then
    source "$OVERLAY_DIR/metadata.env"
fi

log_info "Overlay version: $OVERLAY_VERSION"
log_info "Target OS version: Fedora $OS_VERSION"

# Install packages if packages.txt exists
if [[ -f "$OVERLAY_DIR/packages.txt" ]]; then
    log_info "Installing packages from packages.txt..."

    # Create a temporary dnf installroot
    TEMP_ROOT=$(mktemp -d)
    trap "rm -rf $TEMP_ROOT" EXIT

    # Read packages (skip comments and empty lines)
    PACKAGES=$(grep -v '^#' "$OVERLAY_DIR/packages.txt" | grep -v '^$' | tr '\n' ' ')

    if [[ -n "$PACKAGES" ]]; then
        log_info "Packages to install: $PACKAGES"

        # Install packages to temporary root
        dnf install -y --installroot="$TEMP_ROOT" --releasever="$OS_VERSION" $PACKAGES

        # Copy installed files to build directory
        if [[ -d "$TEMP_ROOT/usr" ]]; then
            cp -r "$TEMP_ROOT/usr/"* "$BUILD_DIR/usr/" 2>/dev/null || true
        fi
    fi
fi

# Copy systemd services
if [[ -d "$OVERLAY_DIR/services" ]]; then
    log_info "Copying systemd services..."
    cp -r "$OVERLAY_DIR/services/"* "$BUILD_DIR/usr/lib/systemd/system/" 2>/dev/null || true
fi

# Copy configuration files
if [[ -d "$OVERLAY_DIR/configs" ]]; then
    log_info "Copying configuration files..."

    # Handle /etc configs (these go into /usr/share for sysext)
    if [[ -d "$OVERLAY_DIR/configs/etc" ]]; then
        mkdir -p "$BUILD_DIR/usr/share/${OVERLAY_NAME}/etc"
        cp -r "$OVERLAY_DIR/configs/etc/"* "$BUILD_DIR/usr/share/${OVERLAY_NAME}/etc/" 2>/dev/null || true
    fi

    # Handle /usr configs
    if [[ -d "$OVERLAY_DIR/configs/usr" ]]; then
        cp -r "$OVERLAY_DIR/configs/usr/"* "$BUILD_DIR/usr/" 2>/dev/null || true
    fi
fi

# Copy audio profiles if they exist
if [[ -d "$OVERLAY_DIR/audio-profiles" ]]; then
    log_info "Copying audio profiles..."

    if [[ -d "$OVERLAY_DIR/audio-profiles/pipewire" ]]; then
        mkdir -p "$BUILD_DIR/usr/share/pipewire/hardware-profiles"
        cp -r "$OVERLAY_DIR/audio-profiles/pipewire/"* "$BUILD_DIR/usr/share/pipewire/hardware-profiles/" 2>/dev/null || true
    fi

    if [[ -d "$OVERLAY_DIR/audio-profiles/wireplumber" ]]; then
        mkdir -p "$BUILD_DIR/usr/share/wireplumber/hardware-profiles"
        cp -r "$OVERLAY_DIR/audio-profiles/wireplumber/"* "$BUILD_DIR/usr/share/wireplumber/hardware-profiles/" 2>/dev/null || true
    fi
fi

# Copy binaries
if [[ -d "$OVERLAY_DIR/bin" ]]; then
    log_info "Copying binaries..."
    cp -r "$OVERLAY_DIR/bin/"* "$BUILD_DIR/usr/bin/" 2>/dev/null || true
    chmod +x "$BUILD_DIR/usr/bin/"* 2>/dev/null || true
fi

# Copy libraries
if [[ -d "$OVERLAY_DIR/lib64" ]]; then
    log_info "Copying libraries..."
    cp -r "$OVERLAY_DIR/lib64/"* "$BUILD_DIR/usr/lib64/" 2>/dev/null || true
fi

# Create extension-release file
EXTENSION_RELEASE_FILE="$BUILD_DIR/usr/lib/extension-release.d/extension-release.${OVERLAY_NAME}"

log_info "Creating extension-release file..."
cat > "$EXTENSION_RELEASE_FILE" <<EOF
ID=fedora
VERSION_ID=${OS_VERSION}
SYSEXT_LEVEL=1.0
ARCHITECTURE=x86-64
POWOS_OVERLAY_VERSION=${OVERLAY_VERSION}
POWOS_OVERLAY_TYPE=${OVERLAY_TYPE}
POWOS_OVERLAY_NAME=${OVERLAY_NAME}
EOF

# Add custom extension-release fields if they exist
if [[ -f "$OVERLAY_DIR/extension-release.d/custom-fields" ]]; then
    cat "$OVERLAY_DIR/extension-release.d/custom-fields" >> "$EXTENSION_RELEASE_FILE"
fi

# Build the image using erofs (efficient read-only filesystem)
OUTPUT_IMAGE="$OUTPUT_DIR/${OVERLAY_NAME}.raw"

log_info "Building erofs image..."

# Check if mkfs.erofs is available
if command -v mkfs.erofs &> /dev/null; then
    mkfs.erofs -zlz4hc,9 "$OUTPUT_IMAGE" "$BUILD_DIR"
    log_info "Image built with erofs compression"
elif command -v mksquashfs &> /dev/null; then
    log_warn "mkfs.erofs not found, using squashfs instead"
    mksquashfs "$BUILD_DIR" "$OUTPUT_IMAGE" -comp zstd -Xcompression-level 19
    log_info "Image built with squashfs compression"
else
    log_error "Neither mkfs.erofs nor mksquashfs found. Please install erofs-utils or squashfs-tools."
    exit 1
fi

# Get image size
IMAGE_SIZE=$(du -h "$OUTPUT_IMAGE" | cut -f1)

log_info "Successfully built overlay: $OVERLAY_NAME"
log_info "Output: $OUTPUT_IMAGE"
log_info "Size: $IMAGE_SIZE"

# Create a manifest file
MANIFEST_FILE="$OUTPUT_DIR/${OVERLAY_NAME}.manifest"
cat > "$MANIFEST_FILE" <<EOF
Overlay: ${OVERLAY_NAME}
Version: ${OVERLAY_VERSION}
Built: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Target OS: Fedora ${OS_VERSION}
Type: ${OVERLAY_TYPE}
Size: ${IMAGE_SIZE}

Files included:
EOF

find "$BUILD_DIR" -type f | sed "s|$BUILD_DIR||" | sort >> "$MANIFEST_FILE"

log_info "Manifest created: $MANIFEST_FILE"

# Cleanup build directory
rm -rf "$BUILD_DIR"

log_info "Build complete!"
