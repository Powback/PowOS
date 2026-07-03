#!/bin/bash
# module-setup.sh - Dracut module for PowOS RAM boot
#
# This module sets up overlayfs with RAM as upper layer, allowing
# the USB to be unplugged while the system keeps running.

check() {
    # Only include if powos-ramboot is requested
    require_binaries rsync || return 1
    return 0
}

depends() {
    echo "base rootfs-block"
    return 0
}

install() {
    # Install required binaries
    inst_multiple rsync mount umount mkdir df

    # Install our hook scripts
    inst_hook pre-pivot 90 "$moddir/ramboot-setup.sh"

    # Install helper script for runtime
    inst_simple "$moddir/powos-overlay-init.sh" /usr/lib/powos/overlay-init.sh

    # Install config
    inst_simple /etc/powos/ramboot.conf /etc/powos/ramboot.conf 2>/dev/null || true
}

installkernel() {
    # Ensure overlay module is included
    instmods overlay
}
