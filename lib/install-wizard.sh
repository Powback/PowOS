#!/bin/bash
# install-wizard.sh - powos install-wizard: guided, friendly disk install
#
# A GUIDED front-end that WRAPS the raw installer (lib/install-system.sh).
# It NEVER reimplements partitioning/bootc logic — it collects choices, writes
# a single shared config file, and then invokes `powos install-system` with the
# right flags. Everything install-system's flags can't express (hostname, user,
# password, SSH, RAM boot, AI creds, restore-from-backup) is recorded in the
# same config file and applied on the installed system's FIRST boot by
# bin/powos-firstboot-apply.
#
# Entry point: cmd_install_wizard "$@"
#
# NOTE: this file is SOURCED (into bin/powos and bin/powos-install-wizard) — it
# must NOT set -e/-u/pipefail at top level (that would change the whole CLI's
# shell options). Functions guard their own inputs with ${x:-} defensively.
#
# Testability: the UI is a thin abstraction (iwz_menu/iwz_input/iwz_password/
# iwz_yesno/iwz_msg) over THREE backends (kdialog GUI, whiptail/dialog TUI,
# plain read). The pure collectors set IWZ_* globals; iwz_write_config and
# iwz_build_installer_args are PURE and unit-tested. Destructive steps route
# through iwz_run_step(), which is a no-op under --dry-run.
#
# SHARED CONTRACT — /etc/powos/install.conf (shell key=value), written here,
# consumed by install-system flags and by powos-firstboot-apply:
#   ISV_DISK ISV_MODE(whole-disk|alongside) ISV_ROOT_GB(or 'auto') ISV_GAMES_GB
#   ISV_WINDOWS_GB ISV_FS(btrfs|ext4) ISV_GAMES_DISK(empty = same disk as PowOS)
#   POWOS_GPU_FLAVOR(nvidia-open|nvidia|amd|intel) POWOS_HOSTNAME POWOS_USERNAME
#   POWOS_PASSWORD_HASH(openssl passwd -6 — NEVER plaintext)
#   POWOS_SSH_ENABLE(0|1) POWOS_SSH_KEY POWOS_RAMBOOT(off|installed)
#   POWOS_AI_PROVIDER(claude|gemini|ollama|none) POWOS_AI_KEY POWOS_RESTORE_URL

# ── Presentation ──────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'

iwz_log()  { echo -e "${CYAN}[wizard]${NC} $*"; }
iwz_ok()   { echo -e "${GREEN}[wizard]${NC} $*"; }
iwz_warn() { echo -e "${YELLOW}[wizard]${NC} $*"; }
iwz_err()  { echo -e "${RED}[wizard]${NC} $*" >&2; }
iwz_step() { echo; echo -e "${BOLD}── $* ──${NC}"; }

# ── Wizard state (contract values live in IWZ_* until iwz_write_config) ──
IWZ_DRY_RUN=0
IWZ_UI=""                          # gui | tui | read  (resolved by iwz_detect_ui)
IWZ_CONFIG_PATH="${IWZ_CONFIG_PATH:-/etc/powos/install.conf}"
IWZ_TITLE="PowOS Install"

IWZ_DISK=""
IWZ_GAMES_DISK=""                  # separate disk for POWOS-GAMES; empty = same disk as PowOS
IWZ_MODE="whole-disk"              # whole-disk | alongside
IWZ_ROOT_GB="auto"                 # informational; installer computes root itself
IWZ_GAMES_GB="auto"                # → --shared-gb
IWZ_WINDOWS_GB="auto"              # → --windows-gb
IWZ_FS="btrfs"                     # btrfs | ext4
IWZ_GPU_FLAVOR="nvidia-open"       # nvidia-open | nvidia | amd | intel
IWZ_HOSTNAME="powos"
IWZ_USERNAME="powos"
IWZ_PASSWORD_HASH=""               # openssl passwd -6 output; NEVER plaintext
IWZ_PASSWORD_NONE=0                # 1 = deliberately NO password (blank entry).
                                   # Distinct from an empty hash, which just
                                   # means "not collected" and leaves the
                                   # account LOCKED.
IWZ_SSH_ENABLE=0                   # 0 | 1
IWZ_SSH_KEY=""                     # optional authorized_keys line
IWZ_RAMBOOT="off"                  # off | installed
IWZ_AI_PROVIDER="none"             # claude | gemini | ollama | none
IWZ_AI_KEY=""                      # optional
IWZ_RESTORE_URL=""                 # optional git URL

# ══════════════════════════════════════════════════════════════════
# UI abstraction — three backends, chosen once at runtime
# ══════════════════════════════════════════════════════════════════

# Pick a backend. Override with IWZ_UI_FORCE=gui|tui|read (used by tests).
#   gui : kdialog present AND a graphical display exists
#   tui : whiptail or dialog present
#   read: plain terminal prompts (always available)
iwz_detect_ui() {
    if [[ -n "${IWZ_UI_FORCE:-}" ]]; then
        echo "$IWZ_UI_FORCE"; return 0
    fi
    if command -v kdialog >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        echo "gui"; return 0
    fi
    if command -v whiptail >/dev/null 2>&1 || command -v dialog >/dev/null 2>&1; then
        echo "tui"; return 0
    fi
    echo "read"
}

# The TUI binary (whiptail preferred, dialog fallback). Both share the
# --menu/--inputbox/--yesno/--msgbox flag vocabulary we use.
iwz__tui_bin() {
    if command -v whiptail >/dev/null 2>&1; then echo "whiptail"
    elif command -v dialog >/dev/null 2>&1; then echo "dialog"
    else echo ""; fi
}

# iwz_msg "text"
iwz_msg() {
    local text="$1"
    case "${IWZ_UI:-read}" in
        gui) kdialog --title "$IWZ_TITLE" --msgbox "$text" ;;
        tui) local b; b=$(iwz__tui_bin); "$b" --title "$IWZ_TITLE" --msgbox "$text" 15 72 ;;
        *)   echo; echo -e "$text"; echo ;;
    esac
}

# iwz_yesno "text"  → returns 0 (yes) / 1 (no)
iwz_yesno() {
    local text="$1"
    case "${IWZ_UI:-read}" in
        gui) kdialog --title "$IWZ_TITLE" --yesno "$text" ;;
        tui) local b; b=$(iwz__tui_bin); "$b" --title "$IWZ_TITLE" --yesno "$text" 15 72 ;;
        *)   echo; echo -e "$text"; local a; read -r -p "  [y/N] " a || return 1
             [[ "$a" =~ ^[Yy] ]] ;;
    esac
}

# iwz_input "prompt" "default"  → prints the value (default on empty)
iwz_input() {
    local prompt="$1" def="${2:-}" val
    case "${IWZ_UI:-read}" in
        gui) val=$(kdialog --title "$IWZ_TITLE" --inputbox "$prompt" "$def") || return 1 ;;
        tui) local b; b=$(iwz__tui_bin)
             # whiptail prints the entry to stderr; swap fds to capture it.
             val=$("$b" --title "$IWZ_TITLE" --inputbox "$prompt" 12 72 "$def" 3>&1 1>&2 2>&3) || return 1 ;;
        *)   read -r -p "$prompt [$def]: " val || return 1 ;;
    esac
    [[ -z "$val" ]] && val="$def"
    printf '%s\n' "$val"
}

# iwz_password "prompt"  → prints the entered secret (no echo in read backend)
iwz_password() {
    local prompt="$1" val
    case "${IWZ_UI:-read}" in
        gui) val=$(kdialog --title "$IWZ_TITLE" --password "$prompt") || return 1 ;;
        tui) local b; b=$(iwz__tui_bin)
             val=$("$b" --title "$IWZ_TITLE" --passwordbox "$prompt" 12 72 3>&1 1>&2 2>&3) || return 1 ;;
        *)   read -r -s -p "$prompt: " val || return 1; echo >&2 ;;
    esac
    printf '%s\n' "$val"
}

# iwz_menu "prompt" tag1 label1 [tag2 label2 ...]  → prints the chosen tag
iwz_menu() {
    local prompt="$1"; shift
    case "${IWZ_UI:-read}" in
        gui) kdialog --title "$IWZ_TITLE" --menu "$prompt" "$@" ;;
        tui) local b; b=$(iwz__tui_bin)
             "$b" --title "$IWZ_TITLE" --menu "$prompt" 20 72 10 "$@" 3>&1 1>&2 2>&3 ;;
        *)   # Plain numbered menu on tag/label pairs.
             echo >&2; echo -e "$prompt" >&2
             local -a tags=() labels=()
             while [[ $# -gt 0 ]]; do tags+=("$1"); labels+=("${2:-}"); shift 2; done
             local i
             for i in "${!tags[@]}"; do
                 printf '  %2d) %s\n' "$((i+1))" "${labels[$i]}" >&2
             done
             local sel
             read -r -p "  Choose [1-${#tags[@]}]: " sel || return 1
             [[ "$sel" =~ ^[0-9]+$ ]] || return 1
             (( sel >= 1 && sel <= ${#tags[@]} )) || return 1
             printf '%s\n' "${tags[$((sel-1))]}" ;;
    esac
}

# ══════════════════════════════════════════════════════════════════
# Destructive-step wrapper (mirrors install-system's run_step)
# ══════════════════════════════════════════════════════════════════
iwz_run_step() {
    local desc="$1"; shift
    # Announce every step so long/destructive operations are never a silent
    # wait — the user sees WHAT is running (desc) and the exact command.
    iwz_log "$desc..."
    echo -e "  ${DIM}\$ $*${NC}"
    if [[ "${IWZ_DRY_RUN:-0}" -eq 1 ]]; then
        iwz_warn "dry-run: skipped ($desc)"
        return 0
    fi
    "$@"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        iwz_ok "$desc — done"
    else
        iwz_err "$desc — failed (exit $rc)"
    fi
    return $rc
}

# ══════════════════════════════════════════════════════════════════
# Pure helpers
# ══════════════════════════════════════════════════════════════════

# Shell-quote a value for a sourced key=value file. Single-quote and escape
# embedded single quotes so `$6$...` hashes / SSH keys survive `source` intact
# (never re-expanded).
iwz__q() {
    local s="${1//\'/\'\\\'\'}"
    printf "'%s'" "$s"
}

# Hash a plaintext password with SHA-512 crypt. The plaintext is passed in,
# hashed, and MUST NOT be retained by the caller.
iwz_hash_password() {
    local plain="$1"
    openssl passwd -6 "$plain" 2>/dev/null
}

# PURE: auto-detect a sensible GPU flavor default from lspci.
# nvidia-open is the project default (open kernel modules); closed 'nvidia'
# is selectable per-machine but never auto-chosen.
iwz_detect_gpu_flavor() {
    local out
    out=$(lspci 2>/dev/null || true)
    if echo "$out" | grep -qiE "VGA.*NVIDIA|3D.*NVIDIA|Display.*NVIDIA"; then
        echo "nvidia-open"; return 0
    fi
    # NB: match AMD/Radeon/"Advanced Micro" — NOT a bare "ATI", which would
    # false-match the "comp-ATI-ble" in "VGA compatible controller".
    if echo "$out" | grep -qiE "VGA.*(AMD|Radeon|Advanced Micro)|Display.*(AMD|Radeon)"; then
        echo "amd"; return 0
    fi
    if echo "$out" | grep -qiE "VGA.*Intel|Display.*Intel"; then
        echo "intel"; return 0
    fi
    # Undetectable → the GENERIC build, not NVIDIA. AMD and Intel drivers are
    # in-kernel so the generic image comes up on anything; guessing NVIDIA
    # instead installs proprietary kmods on a machine that may have no NVIDIA
    # GPU at all, which is the worse failure and the harder one to undo.
    echo "amd"
}

# Steam Deck DMI product names: Jupiter = LCD, Galileo = OLED. A Deck is AMD,
# but it needs upstream's Deck enablement (jupiter kernel, Deck audio and
# controller firmware, gamescope session defaults) that the generic AMD image
# does not carry — so it is its own flavor, checked before the GPU.
iwz_is_steam_deck() {
    local p=""
    [[ -r /sys/class/dmi/id/product_name ]] && p=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    case "$p" in Jupiter|Galileo) return 0 ;; *) return 1 ;; esac
}

# Enumerate installable disks: "/dev/NAME<TAB>SIZE<TAB>MODEL", excluding
# loop/optical/zram and the live USB (the disk holding POWOS-DATA). This is a
# light convenience list for the menu — install-system re-validates the pick
# authoritatively before touching anything.
iwz_list_disks() {
    local live="" data
    data=$(blkid -L POWOS-DATA 2>/dev/null || true)
    if [[ -n "$data" ]]; then
        live=$(lsblk -no PKNAME "$data" 2>/dev/null | head -1)
    fi
    # Emits: /dev/NAME <TAB> SIZE <TAB> MODEL <TAB> removable(yes|no) <TAB> TRAN
    #
    # INTERNAL DISKS ARE EMITTED FIRST, REMOVABLE ONES LAST, and this ordering
    # is load-bearing: whiptail/kdialog pre-highlight the FIRST menu entry, so
    # whatever leads this list is what a bare Enter selects. lsblk's own order
    # puts mmcblk0 (the SD card) ahead of nvme0n1, which is how an install
    # landed on a Steam Deck's SD card and erased the games on it.
    #
    # MODEL is requested LAST so a model string containing spaces is absorbed
    # by the final read variable instead of splitting the fields.
    local name size type rm hotplug tran model removable
    local -a fixed=() removables=()
    while read -r name size type rm hotplug tran model; do
        [[ "$type" == "disk" ]] || continue
        case "$name" in loop*|sr*|zram*) continue ;; esac
        [[ -n "$live" && "$name" == "$live" ]] && continue
        removable=no
        [[ "$rm" == "1" || "$hotplug" == "1" || "$tran" == "usb" ]] && removable=yes
        # SD/eMMC readers report rm=0 on some controllers — treat mmcblk as
        # removable regardless, since on a Deck that is always the card slot.
        case "$name" in mmcblk*) removable=yes ;; esac
        if [[ "$removable" == "yes" ]]; then
            removables+=("$(printf '/dev/%s\t%s\t%s\t%s\t%s' "$name" "$size" "${model:-disk}" "$removable" "${tran:-?}")")
        else
            fixed+=("$(printf '/dev/%s\t%s\t%s\t%s\t%s' "$name" "$size" "${model:-disk}" "$removable" "${tran:-?}")")
        fi
    done < <(lsblk -dn -o NAME,SIZE,TYPE,RM,HOTPLUG,TRAN,MODEL 2>/dev/null)
    local e
    for e in ${fixed[@]+"${fixed[@]}"};      do printf '%s\n' "$e"; done
    for e in ${removables[@]+"${removables[@]}"}; do printf '%s\n' "$e"; done
}

# Is $1 one of the disks iwz_list_disks flagged removable? Used to gate the
# destructive picks behind a typed confirmation.
iwz__is_removable() {
    local want="$1" dev size model removable tran
    while IFS=$'\t' read -r dev size model removable tran; do
        if [[ "$dev" == "$want" ]]; then
            [[ "$removable" == "yes" ]]
            return
        fi
    done < <(iwz_list_disks)
    return 1
}

# PURE: write the shared install.conf from the IWZ_* globals. $1 = path
# (default IWZ_CONFIG_PATH). Values are single-quoted so a later `source`
# reads them verbatim. Password is stored ONLY as a hash. File mode 600.
iwz_write_config() {
    local path="${1:-$IWZ_CONFIG_PATH}"
    local dir; dir=$(dirname "$path")
    mkdir -p "$dir" 2>/dev/null || true
    {
        echo "# PowOS install configuration — generated by powos-install-wizard"
        echo "# Consumed by: powos install-system (flags) + powos-firstboot-apply."
        echo "# SECURITY: POWOS_PASSWORD_HASH is a crypt hash, never plaintext."
        echo "# This file is DELETED after firstboot applies it."
        echo ""
        echo "# ── Disk / partitioning (drives install-system flags) ──"
        echo "ISV_DISK=$(iwz__q "$IWZ_DISK")"
        echo "ISV_GAMES_DISK=$(iwz__q "$IWZ_GAMES_DISK")"
        echo "ISV_MODE=$(iwz__q "$IWZ_MODE")"
        echo "ISV_ROOT_GB=$(iwz__q "$IWZ_ROOT_GB")"
        echo "ISV_GAMES_GB=$(iwz__q "$IWZ_GAMES_GB")"
        echo "ISV_WINDOWS_GB=$(iwz__q "$IWZ_WINDOWS_GB")"
        echo "ISV_FS=$(iwz__q "$IWZ_FS")"
        echo ""
        echo "# ── Identity / drivers ──"
        echo "POWOS_GPU_FLAVOR=$(iwz__q "$IWZ_GPU_FLAVOR")"
        echo "POWOS_HOSTNAME=$(iwz__q "$IWZ_HOSTNAME")"
        echo "POWOS_USERNAME=$(iwz__q "$IWZ_USERNAME")"
        echo "POWOS_PASSWORD_HASH=$(iwz__q "$IWZ_PASSWORD_HASH")"
        echo "POWOS_PASSWORD_NONE=$(iwz__q "$IWZ_PASSWORD_NONE")"
        echo ""
        echo "# ── Remote access ──"
        echo "POWOS_SSH_ENABLE=$(iwz__q "$IWZ_SSH_ENABLE")"
        echo "POWOS_SSH_KEY=$(iwz__q "$IWZ_SSH_KEY")"
        echo ""
        echo "# ── Runtime behaviour ──"
        echo "POWOS_RAMBOOT=$(iwz__q "$IWZ_RAMBOOT")"
        echo ""
        echo "# ── AI / restore ──"
        echo "POWOS_AI_PROVIDER=$(iwz__q "$IWZ_AI_PROVIDER")"
        echo "POWOS_AI_KEY=$(iwz__q "$IWZ_AI_KEY")"
        echo "POWOS_RESTORE_URL=$(iwz__q "$IWZ_RESTORE_URL")"
    } > "$path"
    chmod 600 "$path" 2>/dev/null || true
}

# Load an install.conf back into IWZ_* globals (symmetric with iwz_write_config).
# Best-effort: unknown/missing keys keep their current defaults.
iwz_load_config() {
    local path="${1:-$IWZ_CONFIG_PATH}"
    [[ -f "$path" ]] || return 1
    # shellcheck disable=SC1090
    source "$path"
    IWZ_DISK="${ISV_DISK:-$IWZ_DISK}"
    IWZ_GAMES_DISK="${ISV_GAMES_DISK:-$IWZ_GAMES_DISK}"
    IWZ_MODE="${ISV_MODE:-$IWZ_MODE}"
    IWZ_ROOT_GB="${ISV_ROOT_GB:-$IWZ_ROOT_GB}"
    IWZ_GAMES_GB="${ISV_GAMES_GB:-$IWZ_GAMES_GB}"
    IWZ_WINDOWS_GB="${ISV_WINDOWS_GB:-$IWZ_WINDOWS_GB}"
    IWZ_FS="${ISV_FS:-$IWZ_FS}"
    IWZ_GPU_FLAVOR="${POWOS_GPU_FLAVOR:-$IWZ_GPU_FLAVOR}"
    IWZ_HOSTNAME="${POWOS_HOSTNAME:-$IWZ_HOSTNAME}"
    IWZ_USERNAME="${POWOS_USERNAME:-$IWZ_USERNAME}"
    IWZ_PASSWORD_HASH="${POWOS_PASSWORD_HASH:-$IWZ_PASSWORD_HASH}"
    IWZ_PASSWORD_NONE="${POWOS_PASSWORD_NONE:-$IWZ_PASSWORD_NONE}"
    IWZ_SSH_ENABLE="${POWOS_SSH_ENABLE:-$IWZ_SSH_ENABLE}"
    IWZ_SSH_KEY="${POWOS_SSH_KEY:-$IWZ_SSH_KEY}"
    IWZ_RAMBOOT="${POWOS_RAMBOOT:-$IWZ_RAMBOOT}"
    IWZ_AI_PROVIDER="${POWOS_AI_PROVIDER:-$IWZ_AI_PROVIDER}"
    IWZ_AI_KEY="${POWOS_AI_KEY:-$IWZ_AI_KEY}"
    IWZ_RESTORE_URL="${POWOS_RESTORE_URL:-$IWZ_RESTORE_URL}"
}

# PURE: translate the collected config into `powos install-system` flags.
# Emits a single space-joined line (values here never contain spaces).
# Only the flags install-system understands are produced; identity/SSH/AI/
# restore/RAM-boot are applied later by powos-firstboot-apply.
#
#   whole-disk → --whole-disk --i-understand-data-loss   (the erase gate;
#                --yes alone must NOT satisfy install-system's typed erase
#                confirmation — see confirm() in install-system.sh)
#   alongside  → --alongside                              (no erase flag)
# Published image tag for a GPU flavor. Mirrors fb_variant_for_flavor() in
# bin/powos-firstboot-apply — keep the two in step; test-firstboot-gpu-variant.sh
# and test-install-wizard-disks.sh both pin this mapping.
iwz_variant_for_flavor() {
    local flavor="${1:-}"
    if iwz_is_steam_deck; then echo "deck"; return 0; fi
    case "$flavor" in
        nvidia-open|nvidia) echo "nvidia-open" ;;
        deck)               echo "deck" ;;
        amd|intel|main)     echo "main" ;;
        *)                  echo "main" ;;
    esac
}

iwz_build_installer_args() {
    local -a a=()
    [[ -n "$IWZ_DISK" ]] && a+=(--disk "$IWZ_DISK")
    case "$IWZ_MODE" in
        whole-disk) a+=(--whole-disk) ;;
        alongside)  a+=(--alongside) ;;
    esac
    [[ -n "$IWZ_FS" ]] && a+=(--fs "$IWZ_FS")
    # GPU variant. install-system only acts on this when the media carries the
    # variant's bytes, in which case the install is fully offline; otherwise it
    # installs the running image and says so. Never causes a network fetch.
    [[ -n "$IWZ_GPU_FLAVOR" ]] && a+=(--variant "$(iwz_variant_for_flavor "$IWZ_GPU_FLAVOR")")
    [[ -n "$IWZ_GAMES_GB" ]]   && a+=(--shared-gb "$IWZ_GAMES_GB")
    [[ -n "$IWZ_WINDOWS_GB" ]] && a+=(--windows-gb "$IWZ_WINDOWS_GB")
    # A separate games disk (different from the PowOS target) → --games-disk.
    # Same disk or empty emits nothing, preserving the classic arg line exactly.
    [[ -n "$IWZ_GAMES_DISK" && "$IWZ_GAMES_DISK" != "$IWZ_DISK" ]] && a+=(--games-disk "$IWZ_GAMES_DISK")
    a+=(--yes)
    [[ "$IWZ_MODE" == "whole-disk" ]] && a+=(--i-understand-data-loss)
    echo "${a[*]}"
}

# ══════════════════════════════════════════════════════════════════
# Guided steps — each sets IWZ_* with a sane auto-default
# ══════════════════════════════════════════════════════════════════

iwz_step_disk() {
    iwz_step "Target disk"
    local -a menu=() dev size model removable tran
    while IFS=$'\t' read -r dev size model removable tran; do
        [[ -n "$dev" ]] || continue
        if [[ "$removable" == "yes" ]]; then
            menu+=("$dev" "[REMOVABLE ${tran}] $size  ${model}  — SD card / USB, NOT the internal drive")
        else
            menu+=("$dev" "$size  ${model}  (${tran}, internal)")
        fi
    done < <(iwz_list_disks)

    if [[ ${#menu[@]} -eq 0 ]]; then
        # No enumerable disks (e.g. off-target / no lsblk) — ask directly.
        iwz_warn "Could not enumerate disks automatically."
        local d; d=$(iwz_input "Target disk device (e.g. /dev/nvme0n1)" "${IWZ_DISK:-/dev/nvme0n1}") || return 1
        IWZ_DISK="$d"
    else
        local pick
        pick=$(iwz_menu "Choose the disk to install PowOS onto — THIS DISK IS ERASED COMPLETELY:" "${menu[@]}") || return 1
        [[ -n "$pick" ]] || return 1
        # Picking removable media is nearly always a slip (the SD card sits
        # right next to the internal drive in this list). Never accept it from
        # a keypress alone — make it be typed out in full.
        if iwz__is_removable "$pick"; then
            iwz_warn "$pick is REMOVABLE media (SD card / USB stick), not the internal drive."
            iwz_warn "Installing here ERASES it completely, including any games stored on it."
            local typed
            typed=$(iwz_input "Type $pick exactly to confirm, or leave blank to choose again" "") || return 1
            if [[ "$typed" != "$pick" ]]; then
                iwz_warn "Not confirmed — nothing selected."
                return 1
            fi
        fi
        IWZ_DISK="$pick"
    fi
    iwz_ok "Disk: $IWZ_DISK"
}

# Offer to put the shared games (POWOS-GAMES) partition on a DIFFERENT whole
# disk than PowOS. Only meaningful with >1 installable disk; with a single disk
# it silently keeps IWZ_GAMES_DISK="" (same disk, carve a tail).
iwz_step_games_disk() {
    IWZ_GAMES_DISK=""
    # Collect disks as dev/size/model triples so we can count + list the others.
    local -a disks=() dev size model removable tran
    while IFS=$'\t' read -r dev size model removable tran; do
        [[ -n "$dev" ]] || continue
        disks+=("$dev" "$size" "$model" "$removable" "$tran")
    done < <(iwz_list_disks)

    local n=$(( ${#disks[@]} / 5 ))
    (( n > 1 )) || return 0   # only one disk to choose from — stay same-disk

    iwz_step "Shared games partition location"
    # "same" stays FIRST so the pre-highlighted entry is the non-destructive
    # one — this menu offers to consume whole disks, and on a Deck one of them
    # is the SD card full of the user's games.
    local -a menu=(same "Same disk as PowOS (carve a partition) — leaves other disks untouched")
    local i
    for (( i=0; i<${#disks[@]}; i+=5 )); do
        dev="${disks[i]}"; size="${disks[i+1]}"; model="${disks[i+2]}"
        removable="${disks[i+3]}"; tran="${disks[i+4]}"
        [[ "$dev" == "$IWZ_DISK" ]] && continue   # never the PowOS disk itself
        if [[ "$removable" == "yes" ]]; then
            menu+=("$dev" "ERASE removable $dev ($size  $model, $tran) and use it all for games")
        else
            menu+=("$dev" "ERASE $dev whole ($size  $model) and use it all for games")
        fi
    done

    local pick
    pick=$(iwz_menu "Where should the shared games (POWOS-GAMES) partition live?" "${menu[@]}") || return 1
    if [[ -z "$pick" || "$pick" == "same" ]]; then
        IWZ_GAMES_DISK=""
    else
        if iwz__is_removable "$pick"; then
            iwz_warn "$pick is REMOVABLE media (SD card / USB stick)."
            iwz_warn "Choosing it ERASES the whole card, including games already on it."
            local typed
            typed=$(iwz_input "Type $pick exactly to confirm, or leave blank to keep games on the PowOS disk" "") || return 1
            if [[ "$typed" != "$pick" ]]; then
                iwz_warn "Not confirmed — keeping games on the PowOS disk."
                IWZ_GAMES_DISK=""
                iwz_ok "Games disk: same disk as PowOS"
                return 0
            fi
        fi
        IWZ_GAMES_DISK="$pick"
    fi
    iwz_ok "Games disk: $([[ -n "$IWZ_GAMES_DISK" ]] && echo "$IWZ_GAMES_DISK (separate whole disk)" || echo "same disk as PowOS")"
}

iwz_step_mode() {
    iwz_step "Install mode"
    local m
    m=$(iwz_menu "How should PowOS use $IWZ_DISK?" \
        whole-disk "Erase the whole disk, install only PowOS" \
        alongside  "Dual-boot: install into free space, keep Windows") || return 1
    IWZ_MODE="${m:-whole-disk}"
    iwz_ok "Mode: $IWZ_MODE"
}

iwz_step_sizes() {
    iwz_step "Partition sizes"
    # 'auto' lets install-system size games/windows reservations from the disk.
    IWZ_ROOT_GB=$(iwz_input "Root partition size in GB ('auto' = use the rest)" "${IWZ_ROOT_GB:-auto}") || return 1
    IWZ_GAMES_GB=$(iwz_input "Shared games NTFS partition GB ('auto', 0 = none)" "${IWZ_GAMES_GB:-auto}") || return 1
    IWZ_WINDOWS_GB=$(iwz_input "Reserved Windows tail GB ('auto', 0 = none)" "${IWZ_WINDOWS_GB:-auto}") || return 1
    local fs
    fs=$(iwz_menu "Root filesystem:" \
        btrfs "btrfs — snapshots, recommended" \
        ext4  "ext4 — simple, widely compatible") || return 1
    IWZ_FS="${fs:-btrfs}"
    iwz_ok "Root=$IWZ_ROOT_GB games=$IWZ_GAMES_GB windows=$IWZ_WINDOWS_GB fs=$IWZ_FS"
}

iwz_step_gpu() {
    iwz_step "GPU driver flavor"
    # Deck hardware wins over the GPU answer — see iwz_is_steam_deck.
    local detected
    if iwz_is_steam_deck; then
        detected="deck"
    else
        detected=$(iwz_detect_gpu_flavor)
    fi
    iwz_log "Auto-detected: $detected"
    local g
    g=$(iwz_menu "GPU driver flavor (detected default: $detected):" \
        "$detected"  "Use the auto-detected default ($detected)" \
        deck         "Steam Deck (Deck kernel, firmware, gamescope session)" \
        nvidia-open  "NVIDIA open kernel modules (RTX 40/50-series need this)" \
        nvidia       "NVIDIA closed/proprietary modules" \
        amd          "AMD (Mesa)" \
        intel        "Intel (Mesa)") || return 1
    IWZ_GPU_FLAVOR="${g:-$detected}"
    iwz_ok "GPU flavor: $IWZ_GPU_FLAVOR"
}

iwz_step_identity() {
    iwz_step "Hostname, user and password"
    IWZ_HOSTNAME=$(iwz_input "Hostname" "${IWZ_HOSTNAME:-powos}") || return 1
    IWZ_USERNAME=$(iwz_input "Primary username" "${IWZ_USERNAME:-powos}") || return 1

    # Collect + confirm the password, hash it immediately, and never keep the
    # plaintext. A single loop lets the user retry on mismatch.
    # An EMPTY entry means "use the default", it does not re-prompt.
    #
    # This loop used to reject blank and loop forever. On a Steam Deck that is
    # an unescapable trap: with no Steam client running the controller falls
    # back to keyboard emulation that provides arrows, Enter and Escape — and
    # no letters. The installer drew the password box and there was physically
    # no way to answer it or get past it.
    local p1 p2
    while true; do
        p1=$(iwz_password "Password for '$IWZ_USERNAME' (leave blank for NO password)") || return 1
        if [[ -z "$p1" ]]; then
            IWZ_PASSWORD_HASH=""
            IWZ_PASSWORD_NONE=1
            iwz_warn "No password — '$IWZ_USERNAME' will log in without one. Set one later: passwd"
            break
        fi
        p2=$(iwz_password "Confirm password") || return 1
        if [[ "$p1" != "$p2" ]]; then
            iwz_warn "Passwords did not match — try again."
            p1=""; p2=""
            continue
        fi
        IWZ_PASSWORD_HASH=$(iwz_hash_password "$p1")
        IWZ_PASSWORD_NONE=0
        p1=""; p2=""
        if [[ -z "$IWZ_PASSWORD_HASH" ]]; then
            iwz_err "Could not hash the password (is openssl installed?)."
            return 1
        fi
        break
    done
    iwz_ok "User '$IWZ_USERNAME' on host '$IWZ_HOSTNAME' (password hashed)."
}

iwz_step_ssh() {
    iwz_step "Remote access (SSH)"
    if iwz_yesno "Enable the SSH server on the installed system?"; then
        IWZ_SSH_ENABLE=1
        local k
        k=$(iwz_input "Optional SSH public key (authorized_keys line, blank to skip)" "${IWZ_SSH_KEY:-}") || k=""
        # An empty input returns the (empty) default — keep whatever we had.
        [[ "$k" == "" ]] && k="$IWZ_SSH_KEY"
        IWZ_SSH_KEY="$k"
    else
        IWZ_SSH_ENABLE=0
    fi
    iwz_ok "SSH: $([[ $IWZ_SSH_ENABLE -eq 1 ]] && echo enabled || echo disabled)"
}

iwz_step_ramboot() {
    iwz_step "RAM boot"
    local r
    r=$(iwz_menu "Run the installed OS from RAM (layered overlay)?" \
        off       "Off — normal disk boot (recommended)" \
        installed "Installed RAM boot (EXPERIMENTAL, self-heal)") || return 1
    IWZ_RAMBOOT="${r:-off}"
    if [[ "$IWZ_RAMBOOT" == "installed" ]]; then
        iwz_msg "RAM boot on an installed disk is EXPERIMENTAL.\n\nThe OS is copied into a RAM overlay at boot and self-heals from the on-disk copy. Expect rough edges; you can disable it later with 'powos ramboot disable'."
    fi
    iwz_ok "RAM boot: $IWZ_RAMBOOT"
}

iwz_step_ai() {
    iwz_step "AI assistant"
    local p
    p=$(iwz_menu "Default AI provider for 'powos ai':" \
        none   "None — skip AI setup" \
        claude "Claude (Anthropic)" \
        gemini "Gemini (Google)" \
        ollama "Ollama (local, no key)") || return 1
    IWZ_AI_PROVIDER="${p:-none}"
    IWZ_AI_KEY=""
    case "$IWZ_AI_PROVIDER" in
        claude|gemini)
            local k
            k=$(iwz_input "API key for $IWZ_AI_PROVIDER (blank to add later)" "") || k=""
            IWZ_AI_KEY="$k"
            ;;
    esac
    iwz_ok "AI provider: $IWZ_AI_PROVIDER"
}

iwz_step_restore() {
    iwz_step "Restore from backup"
    if iwz_yesno "Restore projects/config from a PowOS cloud backup after install?"; then
        local u
        u=$(iwz_input "Git repository URL of your backup" "${IWZ_RESTORE_URL:-}") || u=""
        IWZ_RESTORE_URL="$u"
    else
        IWZ_RESTORE_URL=""
    fi
    # `return 0` is load-bearing. A bare trailing "[[ ... ]] && cmd" makes the
    # FUNCTION's exit status that of the test, so declining the restore (empty
    # URL) returned 1 and the caller treated it as a cancel — answering "No"
    # aborted the whole installer.
    [[ -n "$IWZ_RESTORE_URL" ]] && iwz_ok "Restore from: $IWZ_RESTORE_URL"
    return 0
}

# PURE-ish: build the human review summary as a string (no side effects).
iwz_review_text() {
    cat <<EOF
Review your install choices:

  Disk        : ${IWZ_DISK}
  Games disk  : $([[ -n "$IWZ_GAMES_DISK" && "$IWZ_GAMES_DISK" != "$IWZ_DISK" ]] && echo "${IWZ_GAMES_DISK} (separate whole disk)" || echo "same disk (partition)")
  Mode        : ${IWZ_MODE}
  Root        : ${IWZ_ROOT_GB} GB
  Games (NTFS): ${IWZ_GAMES_GB} GB
  Windows tail: ${IWZ_WINDOWS_GB} GB
  Filesystem  : ${IWZ_FS}
  GPU flavor  : ${IWZ_GPU_FLAVOR}
  Hostname    : ${IWZ_HOSTNAME}
  Username    : ${IWZ_USERNAME}
  Password    : $([[ -n "$IWZ_PASSWORD_HASH" ]] && echo "set (hashed)" || echo "NOT SET")
  SSH         : $([[ $IWZ_SSH_ENABLE -eq 1 ]] && echo "enabled$([[ -n "$IWZ_SSH_KEY" ]] && echo " + key")" || echo "disabled")
  RAM boot    : ${IWZ_RAMBOOT}
  AI provider : ${IWZ_AI_PROVIDER}$([[ -n "$IWZ_AI_KEY" ]] && echo " (key set)")
  Restore URL : ${IWZ_RESTORE_URL:-none}

Installer command:
  powos install-system $(iwz_build_installer_args)

NOTHING is written to disk until you confirm below.
EOF
}

# ══════════════════════════════════════════════════════════════════
# Commit — the only place with side effects; all gated by iwz_run_step
# ══════════════════════════════════════════════════════════════════

# Best-effort: copy install.conf onto the freshly installed system so
# powos-firstboot-apply finds it on first boot. The target root is identified
# by GPT label "PowOS". Non-fatal — every failure is logged, never fatal.
# TODO(hw): validate mount/copy against real bootc-laid layouts.
iwz_copy_config_to_target() {
    local part mnt
    part=$(blkid -L PowOS 2>/dev/null || true)
    if [[ -z "$part" ]]; then
        iwz_warn "Could not find the installed PowOS partition by label — firstboot"
        iwz_warn "config not copied. Re-run identity setup on the installed system."
        return 0
    fi
    mnt=$(mktemp -d) || return 0
    if mount "$part" "$mnt" 2>/dev/null; then
        mkdir -p "$mnt/etc/powos" 2>/dev/null || true
        if cp "$IWZ_CONFIG_PATH" "$mnt/etc/powos/install.conf" 2>/dev/null; then
            chmod 600 "$mnt/etc/powos/install.conf" 2>/dev/null || true
            iwz_ok "First-boot config placed on the installed system."
        else
            iwz_warn "Could not copy install.conf onto the target."
        fi
        umount "$mnt" 2>/dev/null || true
    else
        iwz_warn "Could not mount $part to place the first-boot config."
    fi
    rmdir "$mnt" 2>/dev/null || true
}

iwz_commit() {
    iwz_step "Installing"

    # 1) Persist the choices (600, hash-only) — gated so dry-run writes nothing.
    iwz_run_step "write $IWZ_CONFIG_PATH" iwz_write_config "$IWZ_CONFIG_PATH"

    # 2) Hand off to the raw installer. Under dry-run we still invoke it WITH
    #    its own --dry-run so the user sees the real partitioning plan while
    #    zero bytes change on disk.
    local args; args=$(iwz_build_installer_args)
    if [[ "${IWZ_DRY_RUN:-0}" -eq 1 ]]; then
        echo -e "  ${DIM}\$ powos install-system $args --dry-run${NC}"
        # shellcheck disable=SC2086
        powos install-system $args --dry-run || iwz_warn "installer preview returned non-zero"
    else
        echo -e "  ${DIM}\$ powos install-system $args${NC}"
        # shellcheck disable=SC2086
        powos install-system $args || { iwz_err "Installer failed — aborting."; return 1; }
        # 3) Place the config on the installed system for firstboot.
        iwz_run_step "copy first-boot config to installed system" iwz_copy_config_to_target
    fi
}

# ══════════════════════════════════════════════════════════════════
# Driver
# ══════════════════════════════════════════════════════════════════
iwz_usage() {
    cat <<EOF
powos install-wizard — guided PowOS disk install (wraps 'powos install-system')

Usage: sudo powos install-wizard [--dry-run]

  --dry-run   Walk every step and show the plan; change NOTHING on disk.
  -h, --help  This help.

The wizard collects disk/mode/sizes/GPU/identity/SSH/RAM-boot/AI/restore,
shows a review screen, then runs the installer. Identity, SSH, AI creds and
restore are applied on the installed system's first boot by
powos-firstboot-apply (via /etc/powos/install.conf).
EOF
}

cmd_install_wizard() {
    IWZ_DRY_RUN=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) IWZ_DRY_RUN=1; shift ;;
            -h|--help) iwz_usage; return 0 ;;
            *) iwz_err "Unknown option: $1"; iwz_usage; return 1 ;;
        esac
    done

    IWZ_UI=$(iwz_detect_ui)

    echo
    echo -e "${CYAN}${BOLD}  PowOS Guided Installer${NC}"
    echo -e "${DIM}  UI backend: ${IWZ_UI}${NC}"
    [[ $IWZ_DRY_RUN -eq 1 ]] && iwz_warn "DRY-RUN: no disk will be modified."

    if [[ ${EUID:-$(id -u)} -ne 0 && $IWZ_DRY_RUN -eq 0 ]]; then
        iwz_err "The installer must run as root:  sudo powos install-wizard"
        return 1
    fi

    iwz_step_disk       || { iwz_warn "Cancelled."; return 1; }
    iwz_step_games_disk || { iwz_warn "Cancelled."; return 1; }
    iwz_step_mode       || { iwz_warn "Cancelled."; return 1; }
    iwz_step_sizes    || { iwz_warn "Cancelled."; return 1; }
    iwz_step_gpu      || { iwz_warn "Cancelled."; return 1; }
    iwz_step_identity || { iwz_warn "Cancelled."; return 1; }
    iwz_step_ssh      || { iwz_warn "Cancelled."; return 1; }
    iwz_step_ramboot  || { iwz_warn "Cancelled."; return 1; }
    iwz_step_ai       || { iwz_warn "Cancelled."; return 1; }
    iwz_step_restore  || { iwz_warn "Cancelled."; return 1; }

    iwz_msg "$(iwz_review_text)"
    if ! iwz_yesno "Proceed with the install shown above?"; then
        iwz_warn "Aborted. Nothing was changed."
        return 1
    fi

    iwz_commit || return 1

    iwz_step "Done"
    iwz_ok "Install complete."
    echo "  Remove the USB and reboot. On first boot PowOS applies your"
    echo "  hostname, user, SSH, AI and restore settings automatically."
    echo
}
