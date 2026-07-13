#!/bin/bash
# base.sh - manage and swap the OS base image at runtime.
#
# A "base" is a GPU/OS variant living on the USB under layers/base-<name>/.
# This wraps the multi-variant machinery into a clean runtime interface:
#
#   powos base list                       # bases on the USB + which is active
#   powos base current                    # the active base
#   powos base switch <name>              # boot into <name> next reboot (persistent)
#   powos base add <bootc-image> [name]   # pull/build a new base onto the USB
#   powos base remove <name>              # delete a base
#
# Switching is a reboot, not live — the base is the read-only lower layer of the
# RAM overlay, so a new one takes effect on the next boot. `switch` writes a
# persistent default that ramboot-setup.sh honors (below cmdline, above auto).
#
# CONSTRAINTS (be honest with the user):
#   - Each base is several GB on the USB (space + time to add).
#   - A base only boots the PowOS way if it carries the ramboot dracut module —
#     i.e. it was built through PowOS's Containerfile. `add` does that build.
#   - Same-family swaps (nvidia open/closed, amd, newer/older bazzite/ublue) work.
#     A non-bootc/non-Fedora distro is NOT a drop-in — PowOS's boot + persistence
#     stack assumes the Fedora/bootc family.
# TODO(hw): add/switch touch the boot path — validate in a VM before trusting.

set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'

base_log()  { echo -e "${CYAN}[base]${NC} $*"; }
base_ok()   { echo -e "${GREEN}[base]${NC} $*"; }
base_warn() { echo -e "${YELLOW}[base]${NC} $*"; }
base_err()  { echo -e "${RED}[base]${NC} $*" >&2; }

# Where the USB layers live on a booted system (bind-mounted by ramboot).
BASE_LAYERS_DIR="${POWOS_USB_LAYERS:-/run/powos/usb-layers}/layers"
BASE_DEFAULT_FILE="${POWOS_USB_LAYERS:-/run/powos/usb-layers}/.powos-default-variant"
POWOS_SRC_DIR="${POWOS_SRC:-/var/lib/powos/src}"

# ── Pure helpers (unit-testable) ──────────────────────────────────

# List variant names from a layers dir ($1). One per line.
base_list_names() {
    local dir="${1:-$BASE_LAYERS_DIR}" d name
    for d in "$dir"/base-*/; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d"); echo "${name#base-}"
    done
}

# Validate a base name is a known variant on the USB ($2 = layers dir).
base_name_valid() {
    local want="$1" dir="${2:-$BASE_LAYERS_DIR}"
    [[ -d "$dir/base-$want" ]]
}

# Map a bootc image ref to a sensible variant name (for `add` without a name).
base_name_from_image() {
    case "$1" in
        *bazzite-nvidia-open*) echo "nvidia-open" ;;
        *bazzite-nvidia*)      echo "nvidia" ;;
        *bazzite*)             echo "main" ;;
        *) basename "$1" | tr ':/' '--' ;;   # e.g. bluefin-latest
    esac
}

# ── Commands ──────────────────────────────────────────────────────
base_current() {
    # cmdline override wins; else the persisted default; else "auto".
    local vk
    vk=$(grep -o 'rd.powos.variant=[^ ]*' /proc/cmdline 2>/dev/null | head -1)
    if [[ -n "$vk" ]]; then echo "${vk#rd.powos.variant=} (this boot, from cmdline)"; return; fi
    if [[ -f "$BASE_DEFAULT_FILE" ]]; then echo "$(cat "$BASE_DEFAULT_FILE") (persistent default)"; return; fi
    echo "auto (GPU-detected each boot)"
}

base_list() {
    echo -e "${BOLD}Bases on this USB${NC}"
    local names active
    names=$(base_list_names)
    if [[ -z "$names" ]]; then
        base_warn "No base-*/ variants on the USB (single-variant install)."
        echo "  Add one:  powos base add ghcr.io/ublue-os/bazzite-nvidia-open:stable"
        return 0
    fi
    active=$(base_current)
    local n
    while read -r n; do
        [[ -z "$n" ]] && continue
        if [[ "$active" == "$n"* ]]; then echo -e "  ${GREEN}●${NC} $n ${DIM}(active)${NC}"
        else echo -e "  ○ $n"; fi
    done <<< "$names"
    echo
    echo -e "  ${DIM}active selection: $active${NC}"
}

base_switch() {
    local name="${1:-}"
    [[ -z "$name" ]] && { base_err "Usage: powos base switch <name|auto>"; return 1; }
    if [[ "$name" != "auto" ]] && ! base_name_valid "$name"; then
        base_err "No base '$name' on the USB. Available:"
        base_list_names | sed 's/^/    /'
        return 1
    fi
    if [[ ! -d "$(dirname "$BASE_DEFAULT_FILE")" ]]; then
        base_err "USB layers not mounted at ${POWOS_USB_LAYERS:-/run/powos/usb-layers}."
        return 1
    fi
    if [[ "$name" == "auto" ]]; then
        rm -f "$BASE_DEFAULT_FILE"
        base_ok "Default cleared — next boot auto-detects the GPU."
    else
        echo "$name" > "$BASE_DEFAULT_FILE"
        base_ok "Default base set to '$name'."
    fi
    base_log "Reboot to boot into it:  systemctl reboot"
}

base_add() {
    local image="${1:-}" name="${2:-}"
    [[ -z "$image" ]] && { base_err "Usage: powos base add <bootc-image> [name]"; return 1; }
    [[ -z "$name" ]] && name=$(base_name_from_image "$image")
    base_log "Adding base '$name' from image: $image"

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then base_err "Run as root: sudo powos base add ..."; return 1; fi
    for t in podman tar; do command -v "$t" &>/dev/null || { base_err "Missing tool: $t"; return 1; }; done
    if [[ ! -f "$POWOS_SRC_DIR/Containerfile" ]]; then
        base_err "PowOS source not found at $POWOS_SRC_DIR (needed to bake in the boot module)."
        return 1
    fi
    local dest="$BASE_LAYERS_DIR/base-$name"
    if [[ -d "$dest" ]]; then base_err "Base '$name' already exists. Remove it first."; return 1; fi

    # Build PowOS on the requested base so the new rootfs carries the ramboot
    # dracut module, then export its filesystem into layers/base-<name>/.
    base_log "Building PowOS on $image (this pulls ~GBs and takes a while)…"
    if ! podman build -f "$POWOS_SRC_DIR/Containerfile" -t "localhost/powos-$name" \
        --build-arg "BASE_IMAGE=$image" "$POWOS_SRC_DIR"; then
        base_err "Build failed."; return 1
    fi
    local cid
    cid=$(podman create "localhost/powos-$name") || { base_err "podman create failed."; return 1; }
    mkdir -p "$dest"
    base_log "Extracting rootfs → $dest"
    if podman export "$cid" | tar -x -C "$dest"; then
        base_ok "Base '$name' added. Switch to it:  powos base switch $name"
    else
        base_err "rootfs export failed."; rm -rf "$dest"; podman rm "$cid" >/dev/null 2>&1; return 1
    fi
    podman rm "$cid" >/dev/null 2>&1 || true
}

base_remove() {
    local name="${1:-}"
    [[ -z "$name" ]] && { base_err "Usage: powos base remove <name>"; return 1; }
    base_name_valid "$name" || { base_err "No base '$name' on the USB."; return 1; }
    if [[ "$(base_current)" == "$name"* ]]; then
        base_warn "'$name' is the active base — switch away first (powos base switch auto)."
        return 1
    fi
    rm -rf "${BASE_LAYERS_DIR:?}/base-$name"
    base_ok "Removed base '$name'."
}

base_usage() {
    cat << EOF
powos base — manage / swap the OS base image (reboot to apply)

  powos base list                       list bases on the USB (● = active)
  powos base current                    show the active base
  powos base switch <name|auto>         set the base for next boot (persistent)
  powos base add <bootc-image> [name]   build+add a new base onto the USB
  powos base remove <name>              delete a base

Swaps within the Fedora/bootc family work (nvidia open/closed, amd, newer/older
bazzite or other ublue images). A non-bootc distro is not a drop-in. Each base
is several GB. 'add' rebuilds through PowOS's Containerfile so the new base keeps
the RAM-boot module.
EOF
}

cmd_base() {
    local sub="${1:-list}"; shift 2>/dev/null || true
    case "$sub" in
        list|ls)        base_list ;;
        current|active) base_current ;;
        switch|use)     base_switch "$@" ;;
        add|install)    base_add "$@" ;;
        remove|rm|del)  base_remove "$@" ;;
        help|-h|--help) base_usage ;;
        *)              base_err "Unknown: base $sub"; base_usage; return 1 ;;
    esac
}
