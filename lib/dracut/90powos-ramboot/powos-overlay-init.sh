#!/bin/bash
# powos-overlay-init.sh - Userspace initialization for RAM overlay
#
# This runs after boot to set up sync daemon and USB monitoring.
# The heavy lifting (overlayfs) was already done in initramfs.

set -e

STATE_FILE="/run/powos/ramboot-state"
USB_STATE="/run/powos/usb-state"

log() { echo "[powos-overlay] $*"; }
log_ok() { echo "[powos-overlay] ✓ $*"; }

# Check if we booted with ramboot
if [[ ! -f "$STATE_FILE" ]]; then
    log "Not running in ramboot mode"
    exit 0
fi

source "$STATE_FILE"
log "Running in RAM overlay mode"
log "  RAM allocated: $POWOS_RAM_SIZE"
log "  Active layers: $POWOS_LAYERS_ACTIVE"
log "  Upper (RAM):   $POWOS_OVERLAY_UPPER"

# Detect and track USB
detect_usb() {
    local usb_dev
    usb_dev=$(blkid -L "POWOS-DATA" 2>/dev/null || true)

    if [[ -z "$usb_dev" ]]; then
        # Try alternate label
        usb_dev=$(blkid -L "POWOS-HOME" 2>/dev/null || true)
    fi

    if [[ -n "$usb_dev" ]]; then
        echo "USB_STATUS=connected" > "$USB_STATE"
        echo "USB_DEV=$usb_dev" >> "$USB_STATE"
        return 0
    else
        echo "USB_STATUS=disconnected" > "$USB_STATE"
        return 1
    fi
}

# Initial USB check
if detect_usb; then
    log_ok "USB detected - sync enabled"
else
    log "USB not detected - running from RAM only"
fi

# NOTE: Layer sync is handled by powos-layer-sync.service (systemd),
# which runs layer-sync.py on a 60s interval. sync-daemon.py has been
# deprecated to eliminate the race condition where both daemons used
# rsync --delete to the same USB directory simultaneously.

# Set up udev rules for USB hotplug (if not already present).
# Write /run/powos/usb-state directly — that's what the sync daemon reads.
# (Do NOT invoke the powos CLI here: `powos usb-connected/-disconnected`
# subcommands don't exist.)
if [[ ! -f /etc/udev/rules.d/99-powos-usb.rules ]]; then
    cat > /etc/udev/rules.d/99-powos-usb.rules << 'EOF'
# PowOS USB hotplug detection - keeps /run/powos/usb-state current
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="POWOS-DATA", RUN+="/bin/sh -c 'mkdir -p /run/powos; echo USB_STATUS=connected > /run/powos/usb-state; echo USB_DEV=$env{DEVNAME} >> /run/powos/usb-state'"
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="POWOS-HOME", RUN+="/bin/sh -c 'mkdir -p /run/powos; echo USB_STATUS=connected > /run/powos/usb-state; echo USB_DEV=$env{DEVNAME} >> /run/powos/usb-state'"
ACTION=="remove", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="POWOS-DATA", RUN+="/bin/sh -c 'mkdir -p /run/powos; echo USB_STATUS=disconnected > /run/powos/usb-state'"
ACTION=="remove", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="POWOS-HOME", RUN+="/bin/sh -c 'mkdir -p /run/powos; echo USB_STATUS=disconnected > /run/powos/usb-state'"
EOF
    udevadm control --reload-rules 2>/dev/null || true
fi

log_ok "PowOS RAM overlay initialized"
