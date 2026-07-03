#!/bin/bash
# boot-manager.sh - seamless one-shot switch between PowOS and other OSes.
#
# For gaming with kernel-level anti-cheat (ARMA Reforger/BattlEye, ARC Raiders/
# EAC, Valorant/Vanguard) you need BARE-METAL Windows — those anti-cheats block
# both Proton and VMs. This makes the switch one command:
#
#   powos boot windows     # reboot straight into Windows THIS time, then back
#   powos boot list        # show UEFI boot entries
#   powos boot next <name> # set next-boot to any entry (one-shot)
#
# It uses UEFI BootNext (efibootmgr --bootnext), a ONE-TIME override: you land in
# Windows for your gaming session, and the next reboot returns to PowOS by itself.
# This sidesteps atomic Bazzite's GRUB (which won't auto-list Windows) entirely.
# (From Windows, set the reverse with:  bcdedit /set {fwbootmgr} bootsequence ... )

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

bm_log()  { echo -e "${CYAN}[boot]${NC} $*"; }
bm_ok()   { echo -e "${GREEN}[boot]${NC} $*"; }
bm_warn() { echo -e "${YELLOW}[boot]${NC} $*"; }
bm_err()  { echo -e "${RED}[boot]${NC} $*" >&2; }

# ── Pure parser (unit-testable) ───────────────────────────────────
# Find the 4-hex boot id whose entry label matches $1 (regex, case-insensitive)
# in efibootmgr output $2. Echoes e.g. "0000"; empty if not found.
bm_find_entry() {
    local re="$1" out="$2"
    echo "$out" \
        | grep -iE "^Boot[0-9A-Fa-f]{4}\*?[[:space:]].*${re}" \
        | head -1 \
        | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/'
}

# Human label for a boot id (for confirmation messages).
bm_entry_label() {
    local id="$1" out="$2"
    echo "$out" | grep -iE "^Boot${id}\*?[[:space:]]" | head -1 \
        | sed -E "s/^Boot${id}\*?[[:space:]]+//; s/\t.*//"
}

# ── Commands ──────────────────────────────────────────────────────
bm_require_efi() {
    if [[ ! -d /sys/firmware/efi ]]; then
        bm_err "Not booted in UEFI mode — BootNext needs UEFI (this is a legacy/BIOS boot)."
        return 1
    fi
    if ! command -v efibootmgr &>/dev/null; then
        bm_err "efibootmgr not found (install efibootmgr)."
        return 1
    fi
}

bm_list() {
    bm_require_efi || return 1
    echo -e "${BOLD}UEFI boot entries${NC}"
    efibootmgr | sed 's/^/  /'
    echo
    echo -e "  ${DIM}Reboot into one for the next boot only:  powos boot next \"<name>\"${NC}"
}

# Reboot once into the entry matching $1 (regex). $2 optional friendly noun.
bm_boot_to() {
    local re="$1" noun="${2:-that OS}"
    bm_require_efi || return 1

    local out id label
    out=$(efibootmgr 2>/dev/null)
    id=$(bm_find_entry "$re" "$out")
    if [[ -z "$id" ]]; then
        bm_err "No UEFI entry matching '$re'. Available:"
        echo "$out" | grep -iE "^Boot[0-9A-Fa-f]{4}" | sed 's/^/    /'
        return 1
    fi
    label=$(bm_entry_label "$id" "$out")
    bm_log "Matched Boot$id: ${label:-$re}"

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        bm_err "Setting BootNext needs root:  sudo powos boot ${re}"
        return 1
    fi

    if ! efibootmgr --bootnext "$id" >/dev/null 2>&1; then
        bm_err "Failed to set BootNext to $id."
        return 1
    fi
    bm_ok "Next boot → ${label:-$noun} (Boot$id). The reboot after returns to PowOS."

    local ans
    read -r -p "Reboot into ${noun} now? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        bm_log "Rebooting…"
        systemctl reboot
    else
        bm_log "BootNext is set — reboot yourself when ready (systemctl reboot)."
    fi
}

bm_usage() {
    cat << EOF
powos boot — one-shot switch to another OS (UEFI BootNext)

  powos boot list             show UEFI boot entries
  powos boot windows          reboot into Windows THIS time (for anti-cheat games)
  powos boot next <name>      one-shot boot into any entry by name (regex)

BootNext is a one-time override: you get one boot into the chosen OS, then it
returns to PowOS automatically. Needs UEFI + efibootmgr + root to switch.
For anti-cheat titles (ARMA Reforger, ARC Raiders, Valorant) this bare-metal
Windows boot is the reliable path — those block Proton AND VMs.
EOF
}

cmd_boot() {
    local sub="${1:-list}"; shift 2>/dev/null || true
    case "$sub" in
        list|ls)       bm_list ;;
        windows|win)   bm_boot_to "windows|microsoft" "Windows" ;;
        next|to)       bm_boot_to "${1:-}" "${1:-that OS}" ;;
        help|-h|--help) bm_usage ;;
        *)             bm_err "Unknown: boot $sub"; bm_usage; return 1 ;;
    esac
}
