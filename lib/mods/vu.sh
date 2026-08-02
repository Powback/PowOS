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
# THE d3dcompiler_47 GOTCHA — this is the whole reason this module exists:
# VU's current WebUI needs a NATIVE d3dcompiler_47. Wine's built-in stub does
# not implement enough of it, and the failure mode is a black / blank UI or a
# silent exit rather than an error, so it reads as "VU is broken on Linux".
# It is not — it has been fixable since 2022. `vu install` puts the native DLL
# in the prefix via winetricks; `vu d3dcompiler` re-does it on its own.
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

# ── Paths ─────────────────────────────────────────────────────────────────────

VU_ROOT="${VU_ROOT:-$HOME/Games/VeniceUnleashed}"
VU_CLIENT_DIR="${VU_CLIENT_DIR:-$VU_ROOT/client}"
VU_INSTANCE_DIR="${VU_INSTANCE_DIR:-$VU_ROOT/instance}"
VU_PREFIX="${VU_PREFIX:-$VU_ROOT/prefix}"
VU_WRAPPER="${VU_WRAPPER:-$HOME/.local/bin/venice-unleashed}"
VU_DESKTOP="${VU_DESKTOP:-$HOME/.local/share/applications/venice-unleashed.desktop}"
VU_CONF="${VU_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/powos/vu.conf}"

VU_ZIP_URL="${VU_ZIP_URL:-https://veniceunleashed.net/files/vu.zip}"

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

vu_installed() { [[ -f "$VU_CLIENT_DIR/vu.com" || -f "$VU_CLIENT_DIR/vu.exe" ]]; }

# Is the NATIVE d3dcompiler_47 in the prefix? Wine's builtin stub lives in the
# same place, so presence alone is not proof — but winetricks records what it
# installed, and that log IS authoritative.
vu_has_d3dcompiler() {
    local log; log="$(vu_wineprefix)/winetricks.log"
    [[ -f "$log" ]] && grep -qx 'd3dcompiler_47' "$log"
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

    # The gotcha
    if [[ ! -d "$(vu_wineprefix)" ]]; then
        echo -e "  d3dcompiler:   $mark_no prefix not created yet"
    elif vu_has_d3dcompiler; then
        echo -e "  d3dcompiler:   $mark_ok native d3dcompiler_47 present"
    else
        echo -e "  d3dcompiler:   $mark_warn MISSING — WebUI will render blank"
        echo -e "                 ${DIM}powos mods vu d3dcompiler${NC}"
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
    plog "Installing native d3dcompiler_47 into VU's prefix (may take a minute)…"
    if ! WINEPREFIX="$(vu_wineprefix)" WINE="$wine" WINESERVER="$(dirname "$wine")/wineserver" \
            winetricks -q d3dcompiler_47; then
        perr "winetricks d3dcompiler_47 failed."
        plog "Without it VU's WebUI renders blank — this is not optional."
        return 1
    fi
    pok "Native d3dcompiler_47 installed."
}

vu_install_cmd() {
    local gamepath="" branch=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gamepath) gamepath="${2:-}"; shift 2 ;;
            --branch)   branch="${2:-}";   shift 2 ;;
            -h|--help)  vu_help; return 0 ;;
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
    vu_has_d3dcompiler || vu_d3dcompiler_cmd || \
        pwarn "Continuing, but VU's WebUI will be blank until d3dcompiler_47 lands."

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

vu_write_desktop() {
    mkdir -p "$(dirname "$VU_DESKTOP")"
    cat > "$VU_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Venice Unleashed
Comment=Battlefield 3 community client and modding framework
Exec=$VU_WRAPPER
Icon=applications-games
Terminal=false
Categories=Game;ActionGame;
Keywords=battlefield;bf3;vu;venice;
EOF
    update-desktop-database "$(dirname "$VU_DESKTOP")" 2>/dev/null || true
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
    [[ -x "$VU_WRAPPER" ]] || vu_write_wrapper
    if ! vu_has_d3dcompiler; then
        pwarn "Native d3dcompiler_47 is missing — expect a blank WebUI."
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

  powos mods vu server init           Create the instance dir + show key steps
  powos mods vu server start [args]   Run the dedicated server (foreground)
  powos mods vu server status         Instance dir, key, port reachability

The instance directory (${VU_INSTANCE_DIR}) holds server.key, config and mods.
Get server.key from your VU account, drop it in that directory.

Ports to forward:
  7948/udp   Monitored Harmony networking
  25200/udp  Frostbite networking
  47200/tcp  RCON

Useful passthrough args: -high60 | -high120 (tick rate), -headless,
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
    echo
    echo -e "  ${DIM}Ports: 7948/udp harmony · 25200/udp frostbite · 47200/tcp rcon${NC}"
    echo
}

vu_server_init() {
    mkdir -p "$VU_INSTANCE_DIR" || return 1
    pok "Instance directory ready: $VU_INSTANCE_DIR"
    if [[ ! -f "$VU_INSTANCE_DIR/server.key" ]]; then
        plog "Now drop your ${BOLD}server.key${NC} into that directory."
        plog "  ${DIM}It comes from your Venice Unleashed account page.${NC}"
    fi
    plog "Then: ${BOLD}powos mods vu server start${NC}"
    plog "Forward 7948/udp, 25200/udp, 47200/tcp."
}

vu_server_start() {
    vu_installed || { perr "VU not installed. Run: powos mods vu install"; return 1; }
    local proton; proton="$(vu_proton || true)"
    [[ -z "$proton" ]] && { perr "No GE-Proton. Run: powos mods modlist proton"; return 1; }
    local bf3; bf3="$(vu_detect_bf3 || true)"
    [[ -z "$bf3" ]] && { perr "No BF3 gamepath. Run: powos mods vu install --gamepath DIR"; return 1; }
    [[ -f "$VU_INSTANCE_DIR/server.key" ]] || {
        perr "No server.key in $VU_INSTANCE_DIR."
        plog "Run ${BOLD}powos mods vu server init${NC} for the steps."
        return 1
    }

    # VU wants a Windows-style path for -serverInstancePath.
    local winpath="Z:${VU_INSTANCE_DIR//\//\\}"

    plog "Starting VU dedicated server…"
    plog "  instance: $VU_INSTANCE_DIR"
    mkdir -p "$VU_PREFIX"
    STEAM_COMPAT_DATA_PATH="$VU_PREFIX" \
    STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.steam/steam}" \
        "$proton" run "$VU_CLIENT_DIR/vu.com" \
            -gamepath "$bf3" \
            -serverInstancePath "$winpath" \
            -server -dedicated "$@"
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
                                  Download the client, install GE-Proton and
                                    the native d3dcompiler_47, write launcher
                                    + KDE menu entry. Re-run with --gamepath
                                    to repoint at your BF3 files.
  powos mods vu activate [--token EA_TOKEN]
                                  Activate BF3. Without --token this uses the
                                    running EA app (-lsx); with it, the
                                    headless path for servers.
  powos mods vu d3dcompiler       (Re)install the native d3dcompiler_47.
  powos mods vu branch [prod|dev] Show or set the update branch.

Play:
  powos mods vu play [args...]    Launch the client (also in the KDE menu).
                                    Extra args pass through to vu.com, e.g.
                                    vu://join/<guid>, -dwebui, -console.

Server:
  powos mods vu server init       Create the instance dir, explain server.key
  powos mods vu server start      Run the dedicated server (foreground)
  powos mods vu server status     Instance, key and port summary
  powos mods vu server help       Server-specific detail

Other:
  powos mods vu status            Client, gamepath, runtime, d3dcompiler
  powos mods vu uninstall [--purge]
                                  Remove client + prefix (--purge also drops
                                    the instance dir and config)

${BOLD}The d3dcompiler_47 gotcha${NC} — VU's WebUI needs a NATIVE
d3dcompiler_47 on EVERY branch, not just dev; Wine's built-in stub is not
enough. The symptom is a blank or black UI, not an error message, so it reads
like "VU is broken on Linux". It is not, and has been fixable since 2022.
'vu install' handles it; 'vu status' tells you if it went missing.

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
        status)       vu_status_cmd ;;
        uninstall)    vu_uninstall_cmd "$@" ;;
        help|-h|--help) vu_help ;;
        *) perr "Unknown vu verb: $sub"; vu_help; return 1 ;;
    esac
}
