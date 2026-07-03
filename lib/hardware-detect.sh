#!/usr/bin/env bash
# hardware-detect.sh - Chameleon boot hardware detection
#
# Automatically detects hardware and applies appropriate profiles.
# Supports mocking for testing via POWOS_MOCK_HARDWARE and POWOS_MOCK_POWER.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────

POWOS_ROOT="${POWOS_ROOT:-$HOME/powos}"
PROFILES_DIR="${POWOS_PROFILES_DIR:-/etc/powos/profiles}"
MOCK_HARDWARE="${POWOS_MOCK_HARDWARE:-}"
MOCK_POWER="${POWOS_MOCK_POWER:-}"
MOCK_VIRT="${POWOS_MOCK_VIRT:-}"
LOG_PREFIX="[hardware-detect]"

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# ─────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────

log_info() {
    echo -e "${BLUE}${LOG_PREFIX}${NC} $*"
}

log_success() {
    echo -e "${GREEN}${LOG_PREFIX}${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}${LOG_PREFIX}${NC} $*"
}

log_error() {
    echo -e "${RED}${LOG_PREFIX}${NC} $*" >&2
}

log_detail() {
    echo -e "${CYAN}${LOG_PREFIX}${NC}   -> $*"
}

# ─────────────────────────────────────────────────────────────────
# Hardware Detection Functions
# ─────────────────────────────────────────────────────────────────

# Detect GPU type
detect_gpu() {
    # Use mock if set (for testing)
    if [[ -n "$MOCK_HARDWARE" ]]; then
        log_detail "Using mock hardware: $MOCK_HARDWARE" >&2
        echo "$MOCK_HARDWARE"
        return
    fi

    # Check for lspci
    if ! command -v lspci &>/dev/null; then
        log_warn "lspci not available, assuming unknown GPU"
        echo "unknown"
        return
    fi

    local lspci_output
    lspci_output=$(lspci 2>/dev/null || true)

    # Check for Nvidia
    if echo "$lspci_output" | grep -qi "nvidia"; then
        # Determine if desktop or mobile by looking for high-end desktop cards
        if echo "$lspci_output" | grep -qiE "GeForce RTX (30|40|50)|Quadro|Tesla|A100|A6000|H100"; then
            echo "nvidia-desktop"
        elif echo "$lspci_output" | grep -qiE "GeForce (GTX|RTX).*Mobile|GeForce MX"; then
            echo "nvidia-mobile"
        else
            # Default to desktop for other Nvidia cards
            echo "nvidia-desktop"
        fi
        return
    fi

    # Check for AMD
    if echo "$lspci_output" | grep -qiE "AMD.*Radeon|AMD.*Graphics"; then
        if echo "$lspci_output" | grep -qiE "RX (6[89]00|7[89]00|9[0-9]{3})"; then
            echo "amd-desktop"
        else
            echo "amd"
        fi
        return
    fi

    # Check for Intel
    if echo "$lspci_output" | grep -qiE "Intel.*Graphics|Intel.*UHD|Intel.*Iris"; then
        echo "intel"
        return
    fi

    echo "unknown"
}

# Detect power source (AC or battery)
detect_power_source() {
    # Use mock if set
    if [[ -n "$MOCK_POWER" ]]; then
        log_detail "Using mock power: $MOCK_POWER" >&2
        echo "$MOCK_POWER"
        return
    fi

    # Check for AC adapter
    local ac_paths=(
        /sys/class/power_supply/AC*
        /sys/class/power_supply/ADP*
        /sys/class/power_supply/ACAD*
    )

    for ac_path in "${ac_paths[@]}"; do
        if [[ -d $ac_path ]]; then
            if [[ -f "${ac_path}/online" ]]; then
                if [[ "$(cat "${ac_path}/online" 2>/dev/null)" == "1" ]]; then
                    echo "ac"
                    return
                fi
            fi
        fi
    done

    # Check for battery
    if [[ -d /sys/class/power_supply/BAT* ]]; then
        echo "battery"
        return
    fi

    # No battery detected = desktop
    echo "ac"
}

# Detect if running in VM
detect_virtualization() {
    # Use mock if set
    if [[ -n "$MOCK_VIRT" ]]; then
        log_detail "Using mock virtualization: $MOCK_VIRT" >&2
        echo "$MOCK_VIRT"
        return
    fi

    if [[ -f /sys/class/dmi/id/product_name ]]; then
        local product
        product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)

        case "$product" in
            *VirtualBox*|*VMware*|*QEMU*|*KVM*)
                echo "vm"
                return
                ;;
        esac
    fi

    # Check systemd-detect-virt if available
    if command -v systemd-detect-virt &>/dev/null; then
        local virt
        virt=$(systemd-detect-virt 2>/dev/null || echo "none")
        if [[ "$virt" != "none" ]]; then
            echo "vm"
            return
        fi
    fi

    echo "physical"
}

# Detect system form factor
detect_form_factor() {
    # Check for battery presence (laptops have batteries)
    if [[ -d /sys/class/power_supply/BAT0 ]] || [[ -d /sys/class/power_supply/BAT1 ]]; then
        echo "laptop"
        return
    fi

    # Check chassis type via DMI
    if [[ -f /sys/class/dmi/id/chassis_type ]]; then
        local chassis
        chassis=$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo "0")

        case "$chassis" in
            3|4|5|6|7|15|16)  # Desktop, Low Profile Desktop, Mini Tower, Tower, etc.
                echo "desktop"
                ;;
            8|9|10|11|14)  # Portable, Laptop, Notebook, etc.
                echo "laptop"
                ;;
            *)
                echo "unknown"
                ;;
        esac
        return
    fi

    echo "unknown"
}

# ─────────────────────────────────────────────────────────────────
# Profile Application
# ─────────────────────────────────────────────────────────────────

# Apply a system profile
apply_profile() {
    local profile="$1"
    local profile_file="${PROFILES_DIR}/${profile}.conf"

    log_info "Applying profile: $profile"

    if [[ ! -f "$profile_file" ]]; then
        log_warn "Profile file not found: $profile_file"
        log_detail "Creating default profile..."
        return 1
    fi

    # Source the profile (it should export functions/variables)
    # shellcheck source=/dev/null
    source "$profile_file"

    # Call profile_apply if defined
    if declare -f profile_apply &>/dev/null; then
        profile_apply
    fi

    log_success "Profile applied: $profile"
}

# Load Nvidia drivers
load_nvidia() {
    log_info "Loading Nvidia drivers..."

    if [[ "${POWOS_DEV:-}" == "1" ]]; then
        log_detail "(DEV) Would load: nvidia nvidia_modeset nvidia_uvm nvidia_drm"
        return 0
    fi

    # Load modules
    local modules=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
    for mod in "${modules[@]}"; do
        if ! lsmod | grep -q "^${mod}"; then
            modprobe "$mod" 2>/dev/null || log_warn "Failed to load $mod"
        fi
    done

    log_success "Nvidia drivers loaded"
}

# Unload Nvidia drivers (for battery mode)
unload_nvidia() {
    log_info "Unloading Nvidia drivers..."

    if [[ "${POWOS_DEV:-}" == "1" ]]; then
        log_detail "(DEV) Would unload: nvidia nvidia_modeset nvidia_uvm nvidia_drm"
        return 0
    fi

    # Unload in reverse order
    local modules=(nvidia_drm nvidia_uvm nvidia_modeset nvidia)
    for mod in "${modules[@]}"; do
        if lsmod | grep -q "^${mod}"; then
            rmmod "$mod" 2>/dev/null || log_warn "Failed to unload $mod (may be in use)"
        fi
    done

    log_success "Nvidia drivers unloaded"
}

# Enable power management for PCI devices
enable_power_management() {
    log_info "Enabling PCI power management..."

    if [[ "${POWOS_DEV:-}" == "1" ]]; then
        log_detail "(DEV) Would set power/control to auto"
        return 0
    fi

    for device in /sys/bus/pci/devices/*/power/control; do
        if [[ -w "$device" ]]; then
            echo "auto" > "$device" 2>/dev/null || true
        fi
    done

    log_success "Power management enabled"
}

# ─────────────────────────────────────────────────────────────────
# Main Detection Logic
# ─────────────────────────────────────────────────────────────────

detect_and_configure() {
    log_info "Starting hardware detection..."

    # Gather hardware info
    local gpu power virt form_factor
    gpu=$(detect_gpu)
    power=$(detect_power_source)
    virt=$(detect_virtualization)
    form_factor=$(detect_form_factor)

    log_info "Detection results:"
    log_detail "GPU: $gpu"
    log_detail "Power: $power"
    log_detail "Virtualization: $virt"
    log_detail "Form factor: $form_factor"

    # Determine profile based on hardware
    local profile="default"

    case "$gpu" in
        nvidia-desktop)
            profile="desktop-performance"
            load_nvidia
            ;;
        nvidia-mobile)
            if [[ "$power" == "battery" ]]; then
                profile="laptop-battery"
                unload_nvidia
                enable_power_management
            else
                profile="desktop-performance"
                load_nvidia
            fi
            ;;
        amd-desktop|amd)
            if [[ "$form_factor" == "laptop" && "$power" == "battery" ]]; then
                profile="laptop-battery"
            else
                profile="desktop-performance"
            fi
            ;;
        intel)
            if [[ "$power" == "battery" ]]; then
                profile="laptop-battery"
                enable_power_management
            else
                profile="laptop-balanced"
            fi
            ;;
        *)
            log_warn "Unknown GPU type, using default profile"
            profile="default"
            ;;
    esac

    # VM override
    if [[ "$virt" == "vm" ]]; then
        log_info "Running in VM, using VM-optimized profile"
        profile="vm-balanced"
    fi

    # Apply the selected profile
    apply_profile "$profile" || log_warn "Could not apply profile $profile"

    log_success "Hardware detection complete"

    # Output summary for systemd/logging
    cat << EOF

=== PowOS Hardware Configuration ===
GPU Type:       $gpu
Power Source:   $power
Virtualization: $virt
Form Factor:    $form_factor
Applied Profile: $profile
====================================

EOF
}

# ─────────────────────────────────────────────────────────────────
# CLI Interface
# ─────────────────────────────────────────────────────────────────

show_help() {
    cat << EOF
Usage: $(basename "$0") [command]

Commands:
    detect      Run hardware detection and configure system (default)
    status      Show current hardware status without changing anything
    apply       Apply a specific profile: apply <profile-name>
    list        List available profiles

Environment Variables:
    POWOS_MOCK_HARDWARE   Mock GPU type for testing (nvidia-desktop, intel, etc.)
    POWOS_MOCK_POWER      Mock power source (ac, battery)
    POWOS_DEV             Set to 1 for development mode (no actual changes)
    POWOS_PROFILES_DIR    Custom profiles directory

Examples:
    $(basename "$0") detect                      # Auto-detect and configure
    $(basename "$0") status                      # Show current status
    $(basename "$0") apply desktop-performance   # Force specific profile
    POWOS_MOCK_HARDWARE=intel $(basename "$0")   # Test with mock hardware
EOF
}

show_status() {
    log_info "Current hardware status:"
    log_detail "GPU: $(detect_gpu)"
    log_detail "Power: $(detect_power_source)"
    log_detail "Virtualization: $(detect_virtualization)"
    log_detail "Form Factor: $(detect_form_factor)"
}

list_profiles() {
    log_info "Available profiles:"
    if [[ -d "$PROFILES_DIR" ]]; then
        for profile in "$PROFILES_DIR"/*.conf; do
            if [[ -f "$profile" ]]; then
                local name
                name=$(basename "$profile" .conf)
                log_detail "$name"
            fi
        done
    else
        log_warn "Profiles directory not found: $PROFILES_DIR"
    fi
}

# ─────────────────────────────────────────────────────────────────
# Entry Point
# ─────────────────────────────────────────────────────────────────

main() {
    local command="${1:-detect}"

    case "$command" in
        detect)
            detect_and_configure
            ;;
        status)
            show_status
            ;;
        apply)
            if [[ -z "${2:-}" ]]; then
                log_error "Profile name required"
                exit 1
            fi
            apply_profile "$2"
            ;;
        list)
            list_profiles
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
