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

# Every temp mount this script makes is registered here and unmounted on exit,
# including on error. Without this a mid-script failure leaves the target's
# partitions mounted, which then blocks the next run ("Partition is mounted")
# and leaves stray mounts behind on the host.
POWOS_TMP_MOUNTS=()
_powos_cleanup_mounts() {
    local m
    for (( idx=${#POWOS_TMP_MOUNTS[@]}-1 ; idx>=0 ; idx-- )); do
        m="${POWOS_TMP_MOUNTS[idx]}"
        [[ -n "$m" ]] || continue
        mountpoint -q "$m" 2>/dev/null && umount "$m" 2>/dev/null
        [[ -d "$m" ]] && rmdir "$m" 2>/dev/null
    done
    return 0
}
trap _powos_cleanup_mounts EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWOS_ROOT="$(dirname "$SCRIPT_DIR")"
RAW_PATH="${POWOS_ROOT}/build/output/powos.raw"

# Tail-of-disk reservations (GB). POWOS-DATA takes everything EXCEPT these;
# see docs/WINDOWS.md.
#   GAMES_GB:   POWOS-GAMES NTFS partition, deliberately visible to Windows
#               (shared game assets; the default 'vhd' Windows backend also
#               stores its windows.vhdx image FILE here).
#   WINDOWS_GB: left UNALLOCATED at the disk tail. The 'partition' Windows
#               backend (WINDOWS_BACKEND=partition) carves a dedicated
#               WIN-ESP + POWOS-WIN from it; the default 'vhd' backend does not
#               use it (its image lives on POWOS-GAMES).
# DEFAULT IS "auto": reservations are ON by default, sized from the disk —
# the whole point is that a fresh burn is future-proof and NEVER needs a
# reformat to add games/Windows later. Override with explicit GB, 0 disables.
WINDOWS_GB="auto"
GAMES_GB="auto"

# Resolve "auto" reservations from the disk size (MiB). Policy: big disks get
# generous defaults, small ones scale down, tiny ones get nothing.
resolve_reservations() {
    local disk_mib="$1"
    if [[ "$GAMES_GB" == "auto" ]]; then
        if   (( disk_mib >= 3072*1024 )); then GAMES_GB=512
        elif (( disk_mib >= 1024*1024 )); then GAMES_GB=256
        elif (( disk_mib >=  512*1024 )); then GAMES_GB=128
        else GAMES_GB=0; fi
        log "Auto games reservation: ${GAMES_GB}GB (override with --games-gb N, 0 disables)"
    fi
    if [[ "$WINDOWS_GB" == "auto" ]]; then
        if   (( disk_mib >= 3072*1024 )); then WINDOWS_GB=256
        elif (( disk_mib >= 1024*1024 )); then WINDOWS_GB=128
        else WINDOWS_GB=0; fi
        log "Auto Windows reservation: ${WINDOWS_GB}GB unallocated (for the 'partition' backend; override with --windows-gb N, 0 disables)"
    fi
}

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
        # Non-zero: nothing was written, so callers must be able to tell this
        # apart from success. This used to `exit 0`, which meant an automated
        # bake whose confirmation never reached the prompt reported success and
        # then "verified" a completely blank device.
        log "Aborted — nothing was written"
        exit 1
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
# Force the kernel to (re)read the partition table and create device nodes for
# NEW partitions. `partprobe` alone is unreliable on LOOP devices — it often
# fails to create /dev/loopXpN after a fresh `parted mkpart`; `partx -a` adds
# the new-partition nodes reliably. `udevadm settle` waits for udev to finish.
rescan_parts() {
    local device="$1"
    partprobe "$device" 2>/dev/null || true
    partx -u "$device" 2>/dev/null || true   # refresh existing
    partx -a "$device" 2>/dev/null || true   # add nodes for NEW partitions
    # Loop devices: force a capacity + partition-table re-read.
    [[ "$device" == /dev/loop* ]] && losetup -c "$device" 2>/dev/null || true
    if command -v udevadm &>/dev/null; then
        # Trigger ONLY this device and its partitions. A bare
        # "--subsystem-match=block" re-triggers every block device on the
        # machine, which makes the desktop's automounter mount unrelated disks
        # — including the running system's own root partition. Six of those
        # accumulated during one session here and broke systemd's mount
        # namespacing (systemd-timedated and systemd-hostnamed died with
        # "/etc: No such file or directory", taking NTP with them).
        udevadm trigger --subsystem-match=block \
            --sysname-match="$(basename "$device")" \
            --sysname-match="$(basename "$device")[0-9]*" 2>/dev/null || true
        udevadm settle --timeout=10 2>/dev/null || true
    fi
}

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
    local disk_mib
    disk_mib=$(parted "$device" unit MiB print 2>/dev/null \
        | awk -F': ' '/^Disk \//{gsub("MiB","",$2); print int($2); exit}')
    if [[ "$disk_mib" =~ ^[0-9]+$ ]]; then
        resolve_reservations "$disk_mib"
    else
        # Can't size "auto" without the disk size; explicit GB would need it too.
        log_warn "Could not read the disk size — skipping games/windows reservations."
        WINDOWS_GB=0; GAMES_GB=0
    fi
    # Reserve the tail: POWOS-GAMES (games) + an unallocated region the
    # 'partition' Windows backend can later carve WIN-ESP + POWOS-WIN from.
    local reserve_mib=$(( (WINDOWS_GB + GAMES_GB) * 1024 ))
    if (( reserve_mib > 0 )); then
        local data_end_mib=$(( disk_mib - reserve_mib ))
        # DATA must keep a sane minimum (layers + /home) — 32GiB floor.
        if (( data_end_mib < ${last_end%.*} + 32768 )); then
            log_error "Reservation too large: --games-gb ${GAMES_GB} + --windows-gb ${WINDOWS_GB}"
            log_error "leaves less than 32GiB for POWOS-DATA on this ${disk_mib}MiB disk."
            exit 1
        fi
        data_end="${data_end_mib}MiB"
        log "Reserving ${reserve_mib}MiB at the disk tail (games=${GAMES_GB}GB POWOS-GAMES + windows=${WINDOWS_GB}GB unallocated)"
    fi

    log "Adding POWOS-DATA partition (${last_end}MiB → ${data_end})..."

    parted "$device" --script mkpart POWOS-DATA btrfs "${last_end}MiB" "$data_end" || {
        log_error "Could not create the POWOS-DATA partition on $device."
        log_error "Without it the USB has NO persistence (layers, /home). Aborting."
        log_error "Inspect with: sudo parted $device unit MiB print free"
        log_error "Then create it manually: sudo parted $device mkpart POWOS-DATA btrfs ${last_end}MiB ${data_end}"
        exit 1
    }

    # Re-read the partition table AND wait for the new partition's device node.
    # On LOOP devices `parted` writes the partition into the GPT but `partprobe`
    # frequently does NOT create /dev/loopXpN — so the -b check would abort on a
    # partition that genuinely exists (this is what broke the baked-image build
    # and the CI 'Build Disk Image' runs). rescan_parts() forces the node via
    # `partx -a`; retry a few times for udev to catch up.
    local data_part="" pnum _try
    rescan_parts "$device"
    for _try in $(seq 1 12); do
        # By GPT label first (robust); else the highest partition number
        # (lexicographic device sort breaks at partition 10).
        data_part=$(lsblk -ln -o PATH,PARTLABEL "$device" 2>/dev/null \
            | awk '$2 == "POWOS-DATA" {print $1; exit}')
        if [[ -z "$data_part" ]]; then
            pnum=$(parted -m -s "$device" print 2>/dev/null \
                | awk -F: '/^[0-9]+:/ {n=$1} END {print n}')
            if [[ "$pnum" =~ ^[0-9]+$ ]]; then
                if [[ "$device" =~ [0-9]$ ]]; then data_part="${device}p${pnum}"; else data_part="${device}${pnum}"; fi
            fi
        fi
        [[ -n "$data_part" && -b "$data_part" ]] && break
        rescan_parts "$device"; sleep 1
    done

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
        log_success "${WINDOWS_GB}GB left unallocated at the disk tail for the 'partition' Windows backend."
        log "The default 'vhd' backend ignores it (image goes on POWOS-GAMES). For partitions:"
        log "  sudo powos windows create   (with WINDOWS_BACKEND=partition)"
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
        # Leave the final WINDOWS_GB unallocated after POWOS-GAMES — the
        # 'partition' Windows backend carves WIN-ESP + POWOS-WIN from it.
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

# Write the Install + Recovery BLS entries into an ALREADY-KNOWN entries_dir.
# Shared by two callers:
#   * add_install_boot_entry   — mounts a target partition to FIND entries_dir
#                                (flash-a-fresh-USB path), then calls us.
#   * self_complete_boot_disk  — the boot dir is already mounted LIVE on first
#                                boot, so it passes /boot/loader/entries directly.
# Finds the live-boot entry as a template, then writes:
#   powos-install.conf  (title "Install PowOS to disk"; +powos.install=1)
#   powos-safe.conf     (Recovery — Safe mode;  +powos.mode=safe  rd.powos.ramboot=0)
#   powos-aidebug.conf  (Recovery — AI Debug;   +powos.mode=aidebug rd.powos.ramboot=0)
# All best-effort: warns and returns 0 on any problem so it NEVER bricks boot.
# Give a BLS entry an explicit sort-key.
#
# Every entry we generate is a COPY of the live entry, so they all inherit the
# same `version` field. grub2's blscfg sorts by version, they tie, and the order
# then falls back to directory read order — arbitrary. The sort-key at least
# makes OUR three entries order deterministically relative to each other
# (install before recovery).
#
# KNOWN LIMITATION, measured on a real boot: this does NOT move them behind the
# plain live entry. The menu still comes up as
#   *Recovery — Safe mode / Install PowOS to disk / Recovery — AI Debug / Bazzite
# with safe mode highlighted, so plugging the stick in and waiting boots into
# safe mode (RAM boot off) rather than the live desktop. Adding sort-key was
# tried and verified NOT to fix that; grub2 does not order sort-key entries
# after unkeyed ones. Making the live entry the default needs a different
# mechanism (grubenv saved_entry, or giving the recovery entries a lower
# version) and is deliberately not attempted here — it is boot-critical, and
# the current behaviour is safe, just unhelpful.
_bls_sort_key() {
    local file="$1" key="$2"
    grep -q '^sort-key ' "$file" 2>/dev/null && return 0
    printf 'sort-key %s\n' "$key" >> "$file"
}

# Make the DISPLAY the primary console on every entry on this medium.
#
# The last console= on the kernel command line becomes /dev/console. Images
# built by bootc-image-builder carry "console=tty0 console=ttyS0", which is
# right for a VM and wrong for physical hardware: on a machine with no serial
# port (a Steam Deck, most laptops) systemd's output and anything else writing
# to /dev/console goes to a port that does not exist, and the screen shows
# nothing but a cursor. Serial is kept — just no longer last — so VM debugging
# still works.
_bls_console_to_display() {
    local f="$1"
    grep -q '^options .*console=' "$f" 2>/dev/null || return 0
    awk '
        /^options / {
            n = 0
            for (i = 2; i <= NF; i++) {
                # Drop EVERY serial console. Keeping one and merely putting
                # console=tty0 last is theoretically equivalent — the last
                # console= becomes /dev/console — but on a Steam Deck that
                # still produced a blank screen, while deleting console=ttyS0
                # outright produced a working one. Ship the configuration that
                # was observed to work, not the one that should have.
                if ($i ~ /^console=ttyS/ || $i ~ /^console=ttyUSB/ || $i ~ /^console=ttyAMA/) continue
                if ($i == "console=tty0" || $i ~ /^plymouth.enable=/) continue
                out[n++] = $i
            }
            line = "options"
            for (i = 0; i < n; i++) line = line " " out[i]
            print line " console=tty0 plymouth.enable=0"
            next
        }
        { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# Give the boot menu a usable timeout and a sane default entry.
#
# The image ships "set timeout=1" and no explicit default, so GRUB takes entry
# 0 — and grub's blscfg lists BLS entries by FILENAME DESCENDING, which makes
# powos-safe.conf first. The result on real hardware: "Recovery — Safe mode"
# auto-boots one second after the menu appears, and a user who is not already
# holding an arrow key never gets to choose. (sort-key does NOT fix this: this
# grub ignores it when the entries do not all carry one, which was measured on
# a real boot.)
#
# Default is the plain live entry, not the installer: auto-starting a disk
# installer unattended is not something a boot timeout should ever do.
# Stop the LIVE medium from re-deploying itself, and from mounting the target
# machine's disks.
#
# bazzite-hardware-setup runs `rpm-ostree kargs` on first boot to add
# hardware-specific kargs, then reboots. On an installed system that is
# correct. On a live USB it is actively harmful: it creates a SECOND
# deployment, which makes ostree regenerate the loader slot (deleting the
# Install and Recovery entries), forces an extra reboot, and — observed on a
# Steam Deck — produced a deployment that hangs at initrd-switch-root, leaving
# the older one as the only bootable option.
#
# Masking it here affects ONLY the medium. A system installed FROM this stick
# is laid down from the offline variant store, so it gets the unmasked unit and
# configures its hardware normally on first boot.
# Units masked on the medium only. Each is correct on an installed system and
# wrong on an installer:
#
#   bazzite-hardware-setup     runs `rpm-ostree kargs` and reboots, creating a
#                              SECOND deployment — which makes ostree regenerate
#                              the loader slot and delete the Install/Recovery
#                              entries, and produced a deployment that hung at
#                              initrd-switch-root.
#   ublue-os-media-automount   "Mount partitons automaticaly" — it mounts the
#                              disks of the machine being installed. On a Steam
#                              Deck whose internal drive holds half of a
#                              degraded two-device btrfs, the mount never
#                              completes: dev-nvme0n1p1.device times out after
#                              90s, systemd-fsck@ and the .mount unit fail, and
#                              the boot stalls. An installer must not mount the
#                              disk it is about to write.
POWOS_LIVE_MASK_UNITS=(
    bazzite-hardware-setup.service
    ublue-os-media-automount.service
)

# Put /var/lib/containers on POWOS-DATA, from boot, via the medium's fstab.
#
# Installing a variant unpacks ~13.5GB into container storage. The medium's root
# holds the OS and has nowhere near that free — on a Steam Deck stick it is
# 25.9GB with the system already in it, so the install spent minutes copying
# blobs and then died with "no space left on device".
#
# Doing this at WRITE time rather than at install time is deliberate. Two
# attempts to relocate the storage at runtime both broke bootc, which resolves
# its own image through the canonical /var/lib/containers/storage and then
# re-execs in the host mount namespace: --root gave "no such object", and
# mounting the graph elsewhere gave "Re-exec in host mountns: exec: No such file
# or directory". An fstab entry keeps the canonical path AND puts the bytes on
# the big partition, with nothing to arrange mid-install.
_fstab_containers_on_data() {
    local device="$1" root_part data_part data_uuid mp deploy
    root_part=$(lsblk -nro NAME,LABEL "$device" 2>/dev/null | awk '$2=="root"{print "/dev/"$1; exit}')
    data_part=$(lsblk -nro NAME,LABEL "$device" 2>/dev/null | awk '$2=="POWOS-DATA"{print "/dev/"$1; exit}')
    [[ -n "$root_part" && -n "$data_part" ]] || { log_warn "No root/POWOS-DATA pair — container storage left on the medium root."; return 0; }
    data_uuid=$(blkid -s UUID -o value "$data_part" 2>/dev/null)
    [[ -n "$data_uuid" ]] || { log_warn "POWOS-DATA has no UUID yet — skipping the container-storage mount."; return 0; }

    mp=$(mktemp -d); POWOS_TMP_MOUNTS+=("$mp")
    mount "$root_part" "$mp" 2>/dev/null || { log_warn "Could not mount $root_part — container storage left on the medium root."; return 0; }
    local dm; dm=$(mktemp -d); POWOS_TMP_MOUNTS+=("$dm")
    mount "$data_part" "$dm" 2>/dev/null || { log_warn "Could not mount POWOS-DATA to verify the subvolume."; return 0; }
    for deploy in "$mp"/root/ostree/deploy/*/deploy/*.[0-9]; do
        [[ -d "$deploy/etc" ]] || continue
        mkdir -p "$deploy/var/lib/containers" 2>/dev/null || true
        if ! grep -q '/var/lib/containers' "$deploy/etc/fstab" 2>/dev/null; then
            # Only write the entry if the subvolume really exists, otherwise
            # nofail turns a broken mount into a silent one.
            if ! btrfs subvolume show "$dm/@powos/containers" >/dev/null 2>&1; then
                log_warn "@powos/containers is not a subvolume — not adding the fstab entry."
                continue
            fi
            printf 'UUID=%s /var/lib/containers btrfs subvol=@powos/containers,rw,noatime,nofail 0 0\n' \
                "$data_uuid" >> "$deploy/etc/fstab"
            log_success "Live medium: /var/lib/containers mounted from POWOS-DATA (room for the install)"
        fi
    done
    sync; umount "$mp" 2>/dev/null || true
}

_mask_live_hardware_setup() {
    local device="$1" root_part mp deploy
    root_part=$(lsblk -nro NAME,LABEL "$device" 2>/dev/null | awk '$2=="root"{print "/dev/"$1; exit}')
    [[ -n "$root_part" ]] || { log_warn "No 'root' partition found — hardware-setup left unmasked."; return 0; }
    mp=$(mktemp -d); POWOS_TMP_MOUNTS+=("$mp")
    mount "$root_part" "$mp" 2>/dev/null || { log_warn "Could not mount $root_part — hardware-setup left unmasked."; return 0; }
    local unit
    for deploy in "$mp"/root/ostree/deploy/*/deploy/*.[0-9]; do
        [[ -d "$deploy/etc/systemd/system" ]] || continue
        for unit in "${POWOS_LIVE_MASK_UNITS[@]}"; do
            ln -sfn /dev/null "$deploy/etc/systemd/system/$unit"
        done
        log_success "Live medium: masked ${POWOS_LIVE_MASK_UNITS[*]}"
    done
    sync; umount "$mp" 2>/dev/null || true
}

_grub_menu_defaults() {
    # Separate declarations: bash creates every name in a single `local` before
    # assigning any of them, so "cfg=$boot_mp/..." on the same line reads an
    # unset $boot_mp and dies under set -u.
    local boot_mp="$1"
    local cfg="$boot_mp/grub2/grub.cfg"
    local timeout="${POWOS_MENU_TIMEOUT:-10}"
    [[ -f "$cfg" ]] || { log_warn "No grub.cfg at $cfg — menu timeout/default left as-is."; return 0; }

    sed -i "s/^set timeout=[0-9]\+$/set timeout=$timeout/" "$cfg"

    # Default to the image's own live entry (the one we did not author).
    local live
    # NEWEST deployment, not the first alphabetically. ostree names entries
    # ostree-1.conf, ostree-2.conf, ... with the HIGHEST number being the most
    # recent deployment — so `sort | head -1` picked the OLD one. On a Steam
    # Deck that meant the menu defaulted to the deployment from before
    # bazzite-hardware-setup applied its Deck kargs.
    live=$(find "$boot_mp/loader/entries" -maxdepth 1 -name '*.conf' \
             ! -name 'powos-*' -printf '%f\n' 2>/dev/null | sort -V | tail -1)
    if [[ -z "$live" ]]; then
        log_warn "Could not identify the live BLS entry — default entry left as-is."
        return 0
    fi
    live="${live%.conf}"

    if grep -q '^set default=' "$cfg" && ! grep -q 'BEGIN powos-default' "$cfg"; then
        : # greenboot's conditional default; ours is appended after blscfg below
    fi
    if ! grep -q 'BEGIN powos-default' "$cfg"; then
        awk -v id="$live" '
            /### END 10_blscfg.cfg ###/ {
                print
                print "### BEGIN powos-default ###"
                print "set default=\"" id "\""
                print "### END powos-default ###"
                next
            }
            { print }
        ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    fi
    log_success "Boot menu: ${timeout}s timeout, default entry '$live'"
}

write_bls_entries() {
    local entries_dir="$1"

    if [[ -z "$entries_dir" || ! -d "$entries_dir" ]]; then
        log_warn "write_bls_entries: entries dir '$entries_dir' is missing — skipping."
        return 0
    fi

    # Pick the first existing entry as the template (the live boot entry).
    # Exclude entries WE generate so re-runs (self-complete) stay idempotent and
    # never template off an install/variant/recovery entry.
    local template
    template=$(find "$entries_dir" -maxdepth 1 -name '*.conf' \
        ! -name '*install*' ! -name '*variant*' \
        ! -name 'powos-safe*' ! -name 'powos-aidebug*' | head -1)
    if [[ -z "$template" ]]; then
        log_warn "No BLS entry template found in $entries_dir — skipping install/recovery entries."
        return 0
    fi

    # The template must have an options line (kernel args incl. root=). Writing
    # a bare `options powos.install=1` entry would be UNBOOTABLE — refuse.
    if ! grep -q '^options ' "$template"; then
        log_warn "BLS template $template has no 'options' line — cannot build"
        log_warn "bootable install/recovery entries. Skipping them."
        log_warn "You can still install after booting live:  sudo powos install-system"
        return 0
    fi

    local install_entry="${entries_dir}/powos-install.conf"
    # Copy template; retitle; append the installer kernel arg to the options
    # line. systemd.unit=multi-user.target keeps the display manager (SDDM)
    # from seizing tty1 and hiding the installer.
    awk '
        /^title / { print "title Install PowOS to disk"; next }
        /^options / { print $0 " powos.install=1 systemd.unit=multi-user.target plymouth.enable=0"; next }
        { print }
    ' "$template" > "$install_entry"
    # Ensure a title line existed; if not, add one (cosmetic only).
    grep -q '^title '   "$install_entry" || echo "title Install PowOS to disk" >> "$install_entry"
    # Sanity: the karg injection must have landed on the options line.
    if ! grep -q 'powos.install=1' "$install_entry"; then
        log_warn "Failed to inject powos.install=1 into $install_entry — removing it."
        rm -f "$install_entry"
    else
        _bls_sort_key "$install_entry" "powos-2-install"
        log_success "Added boot entry: 'Install PowOS to disk'"
    fi

    # ── Live boot with systemd debug logging ──────────────────────
    # The live entry reaches graphical.target and never starts a display
    # manager, with ZERO mentions of sddm in the journal despite the unit file,
    # the graphical.target.wants symlink and the display-manager alias all
    # being correct on disk. "Never considered" is not a failure mode that
    # ordinary logging explains, so this entry makes systemd record its
    # dependency resolution and unit loading, which will say whether sddm is
    # loaded, skipped, or dropped from the target.
    local dbg="$entries_dir/powos-debug.conf"
    awk '
        /^title /   { print "title Live boot (systemd debug logging)"; next }
        /^options / { print $0 " systemd.log_level=debug systemd.log_target=journal"; next }
        { print }
    ' "$template" > "$dbg"
    grep -q '^title ' "$dbg" || echo "title Live boot (systemd debug logging)" >> "$dbg"
    if grep -q '^options .*root=' "$dbg"; then
        log_success "Added boot entry: 'Live boot (systemd debug logging)'"
    else
        rm -f "$dbg"
    fi

    # ── Recovery entries (Safe mode + AI Debug) ───────────────────
    # Both force RAM boot OFF (so they come up even when a ramboot/normal boot
    # doesn't) and carry powos.mode=, which powos-safemode.service acts on:
    #   safe    → recovery menu (offer AI debug, rollback, reset, shell)
    #   aidebug → run `powos doctor --ai` straight away
    # systemd.unit=multi-user.target keeps SDDM off tty1 so the console shows.
    _write_recovery_entry() {
        local name="$1" title="$2" mode="$3"
        local out="${entries_dir}/${name}.conf"
        awk -v t="$title" -v m="$mode" '
            /^title / { print "title " t; next }
            /^options / { print $0 " rd.powos.ramboot=0 powos.mode=" m " systemd.unit=multi-user.target plymouth.enable=0"; next }
            { print }
        ' "$template" > "$out"
        grep -q '^title ' "$out" || echo "title $title" >> "$out"
        if grep -q "powos.mode=$mode" "$out"; then
            _bls_sort_key "$out" "powos-9-$name"
            log_success "Added boot entry: '$title'"
        else
            log_warn "Failed to build recovery entry '$title' — removing."
            rm -f "$out"
        fi
    }
    _write_recovery_entry "powos-safe"    "Recovery — Safe mode (RAM boot off)" "safe"
    _write_recovery_entry "powos-aidebug" "Recovery — AI Debug (diagnose boot)" "aidebug"
    # Point every entry on this medium at the display (see
    # _bls_console_to_display). Includes the image's own ostree entries, which
    # we did not write but which boot on the same hardware.
    local _e
    for _e in "$entries_dir"/*.conf; do
        [[ -f "$_e" ]] && _bls_console_to_display "$_e"
    done

}

add_install_boot_entry() {
    local device="$1"

    partprobe "$device" 2>/dev/null || true
    sleep 1
    log "Adding 'Install PowOS' boot menu entry..."

    local mp entries_dir="" part
    mp=$(mktemp -d); POWOS_TMP_MOUNTS+=("$mp")

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

    # Write the Install + Recovery BLS entries into the mounted entries dir.
    write_bls_entries "$entries_dir"
    # entries_dir is <boot>/loader/entries; grub.cfg lives at <boot>/grub2/.
    _grub_menu_defaults "$(dirname "$(dirname "$entries_dir")")"
    _mask_live_hardware_setup "$device"
    _fstab_containers_on_data "$device"

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

    mp=$(mktemp -d); POWOS_TMP_MOUNTS+=("$mp")
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
    mp=$(mktemp -d); POWOS_TMP_MOUNTS+=("$mp")
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
    mount_point=$(mktemp -d); POWOS_TMP_MOUNTS+=("$mount_point")

    log "Setting up persistent layer structure on $data_part..."
    mount "$data_part" "$mount_point"

    # Create btrfs subvolumes
    btrfs subvolume create "${mount_point}/@home" 2>/dev/null || mkdir -p "${mount_point}/@home"
    btrfs subvolume create "${mount_point}/@powos" 2>/dev/null || mkdir -p "${mount_point}/@powos"

    # PowOS directories
    mkdir -p "${mount_point}/@powos/extensions"
    mkdir -p "${mount_point}/@powos/sources"
    # A SUBVOLUME, not a directory: the medium's fstab mounts this at
    # /var/lib/containers with subvol=@powos/containers so the ~13.5GB install
    # unpack lands here instead of filling the medium's root. btrfs subvol=
    # only accepts a subvolume — pointed at a plain directory the mount fails,
    # and with nofail it fails SILENTLY, which is exactly the "no space left on
    # device" the entry exists to prevent.
    if [[ ! -d "${mount_point}/@powos/containers" ]]; then
        btrfs subvolume create "${mount_point}/@powos/containers" >/dev/null 2>&1 \
            || mkdir -p "${mount_point}/@powos/containers"
    fi
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

    # Offline GPU-variant store. Copying the OCI layout here is what lets the
    # installer lay down the NVIDIA image on an NVIDIA box and the Deck image
    # on a Deck FROM THIS STICK, with no network — see lib/variants.sh.
    if [[ -n "${WITH_VARIANTS:-}" ]]; then
        if [[ -f "${WITH_VARIANTS}/index.json" ]]; then
            log "  Copying offline variant store ($(du -sh "$WITH_VARIANTS" 2>/dev/null | cut -f1))..."
            mkdir -p "${mount_point}/@powos/variants"
            # -a preserves the layout verbatim; the blob digests ARE the
            # content addresses, so any rewriting would invalidate it.
            if cp -a "${WITH_VARIANTS}/." "${mount_point}/@powos/variants/"; then
                log_success "  Offline variants: $(python3 -c '
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print(" ".join(filter(None,[(m.get("annotations") or {}).get("org.opencontainers.image.ref.name") for m in d.get("manifests",[])])))
' "${mount_point}/@powos/variants/index.json" 2>/dev/null)"
            else
                log_error "  Failed to copy the variant store — the USB will install the running image only."
            fi
        else
            log_error "  --with-variants '${WITH_VARIANTS}' has no index.json; skipping."
        fi
    fi

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
# First-boot self-completion (runs on REAL hardware, NOT in CI/Docker).
#
# THE PROBLEM: baking POWOS-DATA + boot entries into the raw at BUILD time
# needs loop devices, whose partition nodes (/dev/loopXpN) appear unreliably in
# CI/Docker (partprobe/partx don't always create them). THE FIX: ship a plain
# bootable OS raw (bib makes that reliably) and SELF-COMPLETE here — on the
# first boot from the flashed USB, on real hardware where partition scanning
# works — creating POWOS-DATA in the free space (filling the ACTUAL device,
# whatever its size) and adding the Install/Recovery boot entries.
#
# Everything is best-effort/logged: the OS has ALREADY booted, so a failure
# here only means "no persistence yet", never a bricked boot.
#
# SAFETY INVARIANTS (read before touching this):
#   * ONLY-ADD-IN-FREE-SPACE: add_data_partition merely `mkpart`s a new
#     partition into the disk's FREE SPACE. It NEVER erases, shrinks, or
#     rewrites an existing partition. No dd, no whole-disk parted, no mkfs on
#     anything but the brand-new POWOS-DATA node.
#   * SINGLE-DISK VERIFICATION: we operate ONLY on the disk we actually booted
#     from — resolved from the partition backing /boot/efi (or /boot) and
#     verified to (a) be a whole-disk block device and (b) actually contain
#     that boot partition. We never guess a disk.
#   * IDEMPOTENT: bail immediately if POWOS-DATA already exists. The service
#     layer adds a once-only marker on top of this.
# ─────────────────────────────────────────────────────────────────
self_complete_boot_disk() {
    # Visible, step-by-step progress: this runs on the FIRST boot from a freshly
    # flashed USB (powos-firstboot-disk.service) and used to sit silent for a
    # minute while it partitioned — looking hung. Echo each step so the user can
    # see it is alive. Keep it dependency-free (plain log lines).
    log "Preparing persistence on first boot — this can take a minute, please wait."
    log "[1/4] Checking for an existing persistence partition..."

    # Already completed (label present anywhere)? Nothing to do — idempotent.
    if blkid -L POWOS-DATA >/dev/null 2>&1; then
        log_success "POWOS-DATA already exists — self-completion not needed."
        return 0
    fi

    log "[2/4] Resolving the boot disk we booted from..."
    # Resolve the partition backing /boot/efi (or /boot), then its parent disk.
    # This is the device we BOOTED from — the only disk we are allowed to touch.
    local src
    src=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)
    [[ -z "$src" ]] && src=$(findmnt -n -o SOURCE /boot 2>/dev/null || true)
    if [[ -z "$src" || "$src" != /dev/* ]]; then
        log_warn "Could not resolve the boot partition (/boot/efi or /boot)."
        log_warn "Skipping self-completion (boot is unaffected)."
        return 0
    fi

    local pk disk
    pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
    if [[ -z "$pk" ]]; then
        log_warn "Could not resolve the parent disk of boot source $src — skipping."
        return 0
    fi
    disk="/dev/$pk"

    # SAFETY: single-disk verification. The resolved node MUST be a real
    # whole-disk block device that ACTUALLY contains the boot source partition.
    # We gate on lsblk (the authoritative source of block topology — it reports
    # nothing for a non-existent/non-block path) rather than the `[[ -b ]]`
    # builtin, so this stays fully mockable in tests. If any check fails we
    # refuse rather than guess.
    if [[ "$(lsblk -dno TYPE "$disk" 2>/dev/null | head -1)" != "disk" ]]; then
        log_warn "$disk is not a whole-disk block device — skipping self-completion."
        return 0
    fi
    if ! lsblk -ln -o PATH "$disk" 2>/dev/null | grep -qxF "$src"; then
        log_warn "Boot source $src is not a partition of $disk — refusing to guess."
        return 0
    fi

    log "Resolved boot disk: $disk (backs $src)"

    # The boot USB may report NON-removable, and it is legitimately mounted (it
    # holds our live root/boot). Both would trip the guards on the flash path.
    # We bypass them because SAFETY INVARIANT: add_data_partition only creates a
    # partition in FREE SPACE — existing partitions are never touched.
    export POWOS_OVERRIDE_REMOVABLE=1

    # 1) Create POWOS-DATA in the free space. add_data_partition repair_gpt's
    #    first (moves the backup GPT to the REAL end of disk, so a small raw
    #    flashed onto a big USB exposes its free space), then fills it. Uses the
    #    robust rescan_parts already in this file. Reservations auto-size.
    log "[3/4] Creating POWOS-DATA in the free space (partitioning — please wait)..."
    add_data_partition "$disk" || log_warn "add_data_partition reported an issue — continuing."

    log "[4/4] Writing boot-menu entries and persistence layout..."
    # 2) Add Install/Recovery BLS entries to the ALREADY-MOUNTED live boot dir.
    #    Do NOT re-mount — it is live. Prefer /boot/loader, then /boot/efi/loader.
    local live_entries=""
    if [[ -d /boot/loader/entries ]]; then
        live_entries=/boot/loader/entries
    elif [[ -d /boot/efi/loader/entries ]]; then
        live_entries=/boot/efi/loader/entries
    fi
    if [[ -n "$live_entries" ]]; then
        write_bls_entries "$live_entries"
    else
        log_warn "No live loader/entries dir found — boot menu entries not added (non-fatal)."
    fi

    # 3) Lay down the persistence structure (subvolumes, layer dirs, state repo).
    setup_persistence "$disk" || log_warn "setup_persistence reported an issue — continuing."

    log_success "First-boot self-completion finished."
    return 0
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
    echo "  --self-complete     First-boot ADD-ONLY: resolve the disk we booted from,"
    echo "                      create POWOS-DATA in its free space, add boot entries."
    echo "                      Takes NO device arg (used by powos-firstboot-disk)."
    echo "  --image PATH        Path to powos.raw image (default: build/output/powos.raw)"
    echo "  --variants          Add multi-variant base rootfs + boot entries onto an"
    echo "                      already-written USB (needs ./build/build-iso.sh variants)"
    echo "  --games-gb N        Shared NTFS partition (POWOS-GAMES), visible to Windows"
    echo "                      (shared assets; the default 'vhd' Windows backend also"
    echo "                      stores its image here). DEFAULT: auto (512GB on 3TB+,"
    echo "                      scaling down; 0 on tiny disks). Pass 0 to disable."
    echo "  --windows-gb N      Unallocated tail for the 'partition' Windows backend"
    echo "                      (dedicated WIN-ESP + POWOS-WIN; docs/WINDOWS.md). The"
    echo "                      default 'vhd' backend ignores it. DEFAULT: auto (256GB"
    echo "                      on 3TB+). Pass 0 to disable."
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
    local self_complete=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --setup-data-only)
                setup_data_only=1
                shift
                ;;
            --self-complete)
                self_complete=1
                shift
                ;;
            --variants|--add-variants)
                variants_only=1
                shift
                ;;
            --with-variants)
                WITH_VARIANTS="${2:-}"; shift 2 ;;
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

    # Self-completion resolves its OWN device (the disk we booted from) — it
    # takes no /dev/ argument and runs an ADD-ONLY flow. Handle it before the
    # device-required check and the erase confirmation.
    if [[ "$self_complete" == "1" ]]; then
        log "First-boot self-completion mode (resolve boot disk, add persistence)"
        check_root
        self_complete_boot_disk
        return 0
    fi

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

    # Data-only mode is additive too: it appends POWOS-DATA in free space and
    # writes boot entries — nothing is erased, so the erase prompt would be
    # both wrong and a non-interactive (CI loopback bake) blocker.
    if [[ "$setup_data_only" == "1" ]]; then
        log "Setup data partition only mode (no erase)"
        add_data_partition "$device"
        add_install_boot_entry "$device"
        setup_persistence "$device"
        show_complete "$device"
        return 0
    fi

    confirm_usb_erase "$device"

    write_raw_image "$device" "$image"
    add_data_partition "$device"
    add_install_boot_entry "$device"
    setup_persistence "$device"

    show_complete "$device"
}

# Only auto-run when executed directly. When SOURCED (e.g. the tier-1 tests, or
# any consumer of write_bls_entries / self_complete_boot_disk) this is skipped
# so sourcing does not kick off a real install. NOTE: powos-firstboot-disk runs
# this file as a SUBPROCESS (bash install-to-usb.sh --self-complete), NOT by
# sourcing, so the top-of-file `set -euo pipefail` never contaminates the caller.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
