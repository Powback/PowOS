# PowOS Build Guide

> **⚠️ HISTORICAL / OUTDATED:** This guide documents a legacy build path
> (`containers/` images and the removed `overlays/` system). The current
> build is the root `Containerfile` via `just build-iso`
> (output: `build/output/powos.raw`), with overlays built from
> `sources/<name>/` by `lib/overlay-manager.sh`.

Quick reference for building PowOS base images.

## Prerequisites

```bash
# Install build tools
sudo dnf install podman buildah git

# Clone repository
git clone https://github.com/powos/powos.git
cd powos
```

## Quick Build Commands

### Build Mesa Image (AMD/Intel GPUs)
```bash
cd containers/
podman build -f Containerfile.mesa \
  -t powos-base-mesa:latest \
  --build-arg FEDORA_VERSION=43 \
  .
```

### Build NVIDIA Image
```bash
cd containers/
podman build -f Containerfile.nvidia \
  -t powos-base-nvidia:latest \
  --build-arg FEDORA_VERSION=43 \
  .
```

## Build Arguments

| Argument | Default | Options |
|----------|---------|---------|
| `FEDORA_VERSION` | `43` | `43`, `42`, etc. |
| `BASE_IMAGE_NAME` | `kinoite` | `kinoite` (KDE), `silverblue` (GNOME) |
| `IMAGE_BRANCH` | `stable` | `stable`, `testing`, `unstable` |
| `ARCH` | `x86_64` | `x86_64`, `aarch64` |

## Build Variants

### KDE Plasma (Default)
```bash
podman build -f Containerfile.mesa -t powos-base-mesa:kde \
  --build-arg BASE_IMAGE_NAME=kinoite
```

### GNOME Desktop
```bash
podman build -f Containerfile.mesa -t powos-base-mesa:gnome \
  --build-arg BASE_IMAGE_NAME=silverblue
```

### Testing Branch
```bash
podman build -f Containerfile.mesa -t powos-base-mesa:testing \
  --build-arg IMAGE_BRANCH=testing
```

## Build Troubleshooting

### Issue: DNF Cache Errors
```bash
# Clear podman cache
podman system prune --all --volumes
```

### Issue: Kernel Not Found
```bash
# Verify kernel image exists
podman pull ghcr.io/bazzite-org/kernel-bazzite:latest-f43-x86_64
```

### Issue: NVIDIA Drivers Missing
```bash
# Verify driver image exists
podman pull ghcr.io/bazzite-org/nvidia-drivers:latest-f43-x86_64
```

## Testing Builds

### Quick Container Test
```bash
# Run container
podman run -it --rm powos-base-mesa:latest /bin/bash

# Check packages
rpm -qa | grep mesa
rpm -qa | grep kernel

# Verify services
systemctl list-unit-files | grep enabled
```

### VM Boot Test
```bash
# Create test VM
sudo bootc install to-disk --via-loopback \
  --generic-image --target-transport registry \
  powos-base-mesa:latest /dev/vda
```

## Push to Registry

```bash
# Tag for GitHub Container Registry
podman tag powos-base-mesa:latest ghcr.io/powos/powos-base-mesa:latest

# Login to registry
echo $GITHUB_TOKEN | podman login ghcr.io -u USERNAME --password-stdin

# Push image
podman push ghcr.io/powos/powos-base-mesa:latest
```

## Multi-Architecture Builds

### ARM64 (Experimental)
```bash
podman build -f Containerfile.mesa \
  -t powos-base-mesa:arm64 \
  --build-arg ARCH=aarch64 \
  --platform linux/arm64
```

### Multi-Arch Manifest
```bash
# Build for both architectures
podman build -f Containerfile.mesa -t powos-base-mesa:amd64 --platform linux/amd64
podman build -f Containerfile.mesa -t powos-base-mesa:arm64 --platform linux/arm64

# Create manifest
podman manifest create powos-base-mesa:latest
podman manifest add powos-base-mesa:latest powos-base-mesa:amd64
podman manifest add powos-base-mesa:latest powos-base-mesa:arm64

# Push manifest
podman manifest push powos-base-mesa:latest ghcr.io/powos/powos-base-mesa:latest
```

## CI/CD Example

### GitHub Actions Workflow

```yaml
name: Build PowOS

on:
  push:
    branches: [ main ]
    tags: [ 'v*' ]

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        variant: [mesa, nvidia]
    steps:
      - uses: actions/checkout@v4

      - name: Build Image
        run: |
          cd containers
          podman build -f Containerfile.${{ matrix.variant }} \
            -t powos-base-${{ matrix.variant }}:${{ github.sha }}

      - name: Tag Image
        run: |
          podman tag powos-base-${{ matrix.variant }}:${{ github.sha }} \
            ghcr.io/powos/powos-base-${{ matrix.variant }}:latest

      - name: Login to Registry
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | \
          podman login ghcr.io -u ${{ github.actor }} --password-stdin

      - name: Push Image
        run: |
          podman push ghcr.io/powos/powos-base-${{ matrix.variant }}:latest
```

## Build Performance

### Expected Build Times (GitHub Actions)
- **Mesa Image:** ~45 minutes
- **NVIDIA Image:** ~50 minutes

### Local Build Times (16-core, 32GB RAM)
- **Mesa Image:** ~20 minutes
- **NVIDIA Image:** ~25 minutes

### Image Sizes
- **Mesa Image:** ~3.5GB
- **NVIDIA Image:** ~3.8GB

## Build Structure

```
containers/
├── Containerfile.base-common    # Shared components
├── Containerfile.mesa           # Mesa variant
└── Containerfile.nvidia         # NVIDIA variant

build_files/                     # Build scripts (from Bazzite)
├── install-kernel
├── install-firmware
├── install-nvidia
├── cleanup
├── image-info
├── build-initramfs
└── finalize

system_files/                    # System configurations
├── shared/                      # Common configs
├── nvidia/                      # NVIDIA-specific
└── overrides/                   # System overrides
```

## Release Process

### 1. Tag Release
```bash
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

### 2. Build Images
```bash
podman build -f Containerfile.mesa -t powos-base-mesa:v1.0.0
podman build -f Containerfile.nvidia -t powos-base-nvidia:v1.0.0
```

### 3. Tag for Registry
```bash
# Mesa
podman tag powos-base-mesa:v1.0.0 ghcr.io/powos/powos-base-mesa:v1.0.0
podman tag powos-base-mesa:v1.0.0 ghcr.io/powos/powos-base-mesa:latest

# NVIDIA
podman tag powos-base-nvidia:v1.0.0 ghcr.io/powos/powos-base-nvidia:v1.0.0
podman tag powos-base-nvidia:v1.0.0 ghcr.io/powos/powos-base-nvidia:latest
```

### 4. Push to Registry
```bash
podman push ghcr.io/powos/powos-base-mesa:v1.0.0
podman push ghcr.io/powos/powos-base-mesa:latest
podman push ghcr.io/powos/powos-base-nvidia:v1.0.0
podman push ghcr.io/powos/powos-base-nvidia:latest
```

## Next Steps

After building base images:
1. Build overlays (see `overlays/README.md`)
2. Test on real hardware
3. Create hardware detection service
4. Package for distribution

## Documentation

- [OVERLAY-ARCHITECTURE.md](./OVERLAY-ARCHITECTURE.md) - Overlay system design
- [REMOVED-FOR-OVERLAYS.md](./REMOVED-FOR-OVERLAYS.md) - What was removed
- [containers/README.md](../containers/README.md) - Detailed build documentation

---

**Questions?** Open an issue on GitHub.
