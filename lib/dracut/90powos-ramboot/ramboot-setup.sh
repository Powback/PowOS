#!/bin/bash
# ramboot-setup.sh - Set up RAM overlay before pivot_root
#
# This runs during initramfs, after root is mounted at $NEWROOT but
# before the system switches to it. We intercept and wrap the root
# in an overlayfs with RAM as the upper layer.
#
# Result: Entire OS runs from RAM overlay, USB can be unplugged.

type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

# Check if ramboot is enabled (kernel cmdline: rd.powos.ramboot=1)
if ! getargbool 0 rd.powos.ramboot; then
    info "PowOS ramboot: disabled (add rd.powos.ramboot=1 to enable)"
    return 0
fi

RAM_SIZE=$(getarg rd.powos.ramsize=)
RAM_SIZE=${RAM_SIZE:-8G}

info "PowOS ramboot: Setting up RAM overlay (${RAM_SIZE})"

# Directories
OVERLAY_BASE="/run/powos-overlay"
LOWER="${NEWROOT}"
UPPER="${OVERLAY_BASE}/upper"
WORK="${OVERLAY_BASE}/work"
MERGED="${OVERLAY_BASE}/merged"

# Create overlay structure
mkdir -p "$OVERLAY_BASE" "$UPPER" "$WORK" "$MERGED"

# Create tmpfs for upper layer (this is our RAM storage)
info "PowOS ramboot: Creating tmpfs (${RAM_SIZE}) for overlay upper"
mount -t tmpfs -o "size=${RAM_SIZE},mode=0755" tmpfs "$OVERLAY_BASE"
mkdir -p "$UPPER" "$WORK"

# Set up overlayfs
# Lower = original root (USB), Upper = RAM, Merged = what system sees
info "PowOS ramboot: Mounting overlayfs"
if mount -t overlay overlay \
    -o "lowerdir=${LOWER},upperdir=${UPPER},workdir=${WORK}" \
    "$MERGED"; then
    info "PowOS ramboot: Overlay mounted successfully"
else
    warn "PowOS ramboot: Failed to mount overlay, falling back to normal boot"
    return 0
fi

# Move the original root mount to a subdirectory in the overlay
# This allows us to access USB later for sync operations
mkdir -p "${MERGED}/run/powos/usb-root"

# The key trick: replace NEWROOT with our overlay
# Dracut will pivot_root to NEWROOT, which is now our RAM overlay
export NEWROOT="$MERGED"

# Store state for userspace
mkdir -p "${MERGED}/run/powos"
cat > "${MERGED}/run/powos/ramboot-state" << EOF
POWOS_RAMBOOT=1
POWOS_OVERLAY_LOWER=${LOWER}
POWOS_OVERLAY_UPPER=${UPPER}
POWOS_OVERLAY_MERGED=${MERGED}
POWOS_RAM_SIZE=${RAM_SIZE}
EOF

info "PowOS ramboot: Ready - system will run from RAM"
info "PowOS ramboot: USB can be safely unplugged after boot"
