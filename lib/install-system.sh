#!/bin/bash
# install-system.sh - PowOS interactive to-disk installer
#
# Runs FROM the live environment (booted from USB). Installs PowOS to an
# internal disk with an interactive, non-destructive-by-default flow:
#
#   - You pick the target disk (nothing is wiped without explicit confirmation)
#   - Existing Windows installs are detected and preserved by default
#   - Dual-boot mode installs into FREE SPACE alongside Windows
#   - Whole-disk mode requires typing the disk model to confirm
#   - Common dual-boot footguns are automated (RTC local time, shared data
#     partition, Fast Startup reminder)
#
# Entry point: cmd_install_system "$@"
#
# Boot integration: the USB boot menu's "Install PowOS" entry adds the kernel
# arg `powos.install=1`; powos-installer.service sees it and launches this on
# tty1. It is always runnable by hand:  sudo powos install-system
#
# SAFETY: destructive operations are gated behind run_step()/confirmations and
# skipped entirely under --dry-run. The whole-disk and alongside partition
# paths must still be validated on real hardware / a VM before trusting them
# with data — see the TODO(hw) markers.

set -uo pipefail   # NOTE: not -e; we handle errors explicitly around disk ops

# ── Presentation ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

isv_log()     { echo -e "${CYAN}[install]${NC} $*"; }
isv_ok()      { echo -e "${GREEN}[install]${NC} $*"; }
isv_warn()    { echo -e "${YELLOW}[install]${NC} $*"; }
isv_err()     { echo -e "${RED}[install]${NC} $*" >&2; }
isv_step()    { echo; echo -e "${BOLD}── $* ──${NC}"; }

# ── Global state (set by option parsing) ──────────────────────────
ISV_DRY_RUN=0          # 1 = print destructive actions, never execute
ISV_ASSUME_YES=0       # 1 = skip interactive confirmations (scripting; dangerous)
ISV_MODE=""            # alongside | whole-disk | "" (ask)
ISV_TARGET=""          # /dev/sdX chosen by user or flag
ISV_SHARED_GB=""       # size of shared NTFS data partition, "" = ask, 0 = none
ISV_FS="btrfs"         # root filesystem

# run_step "description" cmd args...
# Executes a (destructive) command unless dry-run. Always echoes it first.
run_step() {
    local desc="$1"; shift
    echo -e "  ${DIM}\$ $*${NC}"
    if [[ $ISV_DRY_RUN -eq 1 ]]; then
        isv_warn "dry-run: skipped ($desc)"
        return 0
    fi
    "$@"
}

confirm() {
    # confirm "prompt" [expected]  — if expected given, user must type it exactly
    local prompt="$1" expected="${2:-}"
    if [[ $ISV_ASSUME_YES -eq 1 ]]; then
        isv_warn "--yes: auto-confirming: $prompt"
        return 0
    fi
    local answer
    if [[ -n "$expected" ]]; then
        read -r -p "$prompt " answer
        [[ "$answer" == "$expected" ]]
    else
        read -r -p "$prompt [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]]
    fi
}

# ── Environment checks ────────────────────────────────────────────
isv_require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        isv_err "The installer must run as root:  sudo powos install-system"
        return 1
    fi
}

isv_require_tools() {
    local missing=()
    for t in lsblk blkid parted; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    if ! command -v bootc &>/dev/null; then
        # bootc is how we actually lay the OS down; without it we can only plan.
        isv_warn "bootc not found — installer will run in PLAN-ONLY mode."
        isv_warn "(bootc ships in the PowOS image; this only happens off-target.)"
        ISV_DRY_RUN=1
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        isv_err "Missing required tools: ${missing[*]}"
        return 1
    fi
}

# Which block device did we boot the live system from? We must never offer it
# as an install target. Resolve the backing device of the live root / USB data.
isv_live_device() {
    local src dev
    # The overlay/live root's backing store, or the POWOS-DATA partition's disk.
    src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    dev=$(blkid -L POWOS-DATA 2>/dev/null || true)
    local out=""
    for s in "$src" "$dev"; do
        [[ -n "$s" ]] || continue
        # Strip to parent disk (e.g. /dev/sdb2 -> /dev/sdb, nvme0n1p2 -> nvme0n1)
        local base
        base=$(lsblk -no PKNAME "$s" 2>/dev/null | head -1)
        [[ -n "$base" ]] && out+=" /dev/$base"
    done
    echo "$out" | xargs -n1 2>/dev/null | sort -u | xargs 2>/dev/null
}

# ── Disk discovery ────────────────────────────────────────────────
# Emit candidate target disks: NAME SIZE MODEL TRAN  (excludes the live device)
isv_candidate_disks() {
    local live; live=" $(isv_live_device) "
    lsblk -dn -o NAME,SIZE,MODEL,TRAN,TYPE 2>/dev/null | while read -r name size model tran type; do
        [[ "$type" == "disk" ]] || continue
        [[ "$name" == loop* || "$name" == sr* || "$name" == zram* ]] && continue
        [[ "$live" == *" /dev/$name "* ]] && continue   # skip the drive we booted from
        printf '%s\t%s\t%s\t%s\n' "/dev/$name" "$size" "${model:-?}" "${tran:-?}"
    done
}

# Detect a Windows install on a given disk. Echoes a human summary if found,
# returns 0 if Windows present, 1 otherwise.
isv_detect_windows() {
    local disk="$1" found=1
    # 1) Windows Boot Manager in an EFI System Partition on this disk
    local part
    while read -r part; do
        [[ -b "$part" ]] || continue
        local fstype
        fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
        # NTFS partition — very likely Windows C: or data
        if [[ "$fstype" == "ntfs" ]]; then
            found=0
        fi
        # EFI vfat that contains the MS bootloader
        if [[ "$fstype" == "vfat" ]]; then
            local mp; mp=$(mktemp -d)
            if mount -o ro "$part" "$mp" 2>/dev/null; then
                [[ -e "$mp/EFI/Microsoft/Boot/bootmgfw.efi" ]] && found=0
                umount "$mp" 2>/dev/null || true
            fi
            rmdir "$mp" 2>/dev/null || true
        fi
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)
    return $found
}

# ── UI: pick a disk ───────────────────────────────────────────────
isv_choose_disk() {
    isv_step "Select target disk"
    local disks=() line
    while IFS= read -r line; do disks+=("$line"); done < <(isv_candidate_disks)

    if [[ ${#disks[@]} -eq 0 ]]; then
        isv_err "No installable disks found (the live USB is excluded)."
        return 1
    fi

    local i=1
    echo
    printf "  ${BOLD}%3s  %-14s %-8s %-24s %-6s %s${NC}\n" "#" "DEVICE" "SIZE" "MODEL" "BUS" "WINDOWS?"
    for line in "${disks[@]}"; do
        local dev size model tran
        IFS=$'\t' read -r dev size model tran <<< "$line"
        local win="no"
        isv_detect_windows "$dev" && win="${YELLOW}YES${NC}"
        printf "  %3s  %-14s %-8s %-24s %-6s %b\n" "$i" "$dev" "$size" "${model:0:24}" "$tran" "$win"
        i=$((i+1))
    done
    echo

    if [[ -n "$ISV_TARGET" ]]; then
        isv_log "Target preselected via flag: $ISV_TARGET"
        return 0
    fi

    local choice
    read -r -p "Choose disk number to install to (or 'q' to quit): " choice
    [[ "$choice" == "q" ]] && { isv_log "Aborted."; return 1; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#disks[@]} )); then
        isv_err "Invalid selection."
        return 1
    fi
    IFS=$'\t' read -r ISV_TARGET _ <<< "${disks[$((choice-1))]}"
    isv_ok "Selected: $ISV_TARGET"
}

# ── UI: pick install mode ─────────────────────────────────────────
isv_choose_mode() {
    [[ -n "$ISV_MODE" ]] && return 0
    isv_step "Install mode for $ISV_TARGET"

    local has_win="no"
    isv_detect_windows "$ISV_TARGET" && has_win="yes"

    echo
    if [[ "$has_win" == "yes" ]]; then
        echo -e "  ${YELLOW}Windows was detected on this disk.${NC}"
        echo
        echo "  1) Dual-boot  — install PowOS into FREE SPACE, keep Windows  ${GREEN}(recommended)${NC}"
        echo "  2) Whole disk — ERASE everything (including Windows) and install only PowOS"
    else
        echo "  1) Dual-boot  — install into free space, preserve existing partitions"
        echo "  2) Whole disk — ERASE the entire disk and install only PowOS"
    fi
    echo
    local choice
    read -r -p "Choose mode [1]: " choice
    case "${choice:-1}" in
        1) ISV_MODE="alongside" ;;
        2) ISV_MODE="whole-disk" ;;
        *) isv_err "Invalid selection."; return 1 ;;
    esac
    isv_ok "Mode: $ISV_MODE"
}

# ── Planning ──────────────────────────────────────────────────────
# Report free space (MiB) on the target disk for the alongside path.
isv_free_space_mib() {
    parted "$ISV_TARGET" unit MiB print free 2>/dev/null \
        | awk '/Free Space/ {gsub("MiB","",$3); if ($3+0 > max) max=$3+0} END {print max+0}'
}

isv_choose_shared_size() {
    [[ -n "$ISV_SHARED_GB" ]] && return 0
    echo
    echo "  A shared data partition (NTFS) is readable by BOTH Windows and PowOS —"
    echo "  ideal for game assets, media, and projects you want in one place."
    local ans
    read -r -p "  Size of shared NTFS partition in GB (0 = none) [0]: " ans
    ISV_SHARED_GB="${ans:-0}"
    if ! [[ "$ISV_SHARED_GB" =~ ^[0-9]+$ ]]; then
        isv_err "Invalid size."; return 1
    fi
}

isv_show_plan() {
    isv_step "Installation plan — REVIEW CAREFULLY"
    echo
    echo -e "  Target disk : ${BOLD}$ISV_TARGET${NC}"
    echo -e "  Mode        : ${BOLD}$ISV_MODE${NC}"
    echo -e "  Root FS     : $ISV_FS"
    echo -e "  Shared NTFS : $([[ "${ISV_SHARED_GB:-0}" == 0 ]] && echo none || echo "${ISV_SHARED_GB}GB")"
    echo
    if [[ "$ISV_MODE" == "whole-disk" ]]; then
        echo -e "  ${RED}${BOLD}THIS WILL ERASE ALL DATA ON $ISV_TARGET.${NC}"
        echo -e "  ${RED}Every existing partition and OS on this disk will be destroyed.${NC}"
    else
        local free; free=$(isv_free_space_mib)
        echo -e "  Largest free block: ${free} MiB"
        echo -e "  PowOS will be installed into free space. Existing partitions are kept."
        if (( free < 65536 )); then
            isv_warn "Less than 64 GiB free — that's tight for PowOS + games."
        fi
    fi
    echo
    echo -e "  ${DIM}Current layout:${NC}"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$ISV_TARGET" 2>/dev/null | sed 's/^/    /'
    echo
}

# ── Execution ─────────────────────────────────────────────────────
isv_install_whole_disk() {
    isv_step "Installing (whole disk) to $ISV_TARGET"
    # bootc lays down ESP + root + bootloader and wipes the disk for us.
    # TODO(hw): validate exact bootc flags against the shipped bootc version.
    run_step "wipe + install PowOS" \
        bootc install to-disk --wipe --filesystem "$ISV_FS" "$ISV_TARGET" || {
        isv_err "bootc install failed."
        return 1
    }
    isv_ok "Base system installed."
}

isv_install_alongside() {
    isv_step "Installing (dual-boot) into free space on $ISV_TARGET"
    isv_warn "Dual-boot install is EXPERIMENTAL — TODO(hw): validate on real hardware/VM."

    # Reuse the existing EFI System Partition (Windows') so both bootloaders coexist.
    local esp
    esp=$(isv_find_esp "$ISV_TARGET")
    if [[ -z "$esp" ]]; then
        isv_err "No EFI System Partition found on $ISV_TARGET."
        isv_err "Dual-boot needs the existing ESP; aborting to avoid damage."
        return 1
    fi
    isv_log "Reusing EFI System Partition: $esp"

    # Start of the largest free block (MiB).
    local start
    start=$(isv_free_block_start)
    if [[ -z "$start" ]]; then
        isv_err "Could not find a free block on $ISV_TARGET. Shrink a partition from"
        isv_err "Windows Disk Management first to make room, then re-run."
        return 1
    fi

    # If a shared partition was requested, reserve it at the tail of the free
    # block so the PowOS root does not consume all remaining space.
    local shared_mib=0 root_end='100%'
    if [[ "${ISV_SHARED_GB:-0}" != 0 ]]; then
        shared_mib=$(( ISV_SHARED_GB * 1024 ))
        root_end="-${shared_mib}MiB"   # parted: negative = measured from disk end
    fi

    run_step "create PowOS root partition (${start}MiB → ${root_end})" \
        parted -s "$ISV_TARGET" mkpart PowOS "$ISV_FS" "${start}MiB" "$root_end" || return 1
    [[ $ISV_DRY_RUN -eq 0 ]] && isv_settle "$ISV_TARGET"

    # Identify the new root by its GPT label (robust vs. device enumeration order).
    local root
    root=$(isv_part_by_partlabel "$ISV_TARGET" "PowOS")
    [[ -z "$root" ]] && root=$(isv_last_partition "$ISV_TARGET")
    if [[ $ISV_DRY_RUN -eq 0 && ! -b "$root" ]]; then
        isv_err "Could not locate the new PowOS partition after creation."
        return 1
    fi
    isv_log "New root partition: ${root:-<dry-run>}"

    # Create the shared NTFS partition in the reserved tail (before formatting root).
    if [[ $shared_mib -gt 0 ]]; then
        isv_create_shared_partition "$ISV_TARGET" "-${shared_mib}MiB" '100%'
    fi

    # Format root, mount it + the shared ESP, hand off to bootc.
    local mnt; mnt=$(mktemp -d)
    run_step "format root ($ISV_FS)" mkfs."$ISV_FS" -f "$root" || return 1
    run_step "mount root" mount "$root" "$mnt" || return 1
    run_step "mount shared ESP" bash -c "mkdir -p '$mnt/boot/efi' && mount '$esp' '$mnt/boot/efi'" || return 1
    # TODO(hw): confirm to-filesystem flags against the shipped bootc version;
    # --acknowledge-destructive refers to the target rootfs (empty here), not the disk.
    run_step "install PowOS to filesystem" \
        bootc install to-filesystem --acknowledge-destructive "$mnt" || {
        isv_err "bootc install to-filesystem failed."
        run_step "cleanup unmount" umount -R "$mnt" 2>/dev/null || true
        return 1
    }
    run_step "unmount target" umount -R "$mnt" 2>/dev/null || true
    rmdir "$mnt" 2>/dev/null || true

    isv_ok "PowOS installed alongside existing OS."
    isv_warn "After reboot, if PowOS doesn't appear: use your motherboard's UEFI"
    isv_warn "boot menu (F-key) to pick it — atomic Bazzite's GRUB won't auto-list"
    isv_warn "Windows, and Windows updates can reset boot order."
}

# Create + format the shared NTFS data partition between $pstart and $pend
# (parted position specs, e.g. "-200GiB" and "100%"). Non-fatal on failure —
# the OS install already succeeded; the user can add the partition later.
isv_create_shared_partition() {
    local dev="$1" pstart="$2" pend="$3"
    isv_step "Creating ${ISV_SHARED_GB}GB shared NTFS data partition"
    if ! command -v mkfs.ntfs &>/dev/null; then
        isv_warn "mkfs.ntfs not available (install ntfsprogs) — skipping."
        isv_warn "You can create POWOS-SHARED later from Windows Disk Management."
        return 0
    fi
    run_step "create shared partition ($pstart → $pend)" \
        parted -s "$dev" mkpart POWOS-SHARED ntfs "$pstart" "$pend" || {
        isv_warn "Could not create shared partition — continuing without it."
        return 0
    }
    isv_settle "$dev"
    local sp
    sp=$(isv_part_by_partlabel "$dev" "POWOS-SHARED")
    [[ -z "$sp" ]] && sp=$(isv_last_partition "$dev")
    if [[ $ISV_DRY_RUN -eq 0 && ! -b "$sp" ]]; then
        isv_warn "Shared partition created but not found for formatting — format it manually."
        return 0
    fi
    run_step "format shared NTFS (label POWOS-SHARED)" \
        mkfs.ntfs -f -L POWOS-SHARED "$sp" || {
        isv_warn "mkfs.ntfs failed — format POWOS-SHARED manually."
        return 0
    }
    isv_ok "Shared data partition ready: ${sp:-<dry-run>} (label POWOS-SHARED)"
    isv_log "Mount it in both Windows and PowOS for shared files / game assets."
}

# Re-read the partition table and ensure kernel partition device nodes exist
# before we reference them. On a booted system udev creates the nodes; on
# minimal/no-udev environments partprobe alone isn't enough, so fall back to
# partx. Without this, a freshly-created partition may not have a /dev node yet.
isv_settle() {
    local dev="$1"
    partprobe "$dev" 2>/dev/null || true
    if command -v udevadm &>/dev/null; then
        udevadm settle 2>/dev/null || true
    fi
    # Fallbacks for environments without a running udev (add new nodes, then
    # refresh existing ones). Harmless if the nodes already exist.
    partx -a "$dev" 2>/dev/null || true
    partx -u "$dev" 2>/dev/null || true
    sleep 1
}

isv_find_esp() {
    # First vfat partition flagged 'esp'/'boot' on the disk.
    local disk="$1" part
    while read -r part; do
        [[ -b "$part" ]] || continue
        local fstype; fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
        [[ "$fstype" == "vfat" ]] || continue
        echo "$part"; return 0
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)
    return 1
}

# Start (MiB) of the LARGEST free block on the target disk.
isv_free_block_start() {
    parted "$ISV_TARGET" unit MiB print free 2>/dev/null | awk '
        /Free Space/ {
            s=$1; sz=$3; gsub("MiB","",s); gsub("MiB","",sz)
            if (sz+0 > max) { max=sz+0; start=s }
        }
        END { if (max>0) print start }'
}

# Resolve a partition on $1 by its GPT partition label ($2). Reads the label
# with blkid (straight from disk) rather than `lsblk -o PARTLABEL`, which comes
# from the udev db and is empty in environments where udev hasn't populated it.
isv_part_by_partlabel() {
    local dev="$1" want="$2" part
    while read -r part; do
        isv_is_block "$part" || continue
        [[ "$(blkid -o value -s PARTLABEL "$part" 2>/dev/null)" == "$want" ]] || continue
        echo "$part"; return 0
    done < <(lsblk -ln -o PATH "$dev" 2>/dev/null | tail -n +2)
    return 1
}

# Is $1 a block device? Wrapped in a function so tests can stub it (the `[[ -b ]]`
# builtin can't be mocked, and unit tests run where /dev/sdX doesn't exist).
isv_is_block() { [[ -b "$1" ]]; }

isv_last_partition() {
    lsblk -ln -o PATH "$1" 2>/dev/null | tail -1
}

# ── Post-install: automate the dual-boot footguns ─────────────────
isv_post_install() {
    isv_step "Post-install tuning (dual-boot friendliness)"

    # 1) Clock: Windows expects local-time RTC; matching it avoids clock skew.
    run_step "set RTC to local time (matches Windows)" \
        timedatectl set-local-rtc 1 --adjust-system-clock 2>/dev/null || \
        isv_warn "Could not set RTC mode now (will need to run post-boot)."

    # 2) Reminders we can't perform from Linux:
    echo
    echo -e "  ${BOLD}Do these in Windows to keep the shared disk safe:${NC}"
    echo "    • Disable Fast Startup + hibernation (locks/dirties NTFS):"
    echo -e "        ${DIM}powercfg.exe /hibernate off${NC}"
    echo "    • If BitLocker is on, suspend or decrypt before sharing partitions."
    echo "    • Prefer the UEFI boot menu (F-key at power-on) to choose OS."
    echo
    echo -e "  ${BOLD}Sharing a Steam library across both OSes:${NC}"
    echo "    • Put large game/media assets on the shared NTFS partition."
    echo "    • Keep each OS's Steam compatdata/prefixes on its NATIVE filesystem"
    echo "      (Proton needs ext4/btrfs semantics NTFS can't provide)."
    echo
}

# ── Main entry ────────────────────────────────────────────────────
isv_usage() {
    cat << EOF
powos install-system — install PowOS to an internal disk (from live USB)

Usage: sudo powos install-system [options]

Options:
  --alongside          Dual-boot: install into free space, keep other OSes
  --whole-disk         Erase the whole target disk (requires confirmation)
  --disk /dev/sdX      Preselect target disk (still shown for confirmation)
  --shared-gb N        Create an N GB shared NTFS data partition (0 = none)
  --fs btrfs|ext4      Root filesystem (default: btrfs)
  --dry-run            Show every action but change NOTHING on disk
  --yes                Skip confirmations (SCRIPTING ONLY — dangerous)
  -h, --help           This help

With no mode/disk flags, the installer is fully interactive.
Nothing is written to disk until you approve the plan.
EOF
}

# Parse CLI options into ISV_* globals. Returns 2 for --help (caller should
# print usage and stop), 1 on bad option, 0 otherwise. Kept separate from
# cmd_install_system so it can be unit-tested without touching any disk.
isv_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --alongside)   ISV_MODE="alongside"; shift ;;
            --whole-disk)  ISV_MODE="whole-disk"; shift ;;
            --disk)        ISV_TARGET="${2:-}"; shift 2 ;;
            --shared-gb)   ISV_SHARED_GB="${2:-}"; shift 2 ;;
            --fs)          ISV_FS="${2:-btrfs}"; shift 2 ;;
            --dry-run)     ISV_DRY_RUN=1; shift ;;
            --yes)         ISV_ASSUME_YES=1; shift ;;
            --auto)        shift ;;   # launched by powos-installer.service; interactive
            -h|--help)     return 2 ;;
            *)             isv_err "Unknown option: $1"; return 1 ;;
        esac
    done
    return 0
}

cmd_install_system() {
    local rc
    isv_parse_args "$@"; rc=$?
    case $rc in
        2) isv_usage; return 0 ;;
        1) isv_usage; return 1 ;;
    esac

    echo
    echo -e "${MAGENTA:-$CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}  PowOS System Installer${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    [[ $ISV_DRY_RUN -eq 1 ]] && isv_warn "DRY-RUN: no disk will be modified."

    isv_require_root  || return 1
    isv_require_tools || return 1

    isv_choose_disk   || return 1
    isv_choose_mode   || return 1
    [[ "$ISV_MODE" == "alongside" ]] && { isv_choose_shared_size || return 1; }

    isv_show_plan

    # Confirmation gate — stronger for destructive whole-disk.
    if [[ "$ISV_MODE" == "whole-disk" ]]; then
        local model
        model=$(lsblk -dn -o MODEL "$ISV_TARGET" 2>/dev/null | xargs || echo DISK)
        isv_warn "To ERASE $ISV_TARGET, type its model exactly: ${BOLD}$model${NC}"
        confirm "Model to confirm total erase:" "$model" || {
            isv_log "Confirmation failed — aborting. Nothing was changed."
            return 1
        }
    else
        confirm "Proceed with dual-boot install into free space?" || {
            isv_log "Aborted. Nothing was changed."
            return 1
        }
    fi

    if [[ "$ISV_MODE" == "whole-disk" ]]; then
        if [[ "${ISV_SHARED_GB:-0}" != 0 ]]; then
            isv_warn "--shared-gb is ignored with --whole-disk: 'bootc install to-disk'"
            isv_warn "claims the entire disk. Install --alongside for a shared partition,"
            isv_warn "or carve POWOS-SHARED afterward from Windows/Disk Management."
        fi
        isv_install_whole_disk || return 1
    else
        # Alongside mode creates the shared partition inline (reserved tail).
        isv_install_alongside  || return 1
    fi
    isv_post_install

    isv_step "Done"
    isv_ok "PowOS installed to $ISV_TARGET."
    echo "  Remove the USB and reboot, then pick PowOS from the UEFI boot menu."
    echo
}
