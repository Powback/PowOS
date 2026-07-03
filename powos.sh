#!/bin/bash
# PowOS Launcher - detects hardware and starts the right image
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

echo -e "${MAGENTA}"
cat << 'EOF'
    ____                 ____  _____
   / __ \____ _      __/ __ \/ ___/
  / /_/ / __ \ | /| / / / / /\__ \
 / ____/ /_/ / |/ |/ / /_/ /___/ /
/_/    \____/|__/|__/\____//____/
EOF
echo -e "${NC}"

# ═══════════════════════════════════════════════════════════════════
# Step 1: GPU Detection (on HOST, before container starts)
# ═══════════════════════════════════════════════════════════════════
echo -e "${CYAN}Detecting GPU...${NC}"

detect_gpu() {
    # Windows (check for nvidia-smi)
    if command -v nvidia-smi &>/dev/null; then
        echo "nvidia"
        return
    fi

    # Linux - check lspci
    if command -v lspci &>/dev/null; then
        if lspci | grep -qi "NVIDIA"; then
            echo "nvidia"
            return
        fi
    fi

    # WSL - check for NVIDIA
    if [[ -f /proc/driver/nvidia/version ]]; then
        echo "nvidia"
        return
    fi

    # Default to mesa
    echo "mesa"
}

GPU=$(detect_gpu)
echo -e "${GREEN}Detected GPU: ${GPU}${NC}"

# ═══════════════════════════════════════════════════════════════════
# Step 2: Select and start the right image
# ═══════════════════════════════════════════════════════════════════
echo -e "${CYAN}Starting PowOS (${GPU} image)...${NC}"

export POWOS_GPU="$GPU"
export POWOS_IMAGE="ghcr.io/bazzite-org/bazzite:stable"

# For nvidia, we'd use the nvidia variant when we have it built
# For now both use the same base, but the boot script will configure appropriately
if [[ "$GPU" == "nvidia" ]]; then
    export POWOS_IMAGE="ghcr.io/bazzite-org/bazzite-nvidia:stable"
fi

echo -e "${CYAN}Using image: ${POWOS_IMAGE}${NC}"

# Run docker compose with the selected image
docker compose up --build "$@"
