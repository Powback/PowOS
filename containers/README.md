# PowOS Container Build System

This directory contains the Containerfiles for building PowOS base images.

## Base Images

PowOS provides **two base images** optimized for different GPU vendors:

### 1. powos-base-mesa (Default/Recommended)
**File:** `Containerfile.mesa`
**Target:** AMD and Intel GPUs
**Graphics:** Valve-patched Mesa stack
**Compute:** ROCm (AMD)
**Size:** ~3.5GB

**Best for:**
- AMD Radeon GPUs (RX 6000/7000 series)
- AMD APUs (Ryzen with integrated graphics)
- Intel Arc GPUs
- Intel integrated graphics
- Steam Deck and other AMD handheld devices

### 2. powos-base-nvidia
**File:** `Containerfile.nvidia`
**Target:** NVIDIA GPUs
**Graphics:** NVIDIA proprietary drivers
**Compute:** CUDA
**Size:** ~3.8GB

**Best for:**
- NVIDIA GeForce GPUs (GTX/RTX series)
- NVIDIA workstation GPUs (Quadro, Tesla)
- Hybrid GPU laptops with NVIDIA dGPU
- AI/ML workloads requiring CUDA

## Build Architecture

### Multi-Stage Build Process

```
Containerfile.base-common
  ├─ Stage: powos-base-common
  │   ├─ CachyOS kernel
  │   ├─ All firmware
  │   ├─ Valve-patched Pipewire/Bluez
  │   ├─ KDE Plasma
  │   ├─ Core gaming packages
  │   └─ Hardware-agnostic utilities
  │
  ├─ Containerfile.mesa (extends base-common)
  │   └─ powos-base-mesa
  │       ├─ Valve-patched Mesa
  │       ├─ AMD ROCm
  │       └─ Remove NVIDIA firmware
  │
  └─ Containerfile.nvidia (extends base-common)
      └─ powos-base-nvidia
          ├─ NVIDIA proprietary drivers
          ├─ NVIDIA Container Toolkit
          ├─ CUDA support
          ├─ Minimal Mesa (Zink)
          └─ Remove AMD ROCm
```

## Building Images

### Prerequisites

```bash
# Install build tools
sudo dnf install podman buildah

# Clone PowOS repository
git clone https://github.com/powos/powos.git
cd powos
```

### Quick Start (Using Build Script)

The easiest way to build images:

```bash
cd containers/

# Build Mesa variant only
bash build.sh mesa

# Build NVIDIA variant only
bash build.sh nvidia

# Build both variants
bash build.sh all
```

### Using Just (Recommended)

If you have [just](https://github.com/casey/just) installed:

```bash
cd containers/

# Build Mesa image
just build-mesa

# Build NVIDIA image
just build-nvidia

# Build both images
just build-all
```

### Manual Build - Mesa Image (AMD/Intel)

```bash
# Build the common base first (embedded in mesa build)
cd containers/

# Build Mesa image
podman build -f Containerfile.mesa -t powos-base-mesa:latest \
  --build-arg FEDORA_VERSION=43 \
  --build-arg BASE_IMAGE_NAME=kinoite \
  .

# Tag for release
podman tag powos-base-mesa:latest ghcr.io/powos/powos-base-mesa:latest
```

### Manual Build - NVIDIA Image

```bash
cd containers/

# Build NVIDIA image
podman build -f Containerfile.nvidia -t powos-base-nvidia:latest \
  --build-arg FEDORA_VERSION=43 \
  --build-arg BASE_IMAGE_NAME=kinoite \
  .

# Tag for release
podman tag powos-base-nvidia:latest ghcr.io/powos/powos-base-nvidia:latest
```

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `FEDORA_VERSION` | `43` | Fedora release version |
| `BASE_IMAGE_NAME` | `kinoite` | Base image (kinoite=KDE, silverblue=GNOME) |
| `ARCH` | `x86_64` | Target architecture |
| `IMAGE_BRANCH` | `stable` | Release branch (stable/testing/unstable) |
| `KERNEL_REF` | `ghcr.io/bazzite-org/kernel-bazzite:latest-f43-x86_64` | Kernel image reference |
| `NVIDIA_REF` | `ghcr.io/bazzite-org/nvidia-drivers:latest-f43-x86_64` | NVIDIA drivers reference |

### Custom Builds

**Build with GNOME instead of KDE:**
```bash
podman build -f Containerfile.mesa -t powos-base-mesa-gnome:latest \
  --build-arg BASE_IMAGE_NAME=silverblue \
  .
```

**Build testing branch:**
```bash
podman build -f Containerfile.mesa -t powos-base-mesa:testing \
  --build-arg IMAGE_BRANCH=testing \
  .
```

## File Structure

```
containers/
├── Containerfile.base-common    # Shared base stage (all common components)
├── Containerfile.mesa           # Mesa variant (AMD/Intel)
├── Containerfile.nvidia         # NVIDIA variant
├── README.md                    # This file
├── BUILD.md                     # Detailed build guide
├── SETUP_COMPLETE.md            # Setup verification
├── build.sh                     # Build script
├── validate.sh                  # Validation script
├── Justfile                     # Just recipes
├── build_files/                 # Build scripts (from Bazzite)
│   ├── install-kernel           # Kernel installation
│   ├── install-firmware         # Firmware installation
│   ├── install-nvidia           # NVIDIA driver installation
│   ├── cleanup                  # DNF cache cleanup
│   ├── image-info               # Image metadata generation
│   ├── build-initramfs          # Initramfs generation
│   ├── finalize                 # Final cleanup
│   ├── ghcurl                   # GitHub API helper
│   ├── dnf5-setopt              # DNF5 configuration
│   └── dnf5-search              # DNF5 search helper
└── system_files/                # System configuration files
    ├── shared/                  # Common configs (188 files)
    ├── nvidia/shared/           # NVIDIA-specific configs (9 files)
    └── overrides/               # Config overrides (46 files)
```

## What's Included (Both Images)

### Kernel & Core System
- **CachyOS kernel** (optimized for gaming)
- **scx-scheds** (sched-ext schedulers)
- **bootc** (bootable container support)
- **rpm-ostree** (atomic updates)
- **plymouth** (boot splash)

### Firmware
- **All firmware packages** (AMD, Intel, NVIDIA, WiFi, Bluetooth)
- This ensures any image works on first boot before detection
- Includes handheld-specific firmware (Steam Deck, ROG Ally, etc.)

### Graphics & Audio
- **Gamescope** (Wayland gaming compositor)
- **Pipewire + WirePlumber** (Valve-patched)
- **Bluez** (Valve-patched, better controller support)
- **Xwayland** (X11 compatibility)

### Gaming
- **Steam** (with bazzite-steam wrapper)
- **Lutris** (game manager)
- **umu-launcher** (unified game launcher)
- **MangoHud** (performance overlay)
- **vkBasalt** (post-processing)
- **OBS VKCapture** (capture tool)
- **Gamescope** (compositor)
- **Winetricks**

### Desktop Environment
- **KDE Plasma** (default, or GNOME if silverblue base)
- **SDDM** (login manager)
- **Ptyxis** (terminal)
- **Bazaar** (application manager)

### Utilities
- **Cockpit** (web-based system management)
- **Distrobox** (containerized development)
- **Waydroid** (Android container)
- **QEMU + libvirt** (virtualization)
- **Btrfs-assistant** (snapshot management)
- **Snapper** (backup tool)
- **Topgrade** (update manager)
- **Tailscale** (VPN)

## What's NOT Included (Moved to Overlays)

These will be provided via systemd-sysext overlays:

### Device-Specific Hardware
- `input-remapper` - Desktop input remapping
- `ryzenadj` - AMD TDP adjustment
- `fw-ectool` / `fw-fanctrl` - Framework laptop tools
- `jupiter-fan-control` - Steam Deck fan control
- `vpower` - Steam Deck power management
- `galileo-mura` - Steam Deck OLED calibration
- `hhd` / `hhd-ui` - Handheld daemon

### Gaming Mode / Deck UI
- `gamescope-session-plus` - Console gaming mode
- `gamescope-session-steam` - Steam Big Picture integration
- `steamos-manager` - SteamOS-like manager
- Auto-login configuration

### Hybrid GPU Support
- `supergfxctl` - GPU switching daemon
- `supergfxctl-plasmoid` - KDE widget

See [OVERLAY-ARCHITECTURE.md](../docs/OVERLAY-ARCHITECTURE.md) for full details.

## Image Metadata

Each image includes metadata labels:

### Mesa Image
```dockerfile
LABEL io.powos.variant="mesa"
      io.powos.gpu-support="amd,intel"
      io.powos.graphics-stack="mesa-valve-patched"
      io.powos.compute-support="rocm"
```

### NVIDIA Image
```dockerfile
LABEL io.powos.variant="nvidia"
      io.powos.gpu-support="nvidia"
      io.powos.graphics-stack="nvidia-proprietary"
      io.powos.compute-support="cuda"
      io.powos.container-support="nvidia-container-toolkit"
```

Inspect metadata:
```bash
podman inspect powos-base-mesa:latest | jq '.[0].Config.Labels'
```

## Testing Images

### Quick Test Boot (VM)

```bash
# Create a test VM with the image
sudo bootc install to-disk --via-loopback \
  --generic-image --target-transport registry \
  powos-base-mesa:latest /dev/vda
```

### Test in Container

```bash
# Run container interactively
podman run -it --rm powos-base-mesa:latest /bin/bash

# Check installed packages
rpm -qa | grep mesa
rpm -qa | grep kernel

# Verify services
systemctl list-unit-files | grep enabled
```

### Verify Graphics Stack

**Mesa image:**
```bash
podman run -it powos-base-mesa:latest /bin/bash
$ rpm -qa | grep mesa
$ ls /usr/lib64/dri/
$ vulkaninfo --summary
```

**NVIDIA image:**
```bash
podman run -it powos-base-nvidia:latest /bin/bash
$ rpm -qa | grep nvidia
$ nvidia-smi --query
$ ls /usr/lib64/libnvidia-*
```

## Build Optimizations

### Enable Build Cache

```bash
# Use buildah for better caching
buildah bud --layers -f Containerfile.mesa -t powos-base-mesa:latest
```

### Parallel Builds

```bash
# Build both images in parallel
podman build -f Containerfile.mesa -t powos-base-mesa:latest &
podman build -f Containerfile.nvidia -t powos-base-nvidia:latest &
wait
```

### Multi-Architecture Builds

```bash
# Build for ARM64 (experimental)
podman build -f Containerfile.mesa -t powos-base-mesa:arm64 \
  --build-arg ARCH=aarch64 \
  --platform linux/arm64
```

## Troubleshooting

### Build Fails with DNF Errors
**Symptom:** `dnf5 install` fails with package conflicts
**Solution:** Clear build cache
```bash
podman system prune --all --volumes
```

### Kernel Installation Fails
**Symptom:** `install-kernel` script errors
**Solution:** Verify kernel reference
```bash
# Check if kernel image exists
podman pull ghcr.io/bazzite-org/kernel-bazzite:latest-f43-x86_64
```

### NVIDIA Driver Missing
**Symptom:** NVIDIA image missing drivers
**Solution:** Verify NVIDIA driver reference
```bash
# Check if driver image exists
podman pull ghcr.io/bazzite-org/nvidia-drivers:latest-f43-x86_64
```

### Image Too Large
**Symptom:** Image exceeds expected size
**Solution:** Check for leftover build artifacts
```bash
# Inspect image layers
podman history powos-base-mesa:latest
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Build PowOS Images

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  build-mesa:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build Mesa Image
        run: |
          cd containers
          podman build -f Containerfile.mesa -t powos-base-mesa:${{ github.sha }}
      - name: Push to Registry
        run: |
          podman tag powos-base-mesa:${{ github.sha }} ghcr.io/powos/powos-base-mesa:latest
          podman push ghcr.io/powos/powos-base-mesa:latest

  build-nvidia:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build NVIDIA Image
        run: |
          cd containers
          podman build -f Containerfile.nvidia -t powos-base-nvidia:${{ github.sha }}
      - name: Push to Registry
        run: |
          podman tag powos-base-nvidia:${{ github.sha }} ghcr.io/powos/powos-base-nvidia:latest
          podman push ghcr.io/powos/powos-base-nvidia:latest
```

## Release Process

1. **Tag Release:**
   ```bash
   git tag -a v1.0.0 -m "Release v1.0.0"
   git push origin v1.0.0
   ```

2. **Build Images:**
   ```bash
   # Build both variants
   podman build -f Containerfile.mesa -t powos-base-mesa:v1.0.0
   podman build -f Containerfile.nvidia -t powos-base-nvidia:v1.0.0
   ```

3. **Tag for Registry:**
   ```bash
   # Tag Mesa
   podman tag powos-base-mesa:v1.0.0 ghcr.io/powos/powos-base-mesa:v1.0.0
   podman tag powos-base-mesa:v1.0.0 ghcr.io/powos/powos-base-mesa:latest

   # Tag NVIDIA
   podman tag powos-base-nvidia:v1.0.0 ghcr.io/powos/powos-base-nvidia:v1.0.0
   podman tag powos-base-nvidia:v1.0.0 ghcr.io/powos/powos-base-nvidia:latest
   ```

4. **Push to Registry:**
   ```bash
   podman push ghcr.io/powos/powos-base-mesa:v1.0.0
   podman push ghcr.io/powos/powos-base-mesa:latest
   podman push ghcr.io/powos/powos-base-nvidia:v1.0.0
   podman push ghcr.io/powos/powos-base-nvidia:latest
   ```

## Contributing

### Adding New Features to Base Images

**Important:** Only add features that are:
1. **Hardware-agnostic** (work on all devices)
2. **Essential** for core functionality
3. **Cannot be provided via overlay**

Device-specific or optional features should go in overlays.

### Modifying Build Scripts

Build scripts are imported from Bazzite. Changes should:
1. Maintain compatibility with Bazzite
2. Document PowOS-specific changes
3. Test thoroughly before merging

### Testing Checklist

- [ ] Image builds without errors
- [ ] Image size within expected range (~3.5GB Mesa, ~3.8GB NVIDIA)
- [ ] `bootc container lint` passes
- [ ] Test boot in VM
- [ ] Graphics stack works (Mesa or NVIDIA)
- [ ] Steam launches
- [ ] Audio works (Pipewire)
- [ ] Network connectivity
- [ ] Flatpak installation works

## Support

- **Documentation:** [PowOS Docs](../docs/)
- **Issues:** [GitHub Issues](https://github.com/powos/powos/issues)
- **Discussions:** [GitHub Discussions](https://github.com/powos/powos/discussions)

---

**Built with containerized gaming in mind.**
