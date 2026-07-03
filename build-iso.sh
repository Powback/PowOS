#!/bin/bash
# PowOS Live USB Builder - Run this in WSL
# Usage: ./build-iso.sh
#
# Creates a LIVE bootable image (not an installer!)
# The image runs directly from USB and never touches other disks.

set -e

echo "═══════════════════════════════════════════════════════════════"
echo "                  PowOS Live USB Builder"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  This creates a LIVE image that runs from USB."
echo "  It will NOT install to or touch any other disks."
echo ""

cd "$(dirname "$0")"

# Step 1: Build container image (as root so bootc-image-builder can see it)
echo ""
echo "Step 1/2: Building container image..."
sudo podman build -t localhost/powos:latest -f Containerfile .

# Step 2: Create raw disk image (LIVE, not installer!)
echo ""
echo "Step 2/2: Creating live USB image..."
mkdir -p build/output

sudo podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    -v ./build/output:/output \
    -v ./build/bootc-config.toml:/config.toml:ro \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type raw \
    --rootfs btrfs \
    --config /config.toml \
    --local localhost/powos:latest

# Rename output for clarity
if [[ -f build/output/image/disk.raw ]]; then
    mv build/output/image/disk.raw build/output/powos.raw
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "Done! Live USB image: build/output/powos.raw"
    echo ""
    echo "Write to USB with:"
    echo "  Linux:   sudo dd if=build/output/powos.raw of=/dev/sdX bs=4M status=progress"
    echo "  Windows: Use Rufus in DD mode, or balenaEtcher"
    echo "═══════════════════════════════════════════════════════════════"
elif [[ -f build/output/disk.raw ]]; then
    mv build/output/disk.raw build/output/powos.raw
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "Done! Live USB image: build/output/powos.raw"
    echo "═══════════════════════════════════════════════════════════════"
else
    echo ""
    echo "Output files:"
    find build/output -type f -name "*.raw" -o -name "disk*" 2>/dev/null
fi
