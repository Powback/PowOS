#!/usr/bin/env bash
# install-to-usb.sh - Install PowOS to a USB drive
#
# SAFE BY DEFAULT: Writes a pre-installed raw disk image that boots as a live
# system. Internal drives are NOT touched. OS runs from RAM.
#
# Usage:
#   sudo ./install-to-usb.sh /dev/sdX               # Write raw image + setup POWOS-DATA
#   sudo ./install-to-usb.sh --setup-data-only /dev/sdX  # Only add POWOS-DATA to existing image
#
# WARNING: This ERASES ALL DATA on the TARGET USB DRIVE (/dev/sdX)!
# It will NOT touch your internal SSD, NVMe, or SD cards.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWOS_ROOT="$(dirname "$SCRIPT_DIR")"
RAW_PATH="${POWOS_ROOT}/build/output/powos.raw"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log() { echo -e "${BLUE}[install]${NC} $*"; }
log_success() { echo -e "${GREEN}[install]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[install]${NC} $*"; }
log_error() { echo -e "${RED}[install]${NC} $*" >&2; }

# ─────────────────────────────────────────────────────────────────
# Safety checks
# ─────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        log_error "Usage: sudo $0 /dev/sdX"
        exit 1
    fi
}

check_device() {
    local device="$1"

    # Must be a block device
    if [[ ! -b "$device" ]]; then
        log_error "Not a block device: $device"
        exit 1
    fi

    # Safety: refuse to write to obviously internal drives
    local devname
    devname=$(basename "$device")
    local removable_file="/sys/block/${devname}/removable"

    if [[ -f "$removable_file" ]]; then
        local is_removable
        is_removable=$(cat "$removable_file")
        if [[ "$is_removable" != "1" ]]; then
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  SAFETY BLOCK: Non-removable drive detected!               ║${NC}"
            echo -e "${RED}║                                                            ║${NC}"
            echo -e "${RED}║  $device appears to be an INTERNAL drive.                  ║${NC}"
            echo -e "${RED}║  Writing PowOS here could destroy your system!             ║${NC}"
            echo -e "${RED}║                                                            ║${NC}"
            echo -e "${RED}║  Please verify you selected the correct device.            ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            log "Removable flag: $is_removable (0=internal, 1=removable)"
            log "Detected drives:"
            lsblk -d -o NAME,SIZE,MODEL,TRAN,HOTPLUG
            echo ""
            echo -e "${YELLOW}If this is truly your USB drive (some USB docks report as non-removable):${NC}"
            echo "  Set POWOS_OVERRIDE_REMOVABLE=1 to bypass this check"
            echo "  Example: sudo POWOS_OVERRIDE_REMOVABLE=1 $0 $device"
            echo ""
            if [[ "${POWOS_OVERRIDE_REMOVABLE:-}" != "1" ]]; then
                exit 1
            fi
            log_warn "SAFETY OVERRIDE: proceeding with non-removable device"
        fi
    fi

    # Don't allow installing to mounted filesystems
    if mount | grep -q "^$device "; then
        log_error "Device is mounted: $device"
        log_error "Unmount all partitions first"
        exit 1
    fi

    # Also check partitions
    for part in "${device}"*[0-9]; do
        if [[ -b "$part" ]] && mount | grep -q "^$part "; then
            log_error "Partition is mounted: $part"
            log_error "Unmount it first: sudo umount $part"
            exit 1
        fi
    done

    # Warn about NVMe
    if [[ "$device" == /dev/nvme* ]]; then
        log_warn "Target appears to be NVMe. Verify this is your USB NVMe enclosure!"
    fi

    # Show device info
    log "Target device: $device"
    lsblk "$device" 2>/dev/null || true
    echo ""
}

confirm_usb_erase() {
    local device="$1"

    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  PowOS will be written to: $device                         ║${NC}"
    echo -e "${YELLOW}║  ALL DATA on this drive will be ERASED.                    ║${NC}"
    echo -e "${YELLOW}║  (Internal drives and other storage will NOT be touched)   ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    log "Current partitions on $device:"
    fdisk -l "$device" 2>/dev/null | head -20 || true
    echo ""

    read -p "Type 'YES' to write PowOS to $device: " confirm
    if [[ "$confirm" != "YES" ]]; then
        log "Aborted"
        exit 0
    fi
}

# ─────────────────────────────────────────────────────────────────
# Write raw disk image to USB
# This writes the pre-installed PowOS system to the USB drive.
# No installer runs - this IS the live boot image.
# ─────────────────────────────────────────────────────────────────
write_raw_image() {
    local device="$1"
    local image="${2:-$RAW_PATH}"

    if [[ ! -f "$image" ]]; then
        log_error "Raw image not found: $image"
        log_error "Build it first: ./build/build-iso.sh live-usb"
        exit 1
    fi

    local image_size
    image_size=$(du -h "$image" | cut -f1)
    log "Writing PowOS image ($image_size) to $device..."
    log "This may take 10-30 minutes depending on drive speed"

    dd if="$image" of="$device" bs=4M status=progress conv=fsync

    sync
    log_success "PowOS image written to $device"
}

# ─────────────────────────────────────────────────────────────────
# Add POWOS-DATA partition for persistent layers
# The raw image has 2 partitions (EFI + root).
# We add a 3rd partition for PowOS layer persistence.
# ─────────────────────────────────────────────────────────────────
add_data_partition() {
    local device="$1"

    # Reload partition table
    partprobe "$device" 2>/dev/null || true
    sleep 2

    log "Adding POWOS-DATA partition for persistent layers..."

    # Find free space start after existing partitions
    local last_end
    last_end=$(parted "$device" unit MiB print free 2>/dev/null \
        | grep "Free Space" | tail -1 | awk '{print $1}' | tr -d 'MiB')

    if [[ -z "$last_end" ]]; then
        log_warn "Could not determine free space - trying last partition end"
        last_end=$(parted "$device" unit MiB print 2>/dev/null \
            | grep -E "^\s+[0-9]" | tail -1 | awk '{print $3}' | tr -d 'MiB')
    fi

    if [[ -z "$last_end" ]]; then
        log_warn "Could not detect partition layout, skipping POWOS-DATA creation"
        log_warn "Add manually: sudo parted $device mkpart POWOS-DATA btrfs <start>MiB 100%"
        return 0
    fi

    log "Adding POWOS-DATA partition starting at ${last_end}MiB..."

    parted "$device" --script mkpart POWOS-DATA btrfs "${last_end}MiB" 100% || {
        log_warn "Could not add POWOS-DATA partition automatically"
        log_warn "Add manually: sudo parted $device mkpart POWOS-DATA btrfs ${last_end}MiB 100%"
        return 0
    }

    partprobe "$device" 2>/dev/null || true
    sleep 2

    # Find the new partition (last one on device)
    local data_part
    data_part=$(lsblk -ln -o NAME "$device" | sort | tail -1)
    data_part="/dev/${data_part}"

    if [[ -b "$data_part" ]]; then
        log "Formatting POWOS-DATA partition: $data_part"
        mkfs.btrfs -f -L "POWOS-DATA" "$data_part"
        log_success "POWOS-DATA partition created: $data_part"
    else
        log_warn "Could not find new partition, skipping format"
    fi
}

# ─────────────────────────────────────────────────────────────────
# Add a boot-menu "Install PowOS" entry (Boot Loader Spec)
#
# The live image ships one BLS entry (loader/entries/*.conf) that GRUB shows
# as "PowOS Live". We add a second entry that is a copy of it plus the kernel
# arg `powos.install=1`. GRUB auto-lists BLS entries, so the boot menu then
# offers BOTH:  "PowOS Live" (default)  and  "Install PowOS to disk".
# powos-installer.service sees powos.install=1 and launches the installer.
#
# This is the supported extension point — we do NOT hand-edit grub.cfg.
# TODO(hw): validate against the real image's boot partition layout.
# ─────────────────────────────────────────────────────────────────
add_install_boot_entry() {
    local device="$1"

    partprobe "$device" 2>/dev/null || true
    sleep 1
    log "Adding 'Install PowOS' boot menu entry..."

    local mp entries_dir="" part
    mp=$(mktemp -d)

    # Find the partition that holds loader/entries (boot or ESP, depending on layout)
    while read -r part; do
        [[ -b "$part" ]] || continue
        if mount "$part" "$mp" 2>/dev/null; then
            if [[ -d "$mp/loader/entries" ]]; then
                entries_dir="$mp/loader/entries"
                break
            elif [[ -d "$mp/boot/loader/entries" ]]; then
                entries_dir="$mp/boot/loader/entries"
                break
            fi
            umount "$mp" 2>/dev/null || true
        fi
    done < <(lsblk -ln -o PATH "$device" 2>/dev/null | tail -n +2)

    if [[ -z "$entries_dir" ]]; then
        log_warn "Could not locate BLS loader/entries on $device."
        log_warn "Boot menu will still work, but the 'Install PowOS' entry was not added."
        log_warn "You can still install after booting live:  sudo powos install-system"
        umount "$mp" 2>/dev/null || true
        rmdir "$mp" 2>/dev/null || true
        return 0
    fi

    # Pick the first existing entry as the template (the live boot entry).
    local template
    template=$(find "$entries_dir" -maxdepth 1 -name '*.conf' ! -name '*install*' | head -1)
    if [[ -z "$template" ]]; then
        log_warn "No BLS entry template found — skipping install menu entry."
        umount "$mp" 2>/dev/null || true
        rmdir "$mp" 2>/dev/null || true
        return 0
    fi

    local install_entry="${entries_dir}/powos-install.conf"
    # Copy template; retitle; append the installer kernel arg to the options line.
    awk '
        /^title / { print "title Install PowOS to disk"; next }
        /^options / { print $0 " powos.install=1"; next }
        { print }
    ' "$template" > "$install_entry"
    # Ensure a title/options line existed; if not, append minimally.
    grep -q '^title '   "$install_entry" || echo "title Install PowOS to disk" >> "$install_entry"
    grep -q 'powos.install=1' "$install_entry" || echo "options powos.install=1" >> "$install_entry"

    log_success "Added boot entry: 'Install PowOS to disk'"

    # Make the menu actually visible (bootc images often hide it / 0s timeout).
    local grubcfg
    for grubcfg in "$mp/grub2/grubenv" "$mp/EFI"/*/grubenv "$mp/boot/grub2/grubenv"; do
        [[ -f "$grubcfg" ]] || continue
        if command -v grub2-editenv &>/dev/null; then
            grub2-editenv "$grubcfg" set menu_auto_hide=0 2>/dev/null || true
        fi
    done

    sync
    umount "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────
# Setup persistent data structure on POWOS-DATA partition
# ─────────────────────────────────────────────────────────────────
setup_persistence() {
    local device="$1"

    # Find POWOS-DATA partition by label
    local data_part
    data_part=$(blkid -L "POWOS-DATA" 2>/dev/null || true)

    # Try to find it on the target device if not found by label
    if [[ -z "$data_part" ]]; then
        data_part=$(lsblk -ln -o NAME,LABEL "$device" \
            | grep "POWOS-DATA" | awk '{print "/dev/"$1}' | head -1)
    fi

    if [[ -z "$data_part" ]]; then
        log_warn "POWOS-DATA partition not found - skipping persistence setup"
        log_warn "Boot PowOS and run 'powos layers' to check status"
        return 0
    fi

    local mount_point
    mount_point=$(mktemp -d)

    log "Setting up persistent layer structure on $data_part..."
    mount "$data_part" "$mount_point"

    # Create btrfs subvolumes
    btrfs subvolume create "${mount_point}/@home" 2>/dev/null || mkdir -p "${mount_point}/@home"
    btrfs subvolume create "${mount_point}/@powos" 2>/dev/null || mkdir -p "${mount_point}/@powos"

    # PowOS directories
    mkdir -p "${mount_point}/@powos/extensions"
    mkdir -p "${mount_point}/@powos/sources"
    mkdir -p "${mount_point}/@powos/containers"
    mkdir -p "${mount_point}/@powos/git"
    mkdir -p "${mount_point}/@powos/state"

    # Layer directories (used by ramboot for layered persistence)
    mkdir -p "${mount_point}/layers/custom/usr"
    mkdir -p "${mount_point}/layers/custom/etc"
    mkdir -p "${mount_point}/layers/custom/var"
    mkdir -p "${mount_point}/layers/updates/usr"
    mkdir -p "${mount_point}/layers/updates/etc"
    mkdir -p "${mount_point}/layers/updates/var"

    # Home directory for CacheFS
    mkdir -p "${mount_point}/home/powos/Documents"
    mkdir -p "${mount_point}/home/powos/Downloads"
    mkdir -p "${mount_point}/home/powos/Projects"

    log_success "Layer directories created:"
    log "    layers/custom/   - Your packages, configs (syncs from RAM)"
    log "    layers/updates/  - OS updates"
    log "    home/            - User data (CacheFS source)"

    # Copy overlay sources if they exist
    if [[ -d "${POWOS_ROOT}/sources" ]]; then
        log "  Copying overlay sources..."
        cp -a "${POWOS_ROOT}/sources/"* "${mount_point}/@powos/sources/" 2>/dev/null || true
    fi

    # Copy container definitions
    if [[ -d "${POWOS_ROOT}/containers" ]]; then
        log "  Copying container definitions..."
        cp -a "${POWOS_ROOT}/containers/"* "${mount_point}/@powos/containers/" 2>/dev/null || true
    fi

    # Initialize git repo for state tracking
    cd "${mount_point}/@powos/git"
    git init -q
    git config user.email "powos@localhost"
    git config user.name "PowOS"

    cat > README.md << 'EOF'
# PowOS State Repository

This repository tracks your PowOS customizations.

## Layer Structure

- `layers/custom/` - Your packages and configs
- `layers/updates/` - OS updates
- `home/` - User data
EOF
    git add README.md
    git commit -q -m "Initial PowOS setup"

    cd /
    umount "$mount_point"
    rmdir "$mount_point"

    log_success "Persistent storage configured"
}

# ─────────────────────────────────────────────────────────────────
# Show completion message
# ─────────────────────────────────────────────────────────────────
show_complete() {
    local device="$1"

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  PowOS USB Drive Ready!                                    ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Installed to: $device"
    echo ""
    echo "  SAFE: This is a LIVE BOOT USB - internal drives were NOT touched."
    echo "        PowOS runs entirely from RAM after booting."
    echo ""
    echo "  To boot PowOS:"
    echo "    1. Plug the USB drive into any computer"
    echo "    2. Enter BIOS/UEFI boot menu (F12, F2, Del, etc.)"
    echo "    3. Select the USB drive"
    echo "    4. PowOS boots and runs from RAM"
    echo ""
    echo "  First boot:"
    echo "    - OS loads into RAM (needs 16GB+ RAM for best experience)"
    echo "    - Detects GPU (NVIDIA/AMD/Intel)"
    echo "    - Applies hardware profile automatically"
    echo "    - Layer sync daemon starts (syncs RAM changes to USB every 60s)"
    echo ""
    echo "  Key commands after boot:"
    echo "    powos status        - System status"
    echo "    powos layers        - View layer stack"
    echo "    powos sync          - Force sync to USB"
    echo "    powos rollback      - Rollback layer options"
    echo ""
}

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────
usage() {
    echo ""
    echo "Usage: sudo $0 [options] /dev/sdX"
    echo ""
    echo "Options:"
    echo "  --setup-data-only   Only add POWOS-DATA partition (raw image already written)"
    echo "  --image PATH        Path to powos.raw image (default: build/output/powos.raw)"
    echo ""
    echo "Available drives:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN,HOTPLUG 2>/dev/null | grep -v "^loop" \
        || lsblk -d -o NAME,SIZE,MODEL
    echo ""
    echo "Identify your USB drive by HOTPLUG=1 or TRAN=usb"
    echo "WARNING: ALL DATA on the target drive will be ERASED!"
}

main() {
    local device=""
    local image="$RAW_PATH"
    local setup_data_only=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --setup-data-only)
                setup_data_only=1
                shift
                ;;
            --image)
                image="$2"
                shift 2
                ;;
            /dev/*)
                device="$1"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  PowOS USB Installer                                       ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"

    if [[ -z "$device" ]]; then
        usage
        exit 1
    fi

    check_root
    check_device "$device"
    confirm_usb_erase "$device"

    if [[ "$setup_data_only" == "1" ]]; then
        log "Setup data partition only mode"
        add_data_partition "$device"
        add_install_boot_entry "$device"
        setup_persistence "$device"
    else
        write_raw_image "$device" "$image"
        add_data_partition "$device"
        add_install_boot_entry "$device"
        setup_persistence "$device"
    fi

    show_complete "$device"
}

main "$@"
