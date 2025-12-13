# justfile - PowOS Command Orchestrator
#
# Usage: just <command>
# Run 'just' with no arguments to see all available commands.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Project paths
powos_root := env_var_or_default("POWOS_ROOT", justfile_directory())
lib_dir := powos_root / "lib"
bin_dir := powos_root / "bin"

# Default: show help
default:
    @just --list --unsorted

# ═══════════════════════════════════════════════════════════════════
#  DEVELOPMENT & TESTING (Tier 1)
# ═══════════════════════════════════════════════════════════════════

# Start the development environment
dev:
    @echo "🚀 Starting PowOS development environment..."
    docker compose up -d powos-dev arch-toolbox
    @echo ""
    @echo "Environment ready! Enter with:"
    @echo "  just shell        # Main dev container"
    @echo "  just shell-arch   # Arch toolbox"

# Enter the main dev container
shell:
    docker compose exec powos-dev bash

# Enter the Arch toolbox container
shell-arch:
    docker compose exec arch-toolbox bash

# Start with AI support (Ollama)
dev-ai:
    @echo "🤖 Starting PowOS with AI support..."
    docker compose --profile ai up -d
    @echo "Waiting for Ollama to start..."
    @sleep 5
    docker compose exec ollama ollama pull codellama:7b || true
    @echo "AI ready! Ollama available at http://localhost:11434"

# Run all Tier 1 tests
test:
    @echo "🧪 Running Tier 1 test suite..."
    docker compose --profile test run --rm test-runner

# Test a specific component
test-component component:
    @echo "🧪 Testing: {{component}}"
    docker compose exec powos-dev bash /powos/test/tier1/test-{{component}}.sh

# Stop development environment
down:
    docker compose down

# Stop and remove all containers (keeps caches)
clean:
    @echo "🧹 Cleaning up containers..."
    docker compose down --remove-orphans
    rm -rf extensions/*
    @echo "Clean complete (caches preserved)"

# Stop and remove all containers AND caches
clean-all:
    @echo "🧹 Deep cleaning (removing all volumes)..."
    docker compose down -v --remove-orphans
    rm -rf extensions/*
    @echo "Clean complete (caches removed)"

# Show cache volume sizes
cache-stats:
    @echo "📊 Cache volume sizes:"
    @docker system df -v 2>/dev/null | grep -E "powos-" || echo "No PowOS volumes found"

# Rebuild dev container from scratch
rebuild:
    docker compose build --no-cache powos-dev
    just dev

# Show container status
status:
    docker compose ps

# View logs
logs *args:
    docker compose logs {{args}}

# ═══════════════════════════════════════════════════════════════════
#  PACKAGE MANAGEMENT
# ═══════════════════════════════════════════════════════════════════

# Install packages (use inside container)
install +packages:
    @{{bin_dir}}/pinstall {{packages}}

# Remove packages (use inside container)
remove +packages:
    @{{bin_dir}}/premove {{packages}}

# Show installed packages from config
packages:
    @echo "Packages recorded in config:"
    @grep "additional_packages=" containers/distrobox.ini 2>/dev/null || echo "(none)"

# ═══════════════════════════════════════════════════════════════════
#  OVERLAY MANAGEMENT
# ═══════════════════════════════════════════════════════════════════

# Build a custom component overlay
build component:
    @{{lib_dir}}/overlay-manager.sh build {{component}}

# Build all overlays
build-all:
    @{{lib_dir}}/overlay-manager.sh build-all

# Enable an overlay (make active)
enable-overlay component:
    @{{lib_dir}}/overlay-manager.sh enable {{component}}

# Disable an overlay
disable-overlay component:
    @{{lib_dir}}/overlay-manager.sh disable {{component}}

# Enable all built overlays
enable-all-overlays:
    @{{lib_dir}}/overlay-manager.sh enable-all

# List all overlays with status
list-overlays:
    @{{lib_dir}}/overlay-manager.sh list

# Show status of specific overlay
overlay-status component:
    @{{lib_dir}}/overlay-manager.sh status {{component}}

# Clean a built overlay
clean-overlay component:
    @{{lib_dir}}/overlay-manager.sh clean {{component}}

# Clean all built overlays
clean-all-overlays:
    @{{lib_dir}}/overlay-manager.sh clean-all

# ═══════════════════════════════════════════════════════════════════
#  HARDWARE & PROFILES
# ═══════════════════════════════════════════════════════════════════

# Run hardware detection
detect:
    @{{lib_dir}}/hardware-detect.sh detect

# Show current hardware status
hw-status:
    @{{lib_dir}}/hardware-detect.sh status

# Apply a specific profile
mode profile:
    @{{lib_dir}}/hardware-detect.sh apply {{profile}}

# List available profiles
list-profiles:
    @{{lib_dir}}/hardware-detect.sh list

# Test hardware detection with mock
test-hw-mock hardware="nvidia-desktop" power="ac":
    @POWOS_MOCK_HARDWARE={{hardware}} POWOS_MOCK_POWER={{power}} {{lib_dir}}/hardware-detect.sh detect

# ═══════════════════════════════════════════════════════════════════
#  SYSTEM OPERATIONS
# ═══════════════════════════════════════════════════════════════════

# Full system hydration (restore from scratch)
hydrate:
    @echo "🌊 Hydrating PowOS..."
    @echo ""
    @echo "Step 1/4: Setting up distrobox containers..."
    distrobox assemble create --file containers/distrobox.ini || echo "Distrobox setup skipped (not available)"
    @echo ""
    @echo "Step 2/4: Building overlays..."
    just build-all || echo "No overlays to build"
    @echo ""
    @echo "Step 3/4: Enabling overlays..."
    just enable-all-overlays || echo "No overlays to enable"
    @echo ""
    @echo "Step 4/4: Restoring secrets..."
    just secrets-decrypt || echo "No secrets to restore"
    @echo ""
    @echo "✅ Hydration complete!"

# Minimal hydration (basic tools only)
hydrate-minimal:
    @echo "🌊 Minimal hydration..."
    distrobox assemble create --file containers/distrobox.ini || true
    @echo "✅ Minimal hydration complete!"

# System update with overlay checks
update:
    @echo "🔄 Starting update..."
    @echo ""
    @echo "Step 1: Checking overlay compatibility..."
    # TODO: Implement compatibility check
    @echo ""
    @echo "Step 2: Running system update..."
    rpm-ostree upgrade 2>/dev/null || echo "Not on ostree system (skipping)"
    @echo ""
    @echo "Step 3: Rebuilding overlays..."
    just build-all || echo "No overlays to rebuild"
    @echo ""
    @echo "✅ Update complete!"

# Update dry run (preview)
update-dry-run:
    @echo "🔍 Update dry run..."
    rpm-ostree upgrade --preview 2>/dev/null || echo "Not on ostree system"

# Initialize git repo if needed
init:
    @if [ ! -d .git ]; then \
        echo "Initializing git repository..."; \
        git init; \
        git add -A; \
        git commit -m "Initial PowOS setup"; \
    else \
        echo "Git repository already initialized"; \
    fi

# ═══════════════════════════════════════════════════════════════════
#  SECRETS MANAGEMENT
# ═══════════════════════════════════════════════════════════════════

# Decrypt secrets
secrets-decrypt:
    @echo "🔓 Decrypting secrets..."
    @if [ -f secrets/secrets.yaml.age ]; then \
        age -d -o /tmp/powos-secrets.yaml secrets/secrets.yaml.age 2>/dev/null || \
        sops -d secrets/secrets.yaml.age > /tmp/powos-secrets.yaml 2>/dev/null || \
        echo "Failed to decrypt (check your key)"; \
    else \
        echo "No secrets file found"; \
    fi

# Encrypt secrets
secrets-encrypt:
    @echo "🔒 Encrypting secrets..."
    @if [ -f /tmp/powos-secrets.yaml ]; then \
        age -e -R secrets/age-recipients.txt -o secrets/secrets.yaml.age /tmp/powos-secrets.yaml 2>/dev/null || \
        sops -e /tmp/powos-secrets.yaml > secrets/secrets.yaml.age 2>/dev/null || \
        echo "Failed to encrypt"; \
        rm -f /tmp/powos-secrets.yaml; \
    else \
        echo "No secrets to encrypt (create /tmp/powos-secrets.yaml first)"; \
    fi

# Generate new age key
secrets-keygen:
    @echo "🔑 Generating new age key..."
    @mkdir -p secrets
    age-keygen -o secrets/age-key.txt 2>/dev/null || echo "age not installed"
    @echo "Key saved to secrets/age-key.txt"
    @echo "Add public key to secrets/age-recipients.txt"

# ═══════════════════════════════════════════════════════════════════
#  ISO BUILDING (Production)
# ═══════════════════════════════════════════════════════════════════

# Build bootable PowOS ISO (the main goal!)
build-iso:
    @echo "🔥 Building PowOS bootable ISO..."
    @echo ""
    @echo "NOTE: ISO building requires podman (not docker) and bootc-image-builder"
    @echo ""
    @mkdir -p build/output
    bash build/build-iso.sh full
    @echo ""
    @echo "ISO should be at: build/output/powos.iso"
    @ls -lh build/output/*.iso 2>/dev/null || echo "Check build/output/ for results"

# Build container image only (faster, for testing)
build-iso-test:
    @echo "🔥 Building PowOS container image only..."
    bash build/build-iso.sh test

# Build container image only (for testing)
build-image:
    @echo "🏗️ Building PowOS container image..."
    podman build -f Containerfile.base -t localhost/powos:latest . || \
    docker build -f Containerfile.base -t powos:latest .
    @echo "✅ Image built"

# Install PowOS to USB drive
install-usb device:
    @echo "💾 Installing PowOS to {{device}}..."
    sudo bash build/install-to-usb.sh {{device}}

# Push to registry
push registry="ghcr.io/user/powos":
    podman tag localhost/powos:latest {{registry}}:latest
    podman push {{registry}}:latest
    @echo "Pushed to {{registry}}"

# ═══════════════════════════════════════════════════════════════════
#  VM TESTING (Tier 2)
# ═══════════════════════════════════════════════════════════════════

# Create QEMU disk image for testing
vm-create-disk size="20G":
    @mkdir -p test/tier2
    qemu-img create -f qcow2 test/tier2/powos-test.qcow2 {{size}}
    @echo "Created: test/tier2/powos-test.qcow2 ({{size}})"

# Boot VM for testing (requires ISO)
vm-boot:
    @if [ ! -f test/tier2/powos.iso ]; then \
        echo "Error: test/tier2/powos.iso not found"; \
        echo "Place a bootable ISO there first"; \
        exit 1; \
    fi
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

# Boot VM from disk only (after install)
vm-boot-installed:
    qemu-system-x86_64 \
        -enable-kvm \
        -m 4G \
        -smp 4 \
        -drive file=test/tier2/powos-test.qcow2,format=qcow2 \
        -display gtk \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22

# SSH into running VM
vm-ssh:
    ssh -p 2222 localhost

# ═══════════════════════════════════════════════════════════════════
#  AI INTEGRATION
# ═══════════════════════════════════════════════════════════════════

# Start Ollama service
ai-start:
    docker compose --profile ai up -d ollama
    @echo "Waiting for Ollama..."
    @sleep 5
    @echo "Ollama available at http://localhost:11434"

# Pull AI model for patching
ai-pull model="codellama:7b":
    docker compose exec ollama ollama pull {{model}}

# Test AI connection
ai-test:
    @curl -s http://localhost:11434/api/tags | jq '.models[].name' 2>/dev/null || \
        echo "Ollama not running. Start with: just ai-start"

# Stop Ollama
ai-stop:
    docker compose --profile ai stop ollama

# ═══════════════════════════════════════════════════════════════════
#  UTILITIES
# ═══════════════════════════════════════════════════════════════════

# Format all shell scripts
fmt:
    @echo "Formatting shell scripts..."
    shfmt -w -i 4 bin/* lib/* 2>/dev/null || echo "shfmt not installed"

# Lint shell scripts
lint:
    @echo "Linting shell scripts..."
    shellcheck bin/* lib/*.sh 2>/dev/null || echo "shellcheck not installed"

# Show project structure
tree:
    @tree -I 'extensions|.git|node_modules' --dirsfirst 2>/dev/null || \
        find . -type f -not -path './.git/*' -not -path './extensions/*' | sort

# Quick setup for new clone
setup:
    just init
    chmod +x bin/* lib/*.sh systemd/* 2>/dev/null || true
    @echo "Setup complete! Run 'just dev' to start"

# ═══════════════════════════════════════════════════════════════════
#  PRODUCTION DEPLOYMENT
# ═══════════════════════════════════════════════════════════════════

# Build production OS container image
build-prod:
    @echo "🏗️ Building PowOS production image..."
    podman build -f Containerfile.base -t ghcr.io/user/powos:latest .
    @echo "✅ Production image built"

# Deploy to bootc/ostree system
deploy-prod:
    @echo "🚀 Deploying PowOS..."
    @if command -v bootc &>/dev/null; then \
        sudo bootc switch ghcr.io/user/powos:latest; \
    elif command -v rpm-ostree &>/dev/null; then \
        sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/user/powos:latest; \
    else \
        echo "Neither bootc nor rpm-ostree available"; \
        exit 1; \
    fi
    @echo "✅ Deployment complete - reboot to apply"

# Install systemd services (for dev/testing)
install-services:
    @echo "📦 Installing PowOS systemd services..."
    sudo mkdir -p /etc/powos
    sudo cp config/etc/powos.conf /etc/powos/config
    sudo cp systemd/*.service /usr/lib/systemd/system/
    sudo cp systemd/powos-* /usr/lib/powos/
    sudo chmod +x /usr/lib/powos/powos-*
    sudo systemctl daemon-reload
    @echo "✅ Services installed"

# Enable PowOS services for boot
enable-services:
    @echo "🔧 Enabling PowOS services..."
    sudo systemctl enable powos-init.service
    sudo systemctl enable powos-hardware.service
    sudo systemctl enable powos-overlay.service
    @echo "✅ Services enabled"

# Run boot-time hardware detection manually
run-hw-detect:
    @echo "🔍 Running hardware detection..."
    sudo /usr/lib/powos/powos-hardware-detect 2>&1 || \
        sudo bash systemd/powos-hardware-detect

# Run overlay loading manually
run-overlay-load:
    @echo "📦 Loading overlays..."
    sudo /usr/lib/powos/powos-overlay-load 2>&1 || \
        sudo bash systemd/powos-overlay-load

# Run full hydration manually
run-hydrate:
    @echo "🌊 Running hydration..."
    sudo /usr/lib/powos/powos-hydrate 2>&1 || \
        sudo bash systemd/powos-hydrate

# ═══════════════════════════════════════════════════════════════════
#  USB INSTALLATION
# ═══════════════════════════════════════════════════════════════════

# Create bootable USB with PowOS (DANGEROUS - targets entire device)
create-usb device:
    @echo "⚠️  WARNING: This will ERASE ALL DATA on {{device}}"
    @echo "Device: {{device}}"
    @read -p "Type 'yes' to continue: " confirm && [ "$$confirm" = "yes" ] || exit 1
    @echo ""
    @echo "Creating bootable PowOS USB..."
    # TODO: Implement USB creation (use bootc-image-builder or similar)
    @echo "Not yet implemented - use bootc-image-builder"

# Partition USB for PowOS (EFI + Data)
partition-usb device:
    @echo "⚠️  WARNING: This will ERASE ALL DATA on {{device}}"
    @read -p "Type 'yes' to continue: " confirm && [ "$$confirm" = "yes" ] || exit 1
    @echo "Partitioning {{device}}..."
    # Create GPT table with EFI and data partitions
    sudo parted {{device}} --script \
        mklabel gpt \
        mkpart ESP fat32 1MiB 512MiB \
        set 1 esp on \
        mkpart POWOS ext4 512MiB 100%
    sudo mkfs.fat -F32 {{device}}1
    sudo mkfs.ext4 -L POWOS {{device}}2
    @echo "✅ Partitioned {{device}}"

# ═══════════════════════════════════════════════════════════════════
#  DIAGNOSTICS
# ═══════════════════════════════════════════════════════════════════

# Show full system status
full-status:
    @echo "═══════════════════════════════════════════════════════════"
    @echo " PowOS System Status"
    @echo "═══════════════════════════════════════════════════════════"
    @echo ""
    @echo "Hardware:"
    @cat /run/powos/hardware 2>/dev/null || echo "  (not detected yet)"
    @echo ""
    @echo "Boot State:"
    @cat /var/lib/powos/state/boot-state 2>/dev/null || echo "  (not initialized)"
    @echo ""
    @echo "Active Overlays:"
    @systemd-sysext status 2>/dev/null || echo "  (systemd-sysext not available)"
    @echo ""
    @echo "Services:"
    @systemctl is-active powos-init.service 2>/dev/null && echo "  powos-init: active" || echo "  powos-init: inactive"
    @systemctl is-active powos-hardware.service 2>/dev/null && echo "  powos-hardware: active" || echo "  powos-hardware: inactive"
    @systemctl is-active powos-overlay.service 2>/dev/null && echo "  powos-overlay: active" || echo "  powos-overlay: inactive"
    @echo ""
    @echo "Containers:"
    @distrobox list 2>/dev/null || echo "  (distrobox not available)"

# View PowOS service logs
service-logs service="powos-init":
    journalctl -u {{service}}.service --no-pager -n 50

# View all PowOS logs
powos-logs:
    journalctl -t powos-init -t powos-hardware -t powos-overlay -t powos-hydrate --no-pager -n 100

# Check for issues
diagnose:
    @echo "🔍 Running diagnostics..."
    @echo ""
    @echo "Checking systemd-sysext..."
    @systemd-sysext list 2>/dev/null || echo "  ❌ systemd-sysext not available"
    @echo ""
    @echo "Checking distrobox..."
    @distrobox --version 2>/dev/null || echo "  ❌ distrobox not installed"
    @echo ""
    @echo "Checking podman..."
    @podman --version 2>/dev/null || echo "  ❌ podman not installed"
    @echo ""
    @echo "Checking persistent storage..."
    @if [ -d /mnt/powos ]; then echo "  ✅ /mnt/powos exists"; else echo "  ⚠️  /mnt/powos not mounted"; fi
    @echo ""
    @echo "Checking PowOS directories..."
    @ls -la /var/lib/powos 2>/dev/null || echo "  ⚠️  /var/lib/powos not found"
