#!/bin/bash
# vu.sh - Venice Unleashed (Battlefield 3) client + dedicated server
#
# VU is a third-party BF3 client ("BF3: Reality Mod" and friends run on it) —
# a game client plus a modding framework (VEXT), not a Nexus mod. It lives
# under `powos mods` rather than `powos games` because it is a Windows app in
# a Wine prefix, exactly like the Vortex and MO2 installs next door.
# `powos games` is the DISK subsystem (POWOS-GAMES partition, Steam library
# wiring, resize) and knows nothing about prefixes.
#
# Runtime: GE-Proton in a dedicated prefix, reusing the same mechanism as MO2
# (modlist_install_ge_proton + $MODLIST_COMPAT_DIR). No Bottles, no Steam
# shortcut required.
#
# THE WEBUI RUNTIME GOTCHA — this is the whole reason this module exists:
# VU's current WebUI (Coherent Gameface: cohtml + v8 + vu-core) needs TWO
# native pieces in the prefix, and Wine's built-ins are not enough:
#   1. d3dcompiler_47   — for shader compilation. Missing → black/blank UI.
#   2. vcrun2022 (the VC++ 2015-2022 runtime: msvcp140/vcruntime140/…) — vu.com
#      and vu-core are built against MSVC; without a complete matching runtime
#      the launcher NULL-derefs inside msvcp140 the instant it starts and dies
#      with NO window at all (page fault c0000005 at msvcp140+0x15413). Wine
#      ships a partial set, which is worse than nothing: it loads, then crashes.
# Both failure modes are silent (no error dialog), so they read as "VU is broken
# on Linux". It is not — it has been fixable since 2022. `vu install` installs
# both via winetricks; `vu d3dcompiler` re-does them on its own.
#
# Ports a dedicated server needs open (from the VU hosting docs):
#   7948/udp   Monitored Harmony networking
#   25200/udp  Frostbite networking
#   47200/tcp  RCON
#
# Docs: https://docs.veniceunleashed.net/
#
# Entry point: cmd_mods_vu "$@"   (called from lib/mods/install.sh dispatcher)
#
# NOTE: sourced into bin/powos — must NOT set -e/-u/pipefail at top level.

source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}/common.sh" 2>/dev/null || {
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
    plog()  { echo -e "${CYAN}[vu]${NC} $*"; }
    pok()   { echo -e "${GREEN}[vu]${NC} $*"; }
    pwarn() { echo -e "${YELLOW}[vu]${NC} $*"; }
    perr()  { echo -e "${RED}[vu]${NC} $*" >&2; }
}
POWOS_TAG=vu

# This module's own directory — vu-rcon.py (the Frostbite RCON client) ships
# right beside it, in both the installed image and a source checkout.
VU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Paths ─────────────────────────────────────────────────────────────────────

VU_ROOT="${VU_ROOT:-$HOME/Games/VeniceUnleashed}"
VU_CLIENT_DIR="${VU_CLIENT_DIR:-$VU_ROOT/client}"
VU_INSTANCE_DIR="${VU_INSTANCE_DIR:-$VU_ROOT/instance}"
VU_PREFIX="${VU_PREFIX:-$VU_ROOT/prefix}"
VU_WRAPPER="${VU_WRAPPER:-$HOME/.local/bin/venice-unleashed}"
VU_DESKTOP="${VU_DESKTOP:-$HOME/.local/share/applications/venice-unleashed.desktop}"
VU_CONF="${VU_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/powos/vu.conf}"

VU_ZIP_URL="${VU_ZIP_URL:-https://veniceunleashed.net/files/vu.zip}"

# Server mods live in <instance>/Admin/Mods/<name>/ (each a folder with a
# mod.json) and are only LOADED when their folder name is listed in
# <instance>/Admin/ModList.txt — placing files is not enough. See
# https://docs.veniceunleashed.net/hosting/mods/
VU_MODS_DIR="${VU_MODS_DIR:-$VU_INSTANCE_DIR/Admin/Mods}"
VU_MODLIST="${VU_MODLIST:-$VU_INSTANCE_DIR/Admin/ModList.txt}"
# Captured server console (VeniceEXT logs, Lua errors). VU renders its console
# via wine's terminal backend, so `vu server start` records it through a PTY
# (`script`) into this file — readable/tailable by the dev loop and `powos ai`.
VU_SERVER_LOG="${VU_SERVER_LOG:-$VU_INSTANCE_DIR/logs/server.log}"
# Cached vumm-cli binary (optional path — only used for vumm:<name> sources).
VU_VUMM_BIN="${VU_VUMM_BIN:-${XDG_CACHE_HOME:-$HOME/.cache}/powos/vumm}"
VU_VUMM_VERSION="${VU_VUMM_VERSION:-v0.2.1}"

# RCON — the running dedicated server speaks the Frostbite protocol on
# 47200/tcp. vu-rcon.py does the salted-hash login and packet framing.
VU_RCON_PY="${VU_RCON_PY:-$VU_LIB_DIR/vu-rcon.py}"
VU_RCON_HOST="${VU_RCON_HOST:-127.0.0.1}"
VU_RCON_PORT="${VU_RCON_PORT:-47200}"
# The VEXT server-wide hot-reload command (reloads every extension in ModList).
VU_RELOAD_CMD="${VU_RELOAD_CMD:-modList.ReloadExtensions}"

# vuicc — VU's WebUI compiler that packs a built WebUI (dist/) into ui.vuic, the
# container VU serves. It ships only as a Windows .exe, so PowOS runs it under
# GE-Proton wine. Cached once from VU's file host.
VU_VUICC_URL="${VU_VUICC_URL:-https://veniceunleashed.net/files/vuicc.exe}"
VU_VUICC_BIN="${VU_VUICC_BIN:-${XDG_CACHE_HOME:-$HOME/.cache}/powos/vuicc.exe}"

# ── Config (key=value, parsed without eval) ───────────────────────────────────

vu_conf_get() {
    local key="$1"
    [[ -f "$VU_CONF" ]] || return 1
    local line
    line="$(grep -m1 "^${key}=" "$VU_CONF" 2>/dev/null)" || return 1
    printf '%s' "${line#*=}"
}

vu_conf_set() {
    local key="$1" val="$2"
    mkdir -p "$(dirname "$VU_CONF")"
    touch "$VU_CONF"
    if grep -q "^${key}=" "$VU_CONF" 2>/dev/null; then
        # No sed -i on the live file with an unescaped value — rewrite instead.
        local tmp; tmp="$(mktemp)"
        grep -v "^${key}=" "$VU_CONF" > "$tmp"
        printf '%s=%s\n' "$key" "$val" >> "$tmp"
        mv "$tmp" "$VU_CONF"
    else
        printf '%s=%s\n' "$key" "$val" >> "$VU_CONF"
    fi
}

# ── Runtime resolution ────────────────────────────────────────────────────────

# Newest GE-Proton directory, or empty.
vu_proton_dir() {
    local compat="${MODLIST_COMPAT_DIR:-$HOME/.steam/root/compatibilitytools.d}"
    find "$compat" -maxdepth 1 -type d -name 'GE-Proton*' 2>/dev/null | sort -V | tail -1
}

vu_proton() {
    local d; d="$(vu_proton_dir)"
    [[ -n "$d" && -x "$d/proton" ]] && printf '%s' "$d/proton"
}

# GE-Proton bundles a wine binary — winetricks needs it to touch the prefix
# directly (protontricks only addresses Steam appids, and VU is not one).
vu_wine() {
    local d; d="$(vu_proton_dir)"
    [[ -n "$d" && -x "$d/files/bin/wine" ]] && printf '%s' "$d/files/bin/wine"
}

vu_wineprefix() { printf '%s' "$VU_PREFIX/pfx"; }

# ── Prefix choice: VU's own prefix vs BF3's Steam prefix (vu-proton style) ─────
# Default: VU runs in its OWN GE-Proton prefix ($VU_ROOT/prefix). But BF3 owned
# on Steam activates THROUGH Steam — no separate EA sign-in — and that
# activation plus the game's DXVK state live in Steam's own Proton prefix.
# Opting to reuse it (`vu install --steam-prefix`, persisted in vu.conf; or
# VU_STEAM_PREFIX=1) repoints VU at that already-activated prefix, and
# d3dcompiler_47 then lands there — the reliable path the vu-proton project
# documents (github.com/VileEnd/vu-proton).

# BF3's Steam appid, read from the appmanifest beside the gamepath (1238820 fb).
vu_bf3_appid() {
    local bf3 steamapps mf appid
    bf3="$(vu_detect_bf3 2>/dev/null)"      || { printf '1238820'; return 0; }
    steamapps="$(cd "$bf3/../.." 2>/dev/null && pwd)" || { printf '1238820'; return 0; }
    for mf in "$steamapps"/appmanifest_*.acf; do
        [[ -f "$mf" ]] || continue
        grep -qi '"installdir"[[:space:]]*"Battlefield 3"' "$mf" || continue
        appid="$(grep -oE '"appid"[[:space:]]*"[0-9]+"' "$mf" | grep -oE '[0-9]+' | head -1)"
        [[ -n "$appid" ]] && { printf '%s' "$appid"; return 0; }
    done
    printf '1238820'
}

# Path to BF3's Steam Proton prefix (steamapps/compatdata/<appid>), or empty.
vu_steam_prefix() {
    local bf3 steamapps
    bf3="$(vu_detect_bf3 2>/dev/null)"      || return 1
    steamapps="$(cd "$bf3/../.." 2>/dev/null && pwd)" || return 1
    printf '%s/compatdata/%s' "$steamapps" "$(vu_bf3_appid)"
}

# Repoint VU_PREFIX at BF3's Steam prefix when opted in. Idempotent — call at the
# top of install/play/server before VU_PREFIX is used.
vu_apply_prefix_choice() {
    local mode="${VU_STEAM_PREFIX:-$(vu_conf_get prefix 2>/dev/null || true)}"
    case "$mode" in
        steam|1)
            local sp; sp="$(vu_steam_prefix 2>/dev/null || true)"
            if [[ -n "$sp" ]]; then
                VU_PREFIX="$sp"
                plog "Using BF3's Steam prefix: ${DIM}$VU_PREFIX${NC}"
            else
                pwarn "--steam-prefix set but BF3's Steam prefix not found; using VU's own prefix."
            fi
            ;;
    esac
}

vu_installed() { [[ -f "$VU_CLIENT_DIR/vu.com" || -f "$VU_CLIENT_DIR/vu.exe" ]]; }

# Is the NATIVE d3dcompiler_47 in the prefix? Wine's builtin stub lives in the
# same place, so presence alone is not proof — but winetricks records what it
# installed, and that log IS authoritative.
vu_has_d3dcompiler() {
    local log; log="$(vu_wineprefix)/winetricks.log"
    [[ -f "$log" ]] && grep -qx 'd3dcompiler_47' "$log"
}

# The VC++ 2015-2022 runtime (vcrun2022). vu.com / vu-core NULL-deref inside
# msvcp140 on startup without a complete matching runtime — a hard crash with
# no window, distinct from the blank-UI d3dcompiler failure. winetricks records
# it; that log is authoritative.
vu_has_vcrun() {
    local log; log="$(vu_wineprefix)/winetricks.log"
    [[ -f "$log" ]] && grep -qx 'vcrun2022' "$log"
}

# ── BF3 discovery ─────────────────────────────────────────────────────────────

# VU needs the BF3 game files (the user owns them via Origin/EA). Look in the
# usual places, then fall back to whatever the user configured.
vu_detect_bf3() {
    local configured; configured="$(vu_conf_get gamepath 2>/dev/null || true)"
    if [[ -n "$configured" && -d "$configured" ]]; then
        printf '%s' "$configured"; return 0
    fi

    local c
    for c in \
        "$HOME/Games/Battlefield 3" \
        "$HOME/.local/share/Steam/steamapps/common/Battlefield 3" \
        "/var/mnt/games/Battlefield 3" \
        "$HOME/Games/EABattlefield3/drive_c/Program Files (x86)/Origin Games/Battlefield 3"
    do
        [[ -f "$c/bf3.exe" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# ── Status ────────────────────────────────────────────────────────────────────

vu_status_cmd() {
    echo -e "${BOLD}Venice Unleashed${NC}"
    echo    "════════════════════════════════════════"

    local mark_ok="${GREEN}●${NC}" mark_no="${RED}○${NC}" mark_warn="${YELLOW}◐${NC}"

    # Client
    if vu_installed; then
        echo -e "  Client:        $mark_ok installed  ${DIM}$VU_CLIENT_DIR${NC}"
    else
        echo -e "  Client:        $mark_no not installed  ${DIM}(powos mods vu install)${NC}"
    fi

    # BF3
    local bf3; bf3="$(vu_detect_bf3 || true)"
    if [[ -n "$bf3" ]]; then
        echo -e "  BF3 gamepath:  $mark_ok $bf3"
    else
        echo -e "  BF3 gamepath:  $mark_no not found  ${DIM}(powos mods vu install --gamepath DIR)${NC}"
    fi

    # Runtime
    if [[ -n "$(vu_proton)" ]]; then
        echo -e "  Runtime:       $mark_ok $(basename "$(vu_proton_dir)")"
    else
        echo -e "  Runtime:       $mark_no no GE-Proton  ${DIM}(powos mods modlist proton)${NC}"
    fi

    # The gotcha — both WebUI runtime pieces
    if [[ ! -d "$(vu_wineprefix)" ]]; then
        echo -e "  d3dcompiler:   $mark_no prefix not created yet"
        echo -e "  vcrun2022:     $mark_no prefix not created yet"
    else
        if vu_has_d3dcompiler; then
            echo -e "  d3dcompiler:   $mark_ok native d3dcompiler_47 present"
        else
            echo -e "  d3dcompiler:   $mark_warn MISSING — WebUI will render blank"
            echo -e "                 ${DIM}powos mods vu d3dcompiler${NC}"
        fi
        if vu_has_vcrun; then
            echo -e "  vcrun2022:     $mark_ok VC++ 2015-2022 runtime present"
        else
            echo -e "  vcrun2022:     $mark_warn MISSING — launcher crashes on startup (msvcp140)"
            echo -e "                 ${DIM}powos mods vu d3dcompiler${NC}"
        fi
    fi

    # Branch
    local branch; branch="$(vu_conf_get branch 2>/dev/null || true)"
    echo -e "  Branch:        ${branch:-prod}"

    # Server instance
    if [[ -f "$VU_INSTANCE_DIR/server.key" ]]; then
        echo -e "  Server key:    $mark_ok $VU_INSTANCE_DIR/server.key"
    else
        echo -e "  Server key:    ${DIM}absent (client-only install)${NC}"
    fi
    echo
}

# ── Install ───────────────────────────────────────────────────────────────────

vu_fetch_client() {
    if vu_installed; then
        pok "VU client already present at $VU_CLIENT_DIR."
        return 0
    fi
    command -v unzip >/dev/null || { perr "unzip is required."; return 1; }

    mkdir -p "$VU_CLIENT_DIR"
    local tmp; tmp="$(mktemp -d)"
    plog "Downloading VU client…"
    if ! curl -fL -sS "$VU_ZIP_URL" -o "$tmp/vu.zip"; then
        perr "Download failed: $VU_ZIP_URL"; rm -rf "$tmp"; return 1
    fi
    plog "Extracting to $VU_CLIENT_DIR…"
    if ! unzip -q -o "$tmp/vu.zip" -d "$VU_CLIENT_DIR"; then
        perr "Extraction failed."; rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    vu_installed || { perr "vu.com/vu.exe missing after extract."; return 1; }
    pok "VU client extracted."
}

# Install the native d3dcompiler_47 into VU's prefix. Separate verb because
# a VU update or a prefix reset silently loses it and the symptom (blank UI)
# does not point at the cause.
vu_d3dcompiler_cmd() {
    local wine; wine="$(vu_wine || true)"
    [[ -z "$wine" ]] && {
        perr "No GE-Proton wine binary found."
        plog "Install it first: ${BOLD}powos mods modlist proton${NC}"
        return 1
    }
    command -v winetricks >/dev/null || {
        perr "winetricks not found on PATH."
        plog "Bazzite ships it; otherwise install winetricks and re-run."
        return 1
    }

    mkdir -p "$(vu_wineprefix)"

    # The WebUI needs BOTH: d3dcompiler_47 (shaders) and the full VC++ 2015-2022
    # runtime (vcrun2022). Skip whichever is already recorded so re-runs are cheap.
    local -a want=()
    vu_has_d3dcompiler || want+=( d3dcompiler_47 )
    vu_has_vcrun       || want+=( vcrun2022 )
    if [[ ${#want[@]} -eq 0 ]]; then
        pok "WebUI runtime already present (d3dcompiler_47 + vcrun2022)."
        return 0
    fi

    plog "Installing VU WebUI runtime into the prefix: ${want[*]} (may take a minute)…"
    if ! WINEPREFIX="$(vu_wineprefix)" WINE="$wine" WINESERVER="$(dirname "$wine")/wineserver" \
            winetricks -q "${want[@]}"; then
        perr "winetricks failed installing: ${want[*]}"
        plog "Without these VU's WebUI renders blank or crashes on startup — not optional."
        return 1
    fi
    pok "VU WebUI runtime installed (d3dcompiler_47 + vcrun2022)."
}

vu_install_cmd() {
    local gamepath="" branch="" prefix_choice=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gamepath)     gamepath="${2:-}"; shift 2 ;;
            --branch)       branch="${2:-}";   shift 2 ;;
            --steam-prefix) prefix_choice="steam"; shift ;;
            --own-prefix)   prefix_choice="own";   shift ;;
            -h|--help)      vu_help; return 0 ;;
            *) perr "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -n "$gamepath" ]]; then
        [[ -d "$gamepath" ]] || { perr "No such directory: $gamepath"; return 1; }
        [[ -f "$gamepath/bf3.exe" ]] \
            || pwarn "$gamepath has no bf3.exe — VU will refuse to launch if this isn't the BF3 install."
        vu_conf_set gamepath "$gamepath"
    fi
    if [[ -n "$branch" ]]; then
        case "$branch" in
            prod|dev) vu_conf_set branch "$branch" ;;
            *) perr "--branch must be 'prod' or 'dev'."; return 1 ;;
        esac
    fi
    [[ -n "$prefix_choice" ]] && vu_conf_set prefix "$prefix_choice"

    # Honour the prefix choice BEFORE touching the prefix (d3dcompiler must land
    # in whichever prefix VU will actually launch in).
    vu_apply_prefix_choice

    vu_fetch_client || return 1

    # Runtime, then the DLL that everyone trips over.
    if [[ -z "$(vu_proton)" ]]; then
        if declare -f modlist_install_ge_proton >/dev/null; then
            modlist_install_ge_proton "${MODLIST_GE_PROTON_TAG:-latest}" \
                || pwarn "GE-Proton install failed — VU can't launch until it's present."
        else
            pwarn "No GE-Proton. Run: powos mods modlist proton"
        fi
    fi
    if ! vu_has_d3dcompiler || ! vu_has_vcrun; then
        vu_d3dcompiler_cmd || \
            pwarn "Continuing, but VU's WebUI will be blank or crash until the runtime lands."
    fi

    mkdir -p "$VU_INSTANCE_DIR"
    vu_write_wrapper
    vu_write_desktop

    pok "Venice Unleashed installed."
    echo
    plog "Next:"
    local n=1
    if [[ -z "$(vu_detect_bf3 || true)" ]]; then
        plog "  $((n++)). Point VU at your BF3 files:  ${BOLD}powos mods vu install --gamepath /path/to/bf3${NC}"
    fi
    plog "  $((n++)). Activate BF3 with your EA account:  ${BOLD}powos mods vu activate${NC}"
    plog "  $((n++)). Play:  ${BOLD}powos mods vu play${NC}   ${DIM}(or the KDE menu entry)${NC}"
}

# ── Launcher ──────────────────────────────────────────────────────────────────

vu_write_wrapper() {
    mkdir -p "$(dirname "$VU_WRAPPER")"
    cat > "$VU_WRAPPER" <<EOF
#!/bin/bash
# powos: Venice Unleashed launcher — runs vu.com under GE-Proton (no Bottles).
set -uo pipefail
VU_CLIENT_DIR="${VU_CLIENT_DIR}"
VU_PREFIX="${VU_PREFIX}"
VU_CONF="${VU_CONF}"
COMPAT="${MODLIST_COMPAT_DIR:-$HOME/.steam/root/compatibilitytools.d}"
EOF
    cat >> "$VU_WRAPPER" <<'EOF'
PROTON="$(find "$COMPAT" -maxdepth 1 -type d -name 'GE-Proton*' 2>/dev/null | sort -V | tail -1)/proton"
if [[ ! -x "$PROTON" ]]; then
    echo "venice-unleashed: no GE-Proton in $COMPAT. Run: powos mods modlist proton" >&2
    exit 1
fi

conf_get() { [[ -f "$VU_CONF" ]] && sed -n "s/^$1=//p" "$VU_CONF" | head -1; }
GAMEPATH="$(conf_get gamepath)"
BRANCH="$(conf_get branch)"

if [[ -z "$GAMEPATH" ]]; then
    echo "venice-unleashed: no BF3 gamepath configured." >&2
    echo "  powos mods vu install --gamepath /path/to/bf3" >&2
    exit 1
fi

args=( -gamepath "$GAMEPATH" )
if [[ "$BRANCH" == "dev" ]]; then
    args+=( -env dev -updateBranch dev )
fi

mkdir -p "$VU_PREFIX"
export STEAM_COMPAT_DATA_PATH="$VU_PREFIX"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.steam/steam}"

exec "$PROTON" run "$VU_CLIENT_DIR/vu.com" "${args[@]}" "$@"
EOF
    chmod +x "$VU_WRAPPER"
    case ":$PATH:" in
        *:"$(dirname "$VU_WRAPPER")":*) : ;;
        *) pwarn "  Add $(dirname "$VU_WRAPPER") to PATH to run 'venice-unleashed' directly." ;;
    esac
}

# VU ships no icon file, but vu.exe carries the VU logo as an embedded PE icon
# resource. Extract it (needs icoutils: wrestool + icotool) and install it into
# the hicolor theme as 'venice-unleashed' so the menu entry shows the logo
# instead of a generic controller. Idempotent; silently returns non-zero if the
# tools or the exe are absent, in which case the caller keeps the generic icon.
VU_ICON_NAME="${VU_ICON_NAME:-venice-unleashed}"
vu_icon_theme_dir() { printf '%s/icons/hicolor' "${XDG_DATA_HOME:-$HOME/.local/share}"; }

vu_install_icon() {
    local base; base="$(vu_icon_theme_dir)"
    [[ -f "$base/128x128/apps/$VU_ICON_NAME.png" ]] && return 0   # already done
    local exe="$VU_CLIENT_DIR/vu.exe"
    [[ -f "$exe" ]] || return 1
    command -v wrestool >/dev/null && command -v icotool >/dev/null || return 1

    local tmp; tmp="$(mktemp -d)" || return 1
    if ! wrestool -x -t 14 -o "$tmp/vu.ico" "$exe" 2>/dev/null || [[ ! -s "$tmp/vu.ico" ]]; then
        rm -rf "$tmp"; return 1
    fi
    ( cd "$tmp" && icotool -x vu.ico ) 2>/dev/null || { rm -rf "$tmp"; return 1; }

    local installed=0 png w
    for png in "$tmp"/*.png; do
        [[ -f "$png" ]] || continue
        # icotool names files <base>_<idx>_<w>x<h>x<depth>.png — derive the size.
        w="$(printf '%s' "$png" | sed -n 's/.*_\([0-9]\+\)x[0-9]\+x[0-9]\+\.png$/\1/p')"
        [[ -n "$w" ]] || continue
        mkdir -p "$base/${w}x${w}/apps"
        cp "$png" "$base/${w}x${w}/apps/$VU_ICON_NAME.png" && installed=1
    done
    rm -rf "$tmp"
    [[ $installed -eq 1 ]] || return 1

    gtk-update-icon-cache -f -t "$base" 2>/dev/null || touch "$base" 2>/dev/null
    return 0
}

# On KDE/KWin, a Proton app's window carries the GENERIC WM_CLASS "steam_proton",
# so the Task Manager can't map the running window back to this .desktop and
# draws a blank taskbar icon. A KWin rule matched on VU's window TITLE (so it
# only ever touches VU, never other Proton apps that share the class) forces the
# window to associate with the venice-unleashed desktop file — giving the running
# window the VU logo. Idempotent; KDE-only (no-op without kwriteconfig6).
vu_install_kwin_rule() {
    command -v kwriteconfig6 >/dev/null || return 1
    local rc="${XDG_CONFIG_HOME:-$HOME/.config}/kwinrulesrc"
    grep -q "^desktopfile=$VU_ICON_NAME\$" "$rc" 2>/dev/null && return 0   # already present
    local uuid
    uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || uuid="$(uuidgen 2>/dev/null)" || return 1
    local cur newlist
    cur="$(kreadconfig6 --file kwinrulesrc --group General --key rules 2>/dev/null)"
    [[ -n "$cur" ]] && newlist="$cur,$uuid" || newlist="$uuid"
    kwriteconfig6 --file kwinrulesrc --group General --key rules "$newlist"
    kwriteconfig6 --file kwinrulesrc --group "$uuid" --key Description "Venice Unleashed taskbar icon (PowOS)"
    kwriteconfig6 --file kwinrulesrc --group "$uuid" --key wmclass "steam_proton"
    kwriteconfig6 --file kwinrulesrc --group "$uuid" --key wmclassmatch 1
    kwriteconfig6 --file kwinrulesrc --group "$uuid" --key title 'Venice Unleashed|vu\.com'
    kwriteconfig6 --file kwinrulesrc --group "$uuid" --key titlematch 3
    kwriteconfig6 --file kwinrulesrc --group "$uuid" --key desktopfile "$VU_ICON_NAME"
    kwriteconfig6 --file kwinrulesrc --group "$uuid" --key desktopfilerule 2
    qdbus org.kde.KWin /KWin reconfigure 2>/dev/null \
        || dbus-send --type=method_call --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null \
        || true
    return 0
}

vu_write_desktop() {
    mkdir -p "$(dirname "$VU_DESKTOP")"
    local icon="applications-games"
    vu_install_icon && icon="$VU_ICON_NAME"
    cat > "$VU_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Venice Unleashed
Comment=Battlefield 3 community client and modding framework
Exec=$VU_WRAPPER
Icon=$icon
Terminal=false
Categories=Game;ActionGame;
Keywords=battlefield;bf3;vu;venice;
EOF
    update-desktop-database "$(dirname "$VU_DESKTOP")" 2>/dev/null || true
    # KDE: the running window shares the generic steam_proton class — give it the
    # VU icon via a title-matched KWin rule (only when we actually installed one).
    if [[ "$icon" == "$VU_ICON_NAME" ]]; then vu_install_kwin_rule || true; fi
}

# ── Activate / play ───────────────────────────────────────────────────────────

vu_activate_cmd() {
    local token=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token) token="${2:-}"; shift 2 ;;
            -h|--help) vu_help; return 0 ;;
            *) perr "Unknown option: $1"; return 1 ;;
        esac
    done

    vu_installed || { perr "VU not installed. Run: powos mods vu install"; return 1; }
    local proton; proton="$(vu_proton || true)"
    [[ -z "$proton" ]] && { perr "No GE-Proton. Run: powos mods modlist proton"; return 1; }
    local bf3; bf3="$(vu_detect_bf3 || true)"
    [[ -z "$bf3" ]] && {
        perr "No BF3 gamepath configured."
        plog "  powos mods vu install --gamepath /path/to/bf3"
        return 1
    }

    # -lsx talks to a running EA app; -ea_token is the headless path (and the
    # only one that works on a server with no desktop session).
    local -a args=( -gamepath "$bf3" -activate )
    if [[ -n "$token" ]]; then
        args+=( -ea_token "$token" )
        plog "Activating BF3 with the supplied EA token…"
    else
        args+=( -lsx )
        plog "Activating BF3 via the EA app (must be running and logged in)…"
        plog "  ${DIM}Headless/server? Use: powos mods vu activate --token <ea_token>${NC}"
    fi

    mkdir -p "$VU_PREFIX"
    STEAM_COMPAT_DATA_PATH="$VU_PREFIX" \
    STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.steam/steam}" \
        "$proton" run "$VU_CLIENT_DIR/vu.com" "${args[@]}"
}

vu_play_cmd() {
    vu_installed || { perr "VU not installed. Run: powos mods vu install"; return 1; }
    vu_apply_prefix_choice
    vu_write_wrapper   # rewrite so the launcher reflects the current prefix choice
    if ! vu_has_d3dcompiler || ! vu_has_vcrun; then
        vu_has_d3dcompiler || pwarn "Native d3dcompiler_47 is missing — expect a blank WebUI."
        vu_has_vcrun       || pwarn "VC++ 2015-2022 runtime (vcrun2022) is missing — launcher will crash on startup."
        pwarn "Fix: ${BOLD}powos mods vu d3dcompiler${NC}"
    fi
    exec "$VU_WRAPPER" "$@"
}

vu_branch_cmd() {
    local branch="${1:-}"
    if [[ -z "$branch" ]]; then
        local cur; cur="$(vu_conf_get branch 2>/dev/null || true)"
        echo "${cur:-prod}"
        return 0
    fi
    case "$branch" in
        prod|dev) ;;
        *) perr "Branch must be 'prod' or 'dev'."; return 1 ;;
    esac
    vu_conf_set branch "$branch"
    pok "VU branch set to '$branch'."
}

# ── Dedicated server ──────────────────────────────────────────────────────────

vu_server_help() {
    cat <<EOF
${BOLD}powos mods vu server${NC} — VU dedicated server

  powos mods vu server init           Create the instance dir + scaffold config
  powos mods vu server start [args]   Run the dedicated server (headless)
  powos mods vu server status         Instance dir, key, config, port reachability

Mods for the server: ${BOLD}powos mods vu mod${NC} (install/list/enable/…).

The instance directory (${VU_INSTANCE_DIR}) holds server.key, config and mods.
Get server.key from your VU account, drop it in that directory. 'init' also
writes ${BOLD}Admin/Startup.txt${NC} (server name + RCON password) and
${BOLD}Admin/MapList.txt${NC} (map rotation) — edit those to taste; they are
never overwritten once they exist.

'start' runs with ${BOLD}-server -dedicated -headless${NC} so no window is
created (the docs' default '-dedicated' alone still opens a server GUI window).

Ports to forward:
  7948/udp   Monitored Harmony networking
  25200/udp  Frostbite networking
  47200/tcp  RCON

Useful passthrough args: -high60 | -high120 (tick rate),
-maxPlayers N, -unlisted, -listen host:port, -highResTerrain.
EOF
}

vu_server_status() {
    echo -e "${BOLD}VU dedicated server${NC}"
    echo    "════════════════════════════════════════"
    echo -e "  Instance:  $VU_INSTANCE_DIR"
    if [[ -f "$VU_INSTANCE_DIR/server.key" ]]; then
        echo -e "  server.key ${GREEN}●${NC} present"
    else
        echo -e "  server.key ${RED}○${NC} MISSING — the server will not start"
        echo -e "             ${DIM}get it from your VU account page${NC}"
    fi
    local bf3; bf3="$(vu_detect_bf3 || true)"
    echo -e "  gamepath:  ${bf3:-${RED}not configured${NC}}"
    if [[ -f "$VU_INSTANCE_DIR/Admin/Startup.txt" && -f "$VU_INSTANCE_DIR/Admin/MapList.txt" ]]; then
        local maps; maps="$(grep -cvE '^\s*$' "$VU_INSTANCE_DIR/Admin/MapList.txt" 2>/dev/null)"
        echo -e "  config:    ${GREEN}●${NC} Startup.txt + MapList.txt (${maps:-0} maps)"
    else
        echo -e "  config:    ${YELLOW}○${NC} missing — run ${BOLD}powos mods vu server init${NC}"
    fi
    echo
    echo -e "  ${DIM}Ports: 7948/udp harmony · 25200/udp frostbite · 47200/tcp rcon${NC}"
    echo
}

vu_server_init() {
    local admin="$VU_INSTANCE_DIR/Admin"
    mkdir -p "$admin/Mods" "$VU_INSTANCE_DIR/logs" || return 1
    pok "Instance directory ready: $VU_INSTANCE_DIR"

    # The server won't host a real match without its Admin config: MapList.txt
    # (map rotation), Startup.txt (server name + RCON password + vars), and an
    # (optionally empty) ModList.txt. Scaffold sane defaults, but NEVER clobber
    # files the user has already edited.
    if [[ ! -f "$admin/Startup.txt" ]]; then
        local rcon
        rcon="$(openssl rand -hex 8 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 16)"
        [[ -n "$rcon" ]] || rcon="changeme-$$"
        cat > "$admin/Startup.txt" <<EOF
vars.serverName "PowOS Venice Unleashed"
vars.maxPlayers 64
vars.friendlyFire false
vars.autoBalance true
vars.roundStartPlayerCount 1
vars.roundRestartPlayerCount 1
admin.password "$rcon"
EOF
        pok "Wrote Admin/Startup.txt  ${DIM}(RCON/admin password: $rcon)${NC}"
    fi
    if [[ ! -f "$admin/MapList.txt" ]]; then
        cat > "$admin/MapList.txt" <<'EOF'
MP_001 ConquestLarge0 2
MP_003 ConquestLarge0 2
MP_007 ConquestLarge0 2
MP_011 ConquestLarge0 2
MP_012 ConquestLarge0 2
MP_013 ConquestLarge0 2
MP_017 ConquestLarge0 2
MP_018 ConquestLarge0 2
MP_Subway ConquestLarge0 2
EOF
        pok "Wrote Admin/MapList.txt  ${DIM}(base-game Conquest Large rotation)${NC}"
    fi
    [[ -f "$admin/ModList.txt" ]] || : > "$admin/ModList.txt"

    if [[ ! -f "$VU_INSTANCE_DIR/server.key" ]]; then
        plog "Now drop your ${BOLD}server.key${NC} into $VU_INSTANCE_DIR."
        plog "  ${DIM}It comes from your Venice Unleashed account page.${NC}"
    fi
    plog "Tune ${BOLD}Admin/Startup.txt${NC} / ${BOLD}Admin/MapList.txt${NC}, then:"
    plog "  ${BOLD}powos mods vu server start${NC}   ${DIM}(runs headless — no window)${NC}"
    plog "Forward 7948/udp, 25200/udp, 47200/tcp."
}

# Generate the raw-wine server launcher. Why raw wine + a PTY instead of
# `proton run`:
#   • `proton run` force-redirects the game's stdio to /dev/null — VU's console
#     (VeniceEXT logs, Lua errors) is then uncapturable.
#   • Raw GE-Proton wine inherits our stdio. And when DISPLAY is unset, wine uses
#     its TERMINAL console backend and writes to whatever fd 1 is — but only a
#     PTY makes it render inline; a plain file/pipe makes it spawn a GUI console
#     window. So `vu_server_start` runs this under `script` (a PTY recorder).
#   • Z:/ forward-slash paths: sh arg-parsing strips backslashes, so Z:\a\b
#     arrives as Zab. Z: maps to / in the prefix, and wine accepts forward slashes.
vu_write_server_launcher() {
    local wine pdir bf3 launcher branch bargs
    pdir="$(vu_proton_dir)"; wine="$(vu_wine)"; bf3="$(vu_detect_bf3)"
    launcher="$VU_INSTANCE_DIR/.powos-server-launch.sh"
    # Honour the configured branch — dev VU (and dev-branch mods like MapEditor /
    # NoHavok) need -env dev; -updateBranch dev pulls the dev binaries on launch.
    branch="$(vu_conf_get branch 2>/dev/null || true)"
    bargs=""; [[ "$branch" == "dev" ]] && bargs=" -env dev -updateBranch dev"
    cat > "$launcher" <<EOF
#!/bin/bash
# Generated by PowOS ($(date '+%F %T')). Do not edit — regenerated each start.
export WINEPREFIX="$(vu_wineprefix)"
export WINELOADER="$wine"
export WINESERVER="$pdir/files/bin/wineserver"
export LD_LIBRARY_PATH="$pdir/files/lib64:$pdir/files/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export WINEDEBUG="\${WINEDEBUG:--all}"
export WINEFSYNC=1
# No display → wine's terminal console backend (renders into our PTY, no window).
unset DISPLAY WAYLAND_DISPLAY
# Wide console so captured log lines don't wrap at 80 columns.
stty cols 1000 2>/dev/null || true
exec "$wine" "$VU_CLIENT_DIR/vu.com" \\
  -gamepath "Z:$bf3" \\
  -serverInstancePath "Z:$VU_INSTANCE_DIR" \\
  -server -dedicated -headless$bargs "\$@"
EOF
    chmod +x "$launcher"
    printf '%s' "$launcher"
}

vu_server_start() {
    vu_installed || { perr "VU not installed. Run: powos mods vu install"; return 1; }
    vu_apply_prefix_choice
    [[ -n "$(vu_wine)" ]] || { perr "No GE-Proton wine. Run: powos mods modlist proton"; return 1; }
    local bf3; bf3="$(vu_detect_bf3 || true)"
    [[ -z "$bf3" ]] && { perr "No BF3 gamepath. Run: powos mods vu install --gamepath DIR"; return 1; }
    [[ -f "$VU_INSTANCE_DIR/server.key" ]] || {
        perr "No server.key in $VU_INSTANCE_DIR."
        plog "Run ${BOLD}powos mods vu server init${NC} for the steps."
        return 1
    }
    command -v script >/dev/null || { perr "'script' (util-linux) is required to capture the server console."; return 1; }

    local launcher; launcher="$(vu_write_server_launcher)"
    mkdir -p "$(dirname "$VU_SERVER_LOG")"
    plog "Starting VU dedicated server ${DIM}(raw-wine · headless · console captured)${NC}…"
    plog "  instance: $VU_INSTANCE_DIR"
    plog "  log:      $VU_SERVER_LOG   ${DIM}(watch live: tail -f, or open in Konsole)${NC}"
    # `script` records the PTY session to VU_SERVER_LOG (overwriting last run).
    exec script -qefc "$launcher" "$VU_SERVER_LOG"
}

vu_server_cmd() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        init)    vu_server_init ;;
        start)   vu_server_start "$@" ;;
        status)  vu_server_status ;;
        help|-h|--help) vu_server_help ;;
        *) perr "Unknown server verb: $sub"; vu_server_help; return 1 ;;
    esac
}

# ── Server mods (Admin/Mods + ModList.txt) ────────────────────────────────────
#
# A VU mod is just a folder under <instance>/Admin/Mods/ that contains a
# mod.json. VU won't LOAD it until the folder name is listed in
# <instance>/Admin/ModList.txt. So "installing" a mod is two deterministic
# steps: place the folder, then (optionally) add its name to the list.
#
# The identification rule is exact, not heuristic: a directory is a VU mod iff
# it holds a mod.json with a Name. A repo "ships multiple mods" when several
# mod.json files sit in different subfolders — we surface ALL of them and make
# YOU choose. We never silently install every mod in a repo.

# Read the mod Name out of a mod.json (VU uses "Name"; tolerate lowercase).
vu_modjson_name() {
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print((d.get("Name") or d.get("name") or "").strip())
except Exception:
    pass' "$1" 2>/dev/null
}

# Emit "<name>\t<abs mod-folder path>" for every VU mod under a directory tree.
# maxdepth keeps us out of deep vendored trees; node_modules/.git are skipped.
vu_find_mods() {
    local root="$1" mj dir name
    [[ -d "$root" ]] || return 0
    while IFS= read -r mj; do
        dir="$(cd "$(dirname "$mj")" && pwd)"
        name="$(vu_modjson_name "$mj")"
        [[ -n "$name" ]] && printf '%s\t%s\n' "$name" "$dir"
    done < <(find "$root" -maxdepth 4 -name mod.json -type f \
                  -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | sort)
}

# ModList.txt helpers — the file is folder-names, one per line.
vu_modlist_has() {
    [[ -f "$VU_MODLIST" ]] && grep -qxF "$1" "$VU_MODLIST"
}
vu_modlist_add() {
    mkdir -p "$(dirname "$VU_MODLIST")"; touch "$VU_MODLIST"
    vu_modlist_has "$1" || printf '%s\n' "$1" >> "$VU_MODLIST"
}
vu_modlist_remove() {
    [[ -f "$VU_MODLIST" ]] || return 0
    local tmp; tmp="$(mktemp)"
    grep -vxF "$1" "$VU_MODLIST" > "$tmp" || true
    mv "$tmp" "$VU_MODLIST"
}

# Copy one mod folder into Admin/Mods/<name>, recording where it came from so
# `update` can re-fetch it. Destination name is sanitised of path separators.
vu_place_mod() {
    local src="$1" name="$2" source_spec="${3:-}"
    name="${name//\//_}"; name="${name//[[:space:]]/_}"
    local dest="$VU_MODS_DIR/$name"
    mkdir -p "$VU_MODS_DIR"
    rm -rf "$dest"
    cp -a "$src" "$dest" || { perr "copy failed: $src -> $dest"; return 1; }
    rm -rf "$dest/.git"
    [[ -n "$source_spec" ]] && printf '%s\n' "$source_spec" > "$dest/.powos-source"
    printf '%s' "$name"
}

# Fetch a GitHub repo tarball (no git needed) into a fresh dir; echo that dir.
# Accepts owner/repo[@ref]; resolves the default branch when no ref is given.
vu_gh_fetch() {
    local spec="$1" ref="" repo
    repo="${spec%@*}"; [[ "$spec" == *@* ]] && ref="${spec##*@}"
    if [[ -z "$ref" ]]; then
        ref="$(curl -fsSL "https://api.github.com/repos/$repo" 2>/dev/null \
               | python3 -c 'import json,sys; print(json.load(sys.stdin).get("default_branch","main"))' 2>/dev/null)"
        [[ -z "$ref" ]] && ref=main
    fi
    local tmp; tmp="$(mktemp -d)"
    if ! curl -fsSL "https://codeload.github.com/$repo/tar.gz/$ref" 2>/dev/null \
            | tar xz -C "$tmp" 2>/dev/null; then
        perr "could not download github.com/$repo@$ref"
        rm -rf "$tmp"; return 1
    fi
    printf '%s' "$tmp"
}

# Ensure the vumm binary is present (download once), echo its path.
vu_vumm_bin() {
    if [[ -x "$VU_VUMM_BIN" ]]; then printf '%s' "$VU_VUMM_BIN"; return 0; fi
    local arch; arch="$(uname -m)"
    local a; case "$arch" in x86_64|amd64) a=amd64 ;; i?86) a=386 ;;
        *) perr "no vumm build for $arch"; return 1 ;; esac
    plog "Fetching vumm-cli $VU_VUMM_VERSION ($a)…" >&2
    local tmp; tmp="$(mktemp -d)"
    local url="https://github.com/BF3RM/vumm-cli/releases/download/$VU_VUMM_VERSION/vumm_linux_${a}.tar.gz"
    if ! curl -fsSL "$url" 2>/dev/null | tar xz -C "$tmp" 2>/dev/null; then
        perr "vumm download failed: $url"; rm -rf "$tmp"; return 1
    fi
    mkdir -p "$(dirname "$VU_VUMM_BIN")"
    mv "$tmp/vumm" "$VU_VUMM_BIN" && chmod +x "$VU_VUMM_BIN"
    rm -rf "$tmp"
    printf '%s' "$VU_VUMM_BIN"
}

# Resolve a source token to a local directory of candidate mods + a provenance
# string. Prints "<dir>\t<source_spec>". Caller cleans up temp dirs itself.
vu_mod_resolve_source() {
    local src="$1"
    case "$src" in
        gh:*)
            local spec="${src#gh:}" dir
            dir="$(vu_gh_fetch "$spec")" || return 1
            printf '%s\t%s\n' "$dir" "gh:$spec"
            ;;
        http*://*github.com/*)
            # https://github.com/owner/repo(.git)(/tree/ref) → gh:owner/repo[@ref]
            local rest="${src#*github.com/}" owner repo ref="" spec
            owner="${rest%%/*}"; rest="${rest#*/}"; repo="${rest%%/*}"; repo="${repo%.git}"
            [[ "$rest" == */tree/* ]] && ref="${rest##*/tree/}"
            spec="$owner/$repo"; [[ -n "$ref" ]] && spec="$spec@$ref"
            local dir; dir="$(vu_gh_fetch "$spec")" || return 1
            printf '%s\t%s\n' "$dir" "gh:$spec"
            ;;
        vumm:*)
            perr "vumm mods install into the instance dir, not a folder tree."
            plog "  Run:  ${BOLD}cd '$VU_INSTANCE_DIR' && '$(vu_vumm_bin 2>/dev/null || echo vumm)' install ${src#vumm:}${NC}"
            plog "  vumm needs a bf3reality login first (even realitymod 403s anonymously):"
            plog "    ${DIM}vumm register / vumm login${NC}"
            return 3
            ;;
        *)
            # Local path: a directory, or a .zip / .tar(.gz) archive.
            if [[ -d "$src" ]]; then
                printf '%s\t%s\n' "$(cd "$src" && pwd)" "path:$(cd "$src" && pwd)"
            elif [[ -f "$src" ]]; then
                local tmp; tmp="$(mktemp -d)"
                case "$src" in
                    *.zip)        unzip -q "$src" -d "$tmp" 2>/dev/null ;;
                    *.tar.gz|*.tgz) tar xzf "$src" -C "$tmp" 2>/dev/null ;;
                    *.tar)        tar xf "$src" -C "$tmp" 2>/dev/null ;;
                    *) perr "unknown archive: $src"; rm -rf "$tmp"; return 1 ;;
                esac || { perr "extract failed: $src"; rm -rf "$tmp"; return 1; }
                printf '%s\t%s\n' "$tmp" "path:$src"
                else
                perr "not a github source, directory, or archive: $src"
                return 1
            fi
            ;;
    esac
}

vu_mod_help() {
    cat <<EOF
${BOLD}powos mods vu mod${NC} — manage VU mods

VU mods are always server-side: a server loads them, and clients auto-download
them on join. So there is no client/server split here — just 'vu mod'.

  install <source> [--only A,B | --all] [--disabled]
                          Install mod(s) into the server and enable them.
                          --only picks specific mods from a multi-mod repo;
                          --all takes every one; --disabled skips ModList.
  list                    Show installed mods and their enabled state.
  enable  <name>          Add a mod to ModList.txt (VU loads it).
  disable <name>          Remove from ModList.txt (files kept).
  remove  <name>          Delete the mod folder and delist it.
  update  [name]          Re-fetch GitHub mods (no name = all of them).
  build   <name>          Build a WebUI mod (pnpm) and pack ui.vuic via vuicc
                          under wine — for HasWebUI mods like MapEditor.
  dev     [name]          Hot-reload dev loop: watch the mods dir and send
                          ${VU_RELOAD_CMD} on every save. Edit the Lua in
                          ${VU_MODS_DIR}/<mod>/ and it reloads live — no restart.
                          (Pairs with ${BOLD}powos mods vu rcon${NC} for one-off commands.)

${BOLD}Sources${NC}
  gh:owner/repo[@ref]     A GitHub repo (default branch unless @ref).
  https://github.com/…    Same, as a full URL (…/tree/<ref> honoured).
  ./path  |  file.zip|.tar.gz
                          A local folder or archive — the escape hatch for
                          mods handed out on Discord/forums: download it,
                          point PowOS at it, it finds the mod.json and places
                          it correctly.
  vumm:<name>             The BF3-Reality registry (prints the exact vumm
                          command; needs a bf3reality login — even realitymod
                          403s anonymously, so vumm is an account-gated path).

${BOLD}Choosing when a repo ships several mods${NC}
  A repo with multiple mod.json folders is NOT installed wholesale. With no
  ${BOLD}--only${NC}/${BOLD}--all${NC} (and no TTY to prompt) install LISTS the mods and stops.
  Use ${BOLD}--only ModA,ModB${NC} to pick, or ${BOLD}--all${NC} to take everything on purpose.

A mod is identified by a mod.json containing a Name — nothing is guessed.
EOF
}

# install <source> [--only A,B | --all] [--disabled]
vu_mod_install_cmd() {
    local source="" want=() take_all=false do_enable=true _o=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)      take_all=true ;;
            --only)     IFS=', ' read -r -a _o <<< "${2:-}"; want+=("${_o[@]}"); shift ;;
            --only=*)   IFS=', ' read -r -a _o <<< "${1#*=}"; want+=("${_o[@]}") ;;
            --disabled) do_enable=false ;;
            -h|--help)  vu_mod_help; return 0 ;;
            -*)         perr "unknown flag: $1"; return 1 ;;
            *) if [[ -z "$source" ]]; then source="$1"
               else perr "unexpected argument '$1' — pick mods with ${BOLD}--only NAME[,NAME]${NC}, not positionally."; return 1; fi ;;
        esac
        shift
    done
    [[ -z "$source" ]] && { perr "usage: powos mods vu mod install <source> [--only A,B | --all] [--disabled]"; vu_mod_help; return 1; }
    # Pin a ref with the source itself: gh:owner/repo@ref (no separate flag).

    local resolved dir spec
    resolved="$(vu_mod_resolve_source "$source")" || return $?
    dir="${resolved%%$'\t'*}"; spec="${resolved#*$'\t'}"
    local cleanup=""; [[ "$spec" == gh:* || "$spec" == path:*.zip || "$spec" == path:*.tar* ]] && cleanup="$dir"

    local -a names=() paths=()
    local line
    while IFS=$'\t' read -r n p; do names+=("$n"); paths+=("$p"); done < <(vu_find_mods "$dir")

    local count=${#names[@]}
    if [[ $count -eq 0 ]]; then
        perr "no mod.json found under $source — not a VU mod."
        [[ -n "$cleanup" ]] && rm -rf "$cleanup"
        return 1
    fi

    # Decide which indices to install.
    local -a pick=()
    if [[ ${#want[@]} -gt 0 ]]; then
        local w i found
        for w in "${want[@]}"; do
            found=false
            for i in "${!names[@]}"; do
                if [[ "${names[$i],,}" == "${w,,}" ]]; then pick+=("$i"); found=true; fi
            done
            $found || { perr "no mod named '$w' in $source"; vu_mod_install_list_available names[@]; [[ -n "$cleanup" ]] && rm -rf "$cleanup"; return 1; }
        done
    elif $take_all || [[ $count -eq 1 ]]; then
        for i in "${!names[@]}"; do pick+=("$i"); done
    elif [[ -t 0 ]]; then
        echo "This source ships ${count} mods:"; vu_mod_install_list_available names[@]
        printf 'Install which? (numbers, space-separated, or "a" for all): '
        local ans; read -r ans
        if [[ "$ans" == a || "$ans" == all ]]; then
            for i in "${!names[@]}"; do pick+=("$i"); done
        else
            local tok
            for tok in $ans; do
                [[ "$tok" =~ ^[0-9]+$ ]] && (( tok>=1 && tok<=count )) && pick+=("$((tok-1))")
            done
        fi
    else
        # Non-interactive, multiple mods, no selection → refuse; never auto-all.
        perr "$source ships ${count} mods — choose which, don't install all blindly:"
        vu_mod_install_list_available names[@]
        plog "  pick with ${BOLD}--only ModA,ModB${NC}, or ${BOLD}--all${NC} to take every one."
        [[ -n "$cleanup" ]] && rm -rf "$cleanup"
        return 2
    fi

    if [[ ${#pick[@]} -eq 0 ]]; then
        pwarn "Nothing selected."
        [[ -n "$cleanup" ]] && rm -rf "$cleanup"
        return 1
    fi

    local i installed rc=0
    for i in "${pick[@]}"; do
        if installed="$(vu_place_mod "${paths[$i]}" "${names[$i]}" "$spec")"; then
            if $do_enable; then vu_modlist_add "$installed"; pok "installed + enabled: $installed"
            else pok "installed (disabled): $installed  ${DIM}enable with: powos mods vu mod enable $installed${NC}"; fi
        else
            rc=1
        fi
    done
    [[ -n "$cleanup" ]] && rm -rf "$cleanup"
    return $rc
}

# helper: print a numbered "  N) name" list from a names-array passed by name.
vu_mod_install_list_available() {
    local -n _arr="$1"
    local i
    for i in "${!_arr[@]}"; do printf '  %d) %s\n' "$((i+1))" "${_arr[$i]}"; done
}

vu_mod_list_cmd() {
    echo -e "${BOLD}VU mods${NC}  ${DIM}$VU_MODS_DIR${NC}"
    echo    "════════════════════════════════════════"
    if [[ ! -d "$VU_MODS_DIR" ]] || [[ -z "$(ls -A "$VU_MODS_DIR" 2>/dev/null)" ]]; then
        echo "  (none installed)"; return 0
    fi
    local d name src
    for d in "$VU_MODS_DIR"/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        src=""; [[ -f "$d/.powos-source" ]] && src="$(cat "$d/.powos-source")"
        if vu_modlist_has "$name"; then
            echo -e "  ${GREEN}●${NC} $name  ${DIM}enabled${NC}${src:+   ${DIM}($src)${NC}}"
        else
            echo -e "  ${YELLOW}○${NC} $name  ${DIM}disabled${NC}${src:+   ${DIM}($src)${NC}}"
        fi
    done
}

vu_mod_enable_cmd() {
    [[ -n "${1:-}" ]] || { perr "usage: powos mods vu mod enable <name>"; return 1; }
    [[ -d "$VU_MODS_DIR/$1" ]] || { perr "no such mod folder: $1  (install it first)"; return 1; }
    vu_modlist_add "$1"; pok "enabled: $1"
}

vu_mod_disable_cmd() {
    [[ -n "${1:-}" ]] || { perr "usage: powos mods vu mod disable <name>"; return 1; }
    vu_modlist_remove "$1"; pok "disabled: $1  ${DIM}(files kept)${NC}"
}

vu_mod_remove_cmd() {
    [[ -n "${1:-}" ]] || { perr "usage: powos mods vu mod remove <name>"; return 1; }
    vu_modlist_remove "$1"
    rm -rf "${VU_MODS_DIR:?}/$1"
    pok "removed: $1"
}

# update [name] — re-fetch gh-sourced mods from their recorded provenance.
vu_mod_update_cmd() {
    local target="${1:-}"
    [[ -d "$VU_MODS_DIR" ]] || { perr "no mods installed."; return 1; }
    local d name src updated=0 skipped=0
    for d in "$VU_MODS_DIR"/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        [[ -n "$target" && "$target" != "--all" && "$target" != "$name" ]] && continue
        src=""; [[ -f "$d/.powos-source" ]] && src="$(cat "$d/.powos-source")"
        if [[ "$src" != gh:* ]]; then
            pwarn "skip $name — not a GitHub mod (source: ${src:-unknown})"; skipped=$((skipped+1)); continue
        fi
        plog "updating $name from ${src}…"
        local tmp; tmp="$(vu_gh_fetch "${src#gh:}")" || { skipped=$((skipped+1)); continue; }
        # Find the mod folder in the fresh tree whose Name matches this one.
        local newpath="" n p
        while IFS=$'\t' read -r n p; do
            [[ "${n//\//_}" == "$name" || "$n" == "$name" ]] && newpath="$p"
        done < <(vu_find_mods "$tmp")
        if [[ -n "$newpath" ]]; then
            vu_place_mod "$newpath" "$name" "$src" >/dev/null && { pok "updated $name"; updated=$((updated+1)); }
        else
            pwarn "could not find '$name' in the refreshed repo — left as-is"; skipped=$((skipped+1))
        fi
        rm -rf "$tmp"
    done
    plog "update done: $updated updated, $skipped skipped."
}

# ── RCON + the hot-reload dev loop ────────────────────────────────────────────
#
# The running dedicated server speaks Frostbite RCON on 47200/tcp; the password
# is the admin.password in the instance's Startup.txt. `rcon` fires one command;
# `mod dev` watches the mods dir and sends modList.ReloadExtensions on every
# save, so you edit Lua in Admin/Mods/<mod>/ and see it live without a restart.

# The RCON/admin password = admin.password from the instance Startup.txt.
vu_rcon_password() {
    local f="$VU_INSTANCE_DIR/Admin/Startup.txt"
    [[ -f "$f" ]] || return 1
    sed -n 's/^admin\.password[[:space:]]*"\(.*\)".*/\1/p' "$f" | head -1
}

# Is the server's RCON port accepting connections?
vu_rcon_up() {
    ss -ltn 2>/dev/null | grep -qE "[:.]${VU_RCON_PORT}[[:space:]]"
}

# Start the dedicated server fully detached (new session) so it outlives the
# dev loop / this shell. Output still lands in VU_SERVER_LOG via the tee inside
# vu_server_start; we re-invoke powos itself to avoid function-scope issues.
vu_server_start_detached() {
    setsid "${POWOS_BIN:-$0}" mods vu server start >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
}

# Preflight shared by rcon + dev: python3, the client script, and a password.
vu_rcon_preflight() {
    command -v python3 >/dev/null || { perr "python3 is required for RCON."; return 1; }
    [[ -f "$VU_RCON_PY" ]] || { perr "vu-rcon.py missing at $VU_RCON_PY"; return 1; }
    local pw; pw="$(vu_rcon_password || true)"
    [[ -n "$pw" ]] || {
        perr "No admin.password in $VU_INSTANCE_DIR/Admin/Startup.txt."
        plog "Scaffold it with: ${BOLD}powos mods vu server init${NC}"
        return 1
    }
    printf '%s' "$pw"
}

vu_rcon_cmd() {
    case "${1:-}" in
        ""|-h|--help|help)
            cat <<EOF
${BOLD}powos mods vu rcon${NC} "<command>"  — send one RCON command to the server

  powos mods vu rcon serverInfo
  powos mods vu rcon version
  powos mods vu rcon "modList.ReloadExtensions"
  powos mods vu rcon admin.say "hello" all

Password is read from Admin/Startup.txt (admin.password). Host/port default to
${VU_RCON_HOST}:${VU_RCON_PORT} (override with VU_RCON_HOST / VU_RCON_PORT).
Command reference: https://docs.veniceunleashed.net/hosting/commands
EOF
            return 0 ;;
    esac
    local pw; pw="$(vu_rcon_preflight)" || return 1
    # One quoted string → split on whitespace (rcon "version"); multiple args →
    # each is a literal word (rcon admin.say "hello there").
    local -a words
    if [[ $# -eq 1 ]]; then read -r -a words <<< "$1"; else words=( "$@" ); fi
    python3 "$VU_RCON_PY" send "$VU_RCON_HOST" "$VU_RCON_PORT" "$pw" "${words[@]}"
}

vu_mod_dev_cmd() {
    case "${1:-}" in
        -h|--help|help)
            cat <<EOF
${BOLD}powos mods vu mod dev${NC} [mod-name]  — hot-reload dev loop

Watches the mods dir (or one mod under it) and sends ${BOLD}${VU_RELOAD_CMD}${NC}
to the running server on every .lua/.json save — edit in place, see it live.
Mods live where they always do: ${VU_MODS_DIR}/<mod>/. Ctrl-C to stop.

  powos mods vu mod dev            # watch all of Admin/Mods
  powos mods vu mod dev MyMod      # watch just Admin/Mods/MyMod
EOF
            return 0 ;;
    esac
    local pw; pw="$(vu_rcon_preflight)" || return 1
    local watch="$VU_MODS_DIR"
    if [[ -n "${1:-}" ]]; then
        watch="$VU_MODS_DIR/$1"
        [[ -d "$watch" ]] || { perr "No such mod: $1  (looked under $VU_MODS_DIR)"; return 1; }
    fi
    mkdir -p "$watch"

    # Ensure the server is running — this is a dev loop, it owns its server.
    if ! vu_rcon_up; then
        plog "Server not up — starting it headless (log: $VU_SERVER_LOG)…"
        vu_server_start_detached || { perr "Could not start the server."; return 1; }
        local i=0
        until vu_rcon_up; do
            sleep 1; i=$((i+1))
            [[ $i -ge 90 ]] && { perr "Server didn't open RCON within 90s — check $VU_SERVER_LOG"; return 1; }
        done
        pok "Server up (RCON ${VU_RCON_HOST}:${VU_RCON_PORT})."
    fi

    plog "Hot-reload dev loop — edit Lua under ${BOLD}$watch${NC}; ${DIM}[srv] lines = server output, '!' = looks like an error${NC}"
    exec python3 "$VU_RCON_PY" watch "$VU_RCON_HOST" "$VU_RCON_PORT" "$pw" "$watch" "$VU_SERVER_LOG" $VU_RELOAD_CMD
}

# Ensure vuicc.exe is cached; echo its path. Downloaded once from VU's file host.
vu_vuicc_bin() {
    [[ -s "$VU_VUICC_BIN" ]] && { printf '%s' "$VU_VUICC_BIN"; return 0; }
    mkdir -p "$(dirname "$VU_VUICC_BIN")"
    plog "Fetching vuicc.exe (VU WebUI compiler)…" >&2
    if ! curl -fSL "$VU_VUICC_URL" -o "$VU_VUICC_BIN" 2>/dev/null; then
        perr "Could not download vuicc.exe from $VU_VUICC_URL"
        rm -f "$VU_VUICC_BIN"; return 1
    fi
    printf '%s' "$VU_VUICC_BIN"
}

# Build a WebUI mod: pnpm install + production build, then pack dist/ → ui.vuic
# with vuicc under wine (the .exe is Windows-only; vextpack silently skips the
# pack on Linux, so PowOS does it). Idempotent-ish; safe to re-run after edits.
vu_mod_build_cmd() {
    case "${1:-}" in
        ""|-h|--help|help)
            cat <<EOF
${BOLD}powos mods vu mod build${NC} <name>  — build a WebUI mod's ui.vuic

Runs ${BOLD}pnpm i && pnpm build${NC} in the mod's WebUI/, then packs the built
dist/ into ui.vuic using vuicc under GE-Proton wine (VU only ships vuicc as a
Windows .exe). Needed for mods with a WebUI (HasWebUI in mod.json), e.g. MapEditor.
Re-run after WebUI source changes.
EOF
            return 0 ;;
    esac
    local name="$1" moddir webui
    moddir="$VU_MODS_DIR/$name"
    [[ -d "$moddir" ]] || { perr "No such mod: $name  (looked under $VU_MODS_DIR)"; return 1; }
    webui="$moddir/WebUI"
    [[ -f "$webui/package.json" ]] || { perr "$name has no WebUI/package.json — nothing to build."; return 1; }
    command -v pnpm >/dev/null || { perr "pnpm is required. Install it: ${BOLD}npm i -g pnpm${NC}"; return 1; }
    vu_apply_prefix_choice
    local wine pdir; wine="$(vu_wine)"; pdir="$(vu_proton_dir)"
    [[ -n "$wine" ]] || { perr "No GE-Proton wine (needed to run vuicc). Run: powos mods modlist proton"; return 1; }
    local vuicc; vuicc="$(vu_vuicc_bin)" || return 1

    plog "Building $name WebUI ${DIM}($webui)${NC}…"
    if ! ( cd "$webui" && pnpm i && NODE_ENV=production pnpm build ); then
        perr "WebUI build (pnpm) failed."; return 1
    fi
    [[ -d "$webui/dist" ]] || { perr "build produced no dist/ — nothing to pack."; return 1; }

    local out="$moddir/ui.vuic"
    plog "Packing dist/ → ui.vuic ${DIM}(vuicc under wine)${NC}…"
    if ! env -u DISPLAY -u WAYLAND_DISPLAY \
            WINEPREFIX="$(vu_wineprefix)" WINELOADER="$wine" WINESERVER="$pdir/files/bin/wineserver" \
            LD_LIBRARY_PATH="$pdir/files/lib64:$pdir/files/lib" WINEDEBUG=-all \
            "$wine" "$vuicc" "Z:$webui/dist" "Z:$out" >/dev/null 2>&1; then
        perr "vuicc pack failed."; return 1
    fi
    [[ -s "$out" ]] || { perr "vuicc produced no ui.vuic."; return 1; }
    pok "Built $name WebUI → ui.vuic ${DIM}($(du -h "$out" | cut -f1))${NC}. Restart the server to serve it."
}

vu_mod_cmd() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        install|add|i) vu_mod_install_cmd "$@" ;;
        list|ls)       vu_mod_list_cmd ;;
        enable)        vu_mod_enable_cmd "$@" ;;
        disable)       vu_mod_disable_cmd "$@" ;;
        remove|rm)     vu_mod_remove_cmd "$@" ;;
        update)        vu_mod_update_cmd "$@" ;;
        build)         vu_mod_build_cmd "$@" ;;
        dev|watch)     vu_mod_dev_cmd "$@" ;;
        help|-h|--help) vu_mod_help ;;
        *) perr "Unknown mod verb: $sub"; vu_mod_help; return 1 ;;
    esac
}

# ── Uninstall ─────────────────────────────────────────────────────────────────

vu_uninstall_cmd() {
    local keep_instance=true
    [[ "${1:-}" == "--purge" ]] && keep_instance=false

    rm -f "$VU_WRAPPER" "$VU_DESKTOP"
    rm -rf "$VU_CLIENT_DIR" "$VU_PREFIX"
    plog "Removed client, prefix, launcher and desktop entry."
    if $keep_instance; then
        plog "Kept $VU_INSTANCE_DIR (server.key, config, mods)."
        plog "  ${DIM}powos mods vu uninstall --purge  removes it too${NC}"
    else
        rm -rf "$VU_INSTANCE_DIR" "$VU_CONF"
        plog "Purged instance directory and config."
    fi
    pok "Venice Unleashed uninstalled."
}

# ── Help ──────────────────────────────────────────────────────────────────────

vu_help() {
    cat <<EOF
${BOLD}powos mods vu${NC} — Venice Unleashed (Battlefield 3 community client)

VU is a third-party BF3 client plus modding framework (VEXT). It runs under
GE-Proton in its own prefix — no Bottles, no Steam shortcut. You supply the
BF3 game files and an EA account that owns Battlefield 3.

Setup:
  powos mods vu install [--gamepath DIR] [--branch prod|dev]
                        [--steam-prefix | --own-prefix]
                                  Download the client, install GE-Proton and
                                    the native d3dcompiler_47, write launcher
                                    + KDE menu entry. Re-run with --gamepath
                                    to repoint at your BF3 files.
                                    --steam-prefix runs VU inside BF3's Steam
                                    Proton prefix (already Steam-activated — no
                                    EA sign-in); --own-prefix (default) uses a
                                    dedicated VU prefix.
  powos mods vu activate [--token EA_TOKEN]
                                  Activate BF3. Without --token this uses the
                                    running EA app (-lsx); with it, the
                                    headless path for servers.
  powos mods vu d3dcompiler       (Re)install the WebUI runtime into the prefix
                                    (native d3dcompiler_47 + VC++ 2015-2022).
  powos mods vu branch [prod|dev] Show or set the update branch.

Play:
  powos mods vu play [args...]    Launch the client (also in the KDE menu).
                                    Extra args pass through to vu.com, e.g.
                                    vu://join/<guid>, -dwebui, -console.

Server:
  powos mods vu server init       Create the instance dir + scaffold config
  powos mods vu server start      Run the dedicated server (headless)
  powos mods vu server status     Instance, key, config and port summary
  powos mods vu server help       Server-specific detail

Mods (always server-side — clients auto-download on join):
  powos mods vu mod install <source> [--only A,B|--all] [--disabled]
                                  Install mod(s) from GitHub (gh:owner/repo),
                                    a local zip/folder, or vumm. A repo with
                                    several mods lets you pick — never all.
  powos mods vu mod list          Installed mods + enabled state
  powos mods vu mod enable|disable|remove <name>
  powos mods vu mod update [name]
                                  Re-fetch GitHub-sourced mods
  powos mods vu mod dev [name]    Hot-reload dev loop — watch the mods dir,
                                    send modList.ReloadExtensions on each save
  powos mods vu mod help          Sources + selection detail

Live server control (Frostbite RCON on 47200):
  powos mods vu rcon "<command>"  Send an RCON command (serverInfo, version,
                                    admin.say …, modList.ReloadExtensions)

Other:
  powos mods vu status            Client, gamepath, runtime, d3dcompiler
  powos mods vu uninstall [--purge]
                                  Remove client + prefix (--purge also drops
                                    the instance dir and config)

${BOLD}The WebUI runtime gotcha${NC} — VU's WebUI (Coherent Gameface) needs TWO
native pieces in the prefix on EVERY branch, not just dev:
  • d3dcompiler_47  — missing → blank/black UI (Wine's stub isn't enough).
  • vcrun2022 (VC++ 2015-2022) — missing → the launcher NULL-derefs inside
    msvcp140 and dies on startup with NO window at all.
Both symptoms are silent (no error), so they read like "VU is broken on Linux".
It is not, and has been fixable since 2022. 'vu install' installs both;
'vu status' tells you if either went missing.

Server ports: 7948/udp harmony · 25200/udp frostbite · 47200/tcp rcon
Docs: https://docs.veniceunleashed.net/
EOF
}

# ── Dispatcher ────────────────────────────────────────────────────────────────

cmd_mods_vu() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        install)      vu_install_cmd "$@" ;;
        activate)     vu_activate_cmd "$@" ;;
        d3dcompiler)  vu_d3dcompiler_cmd "$@" ;;
        branch)       vu_branch_cmd "$@" ;;
        play|launch)  vu_play_cmd "$@" ;;
        server)       vu_server_cmd "$@" ;;
        mod|mods)     vu_mod_cmd "$@" ;;
        rcon)         vu_rcon_cmd "$@" ;;
        status)       vu_status_cmd ;;
        uninstall)    vu_uninstall_cmd "$@" ;;
        help|-h|--help) vu_help ;;
        *) perr "Unknown vu verb: $sub"; vu_help; return 1 ;;
    esac
}
