#!/bin/bash
# gpu.sh - hotswap a discrete GPU between the PowOS host and a VM guest.
#
# Keep the dGPU (e.g. your 5090) on Linux for CUDA + native gaming day-to-day,
# then hand it to a Windows VM for a gaming session and reclaim it after — WITHOUT
# permanently dedicating it to vfio (so CUDA keeps working when it's on the host).
# This is the dynamic-passthrough half of PowOS's reciprocal-VM story.
#
#   powos gpu status              # where the dGPU is + passthrough readiness
#   powos gpu to-vm [--dry-run]   # release from host driver → bind vfio-pci (VM-ready)
#   powos gpu to-host             # reclaim from vfio → native driver (Linux-ready)
#
# ⚠️ EXPERIMENTAL, hardware-specific, and boot/display-critical. HARD PREREQS:
#   1. IOMMU on (amd_iommu=on iommu=pt / intel_iommu=on) — `powos gpu status` checks.
#   2. Your DESKTOP must run on the OTHER GPU (e.g. the AMD iGPU). If the desktop
#      is on the dGPU, releasing it FREEZES your session — so `to-vm` REFUSES while
#      anything is using the dGPU. Move the display to the iGPU (monitor → the
#      motherboard port) first.
#   3. Nothing may be using the dGPU (close games; `powos cuda disable`/stop it).
#   Keep a TTY (Ctrl-Alt-F3) or SSH open the first time, as a recovery net.
set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh"
POWOS_TAG=gpu

# The discrete GPU slot to manage. Auto = first NVIDIA VGA; override POWOS_GPU_BDF.
gpu_dgpu_bdf() {
    [[ -n "${POWOS_GPU_BDF:-}" ]] && { echo "$POWOS_GPU_BDF"; return; }
    lspci -Dn | awk '$2 == "0300:" && $3 ~ /^10de:/ {print $1; exit}'
}
# Every PCI function on that slot (GPU + its HDMI-audio, e.g. 01:00.0 and 01:00.1)
# — they share an IOMMU group and must move together.
gpu_slot_bdfs() {
    local slot="${1%.*}"                       # 0000:01:00.0 -> 0000:01:00
    lspci -Dn | awk -v s="$slot." 'index($1, s) == 1 {print $1}'
}
gpu_driver_of() { local d; d="$(readlink "/sys/bus/pci/devices/$1/driver" 2>/dev/null)"; echo "${d##*/}"; }
gpu_iommu_on()  { [[ -d /sys/kernel/iommu_groups && -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; }

# Is anything using the dGPU right now (display server or CUDA)? If so, releasing
# it would wedge the machine — refuse.
gpu_in_use() {
    local bdf="$1"
    if command -v nvidia-smi >/dev/null 2>&1; then
        [[ -n "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)" ]] && return 0
    fi
    # any process holding an nvidia device node (compositor, X, games, cuda)
    fuser /dev/nvidia* >/dev/null 2>&1 && return 0
    return 1
}

cmd_gpu_status() {
    local bdf; bdf="$(gpu_dgpu_bdf)"
    echo -e "${BOLD}GPU hotswap status${NC}"
    if [[ -z "$bdf" ]]; then perr "No discrete NVIDIA GPU found."; return 1; fi
    local drv; drv="$(gpu_driver_of "$bdf")"
    echo "  dGPU:        $bdf  ($(lspci -s "${bdf#0000:}" | cut -d' ' -f2- | cut -c1-48))"
    echo "  group slots: $(gpu_slot_bdfs "$bdf" | tr '\n' ' ')"
    case "$drv" in
        vfio-pci) echo -e "  bound to:    ${YELLOW}vfio-pci${NC}  → ready for a VM (host can't use it)" ;;
        nvidia)   echo -e "  bound to:    ${GREEN}nvidia${NC}    → on the host (CUDA / native games)" ;;
        "")       echo -e "  bound to:    ${DIM}(none)${NC}" ;;
        *)        echo    "  bound to:    $drv" ;;
    esac
    gpu_iommu_on && echo -e "  IOMMU:       ${GREEN}on${NC}" || echo -e "  IOMMU:       ${RED}OFF${NC} — add 'amd_iommu=on iommu=pt' karg + reboot"
    if gpu_in_use "$bdf"; then
        echo -e "  in use:      ${YELLOW}yes${NC} — desktop/CUDA is on it; 'to-vm' will refuse until it's idle"
        echo "               (move your desktop to the iGPU: monitor → motherboard port)"
    else
        echo -e "  in use:      ${GREEN}no${NC} — safe to hand to a VM"
    fi
    echo "  swap:        powos gpu to-vm  |  powos gpu to-host"
}

# Move one PCI function to vfio-pci (release from its current driver first).
gpu_bind_vfio() {
    local bdf="$1" cur; cur="$(gpu_driver_of "$bdf")"
    [[ "$cur" == "vfio-pci" ]] && { plog "$bdf already on vfio-pci"; return 0; }
    modprobe vfio-pci 2>/dev/null || true
    [[ -n "$cur" ]] && echo "$bdf" > "/sys/bus/pci/drivers/$cur/unbind" 2>/dev/null || true
    echo vfio-pci > "/sys/bus/pci/devices/$bdf/driver_override"
    echo "$bdf" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    [[ "$(gpu_driver_of "$bdf")" == "vfio-pci" ]]
}
# Return one PCI function to its normal (host) driver.
gpu_bind_host() {
    local bdf="$1"
    [[ "$(gpu_driver_of "$bdf")" == "vfio-pci" ]] && echo "$bdf" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
    echo "" > "/sys/bus/pci/devices/$bdf/driver_override" 2>/dev/null || true
    echo "$bdf" > /sys/bus/pci/drivers_probe 2>/dev/null || true
}

cmd_gpu_to_vm() {
    local dry=0; [[ "${1:-}" == "--dry-run" ]] && dry=1
    local bdf; bdf="$(gpu_dgpu_bdf)"; [[ -n "$bdf" ]] || { perr "No dGPU found."; return 1; }
    gpu_iommu_on || { perr "IOMMU is off — add 'amd_iommu=on iommu=pt' to kargs + reboot first."; return 1; }
    if gpu_in_use "$bdf"; then
        perr "The dGPU is IN USE (desktop or CUDA) — releasing it now would freeze your session."
        perr "Move your desktop to the iGPU (monitor → motherboard port), close GPU apps, then retry."
        return 1
    fi
    local slots; slots="$(gpu_slot_bdfs "$bdf")"
    if (( dry )); then
        plog "Would release + bind to vfio-pci:"; echo "$slots" | sed 's/^/    /'; return 0
    fi
    confirm "Release $bdf (+audio) from the host and hand to vfio-pci?" || { plog "Aborted."; return 0; }
    local b ok=1
    while read -r b; do [[ -z "$b" ]] && continue; if [[ ${EUID:-$(id -u)} -eq 0 ]]; then gpu_bind_vfio "$b" || ok=0; else sudo bash -c "$(declare -f gpu_driver_of gpu_bind_vfio); gpu_bind_vfio $b" || ok=0; fi; done <<< "$slots"
    (( ok )) && pok "dGPU on vfio-pci — start the VM with passthrough (powos vm windows --gpu)." || perr "Some functions didn't bind — check 'powos gpu status'."
}

cmd_gpu_to_host() {
    local bdf; bdf="$(gpu_dgpu_bdf)"; [[ -n "$bdf" ]] || { perr "No dGPU found."; return 1; }
    local slots b; slots="$(gpu_slot_bdfs "$bdf")"
    plog "Reclaiming $bdf (+group) for the host…"
    while read -r b; do [[ -z "$b" ]] && continue; if [[ ${EUID:-$(id -u)} -eq 0 ]]; then gpu_bind_host "$b"; else sudo bash -c "$(declare -f gpu_driver_of gpu_bind_host); gpu_bind_host $b"; fi; done <<< "$slots"
    pok "dGPU back on the host driver ($(gpu_driver_of "$bdf")). CUDA/native gaming ready."
}

cmd_gpu() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        status|"")        cmd_gpu_status ;;
        to-vm|release)    cmd_gpu_to_vm "$@" ;;
        to-host|reclaim)  cmd_gpu_to_host ;;
        -h|--help)        sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
        *) perr "Usage: powos gpu {status|to-vm|to-host} [--dry-run]"; return 1 ;;
    esac
}
