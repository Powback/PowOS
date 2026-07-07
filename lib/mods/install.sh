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

# ─── `powos mods setup` — configure a Steam game for modding ─────────────
# Wraps the standard Nexus Mods App / Cyberpunk-on-Linux fixes:
#   1. Install protontricks (system Flatpak) if missing.
#   2. Run the game's Proton prefix through winetricks with the packages
#      most Windows-side loader mods need (vcrun2022 + d3dcompiler_47).
#      Cyberpunk's Nexus health check specifically asks for these.
#   3. Set the standard WINEDLLOVERRIDES for common mod injection points
#      (winmm=n,b;version=n,b) in Steam's per-user launch options.
#
# Known games (short-name → appid). Adding a game here is a one-line change.
mods_appid_of() {
    case "$1" in
        cyberpunk|cyberpunk2077|cp2077)  echo "1091500" ;;
        skyrim|skyrimse)                  echo "489830"  ;;
        skyrim-ae|skyrimae)               echo "489830"  ;;
        fallout4|fo4)                     echo "377160"  ;;
        starfield)                        echo "1716740" ;;
        witcher3)                         echo "292030"  ;;
        bg3|baldursgate3)                 echo "1086940" ;;
        *) if [[ "$1" =~ ^[0-9]+$ ]]; then echo "$1"; else return 1; fi ;;
    esac
}

mods_setup_steam_userid() {
    # Steam userdata is per-account. Find the (usually only) numeric dir.
    local base="$HOME/.steam/steam/userdata"
    [[ -d "$base" ]] || return 1
    find "$base" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -printf '%f\n' 2>/dev/null | head -1
}

mods_ensure_protontricks() {
    if flatpak info com.github.Matoking.protontricks >/dev/null 2>&1; then
        return 0
    fi
    plog "Installing protontricks (system Flatpak, needs sudo)…"
    if ! sudo flatpak install -y --system flathub com.github.Matoking.protontricks 2>&1 \
            | grep -E "Installing|Installation complete|already installed" | tail -3; then
        perr "protontricks install failed."
        return 1
    fi
}

# Set WINEDLLOVERRIDES in Steam's per-user localconfig.vdf for a specific
# appid. Requires Steam to NOT be running (Steam re-saves the file from
# memory on exit and would clobber our edit otherwise).
mods_set_launch_options() {
    local appid="$1" value="$2"
    local uid; uid="$(mods_setup_steam_userid)" || {
        perr "No Steam userdata found — has Steam been launched at least once?"
        return 1
    }
    local vdf="$HOME/.steam/steam/userdata/$uid/config/localconfig.vdf"
    [[ -f "$vdf" ]] || { perr "Steam localconfig.vdf not found at $vdf"; return 1; }

    if pgrep -x steam >/dev/null 2>&1; then
        perr "Steam is running — quit it first (Steam → Exit) so the config edit isn't overwritten."
        return 1
    fi

    python3 - "$vdf" "$appid" "$value" <<'PY' 2>&1
import os, re, shutil, sys
vdf, appid, new_value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(vdf) as f: text = f.read()

# Locate Software/Valve/Steam/apps { ... } block by brace-matching from
# the `"apps"` header (avoids matching binary ticket lines that mention
# appids up top).
m = re.search(r'(\n\s*"apps"\s*\{)', text)
if not m:
    print("no apps block found"); sys.exit(1)
i = m.end(); depth = 1
while i < len(text) and depth > 0:
    if text[i] == '{': depth += 1
    elif text[i] == '}': depth -= 1
    i += 1
apps_start, apps_end = m.end(), i
apps_body = text[apps_start:apps_end]

# Find the `"<appid>"` sub-block.
sub_m = re.search(r'(\n\s*)"' + re.escape(appid) + r'"(\s*\n\s*)\{', apps_body)
if not sub_m:
    print(f"no {appid} sub-block found in apps"); sys.exit(1)
sub_start = sub_m.end(); depth = 1
j = sub_start
while j < len(apps_body) and depth > 0:
    if apps_body[j] == '{': depth += 1
    elif apps_body[j] == '}': depth -= 1
    j += 1
sub_end = j - 1
sub_body = apps_body[sub_start:sub_end]

shutil.copy(vdf, vdf + ".powos-backup")

new_lo = f'"LaunchOptions"\t\t"{new_value}"'
if re.search(r'"LaunchOptions"\s+"[^"]*"', sub_body):
    sub_body_new = re.sub(r'"LaunchOptions"\s+"[^"]*"', new_lo, sub_body, count=1)
    action = "updated"
else:
    lp = re.search(r'\n(\s*)"LastPlayed"', sub_body)
    indent = lp.group(1) if lp else '\t\t\t\t\t\t'
    sub_body_new = f"\n{indent}{new_lo}" + sub_body
    action = "added"

new_apps = apps_body[:sub_start] + sub_body_new + apps_body[sub_end:]
open(vdf, "w").write(text[:apps_start] + new_apps + text[apps_end:])
print(f"LaunchOptions {action}: {new_value}")
PY
}

mods_setup_cmd() {
    local game="${1:-}"
    if [[ -z "$game" ]]; then
        cat <<EOF
${BOLD}powos mods setup <game>${NC} — one-shot modding prep for a Steam game.

Runs the standard Cyberpunk-on-Linux / Nexus Mods App fix:
  1. Install protontricks (system Flatpak) if missing.
  2. Install winetricks packages the game needs into its Proton prefix
     (vcrun2022 + d3dcompiler_47 — the common Cyberpunk requirements).
  3. Set WINEDLLOVERRIDES="winmm=n,b;version=n,b" %command% on the game's
     Steam launch options so mod-provided loader DLLs actually load.

Known games (add more in mods_appid_of):
  cyberpunk / cp2077 (1091500)   skyrim / skyrimse (489830)
  skyrim-ae (489830)             fallout4 / fo4 (377160)
  starfield (1716740)            witcher3 (292030)
  bg3 (1086940)                  <numeric appid>

Examples:
  powos mods setup cyberpunk
  powos mods setup 1091500
EOF
        return 1
    fi

    local appid; appid="$(mods_appid_of "$game")" \
        || { perr "Unknown game/appid: $game"; return 1; }

    plog "Setting up modding for appid ${BOLD}$appid${NC}…"

    mods_ensure_protontricks || return 1

    # Grab the plasmashell env so protontricks can talk to a display when
    # winetricks fires up wine dialogs — otherwise wine's window driver
    # can't load and vcrun2022 install fails with "explorer failed to start".
    local pp; pp="$(pgrep -x plasmashell | head -1)"
    local env_prefix=""
    if [[ -n "$pp" ]] && [[ -r "/proc/$pp/environ" ]]; then
        local xa db
        xa="$(tr '\0' '\n' </proc/$pp/environ | grep '^XAUTHORITY=' | head -1 | cut -d= -f2-)"
        db="$(tr '\0' '\n' </proc/$pp/environ | grep '^DBUS_SESSION_BUS_ADDRESS=' | head -1 | cut -d= -f2-)"
        env_prefix="env XDG_RUNTIME_DIR=/run/user/$(id -u) WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 XAUTHORITY=$xa DBUS_SESSION_BUS_ADDRESS=$db"
    fi

    plog "Running winetricks: vcrun2022 d3dcompiler_47 (may take a few minutes)…"
    if ! $env_prefix flatpak run com.github.Matoking.protontricks \
            --no-bwrap "$appid" -q vcrun2022 d3dcompiler_47; then
        pwarn "protontricks reported a non-zero exit. If vcrun2022 was already installed"
        pwarn "that's fine; check by running it again — the second run is idempotent."
    fi

    plog "Setting Steam launch options (WINEDLLOVERRIDES)…"
    if pgrep -x steam >/dev/null 2>&1; then
        pwarn "Steam is running. Please Steam → Exit fully, then re-run:"
        pwarn "  powos mods setup $game"
        return 1
    fi
    if mods_set_launch_options "$appid" \
            'WINEDLLOVERRIDES=\"winmm=n,b;version=n,b\" %command%'; then
        pok "Setup complete for appid $appid."
        plog "  Relaunch Steam → the launch option is now active."
        plog "  In Nexus Mods App, hit Refresh on the Health Check — all three errors should clear."
    fi
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
  powos mods setup <game>         One-shot fix a Steam game for modding
                                    (installs protontricks, winetricks
                                    packages, sets WINEDLLOVERRIDES).
                                    Requires Steam to be closed.

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
