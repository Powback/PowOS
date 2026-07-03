#!/bin/bash
# ramboot-setup.sh - Set up layered RAM overlay before pivot_root
#
# This runs during initramfs, after root is mounted at $NEWROOT but
# before the system switches to it. We set up a multi-layer overlayfs:
#
#   upper: RAM (tmpfs)     - all runtime writes go here
#   lower: custom:updates:base  - stacked persistent layers
#
# Result: Entire OS runs from RAM, changes sync to custom layer,
#         updates are separate, everything can be rolled back.

type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

# Check if ramboot is enabled (kernel cmdline: rd.powos.ramboot=1)
if ! getargbool 0 rd.powos.ramboot; then
    info "PowOS ramboot: disabled (add rd.powos.ramboot=1 to enable)"
    return 0
fi

RAM_SIZE=$(getarg rd.powos.ramsize=)
RAM_SIZE=${RAM_SIZE:-8G}

# Rollback options (kernel cmdline)
SKIP_CUSTOM=$(getargbool 0 rd.powos.skip.custom)
SKIP_UPDATES=$(getargbool 0 rd.powos.skip.updates)

info "PowOS ramboot: Setting up layered RAM overlay (${RAM_SIZE})"
[[ "$SKIP_CUSTOM" == "1" ]] && info "PowOS ramboot: ROLLBACK - skipping custom layer"
[[ "$SKIP_UPDATES" == "1" ]] && info "PowOS ramboot: ROLLBACK - skipping updates layer"

# === Directory Setup ===
OVERLAY_BASE="/run/powos-overlay"
USB_LAYERS="/run/powos-usb-layers"

# The original root from USB (will become base layer). If the USB carries
# multiple base variants, this is replaced by the selected layers/base-<variant>.
BASE_LAYER="${NEWROOT}"

# Create overlay structure
mkdir -p "$OVERLAY_BASE" "$USB_LAYERS"

# --- Multi-variant base selection (guarded) -----------------------------------
# A USB may carry several base variants under layers/base-<name>/ (e.g.
# nvidia-open, nvidia, main). Pick one by GPU auto-detect or the boot menu's
# rd.powos.variant= override. If NO base-*/ dirs exist, BASE_LAYER stays as
# NEWROOT and single-variant boot behaves exactly as before.
# TODO(hw): validate on real hardware / a VM — this is boot-critical.
_powos_variant_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

powos_select_base_variant() {
    local override gpu mapped chosen avail="" d name
    for d in "$USB_LAYERS"/layers/base-*/; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d"); name="${name#base-}"
        avail="${avail:+$avail }$name"
    done
    [[ -z "$avail" ]] && return 0   # single-variant USB — keep NEWROOT base

    override=$(getarg rd.powos.variant=)
    # Persistent default set by `powos base switch <name>` (below cmdline, above auto).
    if [[ -z "$override" && -f "$USB_LAYERS/.powos-default-variant" ]]; then
        override=$(cat "$USB_LAYERS/.powos-default-variant" 2>/dev/null)
        [[ -n "$override" ]] && info "PowOS ramboot: persistent default variant '$override'"
    fi
    if command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi nvidia; then
        mapped="nvidia-open"        # open is the NVIDIA default (see variant-select.sh)
    else
        mapped="main"
    fi

    # Precedence: explicit override/default > GPU auto-detect > main > first available.
    if [[ -n "$override" && "$override" != "auto" ]] && _powos_variant_in "$override" "$avail"; then
        chosen="$override"
    elif _powos_variant_in "$mapped" "$avail"; then
        chosen="$mapped"
    elif _powos_variant_in "main" "$avail"; then
        chosen="main"
    else
        chosen="${avail%% *}"
    fi

    if [[ -n "$chosen" && -d "$USB_LAYERS/layers/base-$chosen" ]]; then
        BASE_LAYER="$USB_LAYERS/layers/base-$chosen"
        info "PowOS ramboot: base variant '$chosen' (available: $avail; override='${override:-auto}')"
    fi
}

# === Mount tmpfs for RAM upper layer ===
info "PowOS ramboot: Creating tmpfs (${RAM_SIZE}) for overlay upper"
mount -t tmpfs -o "size=${RAM_SIZE},mode=0755" tmpfs "$OVERLAY_BASE"

UPPER="${OVERLAY_BASE}/upper"
WORK="${OVERLAY_BASE}/work"
MERGED="${OVERLAY_BASE}/merged"
mkdir -p "$UPPER" "$WORK" "$MERGED"

# === Detect and mount USB data partition for layers ===
# Look for POWOS-DATA partition which holds our layers
USB_DATA_DEV=""
for dev in /dev/sd* /dev/nvme*; do
    if blkid "$dev" 2>/dev/null | grep -q "POWOS-DATA"; then
        USB_DATA_DEV="$dev"
        break
    fi
done

LAYERS_AVAILABLE=""

if [[ -n "$USB_DATA_DEV" ]]; then
    info "PowOS ramboot: Found USB data partition: $USB_DATA_DEV"
    mkdir -p "$USB_LAYERS"

    if mount "$USB_DATA_DEV" "$USB_LAYERS" 2>/dev/null; then
        info "PowOS ramboot: USB layers mounted"

        # Pick the base variant (no-op unless the USB carries base-*/ variants).
        powos_select_base_variant

        # Create layer directories if they don't exist
        mkdir -p "$USB_LAYERS/layers/custom"
        mkdir -p "$USB_LAYERS/layers/updates"

        # Build lower layer string (order matters: first = highest priority)
        # Format: custom:updates:base
        LOWER_LAYERS=""

        # Add custom layer (user customizations)
        if [[ "$SKIP_CUSTOM" != "1" ]] && [[ -d "$USB_LAYERS/layers/custom" ]]; then
            if [[ -n "$(ls -A "$USB_LAYERS/layers/custom" 2>/dev/null)" ]]; then
                LOWER_LAYERS="$USB_LAYERS/layers/custom"
                LAYERS_AVAILABLE="${LAYERS_AVAILABLE}custom,"
                info "PowOS ramboot: + custom layer"
            fi
        fi

        # Add updates layer (OS updates)
        if [[ "$SKIP_UPDATES" != "1" ]] && [[ -d "$USB_LAYERS/layers/updates" ]]; then
            if [[ -n "$(ls -A "$USB_LAYERS/layers/updates" 2>/dev/null)" ]]; then
                if [[ -n "$LOWER_LAYERS" ]]; then
                    LOWER_LAYERS="${LOWER_LAYERS}:$USB_LAYERS/layers/updates"
                else
                    LOWER_LAYERS="$USB_LAYERS/layers/updates"
                fi
                LAYERS_AVAILABLE="${LAYERS_AVAILABLE}updates,"
                info "PowOS ramboot: + updates layer"
            fi
        fi

        # Always add base layer last
        if [[ -n "$LOWER_LAYERS" ]]; then
            LOWER_LAYERS="${LOWER_LAYERS}:${BASE_LAYER}"
        else
            LOWER_LAYERS="${BASE_LAYER}"
        fi
        LAYERS_AVAILABLE="${LAYERS_AVAILABLE}base"
        info "PowOS ramboot: + base layer"
    else
        warn "PowOS ramboot: Failed to mount USB layers, using base only"
        LOWER_LAYERS="${BASE_LAYER}"
        LAYERS_AVAILABLE="base"
    fi
else
    info "PowOS ramboot: No USB data partition found, using base only"
    LOWER_LAYERS="${BASE_LAYER}"
    LAYERS_AVAILABLE="base"
fi

# === Mount the stacked overlayfs ===
info "PowOS ramboot: Mounting overlayfs with layers: $LAYERS_AVAILABLE"
info "PowOS ramboot: lowerdir=$LOWER_LAYERS"

if mount -t overlay overlay \
    -o "lowerdir=${LOWER_LAYERS},upperdir=${UPPER},workdir=${WORK}" \
    "$MERGED"; then
    info "PowOS ramboot: Overlay mounted successfully"
else
    warn "PowOS ramboot: Failed to mount overlay, falling back to normal boot"
    return 0
fi

# === Make USB accessible in the new root ===
# Bind mount the USB layers into the merged root for sync daemon access
if [[ -d "$USB_LAYERS/layers" ]]; then
    mkdir -p "${MERGED}/run/powos/usb-layers"
    mount --bind "$USB_LAYERS" "${MERGED}/run/powos/usb-layers"
fi

# Keep reference to original USB root
mkdir -p "${MERGED}/run/powos/usb-root"

# === The key: replace NEWROOT with our overlay ===
export NEWROOT="$MERGED"

# === Store state for userspace ===
mkdir -p "${MERGED}/run/powos"
cat > "${MERGED}/run/powos/ramboot-state" << EOF
POWOS_RAMBOOT=1
POWOS_OVERLAY_BASE=${OVERLAY_BASE}
POWOS_OVERLAY_UPPER=${UPPER}
POWOS_OVERLAY_MERGED=${MERGED}
POWOS_RAM_SIZE=${RAM_SIZE}
POWOS_LAYERS_ACTIVE=${LAYERS_AVAILABLE}
POWOS_USB_LAYERS=${USB_LAYERS}
POWOS_SKIP_CUSTOM=${SKIP_CUSTOM}
POWOS_SKIP_UPDATES=${SKIP_UPDATES}
EOF

# Store layer paths for sync daemon
cat > "${MERGED}/run/powos/layer-paths" << EOF
CUSTOM_LAYER=${USB_LAYERS}/layers/custom
UPDATES_LAYER=${USB_LAYERS}/layers/updates
RAM_UPPER=${UPPER}
EOF

info "PowOS ramboot: Ready - system will run from layered RAM overlay"
info "PowOS ramboot: Active layers: $LAYERS_AVAILABLE"
info "PowOS ramboot: USB can be safely unplugged after boot"
