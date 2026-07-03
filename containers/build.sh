#!/bin/bash
# PowOS Image Build Script
# Usage: ./build.sh [mesa|nvidia|all]

set -e

# Configuration
FEDORA_VERSION="${FEDORA_VERSION:-43}"
ARCH="${ARCH:-x86_64}"
BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-kinoite}"
IMAGE_VENDOR="powos"
IMAGE_BRANCH="${IMAGE_BRANCH:-stable}"
SHA_HEAD_SHORT=$(git rev-parse --short HEAD 2>/dev/null || echo "dev")
VERSION_TAG="${VERSION_TAG:-dev}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print with color
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to build base-common stage
build_base_common() {
    print_info "Building powos-base-common stage..."

    podman build \
        --target powos-base-common \
        --tag powos-base-common:latest \
        --tag powos-base-common:${VERSION_TAG} \
        --build-arg FEDORA_VERSION=${FEDORA_VERSION} \
        --build-arg ARCH=${ARCH} \
        --build-arg BASE_IMAGE_NAME=${BASE_IMAGE_NAME} \
        --build-arg IMAGE_VENDOR=${IMAGE_VENDOR} \
        --build-arg IMAGE_BRANCH=${IMAGE_BRANCH} \
        --build-arg SHA_HEAD_SHORT=${SHA_HEAD_SHORT} \
        --build-arg VERSION_TAG=${VERSION_TAG} \
        --file Containerfile.base-common \
        .

    print_success "Base-common stage built successfully"
}

# Function to build Mesa variant
build_mesa() {
    print_info "Building powos-base-mesa image..."

    podman build \
        --tag powos-base-mesa:latest \
        --tag powos-base-mesa:${VERSION_TAG} \
        --build-arg FEDORA_VERSION=${FEDORA_VERSION} \
        --build-arg ARCH=${ARCH} \
        --build-arg BASE_IMAGE_NAME=${BASE_IMAGE_NAME} \
        --build-arg IMAGE_NAME=powos-base-mesa \
        --build-arg IMAGE_VENDOR=${IMAGE_VENDOR} \
        --build-arg IMAGE_BRANCH=${IMAGE_BRANCH} \
        --build-arg SHA_HEAD_SHORT=${SHA_HEAD_SHORT} \
        --build-arg VERSION_TAG=${VERSION_TAG} \
        --file Containerfile.mesa \
        .

    print_success "Mesa image built successfully: powos-base-mesa:${VERSION_TAG}"
}

# Function to build NVIDIA variant
build_nvidia() {
    print_info "Building powos-base-nvidia image..."

    podman build \
        --tag powos-base-nvidia:latest \
        --tag powos-base-nvidia:${VERSION_TAG} \
        --build-arg FEDORA_VERSION=${FEDORA_VERSION} \
        --build-arg ARCH=${ARCH} \
        --build-arg BASE_IMAGE_NAME=${BASE_IMAGE_NAME} \
        --build-arg IMAGE_NAME=powos-base-nvidia \
        --build-arg IMAGE_VENDOR=${IMAGE_VENDOR} \
        --build-arg IMAGE_BRANCH=${IMAGE_BRANCH} \
        --build-arg SHA_HEAD_SHORT=${SHA_HEAD_SHORT} \
        --build-arg VERSION_TAG=${VERSION_TAG} \
        --file Containerfile.nvidia \
        .

    print_success "NVIDIA image built successfully: powos-base-nvidia:${VERSION_TAG}"
}

# Parse arguments
TARGET="${1:-all}"

# Validate target
case "$TARGET" in
    mesa|nvidia|all)
        ;;
    *)
        print_error "Invalid target: $TARGET"
        echo "Usage: $0 [mesa|nvidia|all]"
        exit 1
        ;;
esac

# Show build configuration
print_info "===== PowOS Build Configuration ====="
echo "  Target:         $TARGET"
echo "  Fedora Version: $FEDORA_VERSION"
echo "  Architecture:   $ARCH"
echo "  Base Image:     $BASE_IMAGE_NAME"
echo "  Version Tag:    $VERSION_TAG"
echo "  Git SHA:        $SHA_HEAD_SHORT"
print_info "======================================"
echo

# Build base-common (always needed)
build_base_common
echo

# Build target variants
case "$TARGET" in
    mesa)
        build_mesa
        ;;
    nvidia)
        build_nvidia
        ;;
    all)
        build_mesa
        echo
        build_nvidia
        ;;
esac

echo
print_success "===== Build Complete ====="
print_info "Images built:"
case "$TARGET" in
    mesa)
        echo "  - powos-base-mesa:${VERSION_TAG}"
        ;;
    nvidia)
        echo "  - powos-base-nvidia:${VERSION_TAG}"
        ;;
    all)
        echo "  - powos-base-mesa:${VERSION_TAG}"
        echo "  - powos-base-nvidia:${VERSION_TAG}"
        ;;
esac
echo
print_info "To test an image, run:"
print_info "  podman run -it powos-base-mesa:${VERSION_TAG}"
