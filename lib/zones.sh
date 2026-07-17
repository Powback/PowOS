#!/bin/bash
# zones.sh — powos zones: KZones window-snapping zone management
#
# KZones is a KWin script that brings FancyZones-style zone snapping to
# KDE Plasma on Wayland. Zones appear automatically when you drag a window;
# drop it into a zone and it resizes/snaps to fill that zone.
#
# Entry point: cmd_zones "$@"
#
# NOTE: this file is SOURCED into bin/powos — do NOT set -e/-u/pipefail at
# top level (that would change the whole CLI's shell options).

# ── Presentation ──────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'

zn_log()  { echo -e "${CYAN}[zones]${NC} $*"; }
zn_ok()   { echo -e "${GREEN}[zones]${NC} $*"; }
zn_warn() { echo -e "${YELLOW}[zones]${NC} $*"; }
zn_err()  { echo -e "${RED}[zones]${NC} $*" >&2; }

# ── Paths ─────────────────────────────────────────────────────────
ZN_SCRIPT_DIR="/usr/share/kwin/scripts/kzones"
ZN_LAYOUTS_JSON="/etc/powos/zones/layouts.json"
ZN_SYSTEM_CFG="/etc/xdg/kwinrc"
ZN_USER_CFG="${HOME}/.config/kwinrc"

# ── Helpers ───────────────────────────────────────────────────────

# // [powos.zones.install]
# zn_is_installed: returns 0 if the KWin script package is present on disk.
# The image bakes kzones into /usr/share/kwin/scripts/kzones/ (Containerfile).
# Users can rebuild via: powos overlay build powzones
zn_is_installed() {
    [[ -d "$ZN_SCRIPT_DIR" && -f "$ZN_SCRIPT_DIR/metadata.json" ]]
}

zn_version() {
    if [[ -f "$ZN_SCRIPT_DIR/metadata.json" ]]; then
        python3 -c "
import json, sys
try:
    d = json.load(open('$ZN_SCRIPT_DIR/metadata.json'))
    print(d.get('KPlugin', d).get('Version', 'unknown'))
except Exception as e:
    print('unknown')
" 2>/dev/null || echo "unknown"
    else
        echo "not installed"
    fi
}

# Returns 0 if kzonesEnabled=true appears in the user or system kwinrc.
zn_is_enabled() {
    local cfg
    for cfg in "$ZN_USER_CFG" "$ZN_SYSTEM_CFG"; do
        [[ -f "$cfg" ]] || continue
        grep -q "kzonesEnabled=true" "$cfg" 2>/dev/null && return 0
    done
    return 1
}

# ── Subcommands ───────────────────────────────────────────────────

cmd_zones() {
    local subcmd="${1:-status}"
    shift 2>/dev/null || true
    case "$subcmd" in
        status)            zn_cmd_status ;;
        list|layouts)      zn_cmd_list ;;
        edit)              zn_cmd_edit ;;
        help|--help|-h)    zn_cmd_help ;;
        *)
            zn_err "Unknown subcommand: $subcmd"
            zn_cmd_help
            return 1
            ;;
    esac
}

zn_cmd_status() {
    echo -e "${BOLD}${CYAN}PowOS Window Zones (KZones)${NC}"
    echo "════════════════════════════════════════"
    echo ""

    if zn_is_installed; then
        local ver; ver=$(zn_version)
        echo -e "  KZones:       ${GREEN}●${NC} installed (v${ver})"
    else
        echo -e "  KZones:       ${RED}✗${NC} not found at $ZN_SCRIPT_DIR"
        echo ""
        echo "  The image should have baked it in. To reinstall:"
        echo "    powos overlay build powzones"
        return 0
    fi

    if zn_is_enabled; then
        echo -e "  Plugin:       ${GREEN}●${NC} enabled"
    else
        echo -e "  Plugin:       ${YELLOW}○${NC} disabled"
        echo -e "  To enable:    kwriteconfig6 --file kwinrc --group Plugins --key kzonesEnabled true"
        echo -e "                qdbus org.kde.KWin /KWin reconfigure"
    fi

    echo ""
    echo -e "${CYAN}Activation UX${NC}"
    # // [powos.zones.activation]
    # Zone overlay shows automatically when you start dragging a window
    # (zoneOverlayShowWhen=0, configured in /etc/xdg/kwinrc [Script-kzones]).
    # Right-click during drag is NOT available on Wayland: the KWin scripting
    # API does not expose pointer-button events during compositor-managed
    # interactive moves. Auto-show on drag is used as the equivalent UX.
    echo "  Drag a window → zone overlay appears automatically."
    echo "  Drop onto a highlighted zone → window snaps to fill it."
    echo ""
    echo "  Shortcuts:"
    echo "    Ctrl+Alt+C       Toggle zone overlay manually"
    echo "    Ctrl+Alt+0-9     Snap active window to zone N"
    echo "    Meta+Arrow       Move window between zones directionally"
    echo "    Ctrl+Alt+D       Cycle through layouts"
    echo ""
    echo -e "  ${DIM}Note: right-click during drag is not available on Wayland."
    echo -e "  Auto-show on drag is the equivalent of the FancyZones UX.${NC}"
    echo ""

    echo -e "${CYAN}Layouts${NC}"
    if [[ -f "$ZN_LAYOUTS_JSON" ]]; then
        local count
        count=$(python3 -c "import json; print(len(json.load(open('$ZN_LAYOUTS_JSON'))))" 2>/dev/null || echo "?")
        echo -e "  ${count} default layouts  (${ZN_LAYOUTS_JSON})"
    fi
    echo "  Run 'powos zones list' to show zone coordinates."
    echo "  Run 'powos zones edit' to customise."
}

zn_cmd_list() {
    echo -e "${BOLD}${CYAN}PowOS Zone Layouts${NC}"
    echo "════════════════════════════════════════"
    echo ""

    if [[ ! -f "$ZN_LAYOUTS_JSON" ]]; then
        zn_warn "No layouts file at $ZN_LAYOUTS_JSON"
        return 0
    fi

    # // [powos.zones.layouts]
    # Reads default zone layouts from /etc/powos/zones/layouts.json and
    # displays each layout with its zone rectangles (screen-percentage coords).
    python3 - <<'PYEOF'
import json, sys

path = "/etc/powos/zones/layouts.json"
try:
    layouts = json.load(open(path))
except Exception as e:
    print(f"Error reading {path}: {e}", file=sys.stderr)
    sys.exit(1)

for i, layout in enumerate(layouts, 1):
    name    = layout.get("name", f"Layout {i}")
    padding = layout.get("padding", 0)
    zones   = layout.get("zones", [])
    print(f"  {i}. {name}")
    print(f"     {len(zones)} zone{'s' if len(zones) != 1 else ''}, padding: {padding}px")
    for j, z in enumerate(zones, 1):
        x = z.get("x", 0); y = z.get("y", 0)
        w = z.get("width", 0); h = z.get("height", 0)
        print(f"     Zone {j}: x={x}% y={y}% w={w}% h={h}%")
    print()
PYEOF

    echo "  System config: $ZN_SYSTEM_CFG  [Script-kzones] layoutsJson"
    echo "  User config:   $ZN_USER_CFG"
    echo "  Edit:          powos zones edit"
}

zn_cmd_edit() {
    # Open System Settings KZones configure page if qdbus is available;
    # fall back to editing kwinrc directly.
    if command -v qdbus &>/dev/null || command -v qdbus6 &>/dev/null; then
        local qd; qd=$(command -v qdbus6 2>/dev/null || command -v qdbus)
        if "$qd" org.kde.KWin /KWin &>/dev/null 2>&1; then
            echo "Opening KWin Scripts settings..."
            if command -v systemsettings &>/dev/null; then
                systemsettings kcm_kwin_scripts &
                return
            fi
        fi
    fi

    # Fallback: edit the user kwinrc (KDE merges it over /etc/xdg/kwinrc)
    local editor="${VISUAL:-${EDITOR:-nano}}"
    local target="$ZN_USER_CFG"
    echo "Opening $target"
    echo ""
    echo "Add or edit the [Script-kzones] section:"
    echo "  layoutsJson=[{\"name\":\"My Layout\",\"padding\":4,\"zones\":[...]}]"
    echo ""
    echo "After saving, reload KWin:"
    echo "  qdbus org.kde.KWin /KWin reconfigure"
    "$editor" "$target"
}

zn_cmd_help() {
    cat <<EOF
Usage: powos zones [SUBCOMMAND]

Manage KZones window-snapping zone layouts for KDE Plasma.

Subcommands:
  status     Show KZones install state, plugin enable state, and activation UX
  list       List default zone layouts with coordinates
  edit       Open the KZones config (System Settings or kwinrc)

How to use zones:
  1. Drag any window — the zone overlay appears automatically.
  2. Hover over a zone — it highlights.
  3. Release the mouse — the window snaps to fill that zone.

Customisation:
  Layouts are JSON with zones as {x,y,width,height} in screen-percent.
  See /etc/powos/zones/README for the full format.

EOF
}
