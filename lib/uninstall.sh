#!/bin/bash
# uninstall.sh - the mirror of install-router.sh: ONE front door for removing
# anything, wherever the router (or you) put it. Probes every backend, reports
# where the thing actually lives, and removes it from each — so
# `powos remove <thing>` really means gone, not "gone from one backend".
#
#   powos remove <thing...>          # probe all backends → remove everywhere found
#   powos remove --dry <thing...>    # probe + report only, remove nothing
#
# Backends probed (same ladder as install):
#   flatpak   `flatpak uninstall` + `--delete-data` (drops the app's sandbox home)
#   sandbox   dnf remove + pip uninstall inside powos-sandbox, un-export host shim
#   brew      `brew uninstall`
#   host      rpm-ostree layered package → `rpm-ostree uninstall` (needs sudo;
#             may need a reboot/apply-live to fully drop from the running system)
#
# HONESTY: host-layer removal drops the package files but NOT config/state it
# wrote under /etc or /var while installed — that residue is reported, not hidden.
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ulog()  { echo -e "${CYAN}[remove]${NC} $*"; }
uok()   { echo -e "${GREEN}[remove]${NC} $*"; }
uwarn() { echo -e "${YELLOW}[remove]${NC} $*"; }

SANDBOX_BOX="${POWOS_SANDBOX_BOX:-powos-sandbox}"

# ── probes: print an identifier when found, nothing otherwise ─────

# Flatpak app whose id's last component matches (md.obsidian.Obsidian ← obsidian)
probe_flatpak() {
    command -v flatpak >/dev/null 2>&1 || return 0
    flatpak list --app --columns=application 2>/dev/null |
        awk -v p="$(echo "$1" | tr '[:upper:]' '[:lower:]')" \
            '{ n=split($1,a,"."); if (tolower(a[n])==p) { print $1; exit } }'
}

probe_sandbox() {
    podman container exists "$SANDBOX_BOX" 2>/dev/null || return 0
    if distrobox enter "$SANDBOX_BOX" -- rpm -q "$1" >/dev/null 2>&1; then
        echo "rpm"
    elif distrobox enter "$SANDBOX_BOX" -- pip3 show "$1" >/dev/null 2>&1; then
        echo "pip"
    fi
}

probe_brew() {
    command -v brew >/dev/null 2>&1 || return 0
    brew list --formula 2>/dev/null | grep -Fx "$1"
}

# Layered on the host image? (requested by the user, not part of the base)
probe_host_layer() {
    command -v rpm-ostree >/dev/null 2>&1 || return 0
    rpm-ostree status --json 2>/dev/null |
        python3 -c '
import json, sys
name = sys.argv[1]
try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for d in s.get("deployments", []):
    if d.get("booted") and name in (d.get("requested-packages") or []):
        print(name)
        break' "$1" 2>/dev/null
}

# ── removal per backend ───────────────────────────────────────────

remove_flatpak() {
    ulog "flatpak: uninstalling $1 (incl. its sandboxed data)"
    flatpak uninstall -y --delete-data "$1"
}

remove_sandbox() {
    local pkg="$1" kind="$2"
    if [[ "$kind" == "pip" ]]; then
        ulog "sandbox: pip uninstall $pkg (inside $SANDBOX_BOX)"
        distrobox enter "$SANDBOX_BOX" -- pip3 uninstall -y "$pkg"
    else
        ulog "sandbox: dnf remove $pkg (inside $SANDBOX_BOX)"
        distrobox enter "$SANDBOX_BOX" -- sudo dnf remove -y "$pkg"
    fi
    # Drop the host PATH shim if install exported one.
    distrobox enter "$SANDBOX_BOX" -- distrobox-export --bin "/usr/bin/$pkg" --delete >/dev/null 2>&1 || true
}

remove_brew() {
    ulog "brew: uninstalling $1"
    brew uninstall "$1"
}

remove_host_layer() {
    ulog "host layer: rpm-ostree uninstall $1 (needs sudo)"
    if ! sudo rpm-ostree uninstall "$1"; then
        return 1
    fi
    if sudo rpm-ostree apply-live --allow-replacement 2>/dev/null; then
        uok "applied live — gone from the running system"
    else
        uwarn "staged: fully gone after the next reboot"
    fi
    uwarn "note: config/state the package wrote under /etc or /var is NOT auto-removed"
}

# ── command ───────────────────────────────────────────────────────

cmd_remove() {
    local dry=false things=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry|--dry-run) dry=true; shift ;;
            --help|-h)
                sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
                return 0 ;;
            *) things+=("$1"); shift ;;
        esac
    done
    if [[ ${#things[@]} -eq 0 ]]; then
        echo "Usage: powos remove [--dry] <thing...>"
        return 1
    fi

    local thing found any_missing=0
    for thing in "${things[@]}"; do
        echo -e "${BOLD}${thing}${NC}"
        found=false

        local fp_id sb_kind brew_hit host_hit
        fp_id=$(probe_flatpak "$thing")
        sb_kind=$(probe_sandbox "$thing")
        brew_hit=$(probe_brew "$thing")
        host_hit=$(probe_host_layer "$thing")

        [[ -n "$fp_id"    ]] && { found=true; ulog "found: flatpak ($fp_id)"; }
        [[ -n "$sb_kind"  ]] && { found=true; ulog "found: sandbox container ($sb_kind, in $SANDBOX_BOX)"; }
        [[ -n "$brew_hit" ]] && { found=true; ulog "found: brew formula"; }
        [[ -n "$host_hit" ]] && { found=true; ulog "found: host layer (rpm-ostree)"; }

        if [[ "$found" == "false" ]]; then
            uwarn "not found in flatpak/sandbox/brew/host layer."
            uwarn "other containers? check:  powos containers list"
            any_missing=1
            continue
        fi
        if [[ "$dry" == "true" ]]; then
            ulog "(dry run — nothing removed)"
            continue
        fi

        [[ -n "$fp_id"    ]] && remove_flatpak "$fp_id"
        [[ -n "$sb_kind"  ]] && remove_sandbox "$thing" "$sb_kind"
        [[ -n "$brew_hit" ]] && remove_brew "$thing"
        [[ -n "$host_hit" ]] && remove_host_layer "$thing"
        uok "$thing removed from every backend it was found in"
    done
    return "$any_missing"
}
