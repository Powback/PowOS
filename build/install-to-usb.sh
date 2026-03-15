#!/usr/bin/env bash
# install-to-usb.sh - Install PowOS to a USB drive
#
# This script:
# 1. Partitions the target drive (EFI + POWOS data)
# 2. Writes the ISO or installs directly
# 3. Sets up the persistent data partition
#
# Usage: sudo ./install-to-usb.sh /dev/sdX
#
# WARNING: This ERASES ALL DATA on the target drive!

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWOS_ROOT="$(dirname "$SCRIPT_DIR")"
ISO_PATH="${POWOS_ROOT}/build/output/powos.iso"

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

check_gaming_handheld() {
    # Detect if running ON a gaming handheld. These devices have internal NVMe
    # that must never be targeted by this installer — running it here would
    # destroy the device's OS (SteamOS, Windows, etc.).
    local product_name=""
    if [[ -f /sys/class/dmi/id/product_name ]]; then
        product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    fi

    local handheld_name=""
    case "$product_name" in
        "Jupiter")       handheld_name="Steam Deck (LCD)" ;;
        "Galileo")       handheld_name="Steam Deck (OLED)" ;;
        RC71L*)          handheld_name="ASUS ROG Ally" ;;
        RC72LA*)         handheld_name="ASUS ROG Ally X" ;;
        "83E1")          handheld_name="Lenovo Legion Go" ;;
        G1618-0*)        handheld_name="GPD Win 4" ;;
        G1617-0*)        handheld_name="GPD Win Mini" ;;
        AYANEO*)         handheld_name="AyaNeo Handheld" ;;
        "ONE XPLAYER"*)  handheld_name="One XPlayer" ;;
        ONEXPLAYER*)     handheld_name="One XPlayer" ;;
    esac

    if [[ -n "$handheld_name" ]]; then
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  BLOCKED: Gaming handheld detected!                        ║${NC}"
        echo -e "${RED}║                                                            ║${NC}"
        printf  "${RED}║  Device: %-50s ║${NC}\n" "$handheld_name"
        echo -e "${RED}║                                                            ║${NC}"
        echo -e "${RED}║  This script installs PowOS to a USB drive. Running it    ║${NC}"
        echo -e "${RED}║  on your handheld WILL DESTROY its operating system.      ║${NC}"
        echo -e "${RED}║                                                            ║${NC}"
        echo -e "${RED}║  Run this script on a separate PC/Mac instead.            ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        exit 1
    fi
}

check_system_disk() {
    local device="$1"

    # Find the device backing the current root filesystem
    local root_source root_device
    root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)

    if [[ -n "$root_source" ]]; then
        # Strip partition number to get base device (e.g. /dev/sda1 → /dev/sda, /dev/nvme0n1p1 → /dev/nvme0n1)
        if [[ "$root_source" == /dev/nvme* ]]; then
            root_device=$(echo "$root_source" | sed 's/p[0-9]*$//')
        else
            root_device=$(echo "$root_source" | sed 's/[0-9]*$//')
        fi

        if [[ "$device" == "$root_device" ]]; then
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  BLOCKED: Target is the system boot disk!                  ║${NC}"
            echo -e "${RED}║                                                            ║${NC}"
            echo -e "${RED}║  $device is the disk this system is running from.          ║${NC}"
            echo -e "${RED}║  Writing to it WILL destroy your operating system.         ║${NC}"
            echo -e "${RED}║                                                            ║${NC}"
            echo -e "${RED}║  Connect a separate USB drive and target that instead.     ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            exit 1
        fi
    fi
}

check_device() {
    local device="$1"

    # Must be a block device
    if [[ ! -b "$device" ]]; then
        log_error "Not a block device: $device"
        exit 1
    fi

    # Don't allow installing to mounted filesystems
    if mount | grep -q "^$device"; then
        log_error "Device is mounted: $device"
        log_error "Unmount all partitions first"
        exit 1
    fi

    # Hard block NVMe unless explicitly allowed
    if [[ "$device" == /dev/nvme* ]]; then
        if [[ "${ALLOW_NVME:-}" != "1" ]]; then
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  BLOCKED: NVMe target requires explicit opt-in             ║${NC}"
            echo -e "${RED}║                                                            ║${NC}"
            echo -e "${RED}║  NVMe drives are typically internal system disks, not      ║${NC}"
            echo -e "${RED}║  USB drives. Writing to an internal NVMe will destroy      ║${NC}"
            echo -e "${RED}║  your operating system (e.g. SteamOS, Windows, Linux).    ║${NC}"
            echo -e "${RED}║                                                            ║${NC}"
            echo -e "${RED}║  If you genuinely have a USB NVMe enclosure, run:          ║${NC}"
            echo -e "${RED}║    ALLOW_NVME=1 sudo $0 $device                            ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            exit 1
        else
            log_warn "NVMe target allowed via ALLOW_NVME=1 - proceeding with caution"
        fi
    fi

    # Show device info
    log "Target device: $device"
    lsblk "$device" 2>/dev/null || true
    echo ""
}

confirm_destruction() {
    local device="$1"

    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNING: ALL DATA WILL BE PERMANENTLY DESTROYED           ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Show device model and partitions
    log "Target device: $device"
    lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT "$device" 2>/dev/null || true
    echo ""
    log "Current partitions:"
    fdisk -l "$device" 2>/dev/null | head -20 || true
    echo ""

    echo -e "${RED}This will ERASE EVERYTHING on $device.${NC}"
    echo -e "${YELLOW}Type the device path ($device) to confirm destruction:${NC}"
    read -r confirm
    if [[ "$confirm" != "$device" ]]; then
        log "Aborted (input did not match $device)"
        exit 0
    fi
}

# ─────────────────────────────────────────────────────────────────
# Partition the drive
# ─────────────────────────────────────────────────────────────────
partition_drive() {
    local device="$1"

    log "Partitioning $device..."

    # Wipe existing partition table
    wipefs -a "$device" 2>/dev/null || true

    # Create GPT partition table with:
    # 1. EFI System Partition (512MB)
    # 2. PowOS root + data (rest of drive)
    parted "$device" --script \
        mklabel gpt \
        mkpart ESP fat32 1MiB 513MiB \
        set 1 esp on \
        mkpart POWOS btrfs 513MiB 100%

    # Wait for kernel to recognize partitions
    partprobe "$device"
    sleep 2

    log_success "Partitioned $device"
}

# ─────────────────────────────────────────────────────────────────
# Format partitions
# ─────────────────────────────────────────────────────────────────
format_partitions() {
    local device="$1"
    local efi_part data_part

    # Determine partition naming (nvme vs sd)
    if [[ "$device" == /dev/nvme* ]]; then
        efi_part="${device}p1"
        data_part="${device}p2"
    else
        efi_part="${device}1"
        data_part="${device}2"
    fi

    log "Formatting partitions..."

    # EFI partition
    log "  Formatting EFI: $efi_part"
    mkfs.fat -F32 -n "EFI" "$efi_part"

    # Data partition (btrfs for snapshots/subvolumes)
    log "  Formatting data: $data_part"
    mkfs.btrfs -f -L "POWOS" "$data_part"

    log_success "Partitions formatted"
}

# ─────────────────────────────────────────────────────────────────
# Write ISO to drive
# ─────────────────────────────────────────────────────────────────
write_iso() {
    local device="$1"

    if [[ ! -f "$ISO_PATH" ]]; then
        log_error "ISO not found: $ISO_PATH"
        log_error "Run ./build/build-iso.sh first"
        exit 1
    fi

    local iso_size
    iso_size=$(du -h "$ISO_PATH" | cut -f1)
    log "Writing ISO ($iso_size) to $device..."
    log "This may take 10-30 minutes depending on drive speed"

    dd if="$ISO_PATH" of="$device" bs=4M status=progress conv=fsync

    sync
    log_success "ISO written to $device"
}

# ─────────────────────────────────────────────────────────────────
# Setup persistent data partition
# ─────────────────────────────────────────────────────────────────
setup_persistence() {
    local device="$1"
    local data_part mount_point

    # Determine data partition
    if [[ "$device" == /dev/nvme* ]]; then
        data_part="${device}p2"
    else
        data_part="${device}2"
    fi

    # Mount and create structure
    mount_point=$(mktemp -d)
    mount "$data_part" "$mount_point"

    log "Setting up persistent data structure..."

    # Create btrfs subvolumes for better snapshot support
    btrfs subvolume create "${mount_point}/@home" 2>/dev/null || mkdir -p "${mount_point}/@home"
    btrfs subvolume create "${mount_point}/@powos" 2>/dev/null || mkdir -p "${mount_point}/@powos"

    # Create PowOS directory structure
    mkdir -p "${mount_point}/@powos/extensions"
    mkdir -p "${mount_point}/@powos/sources"
    mkdir -p "${mount_point}/@powos/containers"
    mkdir -p "${mount_point}/@powos/git"
    mkdir -p "${mount_point}/@powos/state"

    # ══════════════════════════════════════════════════════════════════
    # LAYER DIRECTORIES (for layered persistence)
    # ══════════════════════════════════════════════════════════════════
    log "  Setting up layer directories..."

    # Custom layer - your packages, configs, customizations
    mkdir -p "${mount_point}/@powos/layers/custom/usr"
    mkdir -p "${mount_point}/@powos/layers/custom/etc"
    mkdir -p "${mount_point}/@powos/layers/custom/var"

    # Updates layer - OS updates (separate from customizations)
    mkdir -p "${mount_point}/@powos/layers/updates/usr"
    mkdir -p "${mount_point}/@powos/layers/updates/etc"
    mkdir -p "${mount_point}/@powos/layers/updates/var"

    # Home directory for CacheFS
    mkdir -p "${mount_point}/@powos/home/powos/Documents"
    mkdir -p "${mount_point}/@powos/home/powos/Downloads"
    mkdir -p "${mount_point}/@powos/home/powos/Projects"

    log_success "Layer directories created:"
    log "    layers/custom/   - Your packages, configs (syncs from RAM)"
    log "    layers/updates/  - OS updates (via bootc/dnf)"
    log "    home/            - User data (CacheFS source)"

    # Copy current sources if they exist
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

    # Create initial commit with layer structure
    echo "# PowOS State Repository" > README.md
    echo "" >> README.md
    echo "This repository tracks your PowOS customizations." >> README.md
    echo "" >> README.md
    echo "## Layer Structure" >> README.md
    echo "" >> README.md
    echo "- \`layers/custom/\` - Your packages and configs" >> README.md
    echo "- \`layers/updates/\` - OS updates" >> README.md
    echo "- \`home/\` - User data" >> README.md
    git add README.md
    git commit -q -m "Initial PowOS setup"

    # Cleanup
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
    echo -e "${GREEN}║  PowOS Installation Complete                               ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Installed to: $device"
    echo ""
    echo "  To boot PowOS:"
    echo "    1. Plug the USB drive into any computer"
    echo "    2. Enter BIOS/UEFI boot menu (F12, F2, Del, etc.)"
    echo "    3. Select the USB drive"
    echo "    4. PowOS will auto-detect hardware and boot"
    echo ""
    echo "  First boot will:"
    echo "    - Load entire OS into RAM (8GB+ required)"
    echo "    - Detect your GPU (NVIDIA/AMD/Intel)"
    echo "    - Apply appropriate performance profile"
    echo "    - Start layer sync daemon (syncs changes every 60s)"
    echo "    - Mount user data via CacheFS"
    echo ""
    echo "  Layer Structure:"
    echo "    RAM Upper    → Instant writes (volatile)"
    echo "    Custom Layer → Your packages, configs (syncs from RAM)"
    echo "    Updates Layer → OS updates (separate)"
    echo "    Base Layer   → Bazzite OS (read-only)"
    echo ""
    echo "  Key Commands:"
    echo "    powos status        - Show system status"
    echo "    powos layers        - View layer stack"
    echo "    powos sync          - Force sync to USB"
    echo "    powos rollback      - Rollback options"
    echo ""
    echo "  Default login:"
    echo "    User: powos"
    echo "    Pass: powos (change this!)"
    echo ""
}

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────
main() {
    local device="${1:-}"

    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  PowOS USB Installer                                       ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"

    if [[ -z "$device" ]]; then
        echo ""
        echo "Usage: sudo $0 /dev/sdX"
        echo ""
        echo "Available drives:"
        lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -E "usb|nvme" || lsblk -d -o NAME,SIZE,MODEL
        echo ""
        echo "WARNING: Select your USB drive carefully!"
        exit 1
    fi

    check_root
    check_gaming_handheld
    check_device "$device"
    check_system_disk "$device"
    confirm_destruction "$device"

    # If ISO exists, write it directly
    if [[ -f "$ISO_PATH" ]]; then
        log "Found ISO: $ISO_PATH"
        write_iso "$device"
    else
        # No ISO - partition and setup for manual install
        log "No ISO found - setting up partitions only"
        partition_drive "$device"
        format_partitions "$device"
        setup_persistence "$device"
        log ""
        log_warn "Partitions ready, but no bootable system installed"
        log_warn "Build ISO first: ./build/build-iso.sh"
    fi

    show_complete "$device"
}

main "$@"
