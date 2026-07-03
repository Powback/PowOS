#!/bin/bash
# vm.sh - PowOS reciprocal VM: boot your *other* installed OS as a VM.
#
# The dual-boot dream without rebooting: from PowOS, run the Windows you
# installed on disk as a KVM guest that boots the SAME physical partition —
# no second copy. (The reverse direction, Windows host → PowOS guest, is a
# Windows-side recipe; see docs/DUAL-BOOT-VM.md.)
#
# Entry point: cmd_vm "$@"
#
# SAFETY MODEL (critical — this passes a real disk to a VM):
#   - NEVER boot a disk the host currently has mounted read-write. Booting an OS
#     whose partitions are also live on the host = guaranteed corruption.
#   - Warn loudly if Windows shares a disk with the running PowOS root.
#   - Disable Windows Fast Startup/hibernation first, or the VM boots a frozen
#     image and the on-disk state corrupts.
#   - Nothing launches without an explicit confirmation; --dry-run prints only.
#
# High-perf gaming in the guest needs GPU passthrough (2 GPUs + IOMMU); that is
# an opt-in advanced mode (--gpu), not the default.

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

vm_log()  { echo -e "${CYAN}[vm]${NC} $*"; }
vm_ok()   { echo -e "${GREEN}[vm]${NC} $*"; }
vm_warn() { echo -e "${YELLOW}[vm]${NC} $*"; }
vm_err()  { echo -e "${RED}[vm]${NC} $*" >&2; }
vm_step() { echo; echo -e "${BOLD}── $* ──${NC}"; }

# ── Options / globals ─────────────────────────────────────────────
VM_DRY_RUN=0
VM_RAM="8G"
VM_CPUS="4"
VM_GPU=0            # 1 = attempt GPU passthrough (advanced)
VM_DISK=""          # explicit target disk override

# OVMF (UEFI firmware) search paths — differ across distros.
VM_OVMF_CODE_CANDIDATES=(
    /usr/share/edk2/ovmf/OVMF_CODE.fd
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/qemu/OVMF_CODE.fd
)
VM_OVMF_VARS_CANDIDATES=(
    /usr/share/edk2/ovmf/OVMF_VARS.fd
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/qemu/OVMF_VARS.fd
)

vm_find_first_existing() {
    local f
    for f in "$@"; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done
    return 1
}

# ── Disk discovery ────────────────────────────────────────────────
# Which physical disk backs the running PowOS root? Never boot that one.
vm_host_root_disk() {
    local src base
    src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    [[ -z "$src" ]] && return 0
    base=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
    [[ -n "$base" ]] && echo "/dev/$base"
}

# Find the disk that holds a Windows install (Boot Manager or NTFS).
# Echoes the disk path, returns 0 if found.
vm_find_windows_disk() {
    local disk part
    while read -r disk; do
        [[ -b "$disk" ]] || continue
        while read -r part; do
            [[ -b "$part" ]] || continue
            local fstype; fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
            if [[ "$fstype" == "ntfs" ]]; then echo "$disk"; return 0; fi
            if [[ "$fstype" == "vfat" ]]; then
                local mp; mp=$(mktemp -d)
                if mount -o ro "$part" "$mp" 2>/dev/null; then
                    if [[ -e "$mp/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
                        umount "$mp" 2>/dev/null; rmdir "$mp" 2>/dev/null
                        echo "$disk"; return 0
                    fi
                    umount "$mp" 2>/dev/null || true
                fi
                rmdir "$mp" 2>/dev/null || true
            fi
        done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)
    done < <(lsblk -dn -o PATH,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
    return 1
}

# Is any partition of $1 currently mounted on the host?
vm_disk_is_mounted() {
    local disk="$1" part
    while read -r part; do
        findmnt -n -S "$part" &>/dev/null && return 0
    done < <(lsblk -ln -o PATH "$disk" 2>/dev/null | tail -n +2)
    return 1
}

# ── Launch config generation (pure — unit-testable) ───────────────
# Emit a qemu-system-x86_64 command line for booting $disk as a UEFI guest.
# Uses AHCI/SATA (native Windows driver support) for the passed-through disk.
vm_build_qemu_cmd() {
    local disk="$1" ram="$2" cpus="$3" ovmf_code="$4" ovmf_vars="$5" gpu="${6:-0}"
    local -a cmd=(
        qemu-system-x86_64
        -enable-kvm
        -machine "q35,smm=on"
        -cpu host
        -smp "$cpus"
        -m "$ram"
        -drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}"
        -drive "if=pflash,format=raw,file=${ovmf_vars}"
        -drive "file=${disk},format=raw,if=none,id=osdisk,cache=none,aio=native"
        -device "ahci,id=ahci"
        -device "ide-hd,drive=osdisk,bus=ahci.0"
        -netdev "user,id=net0"
        -device "virtio-net-pci,netdev=net0"
        -usb -device usb-tablet
    )
    if [[ "$gpu" == "1" ]]; then
        # Placeholder — real passthrough needs a specific PCI address bound to
        # vfio-pci and IOMMU on the kernel cmdline. Left explicit on purpose.
        cmd+=( -device "vfio-pci,host=GPU_PCI_ADDR" )
    else
        cmd+=( -display "gtk,gl=on" -device virtio-vga-gl )
    fi
    # Plain space-join: these args contain no spaces, so this stays eval-safe
    # while remaining readable (unlike %q, which backslash-escapes the commas).
    printf '%s ' "${cmd[@]}"
    echo
}

# ── powos vm windows ──────────────────────────────────────────────
vm_windows() {
    vm_step "Boot installed Windows as a VM"

    local disk="$VM_DISK"
    if [[ -z "$disk" ]]; then
        disk=$(vm_find_windows_disk) || {
            vm_err "No Windows install found on any disk."
            vm_err "Install Windows first, or pass --disk /dev/sdX explicitly."
            return 1
        }
    fi
    vm_log "Windows disk: $disk"

    # Safety: never boot a disk the host has mounted.
    if vm_disk_is_mounted "$disk"; then
        vm_err "$disk has partitions mounted on the host RIGHT NOW."
        vm_err "Booting it in a VM would corrupt the filesystem. Unmount them first."
        return 1
    fi

    # Safety: warn if Windows shares the disk with the running PowOS root.
    local root_disk; root_disk=$(vm_host_root_disk)
    if [[ -n "$root_disk" && "$disk" == "$root_disk" ]]; then
        vm_warn "$disk also holds the running PowOS root. The VM will have"
        vm_warn "write access to the whole disk — including your Linux partitions."
        vm_warn "Prefer Windows on a separate disk. Proceed only if you understand this."
    fi

    # Firmware
    local ovmf_code ovmf_vars
    ovmf_code=$(vm_find_first_existing "${VM_OVMF_CODE_CANDIDATES[@]}") || {
        vm_err "OVMF UEFI firmware not found. Install edk2-ovmf (dnf install edk2-ovmf)."
        return 1
    }
    local src_vars
    src_vars=$(vm_find_first_existing "${VM_OVMF_VARS_CANDIDATES[@]}") || {
        vm_err "OVMF_VARS template not found (edk2-ovmf)."; return 1
    }
    # Per-VM writable NVRAM copy.
    local vars_dir="${XDG_STATE_HOME:-$HOME/.local/state}/powos/vm"
    ovmf_vars="${vars_dir}/windows_VARS.fd"

    local cmd
    cmd=$(vm_build_qemu_cmd "$disk" "$VM_RAM" "$VM_CPUS" "$ovmf_code" "$ovmf_vars" "$VM_GPU")

    vm_step "Plan"
    echo "  Disk (passthrough): $disk"
    echo "  RAM / vCPUs:        $VM_RAM / $VM_CPUS"
    echo "  Firmware:           $ovmf_code"
    echo "  NVRAM (writable):   $ovmf_vars"
    echo "  GPU passthrough:    $([[ $VM_GPU == 1 ]] && echo 'yes (needs vfio-pci + IOMMU)' || echo 'no (virtio-vga)')"
    echo
    echo -e "  ${DIM}$cmd${NC}"
    echo
    echo -e "  ${BOLD}Before first boot:${NC} in Windows, disable Fast Startup + hibernation"
    echo "    (powercfg.exe /hibernate off). Windows may re-check activation because"
    echo "    the VM looks like different hardware — a digital licence absorbs this."

    if [[ $VM_DRY_RUN -eq 1 ]]; then
        vm_warn "--dry-run: not launching."
        return 0
    fi

    echo
    read -r -p "Launch the Windows VM now? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { vm_log "Aborted."; return 0; }

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        vm_err "Booting a raw disk needs root. Re-run: sudo powos vm windows"
        return 1
    fi
    if ! command -v qemu-system-x86_64 &>/dev/null; then
        vm_err "qemu not installed. Install qemu-kvm (dnf install qemu-kvm edk2-ovmf)."
        return 1
    fi
    mkdir -p "$vars_dir"
    [[ -f "$ovmf_vars" ]] || cp "$src_vars" "$ovmf_vars"

    vm_ok "Launching Windows VM…"
    eval "$cmd"
}

# ── powos vm status ───────────────────────────────────────────────
vm_status() {
    vm_step "Bootable-as-VM operating systems"
    local root_disk; root_disk=$(vm_host_root_disk)
    echo "  Running PowOS root disk: ${root_disk:-unknown} (never bootable as a VM)"
    echo
    local wdisk
    if wdisk=$(vm_find_windows_disk); then
        local mounted="no"; vm_disk_is_mounted "$wdisk" && mounted="YES (unmount before booting)"
        echo -e "  Windows:  ${GREEN}found${NC} on $wdisk"
        echo "            mounted on host: $mounted"
        echo "            boot it with:    sudo powos vm windows"
    else
        echo "  Windows:  not found on any disk"
    fi
    echo
    echo -e "  ${DIM}Reverse direction (Windows host → PowOS guest): see docs/DUAL-BOOT-VM.md${NC}"
}

vm_usage() {
    cat << EOF
powos vm — boot your other installed OS as a VM (no reboot, same partition)

Usage: powos vm <command> [options]

Commands:
  status            Show which installed OSes can be booted as a VM
  windows           Boot the installed Windows as a KVM guest (needs root)

Options (for 'windows'):
  --dry-run         Print the plan + qemu command, launch nothing
  --disk /dev/sdX   Use this disk instead of auto-detecting Windows
  --ram SIZE        Guest RAM (default: $VM_RAM)
  --cpus N          Guest vCPUs (default: $VM_CPUS)
  --gpu             Attempt GPU passthrough (advanced: needs 2 GPUs + IOMMU)
  -h, --help        This help

Safety: never boots a disk mounted on the host; warns if Windows shares the
PowOS disk; nothing launches without confirmation. Disable Windows Fast Startup
first. Reverse direction (run PowOS from Windows) is in docs/DUAL-BOOT-VM.md.
EOF
}

cmd_vm() {
    local sub="${1:-status}"; shift 2>/dev/null || true
    # Parse options (order-independent).
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) VM_DRY_RUN=1; shift ;;
            --gpu)     VM_GPU=1; shift ;;
            --disk)    VM_DISK="${2:-}"; shift 2 ;;
            --ram)     VM_RAM="${2:-8G}"; shift 2 ;;
            --cpus)    VM_CPUS="${2:-4}"; shift 2 ;;
            -h|--help) vm_usage; return 0 ;;
            *)         args+=("$1"); shift ;;
        esac
    done
    case "$sub" in
        status|list)     vm_status ;;
        windows|win)     vm_windows ;;
        help|-h|--help)  vm_usage ;;
        *)               vm_err "Unknown vm command: $sub"; vm_usage; return 1 ;;
    esac
}
