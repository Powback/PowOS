#!/bin/bash
# mods/install.sh - PowOS mod-manager installer.
#
# Wires up game-modding tooling that isn't in Fedora / Flatpak repos.
# Currently supported:
#   nexus-mods-app  Nexus's cross-platform native-Linux mod manager. Full
#                   Cyberpunk 2077 support since v0.11.1 (May 2025) —
#                   REDmod, REDscript, archives, framework mods, and
#                   Nexus collections. Vendor's recommended path for
#                   Linux modding.
#   vortex          Nexus's legacy Windows-only mod manager. No native
#                   Linux build exists yet ("SteamOS support in 2026"
#                   per Nexus, not shipped). We install it via Proton
#                   as a non-Steam game; documented but sub-optimal
#                   compared to the native app for Cyberpunk.

set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}/common.sh" 2>/dev/null || {
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
    plog()  { echo -e "${CYAN}[mods]${NC} $*"; }
    pok()   { echo -e "${GREEN}[mods]${NC} $*"; }
    pwarn() { echo -e "${YELLOW}[mods]${NC} $*"; }
    perr()  { echo -e "${RED}[mods]${NC} $*" >&2; }
}
POWOS_TAG=mods

MODS_APPS_DIR="${MODS_APPS_DIR:-$HOME/Applications}"
MODS_DESKTOP_DIR="${MODS_DESKTOP_DIR:-$HOME/.local/share/applications}"
MODS_ICONS_DIR="${MODS_ICONS_DIR:-$HOME/.local/share/icons/hicolor/512x512/apps}"

# ─── Tool registry ────────────────────────────────────────────────────────

mods_known_tools() { echo "nexus-mods-app vortex"; }

mods_binary_of() {
    case "$1" in
        nexus-mods-app|nexus|nma)  echo "$MODS_APPS_DIR/NexusModsApp.AppImage" ;;
        vortex)                    echo "$MODS_APPS_DIR/Vortex.exe" ;;
        *) return 1 ;;
    esac
}

mods_normalize_name() {
    case "$1" in
        nexus|nma|nexus-mods-app|"nexus mods app")  echo "nexus-mods-app" ;;
        vortex|vortex-mod-manager)                  echo "vortex" ;;
        *) return 1 ;;
    esac
}

# ─── Nexus Mods App (native AppImage) ─────────────────────────────────────

mods_install_nexus() {
    local url="https://github.com/Nexus-Mods/NexusMods.App/releases/latest/download/NexusMods.App.x86_64.AppImage"
    local target="$MODS_APPS_DIR/NexusModsApp.AppImage"
    local desktop="$MODS_DESKTOP_DIR/nexus-mods-app.desktop"

    mkdir -p "$MODS_APPS_DIR" "$MODS_DESKTOP_DIR"

    plog "Downloading Nexus Mods App AppImage…"
    plog "  ${DIM}$url${NC}"
    if ! curl -fL --progress-bar "$url" -o "$target"; then
        perr "Download failed. Check network."
        return 1
    fi
    chmod +x "$target"

    # Try to extract the app's own icon so the .desktop entry has a real
    # icon rather than a generic games one. Best-effort — silently
    # falls through to the fallback if extraction fails.
    local icon="applications-games"
    if command -v unsquashfs >/dev/null 2>&1 || true; then
        local tmp; tmp="$(mktemp -d)"
        if ( cd "$tmp" && "$target" --appimage-extract 'NexusMods.App.svg' >/dev/null 2>&1 \
                            || "$target" --appimage-extract '*.svg' >/dev/null 2>&1 \
                            || "$target" --appimage-extract '*.png' >/dev/null 2>&1 ); then
            local found
            found="$(find "$tmp/squashfs-root" -maxdepth 3 -type f \( -name '*.png' -o -name '*.svg' \) 2>/dev/null | head -1)"
            if [[ -n "$found" ]]; then
                mkdir -p "$MODS_ICONS_DIR"
                cp "$found" "$MODS_ICONS_DIR/nexus-mods-app.${found##*.}"
                icon="nexus-mods-app"
            fi
        fi
        rm -rf "$tmp"
    fi

    cat > "$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Nexus Mods App
GenericName=Mod Manager
Comment=Cross-platform mod manager for Cyberpunk 2077, BG3, and more (Nexus Mods)
Exec="$target" %F
Icon=$icon
Terminal=false
Categories=Game;Utility;
MimeType=x-scheme-handler/nxm;
StartupNotify=true
StartupWMClass=NexusMods.App
EOF
    chmod +x "$desktop" 2>/dev/null || true
    update-desktop-database "$MODS_DESKTOP_DIR" 2>/dev/null || true

    pok "Nexus Mods App installed."
    plog "  Binary:   $target"
    plog "  Menu:     $desktop"
    plog "  Launch:   powos mods launch nexus-mods-app  ${DIM}(or KDE menu → Nexus Mods App)${NC}"
    plog "  Auto-updates itself on next launch — no bootc / OS involvement needed."
}

# ─── Vortex (Windows, via Proton) ─────────────────────────────────────────

mods_install_vortex() {
    pwarn "Vortex has no native Linux build — Nexus's own recommendation for"
    pwarn "Cyberpunk on Linux is the ${BOLD}Nexus Mods App${NC} (install it with"
    pwarn "${DIM}powos mods install nexus-mods-app${NC}). Vortex-under-Proton has"
    pwarn "known issues, especially with mod deployment paths."
    echo
    plog "If you still want Vortex under Proton, do it manually — it's"
    plog "an interactive Windows installer that Steam+Proton handles best:"
    echo
    plog "  1. Download the installer:"
    plog "     ${DIM}https://www.nexusmods.com/site/mods/1${NC}"
    plog "  2. In Steam: ${BOLD}Games → Add a Non-Steam Game to My Library${NC},"
    plog "     select ${BOLD}Vortex-*.exe${NC}."
    plog "  3. Right-click the entry → ${BOLD}Properties → Compatibility${NC},"
    plog "     ${BOLD}Force the use of a specific Steam Play tool → Proton Experimental${NC}."
    plog "  4. Launch it — the installer prefixes itself into that game's"
    plog "     Proton prefix. Launch again from Steam whenever you need Vortex."
    echo
    plog "  Mod deployment: point Vortex at your game's ${DIM}steamapps/common/<Game>${NC}"
    plog "  path (Proton exposes it inside the prefix)."
    return 0
}

# ─── Commands ────────────────────────────────────────────────────────────

mods_install_cmd() {
    local tool="${1:-}"
    if [[ -z "$tool" ]]; then mods_help; return 1; fi
    local canonical
    canonical="$(mods_normalize_name "$tool")" \
        || { perr "Unknown mod manager: $tool"; plog "Known: $(mods_known_tools)"; return 1; }
    case "$canonical" in
        nexus-mods-app)  mods_install_nexus ;;
        vortex)          mods_install_vortex ;;
    esac
}

mods_uninstall_cmd() {
    local tool="${1:-}"
    if [[ -z "$tool" ]]; then perr "Usage: powos mods uninstall <tool>"; return 1; fi
    local canonical
    canonical="$(mods_normalize_name "$tool")" \
        || { perr "Unknown mod manager: $tool"; return 1; }
    local bin desktop icon
    bin="$(mods_binary_of "$canonical")"
    desktop="$MODS_DESKTOP_DIR/${canonical}.desktop"
    icon="$MODS_ICONS_DIR/${canonical}.png"

    local removed=false
    [[ -e "$bin"     ]] && { rm -f "$bin"     && removed=true; plog "Removed: $bin"; }
    [[ -e "$desktop" ]] && { rm -f "$desktop" && removed=true; plog "Removed: $desktop"; }
    [[ -e "$icon"    ]] && { rm -f "$icon"    && removed=true; }
    [[ -e "${icon%.png}.svg" ]] && rm -f "${icon%.png}.svg"

    if $removed; then
        update-desktop-database "$MODS_DESKTOP_DIR" 2>/dev/null || true
        pok "$canonical uninstalled."
    else
        pwarn "$canonical doesn't appear to be installed."
    fi
}

mods_installed_cmd() {
    echo -e "${BOLD}Installed mod managers${NC}"
    echo "════════════════════════════════════════"
    local tool bin
    for tool in $(mods_known_tools); do
        bin="$(mods_binary_of "$tool")"
        if [[ -x "$bin" ]]; then
            printf "  %-16s ${GREEN}installed${NC}  ${DIM}%s${NC}\n" "$tool" "$bin"
        else
            printf "  %-16s ${DIM}not installed${NC}\n" "$tool"
        fi
    done
    echo
    echo -e "${DIM}Install:   powos mods install <tool>${NC}"
    echo -e "${DIM}Launch:    powos mods launch <tool>${NC}"
    echo -e "${DIM}Uninstall: powos mods uninstall <tool>${NC}"
}

mods_launch_cmd() {
    local tool="${1:-}"
    if [[ -z "$tool" ]]; then perr "Usage: powos mods launch <tool>"; return 1; fi
    local canonical
    canonical="$(mods_normalize_name "$tool")" \
        || { perr "Unknown mod manager: $tool"; return 1; }
    local bin; bin="$(mods_binary_of "$canonical")"
    if [[ ! -x "$bin" ]]; then
        perr "$canonical is not installed. Try: powos mods install $canonical"
        return 1
    fi
    plog "Launching $canonical…"
    # Detach so the CLI returns immediately; AppImages own their own event loop.
    setsid nohup "$bin" >/dev/null 2>&1 < /dev/null &
    disown
}

mods_help() {
    cat <<EOF
${BOLD}powos mods${NC} — manage game-modding tools

  powos mods install <tool>       Install a mod manager
  powos mods uninstall <tool>     Remove
  powos mods installed            List installed managers
  powos mods launch <tool>        Launch (also available from KDE menu)

Known tools:
  ${BOLD}nexus-mods-app${NC}   Nexus's native-Linux cross-platform manager
                   (recommended for Cyberpunk 2077 on Linux). Aliases:
                   ${DIM}nexus${NC}, ${DIM}nma${NC}.
  ${BOLD}vortex${NC}           Nexus's Windows-only manager — installs via
                   Proton as a non-Steam game. Only pick this if you
                   have a workflow that specifically requires it.

Note: Steam Workshop is built into Steam itself — no install needed. Subscribe
to any workshop item and Steam auto-manages the mod for that game.

Examples:
  powos mods install nexus-mods-app
  powos mods launch nexus
  powos mods installed
EOF
}
