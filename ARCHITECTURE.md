# PowOS Technical Architecture

> **Implementation Guide** - How to build and test the Container-Native Workstation

---

## Development Strategy: "Containers All The Way Down"

We test PowOS **inside Docker** before deploying to real hardware. This gives us:

1. **Fast iteration** - No rebooting, no flashing drives
2. **CI/CD testing** - GitHub Actions can validate builds
3. **Safe experimentation** - Break things without consequences
4. **Parallel development** - Test multiple configurations simultaneously

---

## The Three Testing Tiers

```
┌─────────────────────────────────────────────────────────────────┐
│                    TIER 3: REAL HARDWARE                        │
│                    (Final validation only)                      │
│                    USB4 Drive → Physical Machine                │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ Deploy when Tier 2 passes
                              │
┌─────────────────────────────────────────────────────────────────┐
│                    TIER 2: QEMU/KVM VM                          │
│                    (Boot testing, hardware simulation)          │
│                    Tests: Boot sequence, systemd, overlays      │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ Promote when Tier 1 passes
                              │
┌─────────────────────────────────────────────────────────────────┐
│                    TIER 1: DOCKER COMPOSE                       │
│                    (Component testing, fast iteration)          │
│                    Tests: pinstall, overlays, configs           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Tier 1: Docker Compose Test Environment

This is where you'll spend 90% of development time.

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                     docker-compose.yml                           │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │   base-os   │  │  distrobox  │  │   overlay   │              │
│  │  (fedora)   │  │   (arch)    │  │  (builder)  │              │
│  │             │  │             │  │             │              │
│  │ - systemd   │  │ - dev tools │  │ - compiles  │              │
│  │ - udev sim  │  │ - pinstall  │  │ - sysext    │              │
│  │ - configs   │  │ - runtime   │  │ - patches   │              │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘              │
│         │                │                │                      │
│         └────────────────┼────────────────┘                      │
│                          │                                       │
│                   ┌──────┴──────┐                                │
│                   │   volumes   │                                │
│                   │ - /powos    │                                │
│                   │ - /home     │                                │
│                   │ - /secrets  │                                │
│                   └─────────────┘                                │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### What We Can Test in Tier 1

| Component | Test Method | Fidelity |
|-----------|-------------|----------|
| `pinstall` workflow | Direct execution | 100% |
| Git auto-commit | Direct execution | 100% |
| Overlay compilation | Direct execution | 100% |
| Systemd-sysext | Simulated (no real /usr) | 80% |
| Hardware detection | Mocked udev events | 70% |
| Distrobox integration | Real distrobox | 95% |
| AI patch healing | Real Ollama | 100% |

### What We CAN'T Test in Tier 1

- Real boot sequence
- Actual GPU driver loading
- USB4/Thunderbolt detection
- Real systemd service ordering
- Actual kernel module loading

---

## Tier 2: QEMU/KVM Virtual Machine

For testing actual boot sequences and systemd integration.

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        Host Machine                              │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                    QEMU/KVM VM                              │ │
│  │                                                             │ │
│  │   ┌─────────────────────────────────────────────────────┐  │ │
│  │   │              PowOS (Full Boot)                      │  │ │
│  │   │                                                     │  │ │
│  │   │  - Real systemd                                     │  │ │
│  │   │  - Real overlay mounting                            │  │ │
│  │   │  - Simulated hardware (virtio)                      │  │ │
│  │   │  - Optional: GPU passthrough                        │  │ │
│  │   └─────────────────────────────────────────────────────┘  │ │
│  │                                                             │ │
│  │   Virtio devices:                                           │ │
│  │   - virtio-gpu (simulates display)                          │ │
│  │   - virtio-net (network)                                    │ │
│  │   - 9p/virtiofs (share /powos from host)                    │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### What We Can Test in Tier 2

| Component | Test Method | Fidelity |
|-----------|-------------|----------|
| Boot sequence | Real boot | 95% |
| Systemd services | Real systemd | 100% |
| Overlay mounting | Real sysext | 100% |
| Hardware detection scripts | Triggered manually | 85% |
| Full hydration | Real execution | 100% |

---

## Project Structure

```
~/powos/
├── Containerfile.base          # Base OS image (Fedora/Bazzite-like)
├── Containerfile.dev           # Development/testing image
├── docker-compose.yml          # Tier 1 test environment
├── docker-compose.test.yml     # CI/CD test runner
├── justfile                    # Command orchestrator
│
├── bin/                        # User-facing scripts
│   ├── pinstall                # Install + record
│   ├── premove                 # Remove + record
│   └── powos                   # Main CLI entry point
│
├── lib/                        # Internal libraries
│   ├── hardware-detect.sh      # Chameleon boot logic
│   ├── overlay-manager.sh      # Sysext operations
│   ├── ai-patcher.sh           # Ollama integration
│   └── state-recorder.sh       # Git auto-commit logic
│
├── config/                     # System configurations
│   ├── udev/                   # Hardware rules
│   │   ├── 99-nvidia-desktop.rules
│   │   ├── 99-intel-laptop.rules
│   │   └── 99-thunderbolt.rules
│   ├── systemd/                # Service units
│   │   ├── powos-overlay.service
│   │   ├── powos-hardware.service
│   │   └── powos-hydrate.service
│   ├── modprobe.d/             # Kernel module configs
│   └── profiles/               # System profiles
│       ├── desktop-performance.conf
│       ├── laptop-battery.conf
│       └── training-mode.conf
│
├── containers/                 # Distrobox definitions
│   ├── distrobox.ini           # Main dev container
│   ├── arch-dev.ini            # Arch-based tools
│   └── fedora-build.ini        # Build environment
│
├── extensions/                 # Compiled overlay binaries
│   └── .gitkeep                # (built, not committed)
│
├── sources/                    # Custom source code
│   ├── dolphin/                # Example: KDE Dolphin
│   │   ├── patches/
│   │   └── build.sh
│   └── konsole/
│
├── secrets/                    # Encrypted secrets (age/sops)
│   ├── secrets.yaml.age        # Encrypted blob
│   └── .sops.yaml              # SOPS config
│
├── test/                       # Test suites
│   ├── tier1/                  # Docker-based tests
│   │   ├── test-pinstall.sh
│   │   ├── test-overlay.sh
│   │   └── test-hardware-detect.sh
│   ├── tier2/                  # VM-based tests
│   │   ├── test-boot.sh
│   │   └── test-hydrate.sh
│   └── mocks/                  # Hardware mocks
│       ├── nvidia-desktop.sh
│       └── intel-laptop.sh
│
└── docs/
    ├── USER_STORIES.md
    └── ARCHITECTURE.md
```

---

## Implementation: Core Components

### 1. The Base Container (Tier 1 Testing)

```dockerfile
# Containerfile.dev - Development/Testing Environment
FROM fedora:41

# Core system tools
RUN dnf install -y \
    systemd \
    git \
    podman \
    distrobox \
    just \
    age \
    sops \
    curl \
    jq \
    && dnf clean all

# Simulate immutable OS structure
RUN mkdir -p /var/home /var/roothome /var/opt /var/mnt

# Install our tooling
COPY bin/ /usr/local/bin/
COPY lib/ /usr/local/lib/powos/
COPY config/ /etc/powos/

# Setup test environment
ENV POWOS_DEV=1
ENV POWOS_ROOT=/powos

WORKDIR /powos
ENTRYPOINT ["/usr/bin/bash"]
```

### 2. Docker Compose Test Environment

```yaml
# docker-compose.yml
version: "3.9"

services:
  # Main development container
  powos-dev:
    build:
      context: .
      dockerfile: Containerfile.dev
    volumes:
      - .:/powos:rw                    # Project files
      - powos-home:/var/home:rw        # Persistent home
      - /var/run/docker.sock:/var/run/docker.sock  # For distrobox
    environment:
      - POWOS_DEV=1
      - POWOS_MOCK_HARDWARE=nvidia-desktop
    privileged: true                   # Needed for systemd/overlays
    stdin_open: true
    tty: true
    command: sleep infinity

  # Distrobox simulation (Arch)
  arch-toolbox:
    image: archlinux:latest
    volumes:
      - .:/powos:rw
      - powos-home:/var/home:rw
    environment:
      - POWOS_CONTAINER=arch
    stdin_open: true
    tty: true
    command: sleep infinity

  # Overlay builder
  overlay-builder:
    build:
      context: .
      dockerfile: Containerfile.dev
    volumes:
      - .:/powos:rw
      - ./extensions:/extensions:rw
    environment:
      - POWOS_BUILD_ONLY=1
    command: |
      bash -c "
        echo 'Overlay builder ready'
        sleep infinity
      "

  # Local AI for patch healing
  ollama:
    image: ollama/ollama:latest
    volumes:
      - ollama-models:/root/.ollama
    ports:
      - "11434:11434"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

volumes:
  powos-home:
  ollama-models:
```

### 3. The `pinstall` Script

```bash
#!/usr/bin/env bash
# bin/pinstall - Install packages and record to infrastructure code

set -euo pipefail

POWOS_ROOT="${POWOS_ROOT:-$HOME/powos}"
DISTROBOX_INI="${POWOS_ROOT}/containers/distrobox.ini"
PACKAGES=("$@")

if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    echo "Usage: pinstall <package> [package...]"
    exit 1
fi

# Detect package manager
detect_pm() {
    if command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v apt &>/dev/null; then
        echo "apt"
    else
        echo "unknown"
    fi
}

PM=$(detect_pm)

echo "📦 Installing: ${PACKAGES[*]}"

# 1. Install immediately (runtime)
case $PM in
    pacman)
        sudo pacman -S --noconfirm "${PACKAGES[@]}"
        ;;
    dnf)
        sudo dnf install -y "${PACKAGES[@]}"
        ;;
    apt)
        sudo apt-get install -y "${PACKAGES[@]}"
        ;;
    *)
        echo "❌ Unknown package manager"
        exit 1
        ;;
esac

# 2. Record to distrobox.ini (config)
echo "📝 Recording to ${DISTROBOX_INI}"

for pkg in "${PACKAGES[@]}"; do
    # Check if already in config
    if ! grep -q "^additional_packages=.*${pkg}" "${DISTROBOX_INI}" 2>/dev/null; then
        # Append to additional_packages line
        if grep -q "^additional_packages=" "${DISTROBOX_INI}"; then
            sed -i "s/^additional_packages=\(.*\)/additional_packages=\1 ${pkg}/" "${DISTROBOX_INI}"
        else
            echo "additional_packages=${pkg}" >> "${DISTROBOX_INI}"
        fi
    fi
done

# 3. Git commit (persistence)
echo "💾 Committing to git"
cd "${POWOS_ROOT}"
git add "${DISTROBOX_INI}"
git commit -m "install: ${PACKAGES[*]}" || echo "No changes to commit"

echo "✅ Installed and recorded: ${PACKAGES[*]}"
```

### 4. Hardware Detection Script

```bash
#!/usr/bin/env bash
# lib/hardware-detect.sh - Chameleon boot hardware detection

set -euo pipefail

PROFILES_DIR="/etc/powos/profiles"
MOCK_HARDWARE="${POWOS_MOCK_HARDWARE:-}"

log() {
    echo "[hardware-detect] $*"
}

detect_gpu() {
    if [[ -n "$MOCK_HARDWARE" ]]; then
        echo "$MOCK_HARDWARE"
        return
    fi

    if lspci | grep -qi "nvidia"; then
        # Check if it's a desktop card (high TDP) or mobile
        if lspci -v | grep -qi "GeForce RTX 30\|GeForce RTX 40\|Quadro\|Tesla"; then
            echo "nvidia-desktop"
        else
            echo "nvidia-mobile"
        fi
    elif lspci | grep -qi "AMD.*Radeon"; then
        echo "amd"
    elif lspci | grep -qi "Intel.*Graphics"; then
        echo "intel"
    else
        echo "unknown"
    fi
}

detect_power_source() {
    if [[ -d /sys/class/power_supply/AC* ]] || [[ -d /sys/class/power_supply/ADP* ]]; then
        if cat /sys/class/power_supply/AC*/online 2>/dev/null | grep -q "1"; then
            echo "ac"
        else
            echo "battery"
        fi
    else
        echo "ac"  # Desktop assumed
    fi
}

apply_profile() {
    local profile="$1"
    local profile_file="${PROFILES_DIR}/${profile}.conf"

    if [[ ! -f "$profile_file" ]]; then
        log "Profile not found: $profile_file"
        return 1
    fi

    log "Applying profile: $profile"
    source "$profile_file"
}

main() {
    local gpu=$(detect_gpu)
    local power=$(detect_power_source)

    log "Detected GPU: $gpu"
    log "Detected Power: $power"

    case "$gpu" in
        nvidia-desktop)
            apply_profile "desktop-performance"
            # Load nvidia drivers
            modprobe nvidia nvidia_modeset nvidia_uvm nvidia_drm 2>/dev/null || true
            ;;
        nvidia-mobile)
            if [[ "$power" == "battery" ]]; then
                apply_profile "laptop-battery"
                # Sleep nvidia, use integrated
                echo "auto" > /sys/bus/pci/devices/*/power/control 2>/dev/null || true
            else
                apply_profile "desktop-performance"
            fi
            ;;
        intel|amd)
            apply_profile "laptop-battery"
            # Ensure nvidia modules not loaded
            rmmod nvidia_drm nvidia_modeset nvidia_uvm nvidia 2>/dev/null || true
            ;;
        *)
            log "Unknown GPU, using defaults"
            ;;
    esac

    log "Hardware detection complete"
}

main "$@"
```

### 5. Overlay Manager

```bash
#!/usr/bin/env bash
# lib/overlay-manager.sh - Manage systemd-sysext overlays

set -euo pipefail

EXTENSIONS_DIR="${POWOS_ROOT:-$HOME/powos}/extensions"
SYSEXT_DIR="/var/lib/extensions"

log() {
    echo "[overlay] $*"
}

build_overlay() {
    local name="$1"
    local source_dir="${POWOS_ROOT:-$HOME/powos}/sources/${name}"
    local output_dir="${EXTENSIONS_DIR}/${name}"

    if [[ ! -d "$source_dir" ]]; then
        log "Source not found: $source_dir"
        return 1
    fi

    log "Building overlay: $name"

    # Create extension directory structure
    mkdir -p "${output_dir}/usr/bin"
    mkdir -p "${output_dir}/usr/lib"

    # Run component-specific build script
    if [[ -f "${source_dir}/build.sh" ]]; then
        (cd "$source_dir" && bash build.sh "$output_dir")
    else
        log "No build.sh found for $name"
        return 1
    fi

    # Create extension-release file (required for sysext)
    cat > "${output_dir}/usr/lib/extension-release.d/extension-release.${name}" <<EOF
ID=fedora
VERSION_ID=41
EOF

    log "Built overlay: $name -> $output_dir"
}

enable_overlay() {
    local name="$1"
    local source="${EXTENSIONS_DIR}/${name}"
    local target="${SYSEXT_DIR}/${name}"

    if [[ ! -d "$source" ]]; then
        log "Overlay not built: $name"
        return 1
    fi

    log "Enabling overlay: $name"

    # In dev mode, we simulate with bind mounts
    if [[ "${POWOS_DEV:-}" == "1" ]]; then
        log "(DEV) Would symlink $source -> $target"
        return 0
    fi

    # Production: actual sysext
    sudo ln -sf "$source" "$target"
    sudo systemd-sysext refresh

    log "Enabled: $name"
}

disable_overlay() {
    local name="$1"
    local target="${SYSEXT_DIR}/${name}"

    log "Disabling overlay: $name"

    if [[ "${POWOS_DEV:-}" == "1" ]]; then
        log "(DEV) Would remove $target"
        return 0
    fi

    sudo rm -f "$target"
    sudo systemd-sysext refresh

    log "Disabled: $name"
}

list_overlays() {
    echo "Available overlays:"
    for dir in "${EXTENSIONS_DIR}"/*/; do
        if [[ -d "$dir" ]]; then
            local name=$(basename "$dir")
            local status="disabled"
            if [[ -L "${SYSEXT_DIR}/${name}" ]]; then
                status="enabled"
            fi
            echo "  - ${name} [${status}]"
        fi
    done
}

case "${1:-}" in
    build)
        build_overlay "${2:?Component name required}"
        ;;
    enable)
        enable_overlay "${2:?Component name required}"
        ;;
    disable)
        disable_overlay "${2:?Component name required}"
        ;;
    list)
        list_overlays
        ;;
    *)
        echo "Usage: $0 {build|enable|disable|list} [component]"
        exit 1
        ;;
esac
```

### 6. The Justfile (Command Orchestrator)

```just
# justfile - PowOS command orchestrator

set shell := ["bash", "-euo", "pipefail", "-c"]

# Default: show help
default:
    @just --list --unsorted

# ─────────────────────────────────────────────────────────────────
# Development & Testing (Tier 1)
# ─────────────────────────────────────────────────────────────────

# Start the development environment
dev:
    docker compose up -d
    @echo "Dev environment started. Run: docker compose exec powos-dev bash"

# Enter the dev container
shell:
    docker compose exec powos-dev bash

# Run all Tier 1 tests
test:
    docker compose -f docker-compose.test.yml run --rm test

# Test specific component
test-component component:
    docker compose exec powos-dev bash /powos/test/tier1/test-{{component}}.sh

# Stop development environment
down:
    docker compose down

# Clean everything (volumes too)
clean:
    docker compose down -v
    rm -rf extensions/*

# ─────────────────────────────────────────────────────────────────
# Overlay Management
# ─────────────────────────────────────────────────────────────────

# Build a custom component overlay
build component:
    ./lib/overlay-manager.sh build {{component}}

# Build all overlays
build-all:
    for dir in sources/*/; do \
        name=$(basename "$dir"); \
        just build "$name"; \
    done

# Enable an overlay
enable-overlay component:
    ./lib/overlay-manager.sh enable {{component}}

# Disable an overlay
disable-overlay component:
    ./lib/overlay-manager.sh disable {{component}}

# List all overlays
list-overlays:
    ./lib/overlay-manager.sh list

# ─────────────────────────────────────────────────────────────────
# System Operations
# ─────────────────────────────────────────────────────────────────

# Full system hydration (restore from scratch)
hydrate:
    @echo "🌊 Hydrating PowOS..."
    @echo "1. Setting up distrobox containers..."
    distrobox assemble create --file containers/distrobox.ini
    @echo "2. Building overlays..."
    just build-all
    @echo "3. Enabling overlays..."
    for dir in extensions/*/; do \
        name=$(basename "$dir"); \
        just enable-overlay "$name"; \
    done
    @echo "4. Restoring secrets..."
    just secrets-decrypt
    @echo "✅ Hydration complete!"

# Minimal hydration (basic tools only)
hydrate-minimal:
    @echo "🌊 Minimal hydration..."
    distrobox assemble create --file containers/distrobox.ini
    @echo "✅ Minimal hydration complete!"

# System update with overlay checks
update:
    @echo "🔄 Starting update..."
    @echo "1. Checking overlay compatibility..."
    # TODO: Implement compatibility check
    @echo "2. Running system update..."
    rpm-ostree upgrade || echo "Not on ostree system"
    @echo "3. Rebuilding overlays..."
    just build-all
    @echo "✅ Update complete!"

# Update dry run
update-dry-run:
    @echo "🔍 Update dry run..."
    rpm-ostree upgrade --preview || echo "Not on ostree system"

# ─────────────────────────────────────────────────────────────────
# System Profiles
# ─────────────────────────────────────────────────────────────────

# Switch system mode
mode profile:
    @echo "⚡ Switching to {{profile}} mode..."
    ./lib/hardware-detect.sh apply {{profile}}

# ─────────────────────────────────────────────────────────────────
# Secrets Management
# ─────────────────────────────────────────────────────────────────

# Decrypt secrets
secrets-decrypt:
    @echo "🔓 Decrypting secrets..."
    sops -d secrets/secrets.yaml.age > /tmp/secrets.yaml
    @echo "Secrets available at /tmp/secrets.yaml"

# Encrypt secrets
secrets-encrypt:
    @echo "🔒 Encrypting secrets..."
    sops -e /tmp/secrets.yaml > secrets/secrets.yaml.age
    rm /tmp/secrets.yaml
    @echo "Secrets encrypted"

# ─────────────────────────────────────────────────────────────────
# Image Building (Production)
# ─────────────────────────────────────────────────────────────────

# Build the base OS image
build-image:
    @echo "🏗️ Building PowOS image..."
    docker build -f Containerfile.base -t powos:latest .
    @echo "✅ Image built: powos:latest"

# Build and push to registry
build-push registry="ghcr.io/user/powos":
    just build-image
    docker tag powos:latest {{registry}}:latest
    docker push {{registry}}:latest

# ─────────────────────────────────────────────────────────────────
# VM Testing (Tier 2)
# ─────────────────────────────────────────────────────────────────

# Create QEMU disk image
vm-create-disk:
    qemu-img create -f qcow2 test/tier2/powos-test.qcow2 20G

# Boot VM for testing
vm-boot:
    qemu-system-x86_64 \
        -enable-kvm \
        -m 4G \
        -smp 4 \
        -drive file=test/tier2/powos-test.qcow2,format=qcow2 \
        -cdrom test/tier2/powos.iso \
        -boot d \
        -display gtk \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22

# ─────────────────────────────────────────────────────────────────
# AI Integration
# ─────────────────────────────────────────────────────────────────

# Start Ollama for AI patching
ai-start:
    docker compose up -d ollama
    @echo "Waiting for Ollama..."
    sleep 5
    docker compose exec ollama ollama pull codellama:13b
    @echo "✅ AI ready"

# Test AI patch generation
ai-test:
    ./lib/ai-patcher.sh test
```

---

## Testing Workflow

### Quick Start (5 minutes)

```bash
# 1. Clone and enter
cd ~/powos

# 2. Start dev environment
just dev

# 3. Enter container
just shell

# 4. Test pinstall
pinstall ripgrep
cat containers/distrobox.ini  # See it recorded
git log --oneline -1          # See the commit

# 5. Test overlay build (assuming you have a source)
just build dolphin
just list-overlays
```

### Full Test Cycle

```bash
# Tier 1: Docker tests
just test                    # Run all tests
just test-component pinstall # Test specific component

# Tier 2: VM boot test
just vm-create-disk          # One-time setup
just build-image             # Build ISO
just vm-boot                 # Boot and test manually

# Tier 3: Real hardware
# Flash to USB4 drive and boot on actual machine
```

---

## Mock Hardware Testing

For Chameleon Boot testing without real hardware:

```bash
# Test desktop profile
POWOS_MOCK_HARDWARE=nvidia-desktop just shell
./lib/hardware-detect.sh

# Test laptop profile
POWOS_MOCK_HARDWARE=intel just shell
./lib/hardware-detect.sh

# Test battery mode
POWOS_MOCK_HARDWARE=nvidia-mobile POWOS_MOCK_POWER=battery just shell
./lib/hardware-detect.sh
```

---

## CI/CD Pipeline

```yaml
# .github/workflows/test.yml
name: PowOS Tests

on: [push, pull_request]

jobs:
  tier1-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build dev image
        run: docker compose build

      - name: Run Tier 1 tests
        run: docker compose -f docker-compose.test.yml run --rm test

      - name: Test pinstall
        run: docker compose run --rm powos-dev bash -c "pinstall ripgrep && rg --version"

  build-image:
    runs-on: ubuntu-latest
    needs: tier1-tests
    steps:
      - uses: actions/checkout@v4

      - name: Build production image
        run: just build-image

      - name: Push to registry
        if: github.ref == 'refs/heads/main'
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u $ --password-stdin
          just build-push ghcr.io/${{ github.repository }}
```

---

## Next Steps

1. **Initialize the repo** with this structure
2. **Implement `pinstall`** first (most testable)
3. **Build docker-compose.yml** for Tier 1
4. **Add one overlay example** (start with something simple)
5. **Wire up hardware detection** with mocks
6. **Add CI/CD** for automated testing

---

*Last Updated: 2025-12-11*
