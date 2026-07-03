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
ISV_ERASE_CONFIRMED=0  # 1 = --i-understand-data-loss (with --yes: allows ERASE gates)
ISV_MODE=""            # alongside | whole-disk | "" (ask)
ISV_TARGET=""          # /dev/sdX chosen by user or flag
# Tail reservations. DEFAULT IS "auto": a fresh install is future-proof BY
# DEFAULT — games partition + Windows space sized from the disk, so the
# machine never needs a reformat to add them later. Explicit GB overrides,
# 0 disables. (Same policy as build/install-to-usb.sh resolve_reservations.)
ISV_SHARED_GB="auto"   # shared NTFS games partition (label POWOS-GAMES), GB
ISV_WINDOWS_GB="auto"  # unallocated tail for a future bare-metal Windows
ISV_SHARED_AUTO=0      # 1 = value came from "auto" (may shrink to fit)
ISV_WINDOWS_AUTO=0     # 1 = value came from "auto" (may shrink to fit)
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
        if [[ -n "$expected" ]]; then
            # Typed-confirmation gates protect ERASE-class operations. --yes
            # alone must NEVER satisfy them — a stray --yes in a script would
            # otherwise silently wipe a disk. Non-interactive erase requires
            # the additional explicit flag --i-understand-data-loss.
            if [[ ${ISV_ERASE_CONFIRMED:-0} -eq 1 ]]; then
                isv_warn "--yes --i-understand-data-loss: auto-confirming ERASE: $prompt"
                return 0
            fi
            isv_err "--yes does not satisfy a typed erase confirmation."
            isv_err "Re-run interactively, or add --i-understand-data-loss for"
            isv_err "non-interactive whole-disk erase (DANGEROUS)."
            return 1
        fi
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
# as an install target. On a ramboot system `findmnt /` returns "overlay",
# which identifies nothing — so gather every runtime hint we have:
#   1) the live root's backing store (real device on non-ramboot setups)
#   2) the POWOS-DATA partition by label
#   3) the device mounted at POWOS_USB_LAYERS (recorded by the initramfs in
#      /run/powos/ramboot-state)
#   4) USB_DEV from /run/powos/usb-state (written by powos-overlay-init)
isv_live_device() {
    local s candidates=()

    s=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    [[ "$s" == /dev/* ]] && candidates+=("$s")   # "overlay" etc. tell us nothing

    s=$(blkid -L POWOS-DATA 2>/dev/null || true)
    [[ -n "$s" ]] && candidates+=("$s")

    if [[ -r /run/powos/ramboot-state ]]; then
        local usb_layers
        usb_layers=$(awk -F= '$1=="POWOS_USB_LAYERS"{print $2; exit}' /run/powos/ramboot-state 2>/dev/null)
        if [[ -n "$usb_layers" ]]; then
            s=$(findmnt -n -o SOURCE "$usb_layers" 2>/dev/null || true)
            [[ "$s" == /dev/* ]] && candidates+=("$s")
        fi
    fi

    if [[ -r /run/powos/usb-state ]]; then
        s=$(awk -F= '$1=="USB_DEV"{print $2; exit}' /run/powos/usb-state 2>/dev/null)
        [[ "$s" == /dev/* ]] && candidates+=("$s")
    fi

    local out="" c base
    for c in ${candidates[@]+"${candidates[@]}"}; do
        # Strip to parent disk (e.g. /dev/sdb2 -> /dev/sdb, nvme0n1p2 -> nvme0n1)
        base=$(lsblk -no PKNAME "$c" 2>/dev/null | head -1)
        if [[ -n "$base" ]]; then
            out+=" /dev/$base"
        else
            out+=" $c"   # already a whole-disk node (or PKNAME unavailable)
        fi
    done
    echo "$out" | xargs -n1 2>/dev/null | sort -u | xargs 2>/dev/null
}

# ── Disk discovery ────────────────────────────────────────────────
# Emit candidate target disks: NAME SIZE MODEL TRAN REMOVABLE
# (excludes the live device; REMOVABLE is the sysfs flag: 1/0/?)
isv_candidate_disks() {
    local live; live=" $(isv_live_device) "
    lsblk -dn -o NAME,SIZE,MODEL,TRAN,TYPE 2>/dev/null | while read -r name size model tran type; do
        [[ "$type" == "disk" ]] || continue
        [[ "$name" == loop* || "$name" == sr* || "$name" == zram* ]] && continue
        [[ "$live" == *" /dev/$name "* ]] && continue   # skip the drive we booted from
        local rm_flag
        rm_flag=$(cat "/sys/block/$name/removable" 2>/dev/null || echo "?")
        printf '%s\t%s\t%s\t%s\t%s\n' "/dev/$name" "$size" "${model:-?}" "${tran:-?}" "$rm_flag"
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

    # If we could not work out which disk we booted from, the live USB may be
    # IN this list — say so loudly instead of silently including it.
    if [[ -z "$(isv_live_device)" ]]; then
        isv_warn "Could not determine which disk the live system booted from."
        isv_warn "This list may INCLUDE your live USB — check the REMOV column"
        isv_warn "(1 = removable) and the BUS/MODEL before choosing."
    fi

    local i=1
    echo
    printf "  ${BOLD}%3s  %-14s %-8s %-24s %-6s %-6s %s${NC}\n" "#" "DEVICE" "SIZE" "MODEL" "BUS" "REMOV" "WINDOWS?"
    for line in "${disks[@]}"; do
        local dev size model tran rm_flag
        IFS=$'\t' read -r dev size model tran rm_flag <<< "$line"
        local win="no"
        isv_detect_windows "$dev" && win="${YELLOW}YES${NC}"
        printf "  %3s  %-14s %-8s %-24s %-6s %-6s %b\n" "$i" "$dev" "$size" "${model:0:24}" "$tran" "${rm_flag:-?}" "$win"
        i=$((i+1))
    done
    echo

    if [[ -n "$ISV_TARGET" ]]; then
        # A preselected --disk target gets the SAME validation as an
        # interactive pick: it must be one of the enumerated candidates
        # (a real whole-disk block device that is not the live USB).
        local found=0 dev
        for line in "${disks[@]}"; do
            IFS=$'\t' read -r dev _ <<< "$line"
            [[ "$dev" == "$ISV_TARGET" ]] && { found=1; break; }
        done
        if [[ $found -ne 1 ]]; then
            isv_err "--disk $ISV_TARGET is not an installable target."
            isv_err "It is not in the candidate list above — it is not a whole-disk"
            isv_err "block device, or it is the live USB you booted from."
            return 1
        fi
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
# Largest free block on a disk: prints "START END SIZE" (MiB, suffix stripped).
# START/END may be fractional (e.g. 1.02) — pass them back to parted verbatim.
# CRITICAL: partitions must be bounded by END of the FREE BLOCK, never by
# parted's 100% / negative offsets, which measure from the end of the DISK —
# on a common Windows layout the recovery partition sits AFTER the free block.
isv_free_block() {
    local disk="${1:?isv_free_block: disk argument required}"
    parted "$disk" unit MiB print free 2>/dev/null | awk '
        /Free Space/ {
            s=$1; e=$2; sz=$3
            gsub("MiB","",s); gsub("MiB","",e); gsub("MiB","",sz)
            if (sz+0 > max) { max=sz+0; start=s; end=e }
        }
        END { if (max > 0) printf "%s %s %d\n", start, end, max }'
}

# Report free space (MiB) on a disk for the alongside path.
isv_free_space_mib() {
    local out
    out=$(isv_free_block "${1:?isv_free_space_mib: disk argument required}")
    if [[ -n "$out" ]]; then awk '{print $3+0}' <<< "$out"; else echo 0; fi
}

# Back-compat: start (MiB) of the largest free block (used by test/e2e).
isv_free_block_start() {
    isv_free_block "${1:-$ISV_TARGET}" | awk '{print $1}'
}

# Whole-disk size of a device in MiB (0 if unreadable).
isv_disk_size_mib() {
    local b
    b=$(lsblk -bdn -o SIZE "$1" 2>/dev/null | head -1 | tr -d '[:space:]')
    [[ "$b" =~ ^[0-9]+$ ]] || { echo 0; return; }
    echo $(( b / 1048576 ))
}

# PURE: auto-reservation policy — mirrors build/install-to-usb.sh's
# resolve_reservations, so burned USBs and installed disks follow ONE policy.
# $1 = disk size (MiB), $2 = games|windows. Echoes the reservation in GB.
isv_auto_reserve_gb() {
    local disk_mib="$1" kind="$2"
    case "$kind" in
        games)
            if   (( disk_mib >= 3072*1024 )); then echo 512
            elif (( disk_mib >= 1024*1024 )); then echo 256
            elif (( disk_mib >=  512*1024 )); then echo 128
            else echo 0; fi ;;
        windows)
            if   (( disk_mib >= 3072*1024 )); then echo 256
            elif (( disk_mib >= 1024*1024 )); then echo 128
            else echo 0; fi ;;
        *) echo 0 ;;
    esac
}

# Resolve "auto" reservations from the target disk size (call once the target
# is known, before the plan is shown). Explicit flag values pass through.
isv_resolve_reservations() {
    [[ "$ISV_SHARED_GB" == "auto" ]] && ISV_SHARED_AUTO=1
    [[ "$ISV_WINDOWS_GB" == "auto" ]] && ISV_WINDOWS_AUTO=1
    (( ISV_SHARED_AUTO || ISV_WINDOWS_AUTO )) || return 0

    local disk_mib
    disk_mib=$(isv_disk_size_mib "$ISV_TARGET")
    if (( disk_mib == 0 )); then
        isv_warn "Could not read the size of $ISV_TARGET — auto reservations disabled."
        [[ "$ISV_SHARED_GB"  == "auto" ]] && ISV_SHARED_GB=0
        [[ "$ISV_WINDOWS_GB" == "auto" ]] && ISV_WINDOWS_GB=0
        return 0
    fi
    if [[ "$ISV_SHARED_GB" == "auto" ]]; then
        ISV_SHARED_GB=$(isv_auto_reserve_gb "$disk_mib" games)
        isv_log "Auto games reservation: ${ISV_SHARED_GB}GB (--shared-gb N overrides, 0 disables)"
    fi
    if [[ "$ISV_WINDOWS_GB" == "auto" ]]; then
        ISV_WINDOWS_GB=$(isv_auto_reserve_gb "$disk_mib" windows)
        isv_log "Auto windows reservation: ${ISV_WINDOWS_GB}GB (--windows-gb N overrides, 0 disables)"
    fi
}

# PURE: fit reservations into the space they may consume. $1 = available
# space for reservations, $2 = shared, $3 = windows (all in the same unit).
# Shrink order: WINDOWS first, then games (a runnable game library beats
# space for a hypothetical Windows). Echoes "shared windows".
isv_fit_reservations() {
    local avail="$1" shared="$2" windows="$3"
    (( avail < 0 )) && avail=0
    if (( shared + windows > avail )); then
        windows=$(( avail - shared ))
        (( windows < 0 )) && windows=0
        (( shared > avail )) && shared=$avail
    fi
    echo "$shared $windows"
}

# Does the shipped bootc support limiting the root partition? Probed from its
# own help text — never assumed (bootc versions differ across base images).
isv_bootc_supports_root_size() {
    bootc install to-disk --help 2>/dev/null | grep -q -- '--root-size'
}

isv_choose_shared_size() {
    # Explicit --shared-gb → keep it, no prompt. "auto" (already resolved to
    # a number by isv_resolve_reservations) → interactive default is the auto
    # value, so pressing Enter keeps the future-proof layout.
    [[ ${ISV_SHARED_AUTO:-0} -eq 1 ]] || return 0
    [[ $ISV_ASSUME_YES -eq 1 ]] && return 0
    echo
    echo "  A shared games partition (NTFS, label POWOS-GAMES) is readable by BOTH"
    echo "  Windows and PowOS — one game library serving both OSes ('powos games')."
    local ans
    # printf + read (not read -p): the prompt must show even when stdin is
    # piped (read -p only prints on a tty).
    printf '  Size of shared NTFS partition in GB (0 = none) [auto: %s]: ' "$ISV_SHARED_GB"
    read -r ans
    if [[ -n "$ans" ]]; then
        if ! [[ "$ans" =~ ^[0-9]+$ ]]; then
            isv_err "Invalid size."; return 1
        fi
        ISV_SHARED_GB="$ans"
        ISV_SHARED_AUTO=0   # user's explicit answer must not silently shrink
    fi
}

isv_show_plan() {
    isv_step "Installation plan — REVIEW CAREFULLY"
    echo
    echo -e "  Target disk : ${BOLD}$ISV_TARGET${NC}"
    echo -e "  Mode        : ${BOLD}$ISV_MODE${NC}"
    echo -e "  Root FS     : $ISV_FS"
    echo -e "  Games NTFS  : $([[ "${ISV_SHARED_GB:-0}" == "0" ]] && echo none || echo "${ISV_SHARED_GB}GB (label POWOS-GAMES — visible to Windows, by design)")"
    echo -e "  Windows resv: $([[ "${ISV_WINDOWS_GB:-0}" == "0" ]] && echo none || echo "${ISV_WINDOWS_GB}GB unallocated (future 'powos windows create')")"
    echo
    if [[ "$ISV_MODE" == "whole-disk" ]]; then
        echo -e "  ${RED}${BOLD}THIS WILL ERASE ALL DATA ON $ISV_TARGET.${NC}"
        echo -e "  ${RED}Every existing partition and OS on this disk will be destroyed.${NC}"
    else
        local free; free=$(isv_free_space_mib "$ISV_TARGET")
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

    # Tail reservations (games partition + unallocated Windows space).
    # `bootc install to-disk` claims the ENTIRE disk unless it can limit the
    # root partition, so probe its help for --root-size — never assume.
    local shared_gb="${ISV_SHARED_GB:-0}" windows_gb="${ISV_WINDOWS_GB:-0}"
    [[ "$shared_gb"  =~ ^[0-9]+$ ]] || shared_gb=0
    [[ "$windows_gb" =~ ^[0-9]+$ ]] || windows_gb=0
    local reserve_gb=$(( shared_gb + windows_gb ))
    local -a size_args=()

    if (( reserve_gb > 0 )); then
        local supports=0
        if command -v bootc &>/dev/null; then
            isv_bootc_supports_root_size && supports=1
        else
            supports=1   # plan-only mode (no bootc): show the intended plan
        fi
        if (( supports == 1 )); then
            local disk_gib
            disk_gib=$(( $(isv_disk_size_mib "$ISV_TARGET") / 1024 ))
            if (( disk_gib == 0 )); then
                isv_err "Could not read the size of $ISV_TARGET — aborting before install."
                return 1
            fi
            # Root gets disk − reservations − 2GiB (ESP/boot partitions bootc
            # creates) and must keep at least 8GiB. Auto reservations SHRINK
            # to fit (windows first, then games — never fail an install over
            # a default); explicit flags that don't fit are a hard error.
            local fit_shared fit_windows
            read -r fit_shared fit_windows \
                <<< "$(isv_fit_reservations $(( disk_gib - 2 - 8 )) "$shared_gb" "$windows_gb")"
            if (( fit_windows < windows_gb )); then
                if [[ ${ISV_WINDOWS_AUTO:-0} -eq 1 ]]; then
                    isv_warn "Disk too small: windows reservation shrunk ${windows_gb}GB → ${fit_windows}GB."
                else
                    isv_err "Reservations too large: --shared-gb ${shared_gb} + --windows-gb ${windows_gb}"
                    isv_err "leave less than 8GiB for the PowOS root on this ${disk_gib}GiB disk."
                    isv_err "Nothing was changed. Reduce the reservations and re-run."
                    return 1
                fi
            fi
            if (( fit_shared < shared_gb )); then
                if [[ ${ISV_SHARED_AUTO:-0} -eq 1 ]]; then
                    isv_warn "Disk too small: games reservation shrunk ${shared_gb}GB → ${fit_shared}GB."
                else
                    isv_err "Reservation too large: --shared-gb ${shared_gb} leaves less than 8GiB"
                    isv_err "for the PowOS root on this ${disk_gib}GiB disk. Nothing was changed."
                    return 1
                fi
            fi
            shared_gb=$fit_shared; windows_gb=$fit_windows
            reserve_gb=$(( shared_gb + windows_gb ))
            if (( reserve_gb > 0 )); then
                local root_gib=$(( disk_gib - 2 - reserve_gb ))
                # bootc's --root-size takes a human-readable size (e.g. 348G).
                size_args=(--root-size "${root_gib}G")
                isv_log "Root limited to ${root_gib}G — reserving ${shared_gb}GB POWOS-GAMES"
                isv_log "+ ${windows_gb}GB unallocated (Windows) at the disk tail."
            fi
        else
            isv_warn "This bootc has no --root-size: it claims the ENTIRE disk, so the"
            isv_warn "games/windows reservations are impossible on a whole-disk install."
            isv_warn "Install --alongside for reservations, or re-install after a bootc"
            isv_warn "update. Continuing WITHOUT reservations."
            shared_gb=0; windows_gb=0; reserve_gb=0
        fi
    fi

    # bootc lays down ESP + root + bootloader and wipes the disk for us.
    # rd.powos.ramboot=0: the image's kargs.d ships ramboot=1 for the live USB;
    # a DISK install must not run from a tmpfs upper (every write would vanish
    # at reboot, and a plugged-in USB's layers would stack into the root).
    # TODO(hw): validate exact bootc flags against the shipped bootc version.
    run_step "wipe + install PowOS" \
        bootc install to-disk --wipe --karg rd.powos.ramboot=0 \
            --filesystem "$ISV_FS" ${size_args[@]+"${size_args[@]}"} "$ISV_TARGET" || {
        isv_err "bootc install failed."
        return 1
    }
    isv_ok "Base system installed."

    if (( shared_gb > 0 )); then
        # Non-fatal: the OS install already succeeded; a missing games
        # partition can always be added later with `powos games create`.
        isv_whole_disk_tail_partitions "$shared_gb" "$windows_gb" || true
    elif (( windows_gb > 0 )); then
        isv_ok "${windows_gb}GB left unallocated at the disk tail for Windows."
        isv_log "Carve it later from the installed PowOS:  sudo powos windows create"
    fi
}

# After a size-limited whole-disk install: create POWOS-GAMES in the tail
# that --root-size freed. Bounds are explicit MiB positions from the free
# block bootc left — NEVER 100%: when a Windows reservation exists that tail
# must stay UNALLOCATED for `powos windows create`.
isv_whole_disk_tail_partitions() {
    local shared_gb="$1" windows_gb="$2"
    isv_step "Creating the games partition in the reserved tail"

    local fb_start fb_end fb_size
    read -r fb_start fb_end fb_size <<< "$(isv_free_block "$ISV_TARGET")"
    if [[ -z "$fb_start" || -z "$fb_end" ]]; then
        isv_warn "No free block found after the install — cannot create POWOS-GAMES."
        isv_warn "Create it later:  sudo powos games create --size ${shared_gb}"
        return 0
    fi

    local games_end="$fb_end"
    if (( windows_gb > 0 )); then
        # LC_ALL=C: parted needs a period decimal separator, never a comma.
        games_end=$(LC_ALL=C awk -v e="$fb_end" -v w="$(( windows_gb * 1024 ))" \
            'BEGIN { printf "%.2f", e - w }')
    fi
    local expect_mib
    expect_mib=$(LC_ALL=C awk -v s="$fb_start" -v e="$games_end" 'BEGIN { printf "%d", e - s }')
    if (( expect_mib < 1024 )); then
        isv_warn "Free tail too small for POWOS-GAMES (${expect_mib}MiB) — skipping."
        isv_warn "Create it later:  sudo powos games create --size ${shared_gb}"
        return 0
    fi

    isv_create_shared_partition "$ISV_TARGET" "${fb_start}MiB" "${games_end}MiB" "$expect_mib"

    if (( windows_gb > 0 )); then
        isv_ok "${windows_gb}GB left unallocated at the disk tail for Windows."
        isv_log "Carve it later from the installed PowOS:  sudo powos windows create"
    fi
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

    # Bounds of the largest free block (MiB). Both START and END come from the
    # free block itself — NEVER use parted's 100% / -NMiB specs here: those are
    # measured from the end of the DISK, and on the common Windows layout a
    # recovery partition sits after the free block. Using disk-end offsets
    # would overlap (or destroy) it.
    local fb_start fb_end fb_size
    read -r fb_start fb_end fb_size <<< "$(isv_free_block "$ISV_TARGET")"
    if [[ -z "$fb_start" || -z "$fb_end" ]]; then
        isv_err "Could not find a free block on $ISV_TARGET. Shrink a partition from"
        isv_err "Windows Disk Management first to make room, then re-run."
        return 1
    fi

    # Reservations at the tail of the FREE BLOCK (never the disk's tail):
    #   [ PowOS root | POWOS-GAMES | unallocated Windows space ]
    # Auto reservations SHRINK to fit (windows first, then games — an install
    # must never fail over a default); explicit flags that don't fit error.
    local sh_gb="${ISV_SHARED_GB:-0}" win_gb="${ISV_WINDOWS_GB:-0}"
    [[ "$sh_gb"  =~ ^[0-9]+$ ]] || sh_gb=0
    [[ "$win_gb" =~ ^[0-9]+$ ]] || win_gb=0
    local req_shared=$(( sh_gb * 1024 )) req_windows=$(( win_gb * 1024 ))
    local shared_mib=$req_shared windows_mib=$req_windows
    if (( req_shared + req_windows > 0 )); then
        # Root keeps at least 8GiB of the free block.
        read -r shared_mib windows_mib \
            <<< "$(isv_fit_reservations $(( fb_size - 8192 )) "$req_shared" "$req_windows")"
        if (( windows_mib < req_windows )); then
            if [[ ${ISV_WINDOWS_AUTO:-0} -eq 1 ]]; then
                isv_warn "Free block too small: windows reservation shrunk ${req_windows}MiB → ${windows_mib}MiB."
            else
                isv_err "--windows-gb ${win_gb} does not fit in the ${fb_size}MiB free block"
                isv_err "with an 8GiB root minimum. Reduce it and re-run."
                return 1
            fi
        fi
        if (( shared_mib < req_shared )); then
            if [[ ${ISV_SHARED_AUTO:-0} -eq 1 ]]; then
                isv_warn "Free block too small: games reservation shrunk ${req_shared}MiB → ${shared_mib}MiB."
            else
                isv_err "Shared partition (${req_shared}MiB) leaves no room for PowOS in"
                isv_err "the ${fb_size}MiB free block. Reduce --shared-gb and re-run."
                return 1
            fi
        fi
    fi
    local root_end="$fb_end" games_end="$fb_end"
    if (( windows_mib > 0 )); then
        # LC_ALL=C: parted needs a period decimal separator, never a comma.
        games_end=$(LC_ALL=C awk -v e="$fb_end" -v w="$windows_mib" 'BEGIN { printf "%.2f", e - w }')
    fi
    if (( shared_mib + windows_mib > 0 )); then
        root_end=$(LC_ALL=C awk -v e="$fb_end" -v s="$shared_mib" -v w="$windows_mib" \
            'BEGIN { printf "%.2f", e - s - w }')
    fi

    run_step "create PowOS root partition (${fb_start}MiB → ${root_end}MiB)" \
        parted -s "$ISV_TARGET" mkpart PowOS "$ISV_FS" "${fb_start}MiB" "${root_end}MiB" || return 1
    [[ $ISV_DRY_RUN -eq 0 ]] && isv_settle "$ISV_TARGET"

    # Identify the new root by its GPT label (robust vs. device enumeration order).
    local root used_fallback=0
    if [[ $ISV_DRY_RUN -eq 1 ]]; then
        # mkpart was skipped — resolving a live device here would show an
        # EXISTING partition in the plan. Print a placeholder instead.
        root="<new PowOS partition>"
    else
        root=$(isv_part_by_partlabel "$ISV_TARGET" "PowOS")
        if [[ -z "$root" ]]; then
            root=$(isv_last_partition "$ISV_TARGET")
            used_fallback=1
        fi
        if [[ ! -b "$root" ]]; then
            isv_err "Could not locate the new PowOS partition after creation."
            return 1
        fi
        if [[ $used_fallback -eq 1 ]]; then
            # "Last partition" can be a PRE-EXISTING one (GPT fills numbering
            # gaps) — verify before we ever run mkfs on it.
            local expect_mib
            expect_mib=$(awk -v s="$fb_start" -v e="$root_end" 'BEGIN { printf "%d", e - s }')
            isv_warn "Partlabel lookup failed; fallback selected $root — verifying it."
            isv_verify_new_partition "$root" "$expect_mib" || return 1
        fi
    fi
    isv_log "New root partition: $root"

    # Create the games NTFS partition in the reserved tail (before formatting
    # root), bounded INSIDE the free block — the Windows reservation (if any)
    # stays unallocated after it.
    if [[ $shared_mib -gt 0 ]]; then
        isv_create_shared_partition "$ISV_TARGET" "${root_end}MiB" "${games_end}MiB" "$shared_mib"
    fi
    if (( windows_mib > 0 )); then
        isv_ok "${windows_mib}MiB left unallocated inside the free block for Windows."
        isv_log "Carve it later from the installed PowOS:  sudo powos windows create"
    fi

    # Format root, mount it + the shared ESP, hand off to bootc.
    # mkfs force flags differ: btrfs uses -f; ext4 (mke2fs) uses -F — for
    # mke2fs, -f means "fragment size" and would EAT the device argument.
    local mkfs_force="-f"
    [[ "$ISV_FS" == "ext4" ]] && mkfs_force="-F"
    local mnt; mnt=$(mktemp -d)
    run_step "format root ($ISV_FS)" mkfs."$ISV_FS" "$mkfs_force" "$root" || return 1
    run_step "mount root" mount "$root" "$mnt" || return 1
    run_step "mount shared ESP" bash -c "mkdir -p '$mnt/boot/efi' && mount '$esp' '$mnt/boot/efi'" || return 1
    # rd.powos.ramboot=0: see isv_install_whole_disk — a disk install must not
    # inherit the live image's ramboot karg.
    # TODO(hw): confirm to-filesystem flags against the shipped bootc version;
    # --acknowledge-destructive refers to the target rootfs (empty here), not the disk.
    run_step "install PowOS to filesystem" \
        bootc install to-filesystem --acknowledge-destructive \
            --karg rd.powos.ramboot=0 "$mnt" || {
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
# (explicit parted positions INSIDE the free block, e.g. "275200MiB" and
# "480000MiB" — never disk-end-relative specs like -NMiB/100%). $4 is the
# expected size in MiB, used to verify a fallback-selected partition before
# formatting. Non-fatal on failure — the OS install already succeeded; the
# user can add the partition later.
isv_create_shared_partition() {
    local dev="$1" pstart="$2" pend="$3" expect_mib="${4:-}"
    isv_step "Creating shared NTFS games partition (${pstart} → ${pend})"
    if ! command -v mkfs.ntfs &>/dev/null; then
        isv_warn "mkfs.ntfs not available (install ntfsprogs) — skipping."
        isv_warn "You can create POWOS-GAMES later:  sudo powos games create --size N"
        return 0
    fi
    run_step "create shared partition ($pstart → $pend)" \
        parted -s "$dev" mkpart POWOS-GAMES ntfs "$pstart" "$pend" || {
        isv_warn "Could not create shared partition — continuing without it."
        return 0
    }
    if [[ $ISV_DRY_RUN -eq 1 ]]; then
        # mkpart was skipped — don't resolve a live device for the plan.
        run_step "format shared NTFS (label POWOS-GAMES)" \
            mkfs.ntfs -f -L POWOS-GAMES "<new POWOS-GAMES partition>"
        run_step "set GPT type 0700 (Microsoft basic data — visible to Windows)" \
            sgdisk -t "N:0700" "$dev"
        isv_ok "Shared games partition planned (label POWOS-GAMES)."
        return 0
    fi
    isv_settle "$dev"
    local sp used_fallback=0
    sp=$(isv_part_by_partlabel "$dev" "POWOS-GAMES")
    [[ -z "$sp" ]] && { sp=$(isv_last_partition "$dev"); used_fallback=1; }
    if [[ ! -b "$sp" ]]; then
        isv_warn "Shared partition created but not found for formatting — format it manually."
        return 0
    fi
    if [[ $used_fallback -eq 1 ]]; then
        # Never mkfs a fallback-selected partition without proving it's the
        # one we just created (GPT can reuse a lower number for it).
        if ! isv_verify_new_partition "$sp" "$expect_mib"; then
            isv_warn "Skipping format of $sp — format POWOS-GAMES manually after checking."
            return 0
        fi
    fi
    run_step "format shared NTFS (label POWOS-GAMES)" \
        mkfs.ntfs -f -L POWOS-GAMES "$sp" || {
        isv_warn "mkfs.ntfs failed — format POWOS-GAMES manually."
        return 0
    }
    # Exposure contract (docs/WINDOWS.md): 0700 = Microsoft basic data, so
    # Windows letters the partition. Best-effort — without it the partition
    # still works on PowOS, but Windows may show it as un-lettered RAW.
    local pnum="${sp##*[!0-9]}"
    if command -v sgdisk &>/dev/null && [[ -n "$pnum" ]]; then
        run_step "set GPT type 0700 (Microsoft basic data — visible to Windows)" \
            sgdisk -t "${pnum}:0700" "$dev" || \
            isv_warn "sgdisk failed — fix later: sgdisk -t ${pnum}:0700 $dev"
    else
        isv_warn "sgdisk not available — set the GPT type later so Windows"
        isv_warn "letters the partition:  sgdisk -t ${pnum:-N}:0700 $dev"
    fi
    isv_ok "Shared games partition ready: $sp (label POWOS-GAMES)"
    isv_log "Wire it up on the PowOS side:  sudo powos games mount && sudo powos games steam-setup"
    isv_log "On Windows it appears as a drive letter — see 'powos games' / GAMES-README.txt."
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

# Find the EFI System Partition on a disk by its GPT esp/boot FLAG (parted
# machine-readable output). A bare "first vfat partition" heuristic is unsafe:
# a vfat DATA partition earlier on the disk would be selected and later have
# a bootloader written into it. The heuristic is kept only as a fallback and
# requires explicit interactive confirmation.
# NOTE: stdout is the result (captured by callers) — prompts/warnings go to stderr.
isv_find_esp() {
    local disk="$1" num flags part
    while IFS=: read -r num _ _ _ _ _ flags; do
        [[ "$num" =~ ^[0-9]+$ ]] || continue
        flags="${flags%;}"
        # Word-match so 'legacy_boot' does not count as 'boot'.
        flags=" ${flags//,/ } "
        if [[ "$flags" == *" esp "* || "$flags" == *" boot "* ]]; then
            part=$(isv_part_by_number "$disk" "$num") || continue
            echo "$part"; return 0
        fi
    done < <(parted -m -s "$disk" print 2>/dev/null)

    # Fallback heuristic: first vfat partition — never guess silently.
    local cand=""
    while read -r part; do
        isv_is_block "$part" || continue
        [[ "$(blkid -o value -s TYPE "$part" 2>/dev/null)" == "vfat" ]] || continue
        cand="$part"; break
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)
    [[ -z "$cand" ]] && return 1

    isv_warn "No partition carries the esp/boot flag on $disk." >&2
    isv_warn "Heuristic candidate (first vfat partition): $cand" >&2
    isv_warn "If this is a plain vfat DATA partition, answer no!" >&2
    if [[ $ISV_ASSUME_YES -eq 1 ]]; then
        isv_err "--yes: refusing to guess the ESP non-interactively."
        isv_err "Set the flag first (parted $disk set <N> esp on) or run interactively."
        return 1
    fi
    local ans
    read -r -p "Use $cand as the EFI System Partition? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return 1
    echo "$cand"
}

# Resolve partition number $2 on disk $1 to a device path via lsblk
# (handles both /dev/sdX3 and /dev/nvme0n1p3 naming).
isv_part_by_number() {
    local disk="$1" num="$2" part digits
    while read -r part; do
        digits="${part##*[!0-9]}"          # trailing digit run, "" if none
        [[ -n "$digits" && "$digits" == "$num" ]] && { echo "$part"; return 0; }
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)
    return 1
}

# Safety gate before formatting a partition selected by the "last partition"
# FALLBACK (GPT fills numbering gaps, so lsblk's last row can be a
# PRE-EXISTING partition). $1 = partition, $2 = expected size in MiB ("" to
# skip the size check). Returns non-zero — caller must NOT format — if the
# partition carries any filesystem signature or its size is off.
isv_verify_new_partition() {
    local part="$1" expect_mib="${2:-}"
    local sig
    sig=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
    if [[ -n "$sig" ]]; then
        isv_err "SAFETY ABORT: fallback-selected partition $part already contains a"
        isv_err "filesystem ($sig) — it is NOT the partition that was just created."
        isv_err "Nothing was formatted. Inspect the disk with: lsblk -f"
        return 1
    fi
    if [[ -n "$expect_mib" ]]; then
        local size_b size_mib diff
        size_b=$(lsblk -bnd -o SIZE "$part" 2>/dev/null | head -1 | tr -d '[:space:]')
        if [[ "$size_b" =~ ^[0-9]+$ ]]; then
            size_mib=$(( size_b / 1048576 ))
            diff=$(( size_mib - expect_mib )); (( diff < 0 )) && diff=$(( -diff ))
            if (( diff > 64 )); then   # tolerance for alignment rounding
                isv_err "SAFETY ABORT: $part is ${size_mib}MiB but the partition just"
                isv_err "created should be ~${expect_mib}MiB. Refusing to format it."
                return 1
            fi
        else
            isv_warn "Could not read the size of $part to double-check it —"
            isv_warn "proceeding on the (clean) filesystem-signature check alone."
        fi
    fi
    return 0
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

    # 0) GPU driver variant: the install carries whatever variant you booted.
    local booted_variant="nvidia-open (default)"
    local vk
    vk=$(grep -o 'rd.powos.variant=[^ ]*' /proc/cmdline 2>/dev/null | head -1)
    [[ -n "$vk" ]] && booted_variant="${vk#rd.powos.variant=}"
    isv_log "GPU driver variant installed: ${booted_variant}"
    isv_log "  (installs the variant you booted; to switch open<->closed, reboot"
    isv_log "   the live USB and pick a different entry, then re-install.)"

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
  --shared-gb N|auto   Shared NTFS games partition (label POWOS-GAMES),
                       visible to Windows — managed by 'powos games'.
                       Default: auto (sized from the disk; 0 disables)
  --windows-gb N|auto  Reserve N GB unallocated at the disk tail for a future
                       bare-metal Windows ('powos windows create').
                       Default: auto (sized from the disk; 0 disables)
  --fs btrfs|ext4      Root filesystem (default: btrfs)
  --dry-run            Show every action but change NOTHING on disk
  --yes                Skip y/N confirmations (SCRIPTING ONLY — dangerous).
                       Does NOT satisfy the typed-model erase confirmation.
  --i-understand-data-loss
                       With --yes: also auto-confirm the whole-disk ERASE gate
                       (otherwise non-interactive --whole-disk always aborts)
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
            --shared-gb)
                ISV_SHARED_GB="${2:-}"
                if ! [[ "$ISV_SHARED_GB" =~ ^([0-9]+|auto)$ ]]; then
                    isv_err "--shared-gb must be a whole number of GB or 'auto' (got: '${ISV_SHARED_GB}')"
                    return 1
                fi
                shift 2 ;;
            --windows-gb)
                ISV_WINDOWS_GB="${2:-}"
                if ! [[ "$ISV_WINDOWS_GB" =~ ^([0-9]+|auto)$ ]]; then
                    isv_err "--windows-gb must be a whole number of GB or 'auto' (got: '${ISV_WINDOWS_GB}')"
                    return 1
                fi
                shift 2 ;;
            --fs)
                ISV_FS="${2:-btrfs}"
                case "$ISV_FS" in
                    btrfs|ext4) ;;
                    *) isv_err "--fs must be btrfs or ext4 (got: '$ISV_FS')"; return 1 ;;
                esac
                shift 2 ;;
            --dry-run)     ISV_DRY_RUN=1; shift ;;
            --yes)         ISV_ASSUME_YES=1; shift ;;
            --i-understand-data-loss|--erase-confirmed)
                           ISV_ERASE_CONFIRMED=1; shift ;;
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
    # Resolve "auto" reservations from the target's size (default-on: a fresh
    # install is future-proof without asking), then let the interactive
    # alongside flow adjust the games size (default answer = the auto value).
    isv_resolve_reservations
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
        # Whole-disk honors the reservations via bootc --root-size (probed;
        # falls back to an honest warning on bootc versions without it).
        isv_install_whole_disk || return 1
    else
        # Alongside mode creates the games partition inline (reserved tail).
        isv_install_alongside  || return 1
    fi
    isv_post_install

    isv_step "Done"
    isv_ok "PowOS installed to $ISV_TARGET."
    echo "  Remove the USB and reboot, then pick PowOS from the UEFI boot menu."
    echo
}
