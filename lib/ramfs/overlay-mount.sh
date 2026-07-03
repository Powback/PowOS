#!/bin/bash
# overlay-mount.sh - Mount overlayfs with USB lower + RAM upper
#
# This allows the system to run from RAM while syncing changes back to USB.
# If USB is unplugged, the system keeps running from RAM.

set -e

OVERLAY_BASE="/run/powos/overlay"
USB_MOUNT="/mnt/powos-usb"
STATE_FILE="/run/powos/overlay-state"

log() { echo "[overlay] $*"; }
log_ok() { echo "[overlay] ✓ $*"; }
log_err() { echo "[overlay] ✗ $*" >&2; }

# Create overlay for a mount point
# Usage: setup_overlay <name> <usb_subpath> <mount_point> <size>
setup_overlay() {
    local name="$1"
    local usb_path="$2"
    local mount_point="$3"
    local size="${4:-2G}"

    local lower="$USB_MOUNT/$usb_path"
    local upper="$OVERLAY_BASE/$name/upper"
    local work="$OVERLAY_BASE/$name/work"
    local merged="$mount_point"

    log "Setting up overlay: $name -> $mount_point"

    # Create directories
    mkdir -p "$upper" "$work"

    # Check if USB path exists
    if [[ ! -d "$lower" ]]; then
        log "Creating $lower on USB..."
        mkdir -p "$lower"
    fi

    # Mount overlay
    if mount -t overlay "overlay-$name" \
        -o "lowerdir=$lower,upperdir=$upper,workdir=$work" \
        "$merged" 2>/dev/null; then
        log_ok "$name overlay mounted at $merged"
        echo "$name:$merged:$lower:$upper" >> "$STATE_FILE"
        return 0
    else
        log_err "Failed to mount $name overlay"
        return 1
    fi
}

# Setup RAM tmpfs for overlay upper layers
setup_ram() {
    local size="${1:-4G}"

    log "Creating RAM overlay base ($size)..."
    mkdir -p "$OVERLAY_BASE"

    if mount -t tmpfs -o "size=$size,mode=755" tmpfs "$OVERLAY_BASE"; then
        log_ok "RAM overlay space ready: $size"
        return 0
    else
        log_err "Failed to create RAM overlay space"
        return 1
    fi
}

# Detect and mount USB
detect_usb() {
    log "Detecting PowOS USB drive..."

    # Look for POWOS-DATA label
    local usb_dev
    usb_dev=$(blkid -L "POWOS-DATA" 2>/dev/null || true)

    if [[ -z "$usb_dev" ]]; then
        # Try POWOS-HOME for backwards compat
        usb_dev=$(blkid -L "POWOS-HOME" 2>/dev/null || true)
    fi

    if [[ -z "$usb_dev" ]]; then
        log "No PowOS USB detected"
        return 1
    fi

    log "Found USB: $usb_dev"
    mkdir -p "$USB_MOUNT"

    if mount "$usb_dev" "$USB_MOUNT" 2>/dev/null; then
        log_ok "USB mounted at $USB_MOUNT"
        echo "USB_DEV=$usb_dev" > /run/powos/usb-state
        echo "USB_MOUNT=$USB_MOUNT" >> /run/powos/usb-state
        echo "USB_STATUS=connected" >> /run/powos/usb-state
        return 0
    else
        log_err "Failed to mount USB"
        return 1
    fi
}

# Main setup function
setup_all() {
    local ram_size="${POWOS_RAM_SIZE:-4G}"

    mkdir -p /run/powos
    echo "" > "$STATE_FILE"

    # Setup RAM space
    if ! setup_ram "$ram_size"; then
        log_err "Cannot continue without RAM overlay space"
        exit 1
    fi

    # Detect USB
    if detect_usb; then
        # USB found - setup overlays with USB as lower layer
        setup_overlay "home" "home" "/home/powos" "2G"
        # setup_overlay "var" "var" "/var" "1G"  # Optional

        # Start sync daemon
        if command -v powos-sync &>/dev/null; then
            powos-sync daemon &
            log "Sync daemon started"
        fi
    else
        # No USB - pure RAM mode (no persistence)
        log "Running in RAM-only mode (no USB persistence)"
        mkdir -p /home/powos
        mount --bind "$OVERLAY_BASE/home-fallback" /home/powos 2>/dev/null || \
            mkdir -p /home/powos
    fi

    log_ok "Overlay setup complete"
}

# Status function
status() {
    echo "PowOS Overlay Status"
    echo "===================="

    if [[ -f /run/powos/usb-state ]]; then
        source /run/powos/usb-state
        echo "USB: $USB_STATUS ($USB_DEV)"
    else
        echo "USB: not detected"
    fi

    echo ""
    echo "Overlays:"
    if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
        while IFS=: read -r name mount lower upper; do
            local upper_size
            upper_size=$(du -sh "$upper" 2>/dev/null | cut -f1 || echo "0")
            echo "  $name: $mount (RAM usage: $upper_size)"
        done < "$STATE_FILE"
    else
        echo "  (none active)"
    fi

    echo ""
    if mountpoint -q "$OVERLAY_BASE" 2>/dev/null; then
        local total used avail
        read -r total used avail <<< $(df -h "$OVERLAY_BASE" | tail -1 | awk '{print $2, $3, $4}')
        echo "RAM Overlay: $used / $total (available: $avail)"
    fi
}

# Sync all overlays to USB
sync_all() {
    if [[ ! -f /run/powos/usb-state ]]; then
        log_err "USB not connected"
        return 1
    fi

    source /run/powos/usb-state

    if [[ "$USB_STATUS" != "connected" ]]; then
        log_err "USB not connected"
        return 1
    fi

    log "Syncing overlays to USB..."

    while IFS=: read -r name mount lower upper; do
        if [[ -d "$upper" ]] && [[ -d "$lower" ]]; then
            log "  Syncing $name..."
            rsync -av --delete "$upper/" "$lower.pending/" 2>/dev/null && \
                rsync -av --delete "$upper/" "$lower/" 2>/dev/null
        fi
    done < "$STATE_FILE"

    log_ok "Sync complete"
}

# Command dispatch
case "${1:-}" in
    setup)
        setup_all
        ;;
    status)
        status
        ;;
    sync)
        sync_all
        ;;
    *)
        echo "Usage: $0 {setup|status|sync}"
        exit 1
        ;;
esac
