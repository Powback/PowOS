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

mods_known_tools() { echo "nexus-mods-app vortex mod-organizer-2"; }

mods_binary_of() {
    case "$1" in
        nexus-mods-app|nexus|nma)  echo "$MODS_APPS_DIR/NexusModsApp.AppImage" ;;
        vortex)                    echo "$HOME/.local/bin/vortex" ;;
        mod-organizer-2)           echo "$HOME/.local/bin/mod-organizer-2" ;;
        *) return 1 ;;
    esac
}

mods_normalize_name() {
    case "$1" in
        nexus|nma|nexus-mods-app|"nexus mods app")  echo "nexus-mods-app" ;;
        vortex|vortex-mod-manager)                  echo "vortex" ;;
        mo2|mod-organizer|mod-organizer-2|"mod organizer 2")  echo "mod-organizer-2" ;;
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

# ─── Vortex (Windows, via Bottles Flatpak) ────────────────────────────────
# Full setup lives in mods/vortex.sh — installs Bottles, creates a
# dedicated bottle with .NET Desktop 6, runs Vortex's NSIS installer
# silently, writes a `vortex` CLI wrapper, and registers an nxm:// handler.
# Vortex covers all the games NMA doesn't (Skyrim SE/AE, FO4, Starfield,
# BG3, Witcher 3, and every Bethesda title).

mods_install_vortex() {
    source "$(dirname "${BASH_SOURCE[0]}")/vortex.sh"
    vortex_install_cmd "$@"
}

# Vortex binary check — the top-level installer registry (mods_binary_of)
# uses this to answer "is vortex installed?" via `powos mods installed`.
# The Bottles-installed Vortex.exe lives inside the bottle's drive_c;
# reflect the wrapper here so 'installed'/'launch' work uniformly.
mods_vortex_bin() { echo "$HOME/.local/bin/vortex"; }

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
        # GTA V: Rockstar split PC into two SKUs (Mar 2025). "Enhanced" is the
        # current default install and a SEPARATE Nexus catalog (gta5enhanced);
        # "Legacy" is the older build the classic mod scene targets (gta5).
        # Bare gta/gta5 → Enhanced (what Steam installs now); -legacy for the old one.
        gta|gta5|gtav|gta5-enhanced|gtav-enhanced|gta-enhanced)  echo "3240220" ;;
        gta5-legacy|gtav-legacy|gta-legacy)                       echo "271590"  ;;
        rdr2|reddead|reddeadredemption2|rdr)                      echo "1174180" ;;
        *) if [[ "$1" =~ ^[0-9]+$ ]]; then echo "$1"; else return 1; fi ;;
    esac
}

# RAGE-engine games (GTA V Enhanced/Legacy, RDR2) are NOT manager-deployable
# on Linux — no NMA/Vortex backend puts an ASI loader + .asi into the Steam
# game dir. `powos mods install <game> …` auto-routes these to the built-in
# ASI subsystem (mods/asi.sh) instead of the Nexus/NMA path.
mods_is_rage_game() {
    local appid; appid="$(mods_appid_of "$1" 2>/dev/null)" || return 1
    case "$appid" in
        3240220|271590|1174180) return 0 ;;
        *) return 1 ;;
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
  3. Set WINEDLLOVERRIDES="winmm=n,b;version=n,b;dinput8=n,b" %command% on the
     game's Steam launch options so mod-provided loader DLLs load — winmm/version
     for CET/RED4ext/SKSE, dinput8 for Script Hook V / RDR2 + ASI loaders.

Known games (add more in mods_appid_of):
  cyberpunk / cp2077 (1091500)   skyrim / skyrimse (489830)
  skyrim-ae (489830)             fallout4 / fo4 (377160)
  starfield (1716740)            witcher3 (292030)
  bg3 (1086940)                  gta / gta5 — Enhanced (3240220)
  gta5-legacy (271590)           rdr2 (1174180)
  <numeric appid>

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
    # winmm/version cover CET, RED4ext, SKSE-style loaders; dinput8 covers
    # Script Hook V / Script Hook RDR2 + most ASI loaders (GTA V, RDR2). All
    # are native-then-builtin, so they're harmless for games that don't ship
    # that DLL (wine just falls back to its builtin).
    if mods_set_launch_options "$appid" \
            'WINEDLLOVERRIDES=\"winmm=n,b;version=n,b;dinput8=n,b\" %command%'; then
        pok "Setup complete for appid $appid."
        plog "  Relaunch Steam → the launch option is now active."
        plog "  In Nexus Mods App, hit Refresh on the Health Check — all three errors should clear."
    fi
}

# ─── Nexus REST API helpers ──────────────────────────────────────────────
# All commands here talk directly to https://api.nexusmods.com/v1/ with the
# Personal API Key saved by `powos setup nexus`. Premium accounts get the
# `download_link.json` endpoint that returns a signed nxm:// URL — that
# URL is what NMA's `protocol-invoke` accepts. Free accounts can still use
# `mod-info`, `mod-files`, and `mod-changelog` but not `download-link`.
#
# For AI agents: this is the vocabulary you use to look at a mod BEFORE
# installing — read description + file list + categories + version → pick
# the right main file → install.

POWOS_NEXUS_KEY_FILE="${POWOS_NEXUS_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/powos/nexus.key}"
POWOS_NEXUS_UA="powos-mods/0.1"

mods_nexus_key() {
    [[ -f "$POWOS_NEXUS_KEY_FILE" ]] || {
        perr "No Nexus API key at $POWOS_NEXUS_KEY_FILE."
        perr "Run: powos setup nexus"
        return 1
    }
    cat "$POWOS_NEXUS_KEY_FILE"
}

# Low-level curl wrapper: prints JSON body to stdout, returns nonzero on
# HTTP error. Rate limited by Nexus (300/day free, 600/day Premium).
mods_api_get() {
    local path="$1"
    local key; key="$(mods_nexus_key)" || return 1
    curl -sS -f \
        -H "apikey: $key" \
        -H "User-Agent: $POWOS_NEXUS_UA" \
        -H "Accept: application/json" \
        "https://api.nexusmods.com/v1$path"
}

# powos mods info <game> <mod-id>   → mod summary (name, author, description,
#                                      category, endorsements, version)
mods_info_cmd() {
    POWOS_MODS_LAST_VERB="info"
    local game="${1:?Usage: powos mods info <game> <mod-id>}"
    local mod_id="${2:?Usage: powos mods info <game> <mod-id>}"
    local slug; slug="$(mods_nexus_slug_of "$game")"
    mods_api_get "/games/$slug/mods/$mod_id.json"
}

# powos mods files <game> <mod-id>  → JSON file list. Category IDs:
#                                      1 MAIN  2 UPDATE  3 OPTIONAL
#                                      4 OLD_VERSION  5 MISCELLANEOUS
mods_files_cmd() {
    POWOS_MODS_LAST_VERB="files"
    local game="${1:?Usage: powos mods files <game> <mod-id>}"
    local mod_id="${2:?Usage: powos mods files <game> <mod-id>}"
    local slug; slug="$(mods_nexus_slug_of "$game")"
    mods_api_get "/games/$slug/mods/$mod_id/files.json"
}

# powos mods changelog <game> <mod-id>  → changelog JSON, keyed by version
mods_changelog_cmd() {
    POWOS_MODS_LAST_VERB="changelog"
    local game="${1:?Usage: powos mods changelog <game> <mod-id>}"
    local mod_id="${2:?Usage: powos mods changelog <game> <mod-id>}"
    local slug; slug="$(mods_nexus_slug_of "$game")"
    mods_api_get "/games/$slug/mods/$mod_id/changelogs.json"
}

# powos mods download-link <game> <mod-id> <file-id>
#   Premium-only. Returns [{"URI": "nxm://…?key=…&expires=…&user_id=…"}].
#   The URI is the signed nxm:// that NMA's protocol-invoke accepts.
mods_download_link_cmd() {
    POWOS_MODS_LAST_VERB="download-link"
    local game="${1:?Usage: powos mods download-link <game> <mod-id> <file-id>}"
    local mod_id="${2:?Usage: powos mods download-link <game> <mod-id> <file-id>}"
    local file_id="${3:?Usage: powos mods download-link <game> <mod-id> <file-id>}"
    local slug; slug="$(mods_nexus_slug_of "$game")"
    mods_api_get "/games/$slug/mods/$mod_id/files/$file_id/download_link.json"
}

# Install ONE mod (main file by default, or a specific file-id).
# Returns 0 on success. `_mods_install_one <game> <mod-id> [file-id]`
#
# The nxm:// URL passed to NMA is BARE (no ?key=&expires=&user_id=).
# Discovered 2026-07-07: NMA's NXMUrl.Parse marks those query params
# optional — the running NMA instance uses its own stored OAuth to auth
# the download. So `download_link.json` (which returns https:// CDN URLs
# NMA doesn't accept via protocol-invoke) is unnecessary — we only need
# `files.json` to resolve mod-id → file-id, then dispatch a bare URL.
_mods_install_one() {
    local game="$1" mod_id="$2" file_id="${3:-}"
    local slug; slug="$(mods_nexus_slug_of "$game")"

    if [[ -z "$file_id" ]]; then
        local files
        files="$(mods_api_get "/games/$slug/mods/$mod_id/files.json")" || return 1
        # Prefer primary + MAIN category. Fall back to newest MAIN, then newest.
        file_id="$(printf '%s' "$files" | python3 -c '
import json, sys
d = json.load(sys.stdin)
files = d.get("files", []) or []
mains = [f for f in files if f.get("category_id") == 1]
picked = None
for f in mains:
    if f.get("is_primary"):
        picked = f; break
if not picked and mains:
    picked = sorted(mains, key=lambda x: x.get("uploaded_timestamp", 0), reverse=True)[0]
if not picked and files:
    picked = sorted(files, key=lambda x: x.get("uploaded_timestamp", 0), reverse=True)[0]
print(picked["file_id"] if picked else "")
')"
        [[ -z "$file_id" ]] && { perr "  mod $mod_id: no downloadable file."; return 1; }
    fi

    local url="nxm://${slug}/mods/${mod_id}/files/${file_id}"
    # Fire the nxm:// at NMA and move on. A running NMA instance queues and
    # prioritizes downloads internally, and its `protocol-invoke` process does
    # NOT exit while the GUI is up — so capturing its output with $(...) blocks
    # forever (observed 2026-07-07: a 6-mod batch hung on mod #1 for 8+ min and
    # nothing downloaded). Bound the hand-off with `timeout`; a timeout here
    # means "URL delivered, invoke just didn't self-exit", which is success.
    # `timeout` can only exec a real binary, not the mods_nma_invoke shell
    # function — so resolve the AppImage path and wrap that directly.
    mods_nma_ensure_installed || return 1
    local out rc bin; bin="$(mods_nma_binary)"
    out="$(timeout -k 3 12 "$bin" protocol-invoke -u "$url" 2>&1)"; rc=$?
    # rc 124 (SIGTERM at timeout) / 137 (SIGKILL via -k) = delivered-then-detached.
    if [[ $rc -ne 0 && $rc -ne 124 && $rc -ne 137 ]]; then
        perr "  mod $mod_id: protocol-invoke failed (rc=$rc)."
        printf '%s\n' "$out" | head -3 >&2
        return 1
    fi
    if printf '%s' "$out" | grep -qE '^Error:|^An error occurred|Exception'; then
        perr "  mod $mod_id: NMA rejected URL. Output:"
        printf '%s\n' "$out" | head -3 >&2
        return 1
    fi
    # Track dispatched mod so future installs' dep-resolution knows it's present.
    declare -f mods_record_installed >/dev/null 2>&1 && mods_record_installed "$slug" "$mod_id"
    printf '%s\n' "$file_id"
}

# ─── Loadout auto-install (post-download) ────────────────────────────────
# NMA's install pipeline has three stages: download to Library → add to
# Loadout (loadout install) → apply to disk (loadout synchronize). The
# nxm:// dispatch only triggers the first stage. `mods_loadout_apply`
# handles stages 2 and 3 for everything currently in the Library that
# isn't already in the target loadout.

# Return the first Cyberpunk/BG3/… loadout ID matching a game slug.
mods_loadout_id_for() {
    local slug="$1"
    mods_nma_invoke loadouts list 2>/dev/null \
        | awk -v want="$(mods_nexus_slug_to_game_name "$slug")" '
            /^│/ && $0 !~ /^│ Id/ && $0 !~ /────/ {
                # Rows look like: │ LoadoutId:X  │ Name │ Game │ …
                # Column-safe: strip the box chars, split on multiple spaces.
                gsub(/│/, "|"); gsub(/^\s+|\s+$/, "");
                n = split($0, cells, /\s*\|\s*/);
                for (i=1; i<=n; i++) if (cells[i] ~ /^LoadoutId:/) lid = cells[i];
                for (i=1; i<=n; i++) if (index(tolower(cells[i]), tolower(want)) > 0) { print lid; exit }
            }'
}

# Human-readable game name from Nexus slug (used to match Loadout row).
mods_nexus_slug_to_game_name() {
    case "$1" in
        cyberpunk2077)          echo "Cyberpunk 2077" ;;
        skyrimspecialedition)   echo "Skyrim Special Edition" ;;
        skyrim)                 echo "Skyrim" ;;
        fallout4)               echo "Fallout 4" ;;
        starfield)              echo "Starfield" ;;
        witcher3)               echo "Witcher 3" ;;
        baldursgate3)           echo "Baldur's Gate 3" ;;
        stardewvalley)          echo "Stardew Valley" ;;
        *) echo "$1" ;;
    esac
}

# powos mods deploy <game>
#   Sync the game's loadout to disk — deploy stage of the pipeline.
#   Handy on its own after all downloads + loadout-installs are done.
mods_deploy_cmd() {
    POWOS_MODS_LAST_VERB="deploy"
    local game="${1:?Usage: powos mods deploy <game>}"
    local slug; slug="$(mods_nexus_slug_of "$game")"
    local lid; lid="$(mods_loadout_id_for "$slug")"
    [[ -z "$lid" ]] && { perr "No loadout found for game $game (slug: $slug)."; return 1; }
    plog "Synchronizing $lid to disk (deploying mods)…"
    mods_nma_invoke loadout synchronize -l "$lid" \
        && pok "Loadout $lid deployed." \
        || { perr "loadout synchronize failed."; return 1; }
}

# powos mods loadouts
#   List all NMA loadouts. Thin wrapper.
mods_loadouts_cmd() {
    POWOS_MODS_LAST_VERB="loadouts"
    mods_nma_invoke loadouts list "$@"
}

# powos mods install <game> <mod-id> [mod-id …]
#   Bulk mod install by mod-id. Picks primary MAIN file for each. Also
#   reads mod-ids from stdin if none given on the command line (one per
#   line, `#` and blank lines ignored). Sleeps 1s between calls to stay
#   inside Nexus's rate limits.
#
#   AI use: for each mod ID in your task list, run `powos mods install
#   <game> <ids…>`. If a mod has multiple variants (HD vs SD, ENB
#   presets, patch series), inspect `powos mods files <game> <mod-id>`
#   first to pick the right file-id, then run `powos mods install-file
#   <game> <mod-id> <file-id>` for THAT one (bypasses auto-pick).
#
#   Flags:
#     --json   Emit one JSON line per mod: {"mod_id":..,"file_id":..,"ok":true/false,"error":".."}
mods_install_smart_cmd() {
    POWOS_MODS_LAST_VERB="install"
    local json=false
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)  json=true; shift ;;
            *)       args+=("$1"); shift ;;
        esac
    done
    set -- "${args[@]}"

    local game="${1:?Usage: powos mods install <game> <mod-id> [mod-id ...] (or pipe IDs on stdin)}"
    shift
    local ids=("$@")

    # RAGE-engine games have no manager backend — auto-route to the ASI
    # subsystem (loader + .asi into the Steam game dir), no Vortex/NMA.
    if mods_is_rage_game "$game"; then
        source "$(dirname "${BASH_SOURCE[0]}")/asi.sh" 2>/dev/null \
            || source "${POWOS_LIB:-}/mods/asi.sh" 2>/dev/null
        asi_install_generic "$game" ${ids[@]+"${ids[@]}"}
        return $?
    fi

    if [[ ${#ids[@]} -eq 0 ]]; then
        # Read from stdin: strip # comments + blank lines + any trailing junk.
        while IFS= read -r line; do
            line="${line%%#*}"
            line="$(echo "$line" | tr -d '[:space:]')"
            [[ -n "$line" ]] && ids+=("$line")
        done
    fi
    [[ ${#ids[@]} -eq 0 ]] && { perr "No mod-ids given. Pass as args or pipe on stdin."; return 1; }

    # ── Pre-flight: auto-resolve dependencies + warn on conflicts ──────────────
    # Reads each mod's README (Requirements links → deps, Compatibility section →
    # conflicts). Missing deps are HARD mod-id links, so we auto-add them. Conflict
    # matches are heuristic (free-text), so we only WARN — never block. Skippable
    # with MODS_NO_PREFLIGHT=1 or --no-deps.
    if declare -f mods_analyze >/dev/null 2>&1 && [[ "${MODS_NO_PREFLIGHT:-}" != 1 ]] && ! $json; then
        local _slug _pf _newdeps _confl _d
        _slug="$(mods_nexus_slug_of "$game")"
        _pf="$(mods_analyze "$_slug" "${ids[@]}" 2>/tmp/.mods_pf.$$)"
        if [[ -s /tmp/.mods_pf.$$ ]]; then plog "Pre-flight (readme analysis):"; cat /tmp/.mods_pf.$$ >&2; fi
        rm -f /tmp/.mods_pf.$$
        _newdeps="$(printf '%s\n' "$_pf" | awk '/^MISSINGDEP/{print $3}' | sort -un)"
        for _d in $_newdeps; do
            printf '%s\n' "${ids[@]}" | grep -qxF "$_d" || ids+=("$_d")
        done
        [[ -n "$_newdeps" ]] && plog "Auto-added missing dependencies: $(echo $_newdeps | tr '\n' ' ')"
        _confl="$(printf '%s\n' "$_pf" | awk '/^CONFLICT/{print}')"
        [[ -n "$_confl" ]] && pwarn "Conflicts flagged above — you probably want only ONE of each pair. Installing all; use 'powos mods remove' to drop one."
    fi

    local ok=0 fail=0 mod_id file_id
    for mod_id in "${ids[@]}"; do
        if ! $json; then plog "→ mod $mod_id"; fi
        if file_id="$(_mods_install_one "$game" "$mod_id" 2>&1)"; then
            if $json; then
                printf '{"mod_id":%s,"file_id":%s,"ok":true}\n' "$mod_id" "${file_id##*$'\n'}"
            else
                pok "  mod $mod_id: dispatched (file $file_id)"
            fi
            ok=$((ok+1))
        else
            local err="${file_id//$'\n'/ }"
            if $json; then
                printf '{"mod_id":%s,"ok":false,"error":%s}\n' "$mod_id" "$(printf '%s' "$err" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')"
            fi
            fail=$((fail+1))
        fi
        sleep 1  # Nexus rate limit: 600/day Premium, 300/day free.
    done

    if ! $json; then
        pok "Done. $ok ok, $fail failed."
    fi
    [[ $fail -eq 0 ]]
}

# powos mods install-file <game> <mod-id> <file-id>
#   Install a SPECIFIC file (bypasses the main-file auto-pick). Use this
#   when you inspected `powos mods files <game> <mod-id>` and want a
#   non-default variant (a patch, an optional file, etc.).
mods_install_file_cmd() {
    POWOS_MODS_LAST_VERB="install-file"
    local game="${1:?Usage: powos mods install-file <game> <mod-id> <file-id>}"
    local mod_id="${2:?Usage: powos mods install-file <game> <mod-id> <file-id>}"
    local file_id="${3:?Usage: powos mods install-file <game> <mod-id> <file-id>}"
    _mods_install_one "$game" "$mod_id" "$file_id" >/dev/null \
        && pok "mod $mod_id file $file_id: dispatched to NMA."
}

# ─── Nexus Mods App CLI wrapper ──────────────────────────────────────────
# NMA has an undocumented `as-main` CLI mode with rich subcommands
# (install-collection, list-games, nexus-api-key, etc.). Two invocation
# modes:
#   • as-main <cmd>          takes exclusive RocksDB lock — GUI must be
#                            CLOSED. Used for auth, list, and headless
#                            install of collections/mods.
#   • protocol-invoke <url>  sends a nxm:// URL to the running instance
#                            (if any). Used to queue installs into a
#                            running GUI, or launch a fresh install.
# Auth persists in the app's data model, so if the user logged in via
# GUI once, all subsequent CLI calls see the same session — no re-auth.

mods_nma_binary() { echo "$MODS_APPS_DIR/NexusModsApp.AppImage"; }

mods_nma_running() {
    # Authoritative check: someone holds NMA's RocksDB LOCK open. That's
    # what actually blocks as-main commands (not GUI-window existence),
    # and it beats string-matching cmdlines — the earlier `pgrep -f` was
    # too loose and matched agent processes whose *prompt text* mentions
    # "NexusModsApp.AppImage", producing false positives. Discovered
    # during E2E agent test 2026-07-07.
    local lock="$HOME/.local/share/NexusMods.App/DataModel/MnemonicDB.rocksdb/LOCK"
    if [[ -f "$lock" ]] && command -v fuser >/dev/null 2>&1; then
        # `fuser` prints holding PIDs to stderr and lists them on stdout.
        # If nothing holds it, stdout is empty and grep -q . fails.
        fuser "$lock" 2>/dev/null | grep -q . && return 0
    fi
    # Fallback: only match the executable at a path boundary — the
    # AppImage's own cmdline starts with the full path to the binary,
    # while cmdlines that merely MENTION the string (agents, docs, this
    # very function's caller stack) don't start with `/…/NexusModsApp.AppImage`.
    pgrep -f "/NexusModsApp\.AppImage($|[[:space:]])" >/dev/null 2>&1
}

mods_nma_ensure_installed() {
    if [[ ! -x "$(mods_nma_binary)" ]]; then
        perr "Nexus Mods App isn't installed. Run: ${BOLD}powos mods install nexus-mods-app${NC}"
        return 1
    fi
}

mods_nma_asmain() {
    mods_nma_ensure_installed || return 1
    if mods_nma_running; then
        perr "Nexus Mods App GUI is currently running."
        perr "This command needs the GUI closed (right-click tray → Quit, or 'pkill -f NexusModsApp')."
        perr "Then re-run:  powos mods $POWOS_MODS_LAST_VERB $*"
        return 1
    fi
    "$(mods_nma_binary)" as-main "$@"
}

mods_nma_invoke() {
    mods_nma_ensure_installed || return 1
    "$(mods_nma_binary)" "$@"
}

# Nexus URL slug (the identifier in nxm:// URLs and www.nexusmods.com/<slug>/mods/*)
# — different from Steam appid or short name.
mods_nexus_slug_of() {
    case "$1" in
        cyberpunk|cyberpunk2077|cp2077|1091500)   echo "cyberpunk2077" ;;
        skyrim|skyrimspecialedition|489830)        echo "skyrimspecialedition" ;;
        skyrim-le)                                  echo "skyrim" ;;
        fallout4|fo4|377160)                        echo "fallout4" ;;
        starfield|1716740)                          echo "starfield" ;;
        witcher3|292030)                            echo "witcher3" ;;
        bg3|baldursgate3|1086940)                   echo "baldursgate3" ;;
        stardewvalley|sdv|413150)                   echo "stardewvalley" ;;
        # GTA V has TWO Nexus catalogs: Enhanced (gta5enhanced, appid 3240220)
        # and Legacy (gta5, appid 271590). They do NOT share mods. Keep bare
        # gta/gta5 == Enhanced here to match mods_appid_of (Steam's current
        # default install); the far-larger classic Legacy catalog is -legacy.
        gta|gta5|gtav|gta5-enhanced|gtav-enhanced|gta-enhanced|3240220)  echo "gta5enhanced" ;;
        gta5-legacy|gtav-legacy|gta-legacy|271590)                       echo "gta5" ;;
        rdr2|reddead|reddeadredemption2|rdr|1174180)                     echo "reddeadredemption2" ;;
        # Assume the input is already a Nexus slug — pass through.
        *) echo "$1" ;;
    esac
}

# ── Auth ─────────────────────────────────────────────────────────────
mods_auth_cmd() {
    local key="${1:-}"
    POWOS_MODS_LAST_VERB="auth"
    if [[ -z "$key" ]]; then
        plog "Opening Nexus OAuth login flow (needs a browser)..."
        mods_nma_asmain nexus-login
    else
        plog "Setting Nexus API key..."
        mods_nma_asmain nexus-api-key "$key" \
            && pok "API key saved. Persists across GUI/CLI runs."
    fi
}

mods_logout_cmd() {
    POWOS_MODS_LAST_VERB="logout"
    mods_nma_asmain nexus-logout && pok "Logged out."
}

# ── Discovery ────────────────────────────────────────────────────────
mods_games_cmd() {
    POWOS_MODS_LAST_VERB="games"
    mods_nma_asmain list-games "$@"
}

mods_tools_cmd() {
    POWOS_MODS_LAST_VERB="tools"
    local game="${1:?Usage: powos mods tools <game>}"
    mods_nma_asmain list-tools -g "$game"
}

mods_run_tool_cmd() {
    POWOS_MODS_LAST_VERB="run-tool"
    local game="${1:?Usage: powos mods run-tool <game> <tool>}"
    local tool="${2:?Usage: powos mods run-tool <game> <tool>}"
    mods_nma_asmain run-tool -g "$game" -t "$tool"
}

# ── Install ──────────────────────────────────────────────────────────
# Install a whole Nexus collection headlessly. Slug comes from the
# collection URL: www.nexusmods.com/<game>/collections/<slug>.
mods_install_collection_cmd() {
    POWOS_MODS_LAST_VERB="install-collection"
    local slug="${1:?Usage: powos mods install-collection <slug> [--game <slug>]}"
    shift
    plog "Installing collection '${BOLD}$slug${NC}' via Nexus Mods App..."
    plog "  ${DIM}(this needs the GUI closed and Steam idle for the game)${NC}"
    mods_nma_asmain install-collection "$slug" "$@"
}

# Install a single mod by mod-id (and optionally a specific file-id).
# Uses the nxm:// protocol-invoke path so it works whether the GUI is
# running or not — if it's running, install goes to that instance;
# if not, NMA launches to handle the URL. Works for the "click download
# with mod manager" button flow because that's the same URL scheme.
mods_install_mod_cmd() {
    POWOS_MODS_LAST_VERB="install-mod"
    local game="${1:?Usage: powos mods install-mod <game> <mod-id> <file-id>}"
    local mod_id="${2:?Usage: powos mods install-mod <game> <mod-id> <file-id>}"
    local file_id="${3:-}"
    local slug; slug="$(mods_nexus_slug_of "$game")"

    # NMA's nxm:// protocol parser REQUIRES a file-id. `nxm://<game>/mods/<id>`
    # (mod page URL) is rejected with "invalid url" — confirmed via E2E agent
    # test 2026-07-07. Refuse cleanly if the caller only knows the mod-id.
    if [[ -z "$file_id" ]]; then
        perr "install-mod needs a <file-id> too — NMA rejects bare mod-page URLs."
        perr "Ways to get the file-id:"
        perr "  1. Visit https://www.nexusmods.com/${slug}/mods/${mod_id}, click a"
        perr "     file's 'Manual Download' or 'Mod Manager Download', and NMA will"
        perr "     receive the full nxm:// URL directly (no CLI needed for this path)."
        perr "  2. Query Nexus API for latest main file:"
        perr "       curl -sS https://api.nexusmods.com/v1/games/${slug}/mods/${mod_id}/files.json \\"
        perr "         -H 'apikey: <your-nexus-api-key>' \\"
        perr "         | jq -r '.files[] | select(.category_name==\"MAIN\") | .file_id' | head -1"
        perr "     Nexus API keys: https://www.nexusmods.com/users/myaccount?tab=api"
        return 1
    fi

    local url="nxm://${slug}/mods/${mod_id}/files/${file_id}"
    plog "Installing file $file_id of mod $mod_id: $url"

    # NexusModsApp's protocol-invoke takes `-u <url>`, not a positional arg.
    # Agent-driven E2E test caught this ("Option '-u' is required").
    #
    # Also: capture and inspect output. NMA's CLI prints "An error occurred
    # while executing the command" then a stack trace on invalid URL / auth
    # failure but its exit code is unreliable — surface any "Error:" line as
    # a wrapper-level failure so callers (agents, scripts) see nonzero.
    local out rc
    out="$(mods_nma_invoke protocol-invoke -u "$url" 2>&1)"; rc=$?
    printf '%s\n' "$out"
    if [[ $rc -ne 0 ]] || printf '%s' "$out" | grep -q '^Error:\|^An error occurred'; then
        perr "protocol-invoke reported an error (see output above)."
        return 1
    fi
    pok "Dispatched to NMA."
}

# Generic escape hatch: forward whatever args to `NexusModsApp as-main`
# for subcommands PowOS hasn't wrapped yet (heartbeat, extract-archive,
# datamodel, etc.). AI can use this to hit anything the app CLI exposes.
mods_raw_cmd() {
    POWOS_MODS_LAST_VERB="raw"
    mods_nma_asmain "$@"
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
        mod-organizer-2)
            source "$(dirname "${BASH_SOURCE[0]}")/modlist.sh"
            mo2_install ;;
    esac
}

mods_uninstall_cmd() {
    local tool="${1:-}"
    if [[ -z "$tool" ]]; then perr "Usage: powos mods uninstall <tool>"; return 1; fi
    local canonical
    canonical="$(mods_normalize_name "$tool")" \
        || { perr "Unknown mod manager: $tool"; return 1; }

    # Vortex has a Bottles bottle + wrapper + two .desktop files + icon +
    # state dir + nxm:// handler override. Let its own uninstall clean
    # everything atomically rather than the generic remove-two-files path.
    if [[ "$canonical" == "vortex" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/vortex.sh"
        vortex_uninstall_cmd
        return $?
    fi

    # MO2 has a wrapper + desktop entry + install dir + Wine prefix — let its
    # own uninstall clean everything rather than the generic two-file path.
    if [[ "$canonical" == "mod-organizer-2" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/modlist.sh"
        mo2_uninstall
        return $?
    fi

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

Mod-manager lifecycle:
  powos mods install <tool>       Install a mod manager
  powos mods uninstall <tool>     Remove
  powos mods installed            List installed managers
  powos mods launch <tool>        Launch (also available from KDE menu)
  powos mods setup <game>         One-shot fix a Steam game for modding
                                    (installs protontricks, winetricks
                                    packages, sets WINEDLLOVERRIDES).
                                    Requires Steam to be closed.

Nexus Mods App CLI (headless mod management — needs nexus-mods-app installed):
  powos mods auth [api-key]       Log in. With key = save it. Without = OAuth.
  powos mods logout               Log out.
  powos mods games                List detected games in NMA.
  powos mods install-collection <slug>
                                  Install a whole Nexus collection headlessly.
                                  Slug is from www.nexusmods.com/<game>/collections/<slug>.
                                  Requires NMA GUI to be closed.
  powos mods install-mod <game> <mod-id> [file-id]
                                  Install a single mod via nxm:// URL. Works
                                  whether GUI is running or not. Game can be
                                  a short name (cyberpunk, skyrimse, bg3, …)
                                  or a Nexus slug.
  powos mods tools <game>         List tools registered for a game.
  powos mods run-tool <game> <tool>
                                  Run a game tool via NMA.
  powos mods raw <args...>        Forward raw args to \`NexusModsApp as-main\`
                                  for any subcommand PowOS hasn't wrapped.

Note: GUI-auth persists to NMA's data model. Log in once via the GUI, all
subsequent CLI commands see the same session — no re-auth needed.

Automated modlists — Genesis, Fallout London, Tale of Two Wastelands, Tuxborn…
(the whole-list-in-one-command path; native engine + Steam+Proton, no Bottles):
  powos mods modlist status               Is the toolchain ready?
  powos mods modlist search [game]        Browse installable Wabbajack lists
  powos mods modlist install <ref>        Install a list (.wabbajack | URL |
                                            Author/Name | name). Lays down MO2
                                            and wires up the Steam+Proton launcher.
  powos mods modlist list                 Lists installed on this machine
  powos mods modlist help                 Full modlist verb list

Vortex CLI (Bethesda / everything NMA doesn't yet support):
  powos mods vortex install               Install Vortex into a Bottles bottle
  powos mods vortex url <nxm://...>       Download + install a mod
  powos mods vortex bulk <game> <ids...>  Bulk from Nexus mod-ids
  powos mods vortex health-check          Verify install
  powos mods vortex help                  Full Vortex verb list

ASI-loader stack for RAGE games (GTA V / RDR2 — off-Nexus loaders + .asi plugins):
  powos mods asi install-loader <game>    Fetch + arch-verify Ultimate ASI Loader
  powos mods asi add <game> <ref>         Install an .asi (github/nexus/url), verified
  powos mods asi list <game>              Show the managed ASI stack
  powos mods asi check <game>             Health/staleness check (reads plugin logs)
  powos mods asi help                     Full ASI verb list

Known tools:
  ${BOLD}nexus-mods-app${NC}   Nexus's native-Linux cross-platform manager
                   (recommended for Cyberpunk 2077 on Linux). Aliases:
                   ${DIM}nexus${NC}, ${DIM}nma${NC}.
  ${BOLD}vortex${NC}           Nexus's Vortex, headless via Bottles Flatpak.
                   Handles every Nexus-tracked game NMA doesn't (Skyrim
                   SE/AE, Fallout 4, Starfield, BG3, Witcher 3, Bethesda
                   classics, …). Has a real CLI: 'vortex -i <nxm://…>'.
                   See:  powos mods vortex help
  ${BOLD}mod-organizer-2${NC}  MO2 (portable) under GE-Proton — no Bottles. For
                   manual modlists. Aliases: ${DIM}mo2${NC}. For automated
                   Wabbajack lists use 'powos mods modlist' instead.

Note: Steam Workshop is built into Steam itself — no install needed. Subscribe
to any workshop item and Steam auto-manages the mod for that game.

Examples:
  powos mods install nexus-mods-app
  powos mods launch nexus
  powos mods installed
EOF
}
