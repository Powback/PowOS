#!/bin/bash
# detect-gpu.sh - Detect GPU vendor for PowOS image selection
#
# Returns: "nvidia" | "amd" | "intel" | "mesa" (fallback)
# Exit codes: 0 = detected, 1 = fallback used
#
# Usage:
#   GPU=$(detect-gpu.sh)
#   detect-gpu.sh --verbose

set -euo pipefail

VERBOSE="${1:-}"

log() {
    [[ "$VERBOSE" == "--verbose" || "$VERBOSE" == "-v" ]] && echo "[gpu-detect] $*" >&2
}

# PCI Vendor IDs
NVIDIA_VENDOR="0x10de"
AMD_VENDOR="0x1002"
INTEL_VENDOR="0x8086"

detect_from_sysfs() {
    # Check /sys/class/drm for GPU info
    for card in /sys/class/drm/card[0-9]*/device/vendor; do
        [[ -f "$card" ]] || continue
        vendor=$(cat "$card" 2>/dev/null || true)

        log "Found GPU vendor: $vendor (from $card)"

        case "$vendor" in
            "$NVIDIA_VENDOR"|"0x10DE")
                echo "nvidia"
                return 0
                ;;
        esac
    done

    # No NVIDIA found, check for AMD or Intel
    for card in /sys/class/drm/card[0-9]*/device/vendor; do
        [[ -f "$card" ]] || continue
        vendor=$(cat "$card" 2>/dev/null || true)

        case "$vendor" in
            "$AMD_VENDOR"|"0x1002")
                echo "amd"
                return 0
                ;;
            "$INTEL_VENDOR"|"0x8086")
                echo "intel"
                return 0
                ;;
        esac
    done

    return 1
}

detect_from_lspci() {
    # Fallback: use lspci if available
    command -v lspci &>/dev/null || return 1

    local pci_output
    pci_output=$(lspci 2>/dev/null || true)

    # Check for NVIDIA first (discrete GPU takes priority)
    if echo "$pci_output" | grep -qi "VGA.*NVIDIA\|3D.*NVIDIA"; then
        log "Found NVIDIA via lspci"
        echo "nvidia"
        return 0
    fi

    # Check for AMD
    if echo "$pci_output" | grep -qi "VGA.*AMD\|VGA.*ATI\|VGA.*Radeon"; then
        log "Found AMD via lspci"
        echo "amd"
        return 0
    fi

    # Check for Intel
    if echo "$pci_output" | grep -qi "VGA.*Intel"; then
        log "Found Intel via lspci"
        echo "intel"
        return 0
    fi

    return 1
}

detect_from_modules() {
    # Check loaded kernel modules
    if [[ -f /proc/modules ]]; then
        if grep -q "^nvidia " /proc/modules 2>/dev/null; then
            log "Found nvidia kernel module loaded"
            echo "nvidia"
            return 0
        fi

        if grep -q "^amdgpu " /proc/modules 2>/dev/null; then
            log "Found amdgpu kernel module loaded"
            echo "amd"
            return 0
        fi

        if grep -q "^i915 " /proc/modules 2>/dev/null; then
            log "Found i915 kernel module loaded"
            echo "intel"
            return 0
        fi
    fi

    return 1
}

detect_hybrid() {
    # Special handling for hybrid GPU laptops (Intel/AMD + NVIDIA)
    # If we have NVIDIA discrete, prefer nvidia image even if integrated exists

    local has_nvidia=false
    local has_integrated=false

    for card in /sys/class/drm/card[0-9]*/device/vendor; do
        [[ -f "$card" ]] || continue
        vendor=$(cat "$card" 2>/dev/null || true)

        case "$vendor" in
            "$NVIDIA_VENDOR"|"0x10DE")
                has_nvidia=true
                ;;
            "$AMD_VENDOR"|"0x1002"|"$INTEL_VENDOR"|"0x8086")
                has_integrated=true
                ;;
        esac
    done

    if $has_nvidia; then
        log "Hybrid GPU detected - NVIDIA discrete present, using nvidia image"
        echo "nvidia"
        return 0
    fi

    return 1
}

main() {
    log "Starting GPU detection..."

    # Priority 1: Check for hybrid setup (NVIDIA discrete takes priority)
    if detect_hybrid; then
        exit 0
    fi

    # Priority 2: Check sysfs (most reliable)
    if detect_from_sysfs; then
        exit 0
    fi

    # Priority 3: Check lspci
    if detect_from_lspci; then
        exit 0
    fi

    # Priority 4: Check loaded modules
    if detect_from_modules; then
        exit 0
    fi

    # Fallback: assume mesa (works for AMD + Intel)
    log "No specific GPU detected, defaulting to mesa"
    echo "mesa"
    exit 1
}

main
