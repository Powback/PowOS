#!/bin/bash
# ramboot.sh - powos ramboot: manage "OS in RAM" as a SAFE, opt-in feature.
#
# Two very different worlds share the word "ramboot":
#
#   1. USB live model  — a POWOS-DATA partition carries the layer stack and the
#      dracut module auto-engages on `rd.powos.ramboot=1`. The whole OS already
#      runs from a RAM overlay; the USB is unpluggable. Nothing to enable here.
#
#   2. Installed system (bootc/composefs on an internal disk) — the root is an
#      ostree composefs mount. Overlaying THAT on itself and pivoting corrupts
#      the deployment → boot loop (this exact incident happened when an installed
#      desktop inherited `rd.powos.ramboot=1` from the image kargs). So installed
#      "OS in RAM" is a DELIBERATE, composefs-safe, COPY-to-tmpfs opt-in, gated
#      behind a DIFFERENT karg: `rd.powos.ramboot.installed=1`.
#
# This CLI manages world #2 safely. It NEVER sets the auto karg (`rd.powos.ramboot=1`)
# on an installed system, refuses to "enable" on the USB model (already in RAM),
# checks the OS actually fits in RAM before flipping the switch, and drives the
# self-heal counter that auto-reverts after repeated failed boots.
#
# CONTRACT with the dracut side (lib/dracut/90powos-ramboot/ramboot-setup.sh) and
# the boot loader — these strings MUST match on both sides:
#   kargs:
#     rd.powos.ramboot=1            USB auto model  (CLI never sets this)
#     rd.powos.ramboot.installed=1  installed opt-in, copy-to-tmpfs (enable sets)
#     rd.powos.ramsize=SIZE         tmpfs size (e.g. 20G)
#   self-heal counter:
#     <esp>/powos/ramboot-attempts  integer; after RB_MAX_ATTEMPTS failed boots
#                                   ramboot auto-skips. `reset` clears it.
#   runtime state (written by initramfs):
#     /run/powos/ramboot-state  fields incl. POWOS_RAMBOOT_MODE=off|usb|installed-copy
#                               and POWOS_RAMBOOT_ATTEMPTS=<n>
#
# Entry point: cmd_ramboot "$@"
#
# NOTE: SOURCED into bin/powos — must NOT set -e/-u/pipefail at top level (that
# would change the whole CLI's shell options).
#
# SAFETY: every mutating operation (karg edits, counter removal) goes through
# rb_run_step() + confirmation, and is skipped entirely under --dry-run.

# ── Presentation ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

rb_log()  { echo -e "${CYAN}[ramboot]${NC} $*"; }
rb_ok()   { echo -e "${GREEN}[ramboot]${NC} $*"; }
rb_warn() { echo -e "${YELLOW}[ramboot]${NC} $*"; }
rb_err()  { echo -e "${RED}[ramboot]${NC} $*" >&2; }
rb_step() { echo; echo -e "${BOLD}── $* ──${NC}"; }

# ── Globals (set by option parsing) ───────────────────────────────
RB_DRY_RUN=0          # 1 = print mutating actions, never execute
RB_ASSUME_YES=0       # 1 = skip y/N confirmations (scripting)
RB_RAM=""             # explicit --ram override (e.g. 20G)

# Tunables (KiB). 1 GiB = 1048576 KiB.
RB_SAFETY_KIB=$((4 * 1048576))    # RAM reserved for everything that ISN'T the OS copy
RB_HEADROOM_KIB=$((4 * 1048576))  # write headroom for the tmpfs above the OS size
RB_MAX_ATTEMPTS=3                 # failed boots before auto-skip (matches dracut side)

# Overridable seams (tests point these at fixtures).
RB_STATE_FILE="${RB_STATE_FILE:-/run/powos/ramboot-state}"

# rb_run_step "description" cmd args...
# Executes a (mutating) command unless dry-run. Always echoes it first.
rb_run_step() {
    local desc="$1"; shift
    echo -e "  ${DIM}\$ $*${NC}"
    if [[ $RB_DRY_RUN -eq 1 ]]; then
        rb_warn "dry-run: skipped ($desc)"
        return 0
    fi
    "$@"
}

rb_confirm() {
    local prompt="$1"
    if [[ $RB_ASSUME_YES -eq 1 ]]; then
        rb_warn "--yes: auto-confirming: $prompt"
        return 0
    fi
    local answer
    read -r -p "$prompt [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# Root gate (seam: tests shadow this). Dry-run callers skip it deliberately.
rb_require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        rb_err "This needs root:  sudo powos ramboot $*"
        return 1
    fi
    return 0
}

# ── Live-system seams (shadowed in tests) ─────────────────────────
# The raw kernel command line for THIS boot.
rb_cmdline() { cat /proc/cmdline 2>/dev/null; }

# Total RAM in KiB (MemTotal from /proc/meminfo, which is already KiB).
rb_ram_total_kib() { rb_meminfo_total_kib "$(cat /proc/meminfo 2>/dev/null)"; }

# Estimated size of the OS that would be copied to tmpfs, in KiB. /usr + /etc is
# the bulk of a composefs deployment; du -x stays on one filesystem.
rb_os_size_kib() {
    du -sx -k /usr /etc 2>/dev/null | awk '{s+=$1} END{ if (s>0) print s }'
}

# Is there a POWOS-DATA partition anywhere (i.e. the USB live model)?
rb_have_powos_data() { blkid -L POWOS-DATA >/dev/null 2>&1; }

# Is this an installed bootc/composefs system (not the USB model)?
rb_is_installed() {
    [[ -e /run/ostree-booted ]] && return 0
    local fstype
    fstype=$(findmnt -n -o FSTYPE / 2>/dev/null | head -1)
    case "$fstype" in composefs|overlay) return 0 ;; esac
    return 1
}

# Find the EFI System Partition mountpoint (where the self-heal counter lives).
rb_find_esp() {
    local m t
    for m in /boot/efi /efi /boot; do
        t=$(findmnt -n -o TARGET "$m" 2>/dev/null | head -1)
        [[ -n "$t" ]] && { echo "$t"; return 0; }
    done
    # Last resort: an EFI-type partition's current mountpoint via blkid.
    t=$(blkid -t TYPE=vfat -o device 2>/dev/null | while read -r d; do
            findmnt -n -o TARGET "$d" 2>/dev/null | head -1; done | head -1)
    [[ -n "$t" ]] && { echo "$t"; return 0; }
    return 1
}

# Which karg tool does this system use? rpm-ostree is the documented, reliable
# path for editing a booted deployment's kargs; bootc is the fallback.
rb_karg_tool() {
    if command -v rpm-ostree >/dev/null 2>&1; then echo "rpm-ostree"; return 0; fi
    if command -v bootc      >/dev/null 2>&1; then echo "bootc";      return 0; fi
    return 1
}

# ── Pure helpers (no side effects — unit-testable) ────────────────

# Configured ramboot mode from a kernel command line string.
#   installed  → rd.powos.ramboot.installed=1 present (opt-in, copy-to-tmpfs)
#   usb        → rd.powos.ramboot=1 present         (USB auto model)
#   off        → neither
rb_mode_from_cmdline() {
    local cmdline="$1" tok installed=0 usb=0
    for tok in $cmdline; do
        case "$tok" in
            rd.powos.ramboot.installed=1) installed=1 ;;
            rd.powos.ramboot=1)           usb=1 ;;
        esac
    done
    if   [[ $installed -eq 1 ]]; then echo "installed"
    elif [[ $usb -eq 1 ]];       then echo "usb"
    else echo "off"; fi
}

# Value of rd.powos.ramsize= from a kernel command line string (empty if unset).
rb_ramsize_from_cmdline() {
    local cmdline="$1" tok
    for tok in $cmdline; do
        case "$tok" in rd.powos.ramsize=*) echo "${tok#rd.powos.ramsize=}"; return 0 ;; esac
    done
    return 0
}

# Read FIELD=value from a KEY=VALUE state file. Prints value; 1 if absent.
rb_state_field() {
    local file="$1" field="$2" k v
    [[ -f "$file" ]] || return 1
    while IFS='=' read -r k v; do
        [[ "$k" == "$field" ]] && { echo "$v"; return 0; }
    done < "$file"
    return 1
}

# MemTotal (KiB) from /proc/meminfo text.
rb_meminfo_total_kib() {
    local text="$1" k v
    while read -r k v _; do
        [[ "$k" == "MemTotal:" ]] && { echo "$v"; return 0; }
    done <<< "$text"
    return 1
}

# Read the self-heal attempt counter from its file (missing/garbage → 0).
rb_read_attempts() {
    local file="$1" val
    [[ -f "$file" ]] || { echo 0; return 0; }
    val=$(tr -dc '0-9' < "$file" 2>/dev/null)
    echo "${val:-0}"
}

# Does the OS fit in RAM with the safety reserve? (all args KiB)
#   fits  ⇔  mem > os + RB_SAFETY_KIB
rb_fits() {
    local os="$1" mem="$2"
    [[ "$os" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] || return 2
    (( mem > os + RB_SAFETY_KIB ))
}

# Default tmpfs size (KiB) = min(os + headroom, mem - safety). Args KiB.
rb_default_ram_kib() {
    local os="$1" mem="$2" want cap
    want=$(( os + RB_HEADROOM_KIB ))
    cap=$(( mem - RB_SAFETY_KIB ))
    (( cap < 0 )) && cap=0
    if (( want < cap )); then echo "$want"; else echo "$cap"; fi
}

# KiB → whole GiB, rounded DOWN (never exceeds the computed cap).
rb_kib_to_gib_floor() {
    local kib="$1"
    [[ "$kib" =~ ^[0-9]+$ ]] || { echo 0; return 1; }
    echo $(( kib / 1048576 ))
}

# KiB → human "N.N GiB".
rb_kib_human() {
    local kib="$1"
    [[ "$kib" =~ ^[0-9]+$ ]] || { echo "unknown"; return 0; }
    awk -v k="$kib" 'BEGIN{ printf "%.1f GiB", k/1048576 }'
}

# Normalise a size string to a tmpfs-friendly form (N G / N M). Bare N ⇒ NG.
rb_normalize_size() {
    local s="${1^^}"
    if   [[ "$s" =~ ^[0-9]+G$ ]]; then echo "$s"
    elif [[ "$s" =~ ^[0-9]+M$ ]]; then echo "$s"
    elif [[ "$s" =~ ^[0-9]+$  ]]; then echo "${s}G"
    else return 1; fi
}

# Size string (NG / NM / N) → KiB.
rb_size_to_kib() {
    local s="${1^^}" n u
    if   [[ "$s" =~ ^[0-9]+G$ ]]; then n="${s%G}"; echo $(( n * 1048576 ))
    elif [[ "$s" =~ ^[0-9]+M$ ]]; then n="${s%M}"; echo $(( n * 1024 ))
    elif [[ "$s" =~ ^[0-9]+$  ]]; then echo $(( s * 1048576 ))
    else return 1; fi
}

# THIS boot's actual mode as reported by the initramfs (off|usb|installed-copy).
rb_active_mode() {
    local m
    m=$(rb_state_field "$RB_STATE_FILE" POWOS_RAMBOOT_MODE 2>/dev/null)
    if [[ -n "$m" ]]; then echo "$m"; return 0; fi
    # Legacy/old state files only carried POWOS_RAMBOOT=1 for the USB model.
    if [[ "$(rb_state_field "$RB_STATE_FILE" POWOS_RAMBOOT 2>/dev/null)" == "1" ]]; then
        echo "usb"; return 0
    fi
    echo "off"
}

# ── USB-model guard ───────────────────────────────────────────────
# True when we're on the USB live model (already running from RAM).
rb_is_usb_model() {
    [[ "$(rb_active_mode)" == "usb" ]] && return 0
    [[ "$(rb_mode_from_cmdline "$(rb_cmdline)")" == "usb" ]] && return 0
    rb_have_powos_data && return 0
    return 1
}

# ── Karg application (per tool) ───────────────────────────────────
rb_kargs_enable() {
    local tool="$1" size="$2"
    case "$tool" in
        rpm-ostree)
            rb_run_step "append rd.powos.ramboot.installed=1" \
                rpm-ostree kargs --append-if-missing=rd.powos.ramboot.installed=1 || return 1
            rb_run_step "set rd.powos.ramsize=$size" \
                rpm-ostree kargs --delete-if-present=rd.powos.ramsize --append=rd.powos.ramsize="$size" || return 1
            ;;
        bootc)
            # bootc's kargs subcommand syntax varies by version; --append-if-missing
            # is the documented intent. rpm-ostree is preferred when present.
            rb_run_step "append rd.powos.ramboot.installed=1" \
                bootc kargs --append-if-missing rd.powos.ramboot.installed=1 || return 1
            rb_run_step "set rd.powos.ramsize=$size" \
                bootc kargs --delete-if-present rd.powos.ramsize --append rd.powos.ramsize="$size" || return 1
            ;;
        *) rb_err "No supported karg tool (rpm-ostree / bootc) found."; return 1 ;;
    esac
}

rb_kargs_disable() {
    local tool="$1"
    case "$tool" in
        rpm-ostree)
            rb_run_step "remove rd.powos.ramboot.installed + rd.powos.ramsize" \
                rpm-ostree kargs --delete-if-present=rd.powos.ramboot.installed=1 \
                                 --delete-if-present=rd.powos.ramsize || return 1
            ;;
        bootc)
            rb_run_step "remove rd.powos.ramboot.installed + rd.powos.ramsize" \
                bootc kargs --delete-if-present rd.powos.ramboot.installed=1 \
                            --delete-if-present rd.powos.ramsize || return 1
            ;;
        *) rb_err "No supported karg tool (rpm-ostree / bootc) found."; return 1 ;;
    esac
}

# ── powos ramboot status ──────────────────────────────────────────
rb_status() {
    rb_step "OS-in-RAM (ramboot) status"

    local cmdline requested active ramsize
    cmdline=$(rb_cmdline)
    requested=$(rb_mode_from_cmdline "$cmdline")
    active=$(rb_active_mode)
    ramsize=$(rb_ramsize_from_cmdline "$cmdline")

    # Human labels.
    local active_label
    case "$active" in
        usb)            active_label="${GREEN}running from RAM${NC} (USB live model)" ;;
        installed-copy) active_label="${GREEN}running from RAM${NC} (installed copy-to-tmpfs)" ;;
        off|"")         active_label="disk-backed (not in RAM this boot)" ;;
        *)              active_label="$active" ;;
    esac

    echo -e "  Active this boot:  $active_label"
    echo    "  Configured kargs:  mode=$requested${ramsize:+, ramsize=$ramsize}"

    # RAM vs OS-size estimate.
    local mem os
    mem=$(rb_ram_total_kib)
    os=$(rb_os_size_kib)
    echo
    echo -e "  ${BOLD}RAM budget${NC}"
    echo    "    Total RAM:       $(rb_kib_human "${mem:-x}")"
    echo    "    OS estimate:     $(rb_kib_human "${os:-x}")  (/usr + /etc, du -sx)"
    if [[ "$mem" =~ ^[0-9]+$ && "$os" =~ ^[0-9]+$ ]]; then
        if rb_fits "$os" "$mem"; then
            local def; def=$(rb_default_ram_kib "$os" "$mem")
            echo -e "    Fit:             ${GREEN}fits${NC} (default tmpfs $(rb_kib_to_gib_floor "$def")G)"
        else
            echo -e "    Fit:             ${YELLOW}does NOT fit${NC} with a $(rb_kib_to_gib_floor $RB_SAFETY_KIB)GiB reserve"
        fi
    fi

    # Self-heal counter (on the ESP).
    local esp attempts_file attempts
    echo
    echo -e "  ${BOLD}Self-heal${NC}"
    if esp=$(rb_find_esp); then
        attempts_file="$esp/powos/ramboot-attempts"
        attempts=$(rb_read_attempts "$attempts_file")
        echo    "    Attempt counter: $attempts / $RB_MAX_ATTEMPTS  ($attempts_file)"
        if (( attempts >= RB_MAX_ATTEMPTS )); then
            echo -e "    ${YELLOW}Auto-skipped${NC}: ramboot backed off after $attempts failed boots."
            echo    "                     Fix the cause, then:  sudo powos ramboot reset"
        fi
    else
        echo    "    Attempt counter: (ESP not found — /boot/efi not mounted?)"
    fi

    # Next-step guidance.
    echo
    echo -e "  ${BOLD}Next${NC}"
    if [[ "$active" == "usb" ]]; then
        echo "    Already runs entirely from RAM (USB model). Nothing to enable."
    elif [[ "$active" == "installed-copy" ]]; then
        echo "    OS-in-RAM is ON. Turn it off with:  sudo powos ramboot disable"
    elif [[ "$requested" == "installed" ]]; then
        echo "    Enabled in kargs but not active this boot — reboot to apply,"
        echo "    or check the self-heal counter above."
    else
        echo "    Installed systems can opt in (EXPERIMENTAL):"
        echo "        sudo powos ramboot enable            # auto-size the tmpfs"
        echo "        sudo powos ramboot enable --dry-run  # show the plan only"
    fi
    return 0
}

# ── powos ramboot enable ──────────────────────────────────────────
rb_enable() {
    rb_step "Enable OS-in-RAM (installed, copy-to-tmpfs)"

    # 1. Never on the USB live model — it already runs from RAM.
    if rb_is_usb_model; then
        rb_err "This is the USB live model — the OS already runs from RAM."
        rb_err "There is nothing to enable. See:  powos ramboot status"
        return 1
    fi

    # 2. Must be an installed bootc/composefs system.
    if ! rb_is_installed; then
        rb_err "Not an installed bootc/composefs system (no /run/ostree-booted,"
        rb_err "root filesystem is not composefs/overlay). Refusing to touch kargs."
        return 1
    fi

    # 3. Which karg tool?
    local tool
    if ! tool=$(rb_karg_tool); then
        rb_err "Neither rpm-ostree nor bootc is available to edit kargs."
        return 1
    fi

    # 4. RAM fit.
    local mem os
    mem=$(rb_ram_total_kib)
    os=$(rb_os_size_kib)
    if ! [[ "$mem" =~ ^[0-9]+$ ]]; then
        rb_err "Could not read total RAM from /proc/meminfo."
        return 1
    fi
    if ! [[ "$os" =~ ^[0-9]+$ ]]; then
        rb_err "Could not estimate the OS size (du -sx /usr /etc)."
        return 1
    fi
    if ! rb_fits "$os" "$mem"; then
        rb_err "The OS will not fit in RAM with a safe reserve:"
        rb_err "    OS estimate:  $(rb_kib_human "$os")"
        rb_err "    Total RAM:    $(rb_kib_human "$mem")"
        rb_err "    Reserve:      $(rb_kib_human "$RB_SAFETY_KIB") (kept free for the running system)"
        rb_err "Add RAM, or shrink the OS. Not enabling."
        return 1
    fi

    # Pick the tmpfs size: --ram override (validated against the cap) or default.
    local size cap_kib want_kib
    cap_kib=$(( mem - RB_SAFETY_KIB ))
    if [[ -n "$RB_RAM" ]]; then
        if ! size=$(rb_normalize_size "$RB_RAM"); then
            rb_err "Bad --ram value '$RB_RAM' (use e.g. 20G or 20480M)."
            return 1
        fi
        want_kib=$(rb_size_to_kib "$size")
        if (( want_kib > cap_kib )); then
            rb_err "--ram $size exceeds the safe cap:"
            rb_err "    requested:  $(rb_kib_human "$want_kib")"
            rb_err "    safe cap:   $(rb_kib_human "$cap_kib")  (Total RAM − reserve)"
            return 1
        fi
    else
        local def_kib; def_kib=$(rb_default_ram_kib "$os" "$mem")
        size="$(rb_kib_to_gib_floor "$def_kib")G"
    fi

    # 5. Plan + confirmation.
    rb_step "Plan"
    echo    "  System:      installed bootc/composefs"
    echo    "  Karg tool:   $tool"
    echo    "  OS estimate: $(rb_kib_human "$os")   Total RAM: $(rb_kib_human "$mem")"
    echo    "  tmpfs size:  $size   (reserve kept free: $(rb_kib_human "$RB_SAFETY_KIB"))"
    echo    "  Kargs set:   rd.powos.ramboot.installed=1  rd.powos.ramsize=$size"
    echo -e "               ${DIM}(the USB auto karg rd.powos.ramboot=1 is NEVER set here)${NC}"
    echo
    echo -e "  ${YELLOW}${BOLD}EXPERIMENTAL${NC} — copy-to-tmpfs OS-in-RAM for installed systems is new."
    echo    "  A reboot is REQUIRED to apply. If it does not boot cleanly, it"
    echo    "  auto-reverts after $RB_MAX_ATTEMPTS failed tries, and you can also pick the"
    echo    "  previous entry from the 5-second boot menu. Nothing is destroyed —"
    echo    "  this only toggles kernel arguments."
    echo

    if [[ $RB_DRY_RUN -eq 0 ]]; then
        rb_require_root "enable" || return 1
        rb_confirm "Enable OS-in-RAM (tmpfs $size) on next boot?" || {
            rb_log "Aborted. No kargs changed."
            return 1
        }
    fi

    # 6. Apply.
    rb_kargs_enable "$tool" "$size" || {
        rb_err "Failed to set kargs. Nothing partial should persist — verify with:"
        rb_err "    $tool kargs   (or: powos ramboot status)"
        return 1
    }

    if [[ $RB_DRY_RUN -eq 1 ]]; then
        rb_warn "dry-run complete — nothing was changed."
        return 0
    fi
    rb_ok "OS-in-RAM enabled (tmpfs $size). Reboot to activate:  systemctl reboot"
    rb_log "If the next boot misbehaves, it auto-reverts after $RB_MAX_ATTEMPTS tries;"
    rb_log "you can also disable it now with:  sudo powos ramboot disable"
    return 0
}

# ── powos ramboot disable ─────────────────────────────────────────
rb_disable() {
    rb_step "Disable OS-in-RAM (installed)"

    if rb_is_usb_model; then
        rb_warn "This is the USB live model — its RAM boot is driven by the USB,"
        rb_warn "not by rd.powos.ramboot.installed. Nothing to disable here."
        return 0
    fi

    local tool
    if ! tool=$(rb_karg_tool); then
        rb_err "Neither rpm-ostree nor bootc is available to edit kargs."
        return 1
    fi

    rb_step "Plan"
    echo "  Remove kargs:  rd.powos.ramboot.installed=1  rd.powos.ramsize"
    echo "  Karg tool:     $tool"
    echo "  Reboot to take effect."
    echo

    if [[ $RB_DRY_RUN -eq 0 ]]; then
        rb_require_root "disable" || return 1
    fi

    rb_kargs_disable "$tool" || {
        rb_err "Failed to remove kargs — verify with:  $tool kargs"
        return 1
    }

    if [[ $RB_DRY_RUN -eq 1 ]]; then
        rb_warn "dry-run complete — nothing was changed."
        return 0
    fi
    rb_ok "OS-in-RAM disabled. Reboot to return to disk-backed boot:  systemctl reboot"
    return 0
}

# ── powos ramboot reset ───────────────────────────────────────────
# Clear the self-heal attempt counter so ramboot is re-attempted (use after
# fixing whatever made the previous attempts fail).
rb_reset() {
    rb_step "Reset the ramboot self-heal counter"

    local esp
    if ! esp=$(rb_find_esp); then
        rb_err "Could not find the EFI System Partition (/boot/efi not mounted?)."
        rb_err "The counter lives at <esp>/powos/ramboot-attempts."
        return 1
    fi
    local file="$esp/powos/ramboot-attempts"
    local attempts; attempts=$(rb_read_attempts "$file")
    echo "  Counter file:  $file"
    echo "  Current value: $attempts / $RB_MAX_ATTEMPTS"
    echo

    if [[ ! -f "$file" ]]; then
        rb_ok "No counter file present — nothing to reset (ramboot is not backed off)."
        return 0
    fi

    if [[ $RB_DRY_RUN -eq 0 ]]; then
        rb_require_root "reset" || return 1
    fi

    rb_run_step "clear self-heal counter" rm -f "$file" || {
        rb_err "Failed to remove $file."
        return 1
    }

    if [[ $RB_DRY_RUN -eq 1 ]]; then
        rb_warn "dry-run complete — nothing was changed."
        return 0
    fi
    rb_ok "Self-heal counter cleared. ramboot will be re-attempted on next boot."
    return 0
}

# ── Usage / entry ─────────────────────────────────────────────────
rb_usage() {
    cat << EOF
powos ramboot — run the whole OS from RAM (safe, opt-in for installed systems)

The USB live model already runs from RAM automatically. On an INSTALLED
bootc/composefs system, OS-in-RAM is a deliberate, composefs-safe opt-in
(copy-to-tmpfs) gated behind its own kernel argument — never the USB auto karg,
which would loop an installed root.

Usage: powos ramboot <command> [options]

Commands:
  status                 Show mode, RAM-vs-OS fit, and the self-heal counter
  enable                 Turn on OS-in-RAM for THIS installed system (reboot)
  disable                Turn it off (reboot)
  reset                  Clear the self-heal counter after fixing a bad boot

Options:
  --ram SIZE             tmpfs size (e.g. 20G); default auto-fits the OS + reserve
  --dry-run              Show every action but change NOTHING
  --yes, -y              Skip confirmations (scripting)
  -h, --help             This help

EXPERIMENTAL. A reboot is required to apply. If a boot misbehaves it
auto-reverts after $RB_MAX_ATTEMPTS tries, and the 5-second boot menu still lets you pick
the previous entry. enable/disable only toggle kernel arguments — nothing is
destroyed.
EOF
}

cmd_ramboot() {
    local sub="${1:-status}"; shift 2>/dev/null || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) RB_DRY_RUN=1; shift ;;
            --yes|-y)  RB_ASSUME_YES=1; shift ;;
            --ram)     RB_RAM="${2:-}"; shift 2 ;;
            -h|--help) rb_usage; return 0 ;;
            *)         rb_err "Unknown option: $1"; rb_usage; return 1 ;;
        esac
    done
    case "$sub" in
        status)         rb_status ;;
        enable|on)      rb_enable ;;
        disable|off)    rb_disable ;;
        reset)          rb_reset ;;
        help|-h|--help) rb_usage; return 0 ;;
        *)              rb_err "Unknown ramboot command: $sub"; rb_usage; return 1 ;;
    esac
}
