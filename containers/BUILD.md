# PowOS Container Build Guide

This directory contains the build structure for PowOS container images.

## Directory Structure

```
containers/
├── build_files/          # Build scripts (copied from Bazzite)
│   ├── cleanup           # Clean up build artifacts
│   ├── install-kernel    # Install CachyOS kernel
│   ├── install-firmware  # Install firmware packages
│   ├── install-nvidia    # Install NVIDIA drivers
│   ├── ghcurl            # GitHub API curl wrapper
│   ├── dnf5-setopt       # DNF5 configuration helper
│   ├── dnf5-search       # DNF5 search helper
│   ├── image-info        # Generate image metadata
│   ├── build-initramfs   # Build initramfs
│   └── finalize          # Final cleanup
├── system_files/
│   ├── shared/           # Common system files (from bazzite desktop/shared)
│   ├── nvidia/shared/    # NVIDIA-specific system files
│   └── overrides/        # Override files for final image
├── Containerfile.base-common  # Shared base stage
├── Containerfile.mesa         # AMD/Intel GPU variant
├── Containerfile.nvidia       # NVIDIA GPU variant
├── build.sh                   # Build script
├── Justfile                   # Just recipes for common tasks
└── BUILD.md                   # This file
```

## Build Variants

### powos-base-mesa
- **Target GPUs**: AMD and Intel
- **Graphics Stack**: Mesa (Valve-patched version)
- **Compute Support**: ROCm (for AMD GPUs)
- **Best For**: AMD Radeon, Intel Arc/Iris

### powos-base-nvidia
- **Target GPUs**: NVIDIA
- **Graphics Stack**: NVIDIA proprietary drivers
- **Compute Support**: CUDA
- **Container Support**: nvidia-container-toolkit
- **Best For**: NVIDIA GeForce, RTX, Quadro

## Prerequisites

- Podman or Docker
- Fedora 43 base images (pulled automatically)
- Internet connection (for package downloads)
- ~20GB free disk space per variant

## Building Images

### Using the build script

```bash
# Build Mesa variant only
bash build.sh mesa

# Build NVIDIA variant only
bash build.sh nvidia

# Build both variants
bash build.sh all
```

### Using Just (recommended)

```bash
# Build Mesa variant
just build-mesa

# Build NVIDIA variant
just build-nvidia

# Build both
just build-all

# Build with custom Fedora version
just build-fedora 44
```

### Environment Variables

You can customize the build with these environment variables:

```bash
# Fedora version (default: 43)
export FEDORA_VERSION=43

# Architecture (default: x86_64)
export ARCH=x86_64

# Base image (default: kinoite for KDE Plasma)
export BASE_IMAGE_NAME=kinoite

# Image branch (default: stable)
export IMAGE_BRANCH=stable

# Version tag (default: dev)
export VERSION_TAG=1.0.0
```

Example:
```bash
FEDORA_VERSION=44 VERSION_TAG=1.0.0 bash build.sh all
```

## Build Process

The build happens in stages:

### Stage 1: Base Common (Containerfile.base-common)
1. Pull Fedora Kinoite base image
2. Copy system files and build scripts
3. Setup Copr repos and package repositories
4. Install CachyOS kernel
5. Install all firmware (AMD, Intel, NVIDIA)
6. Install Valve's patched Pipewire, Bluez, Xwayland
7. Install Steam, Lutris, gaming tools
8. Configure KDE Plasma desktop
9. Install ublue-os tools and Homebrew

### Stage 2a: Mesa Variant (Containerfile.mesa)
1. Import base-common stage
2. Install Valve's patched Mesa
3. Install ROCm for AMD compute
4. Remove NVIDIA firmware
5. Finalize and validate

### Stage 2b: NVIDIA Variant (Containerfile.nvidia)
1. Import base-common stage
2. Pull NVIDIA drivers from Bazzite
3. Remove AMD ROCm packages
4. Install minimal Mesa (for compatibility)
5. Install NVIDIA proprietary drivers
6. Install nvidia-container-toolkit
7. Finalize and validate

## Testing Images

### Quick test
```bash
# Test Mesa
just test-mesa

# Test NVIDIA
just test-nvidia
```

### Interactive test
```bash
# Mesa
podman run -it --rm powos-base-mesa:latest bash

# NVIDIA
podman run -it --rm powos-base-nvidia:latest bash
```

### Check image sizes
```bash
just sizes
```

## Troubleshooting

### Build fails with "command not found"
Make sure all build scripts in `build_files/` are executable:
```bash
chmod +x build_files/*
```

### Build fails with GitHub API rate limit
Export a GitHub token:
```bash
export GITHUB_TOKEN=your_token_here
```

### Build fails to find system_files
Make sure you've run the setup and copied files from bazzite-fork:
```bash
# Check dependencies
test -d build_files && echo "✓ build_files" || echo "✗ missing"
test -d system_files/shared && echo "✓ shared" || echo "✗ missing"
```

### Out of disk space
Clean up old images:
```bash
just clean-all
```

## Managing Images

### List built images
```bash
just list
# or
podman images | grep powos
```

### Remove images
```bash
# Remove all PowOS images
just clean

# Remove images and build cache
just clean-all
```

### Inspect images
```bash
just inspect-mesa
just inspect-nvidia
```

## Pushing to Registry

```bash
# Push to your registry
just push-mesa ghcr.io/yourusername
just push-nvidia ghcr.io/yourusername

# Push both
just push-all ghcr.io/yourusername
```

## Files Copied from Bazzite

This build structure uses files from the Bazzite fork located at:
`/projects/ML/Private/PowOS/bazzite-fork/`

### Copied directories:
- `build_files/` → All build scripts
- `system_files/desktop/shared/` → `system_files/shared/`
- `system_files/nvidia/shared/` → `system_files/nvidia/shared/`
- `system_files/overrides/` → `system_files/overrides/`

## Known Issues and Missing Pieces

### Secrets
The build expects a `GITHUB_TOKEN` secret for API rate limiting. You can:
1. Export it as an environment variable
2. Pass it with `--secret id=GITHUB_TOKEN,env=GITHUB_TOKEN`
3. Omit it (build will work but may hit rate limits)

### External Dependencies
The build pulls these external resources:
- Bazzite kernel: `ghcr.io/bazzite-org/kernel-bazzite`
- NVIDIA drivers: `ghcr.io/bazzite-org/nvidia-drivers`
- Base image: `ghcr.io/ublue-os/kinoite-main`
- Various packages from Copr, RPM Fusion, Terra repos

All are pulled automatically during build.

## Next Steps

After building images:
1. Test basic functionality
2. Create hardware-specific overlays
3. Add PowOS branding/customization
4. Setup CI/CD for automated builds
5. Create installer integration

## Support

For build issues, check:
1. Build logs: Look for error messages
2. Bazzite documentation: https://docs.bazzite.gg
3. Container lint output: `bootc container lint`
4. System requirements: Ensure adequate disk space and memory
