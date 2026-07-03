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

# Tail-of-disk reservations (GB). Set via --windows-gb / --games-gb.
# POWOS-DATA takes everything EXCEPT these; see docs/WINDOWS.md.
#   WINDOWS_GB: left UNALLOCATED — `powos windows create` later carves
#               WIN-ESP + POWOS-WIN out of it for bare-metal Windows.
#   GAMES_GB:   POWOS-GAMES NTFS partition, deliberately visible to Windows
#               (shared game assets between PowOS and the Windows install).
WINDOWS_GB=0
GAMES_GB=0

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
# Repair the GPT so it spans the whole device. After dd'ing a raw image, the
# backup GPT header sits at the end of the IMAGE (mid-disk); parted refuses to
# allocate the space beyond it until the GPT is moved to the real end of disk.
repair_gpt() {
    local device="$1"

    if command -v sgdisk &>/dev/null; then
        log "Repairing GPT (moving backup header to end of disk with sgdisk)..."
        if sgdisk -e "$device" >/dev/null 2>&1; then
            partprobe "$device" 2>/dev/null || true
            return 0
        fi
        log_warn "sgdisk -e failed — falling back to parted's GPT fix"
    fi

    # parted interactively offers to fix a mismatched backup GPT; feed it the
    # answer. Harmless no-op if the GPT is already correct.
    log "Repairing GPT with parted (answering its 'fix' prompt)..."
    printf 'fix\nfix\n' | parted ---pretend-input-tty "$device" print >/dev/null 2>&1 || true
    partprobe "$device" 2>/dev/null || true
}

add_data_partition() {
    local device="$1"

    # Reload partition table
    partprobe "$device" 2>/dev/null || true
    sleep 2

    log "Adding POWOS-DATA partition for persistent layers..."

    # Without this, parted sees no usable free space after the dd'd image and
    # every fresh USB would ship with NO data partition (no persistence).
    repair_gpt "$device"

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
        log_error "Could not detect the partition layout on $device."
        log_error "The USB has NO persistence partition — layers and /home would be lost."
        log_error "Fix the GPT and add it manually, then re-run with --setup-data-only:"
        log_error "  sudo sgdisk -e $device"
        log_error "  sudo parted $device mkpart POWOS-DATA btrfs <start>MiB 100%"
        exit 1
    fi

    # POWOS-DATA end: 100% unless a tail is reserved for the games partition
    # and/or the future Windows install (docs/WINDOWS.md). Reserved space is
    # measured from the END of the disk so DATA gets everything else.
    local data_end="100%"
    local reserve_mib=$(( (WINDOWS_GB + GAMES_GB) * 1024 ))
    if (( reserve_mib > 0 )); then
        local disk_mib
        disk_mib=$(parted "$device" unit MiB print 2>/dev/null \
            | awk -F': ' '/^Disk \//{gsub("MiB","",$2); print int($2); exit}')
        if ! [[ "$disk_mib" =~ ^[0-9]+$ ]]; then
            log_error "Could not read the disk size to apply the ${reserve_mib}MiB reservation."
            exit 1
        fi
        local data_end_mib=$(( disk_mib - reserve_mib ))
        # DATA must keep a sane minimum (layers + /home) — 32GiB floor.
        if (( data_end_mib < ${last_end%.*} + 32768 )); then
            log_error "Reservation too large: --windows-gb ${WINDOWS_GB} + --games-gb ${GAMES_GB}"
            log_error "leaves less than 32GiB for POWOS-DATA on this ${disk_mib}MiB disk."
            exit 1
        fi
        data_end="${data_end_mib}MiB"
        log "Reserving ${reserve_mib}MiB at the end of the disk (windows=${WINDOWS_GB}GB games=${GAMES_GB}GB)"
    fi

    log "Adding POWOS-DATA partition (${last_end}MiB → ${data_end})..."

    parted "$device" --script mkpart POWOS-DATA btrfs "${last_end}MiB" "$data_end" || {
        log_error "Could not create the POWOS-DATA partition on $device."
        log_error "Without it the USB has NO persistence (layers, /home). Aborting."
        log_error "Inspect with: sudo parted $device unit MiB print free"
        log_error "Then create it manually: sudo parted $device mkpart POWOS-DATA btrfs ${last_end}MiB ${data_end}"
        exit 1
    }

    partprobe "$device" 2>/dev/null || true
    sleep 2

    # Find the new partition by the GPT name we just gave it (lexicographic
    # sort of device names breaks at partition 10).
    local data_part
    data_part=$(lsblk -ln -o PATH,PARTLABEL "$device" 2>/dev/null \
        | awk '$2 == "POWOS-DATA" {print $1; exit}')

    # Fallback: highest partition NUMBER from parted (numeric, not lexicographic)
    if [[ -z "$data_part" ]]; then
        local pnum
        pnum=$(parted -m -s "$device" print 2>/dev/null \
            | awk -F: '/^[0-9]+:/ {n=$1} END {print n}')
        if [[ "$pnum" =~ ^[0-9]+$ ]]; then
            if [[ "$device" =~ [0-9]$ ]]; then
                data_part="${device}p${pnum}"
            else
                data_part="${device}${pnum}"
            fi
        fi
    fi

    if [[ -n "$data_part" && -b "$data_part" ]]; then
        log "Formatting POWOS-DATA partition: $data_part"
        mkfs.btrfs -f -L "POWOS-DATA" "$data_part"
        # Exposure contract (docs/WINDOWS.md): Linux partitions must carry the
        # Linux-filesystem GPT type GUID (sgdisk 8300). Windows assigns no
        # drive letter to that type — no "you need to format this disk"
        # prompts, no accidental clicks. parted's type choice is fs-hint
        # dependent, so set it explicitly.
        set_part_type "$device" "$data_part" 8300 "POWOS-DATA (hidden from Windows)"
        log_success "POWOS-DATA partition created: $data_part"
    else
        log_error "POWOS-DATA partition was created but its device node was not found."
        log_error "The USB is NOT ready (no formatted persistence partition). Aborting."
        log_error "Re-run: sudo $0 --setup-data-only $device"
        exit 1
    fi

    if (( GAMES_GB > 0 )); then
        add_games_partition "$device" "$data_end"
    fi
    if (( WINDOWS_GB > 0 )); then
        log_success "${WINDOWS_GB}GB left unallocated at the disk tail for Windows."
        log "Carve it later from a booted PowOS:  sudo powos windows create"
    fi
}

# Set the GPT partition type of $2 (a partition node on disk $1) via sgdisk.
# $3 = sgdisk type code (8300 Linux fs, 0700 Microsoft basic data), $4 = label
# for logging. Best-effort: without sgdisk we warn — the USB still works, but
# Windows may show the partition as un-lettered RAW instead of ignoring it.
set_part_type() {
    local device="$1" part="$2" code="$3" desc="$4"
    local pnum="${part##*[!0-9]}"
    if [[ -z "$pnum" ]]; then
        log_warn "Could not derive partition number of $part — leaving GPT type as-is."
        return 0
    fi
    if command -v sgdisk &>/dev/null; then
        if sgdisk -t "${pnum}:${code}" "$device" >/dev/null 2>&1; then
            log "GPT type ${code} set: $desc"
        else
            log_warn "sgdisk could not set type ${code} on ${part} — leaving as-is."
        fi
    else
        log_warn "sgdisk not installed — GPT type of ${part} left as parted chose it."
        log_warn "For the Windows-exposure contract, run: sgdisk -t ${pnum}:${code} ${device}"
    fi
}

# POWOS-GAMES: shared NTFS partition, deliberately visible to Windows (gets a
# drive letter there). Sits right after POWOS-DATA in the reserved tail.
add_games_partition() {
    local device="$1" start="$2"
    local games_end_spec
    if (( WINDOWS_GB > 0 )); then
        # Leave the final WINDOWS_GB unallocated after the games partition.
        local disk_mib
        disk_mib=$(parted "$device" unit MiB print 2>/dev/null \
            | awk -F': ' '/^Disk \//{gsub("MiB","",$2); print int($2); exit}')
        games_end_spec="$(( disk_mib - WINDOWS_GB * 1024 ))MiB"
    else
        games_end_spec="100%"
    fi

    log "Adding POWOS-GAMES partition (${start} → ${games_end_spec})..."
    parted "$device" --script mkpart POWOS-GAMES ntfs "$start" "$games_end_spec" || {
        log_warn "Could not create POWOS-GAMES — continuing without it."
        log_warn "Create it later: sudo parted $device mkpart POWOS-GAMES ntfs ${start} ${games_end_spec}"
        return 0
    }
    partprobe "$device" 2>/dev/null || true
    sleep 2

    local games_part
    games_part=$(lsblk -ln -o PATH,PARTLABEL "$device" 2>/dev/null \
        | awk '$2 == "POWOS-GAMES" {print $1; exit}')
    if [[ -z "$games_part" || ! -b "$games_part" ]]; then
        log_warn "POWOS-GAMES created but device node not found — format it manually (mkfs.ntfs -f -L POWOS-GAMES)."
        return 0
    fi

    if command -v mkfs.ntfs &>/dev/null; then
        log "Formatting POWOS-GAMES (NTFS): $games_part"
        mkfs.ntfs -f -L "POWOS-GAMES" "$games_part" || {
            log_warn "mkfs.ntfs failed — format $games_part manually."
            return 0
        }
    else
        log_warn "mkfs.ntfs not available (install ntfsprogs/ntfs-3g)."
        log_warn "Format later: sudo mkfs.ntfs -f -L POWOS-GAMES $games_part"
    fi
    # Microsoft basic data type: Windows SHOULD see and letter this one.
    set_part_type "$device" "$games_part" 0700 "POWOS-GAMES (visible to Windows)"
    log_success "POWOS-GAMES partition ready: $games_part"
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

    # The template must have an options line (kernel args incl. root=). Writing
    # a bare `options powos.install=1` entry would be UNBOOTABLE — refuse.
    if ! grep -q '^options ' "$template"; then
        log_warn "BLS template $template has no 'options' line — cannot build a"
        log_warn "bootable install entry. Skipping the 'Install PowOS' menu entry."
        log_warn "You can still install after booting live:  sudo powos install-system"
        umount "$mp" 2>/dev/null || true
        rmdir "$mp" 2>/dev/null || true
        return 0
    fi

    local install_entry="${entries_dir}/powos-install.conf"
    # Copy template; retitle; append the installer kernel arg to the options
    # line. systemd.unit=multi-user.target keeps the display manager (SDDM)
    # from seizing tty1 and hiding the installer.
    awk '
        /^title / { print "title Install PowOS to disk"; next }
        /^options / { print $0 " powos.install=1 systemd.unit=multi-user.target"; next }
        { print }
    ' "$template" > "$install_entry"
    # Ensure a title line existed; if not, add one (cosmetic only).
    grep -q '^title '   "$install_entry" || echo "title Install PowOS to disk" >> "$install_entry"
    # Sanity: the karg injection must have landed on the options line.
    if ! grep -q 'powos.install=1' "$install_entry"; then
        log_warn "Failed to inject powos.install=1 into $install_entry — removing it."
        rm -f "$install_entry"
        umount "$mp" 2>/dev/null || true
        rmdir "$mp" 2>/dev/null || true
        return 0
    fi

    log_success "Added boot entry: 'Install PowOS to disk'"

    # Make the menu actually visible (bootc images often hide it / 0s timeout).
    # Fedora-family hosts ship grub2-editenv; Debian/Ubuntu ship grub-editenv.
    local editenv=""
    if command -v grub2-editenv &>/dev/null; then
        editenv="grub2-editenv"
    elif command -v grub-editenv &>/dev/null; then
        editenv="grub-editenv"
    fi

    local grubcfg
    if [[ -n "$editenv" ]]; then
        for grubcfg in "$mp/grub2/grubenv" "$mp/EFI"/*/grubenv "$mp/boot/grub2/grubenv"; do
            [[ -f "$grubcfg" ]] || continue
            "$editenv" "$grubcfg" set menu_auto_hide=0 2>/dev/null || true
        done
    else
        echo ""
        log_warn "═══════════════════════════════════════════════════════════════"
        log_warn "Neither grub2-editenv nor grub-editenv is installed on this host."
        log_warn "menu_auto_hide could NOT be cleared — the GRUB boot menu (with the"
        log_warn "'Install PowOS' and variant entries) may be HIDDEN at boot."
        log_warn "Fix: install GRUB tools (Fedora: grub2-tools; Debian/Ubuntu:"
        log_warn "grub-common), then run on the USB's boot partition:"
        log_warn "  grub-editenv <mount>/grub2/grubenv set menu_auto_hide=0"
        log_warn "Workaround at boot: hold Esc or Shift to show the menu once."
        log_warn "═══════════════════════════════════════════════════════════════"
        echo ""
    fi

    sync
    umount "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────
# Multi-variant USB: copy build/output/base-<variant>/ rootfs dirs onto the
# POWOS-DATA partition under layers/base-<variant>/, and add a boot-menu entry
# per variant (rd.powos.variant=). At boot, ramboot-setup.sh selects one.
# Assumes a base raw image is already written (it provides kernel + ESP +
# initramfs). TODO(hw): boot-critical — validate in a VM.
# ─────────────────────────────────────────────────────────────────
add_base_variants() {
    local device="$1"
    local src_dir="${POWOS_ROOT}/build/output"

    if ! ls -d "$src_dir"/base-*/ >/dev/null 2>&1; then
        log_error "No base-*/ variant rootfs found in $src_dir"
        log_error "Build them first: ./build/build-iso.sh variants"
        return 1
    fi

    partprobe "$device" 2>/dev/null || true; sleep 1
    local data_part mp
    data_part=$(blkid -L "POWOS-DATA" 2>/dev/null || true)
    [[ -z "$data_part" ]] && data_part=$(lsblk -ln -o NAME,LABEL "$device" | awk '/POWOS-DATA/{print "/dev/"$1; exit}')
    if [[ -z "$data_part" ]]; then
        log_error "POWOS-DATA partition not found — write the base image first."
        return 1
    fi

    mp=$(mktemp -d)
    mount "$data_part" "$mp" || { log_error "mount $data_part failed"; rmdir "$mp"; return 1; }
    mkdir -p "$mp/layers"

    local d name installed="" variant_names=()
    for d in "$src_dir"/base-*/; do
        name=$(basename "$d")   # base-<variant>
        log "Copying $name → USB layers/$name ..."
        rm -rf "${mp:?}/layers/$name"
        cp -a "$d" "$mp/layers/$name"
        installed="${installed}${name} "
        variant_names+=("${name#base-}")
    done
    sync
    log_success "Base variants installed: ${installed}"
    umount "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null || true

    # Only offer boot entries for variants that actually exist on the USB —
    # a menu entry for an uncopied variant would silently boot a different one.
    add_variant_boot_entries "$device" "${variant_names[@]}"
}

# Add a boot-menu entry per INSTALLED variant (passed as args by
# add_base_variants, which enumerated layers/base-* on the data partition),
# plus "auto" (hardware detect) and "main" (the raw image's own base).
add_variant_boot_entries() {
    local device="$1"; shift
    local requested=("$@")
    partprobe "$device" 2>/dev/null || true; sleep 1

    local mp entries_dir="" part
    mp=$(mktemp -d)
    while read -r part; do
        [[ -b "$part" ]] || continue
        if mount "$part" "$mp" 2>/dev/null; then
            if [[ -d "$mp/loader/entries" ]]; then entries_dir="$mp/loader/entries"; break
            elif [[ -d "$mp/boot/loader/entries" ]]; then entries_dir="$mp/boot/loader/entries"; break; fi
            umount "$mp" 2>/dev/null || true
        fi
    done < <(lsblk -ln -o PATH "$device" 2>/dev/null | tail -n +2)

    if [[ -z "$entries_dir" ]]; then
        log_warn "BLS loader/entries not found — variant boot entries not added."
        log_warn "Auto-detect still works; use rd.powos.variant= manually if needed."
        umount "$mp" 2>/dev/null || true; rmdir "$mp" 2>/dev/null || true
        return 0
    fi

    local template v
    template=$(find "$entries_dir" -maxdepth 1 -name '*.conf' ! -name '*install*' ! -name '*variant*' | head -1)
    [[ -z "$template" ]] && { log_warn "No BLS template — skipping variant entries."; umount "$mp" 2>/dev/null; rmdir "$mp"; return 0; }

    # A template without an options line cannot yield bootable entries
    # (a bare `options rd.powos.variant=x` entry has no root=/kernel args).
    if ! grep -q '^options ' "$template"; then
        log_warn "BLS template $template has no 'options' line — skipping variant entries."
        umount "$mp" 2>/dev/null || true; rmdir "$mp" 2>/dev/null || true
        return 0
    fi

    # Entries: auto (hardware detect), main (raw image's own base), and each
    # variant actually installed on the data partition. NO phantom entries.
    local variants=("auto" "main") seen r
    for r in ${requested[@]+"${requested[@]}"}; do
        seen=0
        for v in "${variants[@]}"; do [[ "$v" == "$r" ]] && seen=1; done
        [[ $seen -eq 0 ]] && variants+=("$r")
    done

    for v in "${variants[@]}"; do
        awk -v val="$v" '
            /^title / { print "title PowOS ("val")"; next }
            /^options / { print $0 " rd.powos.variant="val; next }
            { print }
        ' "$template" > "${entries_dir}/powos-variant-${v}.conf"
        if ! grep -q "rd.powos.variant=$v" "${entries_dir}/powos-variant-${v}.conf"; then
            log_warn "Failed to inject rd.powos.variant=$v — removing broken entry."
            rm -f "${entries_dir}/powos-variant-${v}.conf"
        fi
    done
    log_success "Added variant boot entries: ${variants[*]}"
    sync
    umount "$mp" 2>/dev/null || true; rmdir "$mp" 2>/dev/null || true
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
    # Re-runs regenerate an identical README; `git commit` would exit 1 with
    # nothing to commit and set -e would kill the script. Only commit changes.
    if [[ -n "$(git status --porcelain)" ]]; then
        git commit -q -m "Initial PowOS setup"
    else
        log "State repo already initialized — nothing to commit"
    fi

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
    echo "  --variants          Add multi-variant base rootfs + boot entries onto an"
    echo "                      already-written USB (needs ./build/build-iso.sh variants)"
    echo "  --games-gb N        Create an N GB shared NTFS partition (POWOS-GAMES),"
    echo "                      visible to Windows — game assets shared by both OSes"
    echo "  --windows-gb N      Leave N GB unallocated at the disk tail for a future"
    echo "                      bare-metal Windows ('powos windows create', docs/WINDOWS.md)"
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
    local variants_only=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --setup-data-only)
                setup_data_only=1
                shift
                ;;
            --variants|--add-variants)
                variants_only=1
                shift
                ;;
            --image)
                image="$2"
                shift 2
                ;;
            --windows-gb)
                WINDOWS_GB="${2:-0}"
                if ! [[ "$WINDOWS_GB" =~ ^[0-9]+$ ]]; then
                    log_error "--windows-gb needs a whole number of GB (got: '$WINDOWS_GB')"
                    exit 1
                fi
                shift 2
                ;;
            --games-gb)
                GAMES_GB="${2:-0}"
                if ! [[ "$GAMES_GB" =~ ^[0-9]+$ ]]; then
                    log_error "--games-gb needs a whole number of GB (got: '$GAMES_GB')"
                    exit 1
                fi
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

    # Multi-variant mode is additive (no full erase) — handle before confirm.
    if [[ "$variants_only" == "1" ]]; then
        log "Adding base variants to existing PowOS USB (no erase)"
        add_base_variants "$device"
        show_complete "$device"
        return 0
    fi

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
