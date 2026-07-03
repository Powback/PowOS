#!/usr/bin/bash
# PowOS Hardware Detection and Overlay Activation Script
# This script runs at boot to detect hardware and activate appropriate overlays

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function log_info() {
    echo -e "${GREEN}[PowOS]${NC} $*"
}

function log_warn() {
    echo -e "${YELLOW}[PowOS]${NC} $*"
}

function log_error() {
    echo -e "${RED}[PowOS]${NC} $*"
}

# Paths
OVERLAY_AVAILABLE_DIR="/usr/share/powos/overlays"
OVERLAY_ACTIVE_DIR="/var/lib/extensions"
STATE_FILE="/var/lib/powos/hardware-state"

# Create directories if they don't exist
mkdir -p "$OVERLAY_ACTIVE_DIR"
mkdir -p "$(dirname "$STATE_FILE")"

# Hardware detection
log_info "Detecting hardware..."

# Get DMI information
DMI_PRODUCT_NAME=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "Unknown")
DMI_CHASSIS_VENDOR=$(cat /sys/devices/virtual/dmi/id/chassis_vendor 2>/dev/null || echo "Unknown")
DMI_CHASSIS_TYPE=$(cat /sys/devices/virtual/dmi/id/chassis_type 2>/dev/null || echo "Unknown")
DMI_BOARD_NAME=$(cat /sys/devices/virtual/dmi/id/board_name 2>/dev/null || echo "Unknown")

log_info "Product Name: $DMI_PRODUCT_NAME"
log_info "Chassis Vendor: $DMI_CHASSIS_VENDOR"
log_info "Chassis Type: $DMI_CHASSIS_TYPE"

# Get CPU information
CPU_VENDOR=$(grep "vendor_id" /proc/cpuinfo | uniq | awk -F": " '{ print $2 }' || echo "Unknown")
log_info "CPU Vendor: $CPU_VENDOR"

# Get GPU information
GPU_INFO=$(lspci | grep -E "VGA|3D" || echo "Unknown")
log_info "GPU: $GPU_INFO"

# Detect GPU vendor for logging
GPU_VENDOR="Unknown"
if echo "$GPU_INFO" | grep -qi "NVIDIA"; then
    GPU_VENDOR="NVIDIA"
elif echo "$GPU_INFO" | grep -qi "AMD"; then
    GPU_VENDOR="AMD"
elif echo "$GPU_INFO" | grep -qi "Intel"; then
    GPU_VENDOR="Intel"
fi
log_info "GPU Vendor: $GPU_VENDOR"

# Function to activate an overlay
activate_overlay() {
    local overlay_name="$1"
    local overlay_file="${OVERLAY_AVAILABLE_DIR}/${overlay_name}.raw"
    local symlink_target="${OVERLAY_ACTIVE_DIR}/${overlay_name}.raw"

    if [[ -f "$overlay_file" ]]; then
        log_info "Activating overlay: $overlay_name"
        ln -sf "$overlay_file" "$symlink_target"
        echo "$overlay_name" >> "$STATE_FILE.new"
        return 0
    else
        log_warn "Overlay not found: $overlay_name ($overlay_file)"
        return 1
    fi
}

# Function to enable systemd services
enable_services() {
    log_info "Enabling services: $*"
    for service in "$@"; do
        if systemctl enable "$service" 2>/dev/null; then
            log_info "  Enabled: $service"
        else
            log_warn "  Failed to enable: $service"
        fi
    done
}

# Function to disable systemd services
disable_services() {
    log_info "Disabling services: $*"
    for service in "$@"; do
        if systemctl disable "$service" 2>/dev/null; then
            log_info "  Disabled: $service"
        else
            log_warn "  Failed to disable: $service (might not be enabled)"
        fi
    done
}

# Start fresh list of active overlays
rm -f "$STATE_FILE.new"
touch "$STATE_FILE.new"

# Device-specific detection
DEVICE_DETECTED=false

# Check for Valve Steam Deck (Jupiter = LCD, Galileo = OLED)
if [[ ":Jupiter:Galileo:" =~ ":$DMI_PRODUCT_NAME:" ]]; then
    log_info "Detected: Valve Steam Deck ($DMI_PRODUCT_NAME)"

    if [[ "$DMI_PRODUCT_NAME" == "Jupiter" ]]; then
        activate_overlay "steamdeck-jupiter"
    elif [[ "$DMI_PRODUCT_NAME" == "Galileo" ]]; then
        activate_overlay "steamdeck-galileo"
    fi

    # Enable Steam Deck-specific services
    enable_services \
        jupiter-fan-control.service \
        vpower.service \
        pipewire-workaround.service \
        wireplumber-workaround.service

    # Activate gaming mode for Steam Deck
    activate_overlay "gaming-mode"
    enable_services \
        hhd.service \
        bazzite-autologin.service

    # Disable desktop-only services
    disable_services \
        input-remapper.service \
        uupd.timer

    DEVICE_DETECTED=true

# Check for ASUS ROG Ally
elif [[ "$DMI_PRODUCT_NAME" =~ "ROG Ally" ]]; then
    log_info "Detected: ASUS ROG Ally"
    activate_overlay "rog-ally"

    # Activate gaming mode for ROG Ally
    activate_overlay "gaming-mode"
    enable_services \
        hhd.service \
        bazzite-autologin.service

    # Disable desktop-only services
    disable_services \
        input-remapper.service \
        uupd.timer

    DEVICE_DETECTED=true

# Check for Lenovo Legion Go (DMI board name is 83E1)
elif [[ "$DMI_BOARD_NAME" == "83E1" || "$DMI_PRODUCT_NAME" =~ "Legion Go" ]]; then
    log_info "Detected: Lenovo Legion Go"
    activate_overlay "legion-go"

    # Activate gaming mode for Legion Go
    activate_overlay "gaming-mode"
    enable_services \
        hhd.service \
        bazzite-autologin.service

    # Disable desktop-only services
    disable_services \
        input-remapper.service \
        uupd.timer

    DEVICE_DETECTED=true

# Generic handheld detection (chassis type 30 = tablet, 31 = convertible)
elif [[ "$DMI_CHASSIS_TYPE" == "30" || "$DMI_CHASSIS_TYPE" == "31" ]]; then
    log_info "Detected: Generic handheld/tablet device"
    log_warn "No specific device overlay found, using generic configuration"

    # Could activate a generic handheld overlay if it exists
    # activate_overlay "handheld-generic"

    DEVICE_DETECTED=false

# Desktop or laptop
else
    log_info "Detected: Desktop or laptop computer"

    # Check chassis type for laptop-specific optimizations
    # Chassis type 10 = laptop, 9 = laptop, 8 = portable
    if [[ "$DMI_CHASSIS_TYPE" =~ ^(8|9|10)$ ]]; then
        log_info "Form factor: Laptop"
        # activate_overlay "laptop-power"  # If this overlay exists
    else
        log_info "Form factor: Desktop"
        # activate_overlay "desktop-perf"  # If this overlay exists
    fi

    # Enable desktop services
    enable_services \
        input-remapper.service

    DEVICE_DETECTED=false
fi

# Refresh systemd-sysext to apply overlays
log_info "Refreshing systemd-sysext..."
if systemd-sysext refresh; then
    log_info "Successfully activated overlays"
else
    log_error "Failed to refresh systemd-sysext"
    exit 1
fi

# Save the state
mv "$STATE_FILE.new" "$STATE_FILE"

# Show active overlays
log_info "Active overlays:"
if [[ -f "$STATE_FILE" ]]; then
    while read -r overlay; do
        log_info "  - $overlay"
    done < "$STATE_FILE"
else
    log_info "  (none)"
fi

# Show systemd-sysext status
log_info "systemd-sysext status:"
systemd-sysext status || true

log_info "Hardware detection complete!"
