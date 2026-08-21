#!/bin/bash
# stream.sh - PowStream status & control wrapper.
#
# The PowStream overlay ships user units that autostart at login:
#   powstream-webrtc-server.service  (WebRTC server, default :8090, HTTPS)
#   powlens-sidecar.service          (detector sidecar, :8791)
#
# `powos stream` is a thin status/control layer over those units —
# it never duplicates the service management, just makes it discoverable.
#
#   powos stream              Show status (running? URL? token?)
#   powos stream start        Start/restart services
#   powos stream stop         Stop services
#   powos stream restart      Restart services
#   powos stream logs         Tail combined logs
#   powos stream setup        Pre-seed the screencast portal restore token

source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh"
POWOS_TAG=stream

WEBRTC_UNIT="powstream-webrtc-server.service"
SIDECAR_UNIT="powlens-sidecar.service"
TOKEN_PATH="${HOME}/.config/powstream/portal-restore-token"
# The server's own default is 8090 and it serves HTTPS with a self-signed
# cert unless started with --no-tls. This used to say 8080/http, which printed
# a connect URL that simply did not answer. Override with --port in a unit
# drop-in; there is NO POWSTREAM_PORT env var (nothing has ever read one).
WEBRTC_PORT="${POWSTREAM_WEBRTC_PORT:-8090}"
WEBRTC_SCHEME="${POWSTREAM_WEBRTC_SCHEME:-https}"

_unit_state() {
    systemctl --user show -p ActiveState --value "$1" 2>/dev/null || echo "unknown"
}

_unit_running() { [[ "$(_unit_state "$1")" == "active" ]]; }

# Detect the LAN IP for printing the connect URL.
_lan_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n "$ip" ]] && echo "$ip" || echo "localhost"
}

stream_status() {
    echo -e "${BOLD}PowStream Status${NC}"
    echo "════════════════════════════════════════"

    # Service states
    local ws_state ss_state
    ws_state=$(_unit_state "$WEBRTC_UNIT")
    ss_state=$(_unit_state "$SIDECAR_UNIT")

    local ws_color ss_color
    [[ "$ws_state" == "active" ]] && ws_color="$GREEN" || ws_color="$RED"
    [[ "$ss_state" == "active" ]] && ss_color="$GREEN" || ss_color="$RED"

    echo -e "  WebRTC server:   ${ws_color}${ws_state}${NC}  ($WEBRTC_UNIT)"
    echo -e "  Detector sidecar: ${ss_color}${ss_state}${NC}  ($SIDECAR_UNIT)"

    # Restore token
    if [[ -f "$TOKEN_PATH" ]] && [[ -s "$TOKEN_PATH" ]]; then
        echo -e "  Portal token:    ${GREEN}present${NC} ($TOKEN_PATH)"
    else
        echo -e "  Portal token:    ${YELLOW}missing${NC} — run 'powos stream setup' on the local console"
    fi

    # Capture-layer mode — MUST be per-game, never session-global (a global
    # enable loads the game-memory-hooking layer into every Vulkan title,
    # including anti-cheat ones → ban risk).
    local glob=""
    for f in /usr/lib/environment.d/powstream.conf \
             "${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/powstream.conf"; do
        grep -qs '^[[:space:]]*POWSTREAM_CAPTURE=1' "$f" 2>/dev/null && glob="$f"
    done
    if [[ -n "$glob" ]]; then
        echo -e "  Capture layer:   ${RED}GLOBAL — UNSAFE${NC} (loads into every Vulkan game)"
        echo -e "    ${YELLOW}Fix:${NC} remove the POWSTREAM_CAPTURE=1 line from ${DIM}$glob${NC}, re-login."
        echo -e "         then enable per game: ${BOLD}powos stream launch -- <cmd>${NC}"
    else
        echo -e "  Capture layer:   ${GREEN}per-game opt-in${NC} (safe — 'powos stream launch')"
    fi

    # Connect URL
    if [[ "$ws_state" == "active" ]]; then
        local ip; ip=$(_lan_ip)
        echo ""
        echo -e "  ${CYAN}Connect:${NC} ${WEBRTC_SCHEME}://${ip}:${WEBRTC_PORT}/"
    fi

    # Quick hint if units not found (overlay not installed)
    if ! systemctl --user cat "$WEBRTC_UNIT" &>/dev/null; then
        echo ""
        pwarn "PowStream units not installed. Build + enable the overlay first:"
        pwarn "  powos overlay build powstream && powos overlay enable powstream"
    fi
}

stream_start() {
    plog "Starting PowStream services…"
    systemctl --user start "$WEBRTC_UNIT" 2>/dev/null || pwarn "Failed to start $WEBRTC_UNIT"
    systemctl --user start "$SIDECAR_UNIT" 2>/dev/null || pwarn "Failed to start $SIDECAR_UNIT"
    if _unit_running "$WEBRTC_UNIT"; then
        local ip; ip=$(_lan_ip)
        pok "PowStream running — connect at ${WEBRTC_SCHEME}://${ip}:${WEBRTC_PORT}/"
    else
        perr "WebRTC server failed to start. Check: powos stream logs"
    fi
}

stream_stop() {
    plog "Stopping PowStream services…"
    systemctl --user stop "$SIDECAR_UNIT" 2>/dev/null || true
    systemctl --user stop "$WEBRTC_UNIT" 2>/dev/null || true
    pok "PowStream stopped."
}

stream_restart() {
    plog "Restarting PowStream services…"
    systemctl --user restart "$WEBRTC_UNIT" 2>/dev/null || pwarn "Failed to restart $WEBRTC_UNIT"
    systemctl --user restart "$SIDECAR_UNIT" 2>/dev/null || pwarn "Failed to restart $SIDECAR_UNIT"
    if _unit_running "$WEBRTC_UNIT"; then
        local ip; ip=$(_lan_ip)
        pok "PowStream restarted — connect at ${WEBRTC_SCHEME}://${ip}:${WEBRTC_PORT}/"
    else
        perr "WebRTC server failed to start. Check: powos stream logs"
    fi
}

stream_logs() {
    local lines="${1:-100}"
    journalctl --user -u "$WEBRTC_UNIT" -u "$SIDECAR_UNIT" \
        --no-hostname -n "$lines" --no-pager 2>/dev/null \
        || pwarn "No journal logs found for PowStream units."
}

# ── Setup: pre-seed the XDG screencast portal restore token ─────────
# The KDE screencast portal shows a consent dialog on the PHYSICAL
# monitor — invisible to a remote user. Running `setup` once on the
# local console stores a restore token so future captures are silent.
stream_setup() {
    echo -e "${BOLD}PowStream Setup — Portal Restore Token${NC}"
    echo "════════════════════════════════════════"
    echo ""

    if [[ -f "$TOKEN_PATH" ]] && [[ -s "$TOKEN_PATH" ]]; then
        pok "Restore token already exists: $TOKEN_PATH"
        echo "  To re-create: delete the file, then re-run this command."
        return 0
    fi

    # Check if we have a display (needed for portal dialog)
    if [[ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
        perr "No display session detected."
        perr "This command must be run once on the LOCAL console (physical monitor)"
        perr "so the KDE screencast consent dialog can appear and be approved."
        perr "After approval the restore token is saved and remote sessions"
        perr "can capture without the dialog."
        return 1
    fi

    plog "Requesting a screencast portal session…"
    plog "A KDE consent dialog will appear — approve it to save the restore token."
    echo ""

    # Use the PowStream server itself to do the portal handshake if available,
    # otherwise fall back to a minimal portal request via busctl/gdbus.
    local server_bin="/usr/lib/powstream/bin/powstream-webrtc-server"
    if [[ -x "$server_bin" ]]; then
        # Start the server briefly — it does the portal handshake on startup
        # and saves the token. We just need it to run long enough to complete.
        mkdir -p "$(dirname "$TOKEN_PATH")"
        plog "Starting PowStream server for portal handshake…"
        systemctl --user start "$WEBRTC_UNIT" 2>/dev/null || true
        # Wait for the token to appear (portal dialog must be approved)
        local waited=0
        while [[ ! -s "$TOKEN_PATH" ]] && (( waited < 60 )); do
            sleep 2
            waited=$((waited + 2))
        done
        if [[ -s "$TOKEN_PATH" ]]; then
            pok "Portal token saved at $TOKEN_PATH"
            pok "Future captures will be dialog-free (including remote sessions)."
        else
            pwarn "Token not saved within 60s. Did you approve the KDE dialog?"
            pwarn "The dialog appears on the physical monitor only."
            pwarn "Retry: powos stream setup"
        fi
    else
        perr "PowStream server binary not found."
        perr "Install the overlay first: powos overlay build powstream && powos overlay enable powstream"
        return 1
    fi
}

# ── Per-game capture opt-in ───────────────────────────────────────────────────
# The depth/camera capture layer (VK_LAYER_POWSTREAM_capture) is an IMPLICIT
# Vulkan layer — it must be enabled PER GAME, never globally, so it never loads
# into a game you're not streaming (and NEVER into an anti-cheat title, where its
# present hook + game-memory read/write is a ban risk). Not every game supports
# the ATW/reprojection either, so opt-in is the right model.
POWSTREAM_LAYER="VK_LAYER_POWSTREAM_capture"
STREAM_GAMES_LIST="${XDG_CONFIG_HOME:-$HOME/.config}/powstream/games.list"

# Run a command with capture ON for THAT process only (env is inherited by the
# game; exec replaces this shell). This is the per-game enable for any launcher.
#
#   powos stream launch [--game NAME] -- <command> [args…]
#
# --game NAME sets POWSTREAM_GAME so the detector tags its profile
# (cam_profile.NAME.json) instead of guessing from a mapped .exe. Proton titles
# self-name from the .exe, but a NATIVE game (Minecraft's `java`) has none, so
# without this its profile lands under "unknown" (or collides with other `java`
# titles). Optional — omit it for Steam/Proton games.
stream_launch() {
    local game=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --game)   game="${2:-}"; shift 2 || { perr "--game needs a name"; return 1; } ;;
            --game=*) game="${1#--game=}"; shift ;;
            --)       shift; break ;;
            *)        break ;;   # first non-flag = start of the command
        esac
    done
    [[ $# -gt 0 ]] || { perr "usage: powos stream launch [--game NAME] -- <command> [args…]"; return 1; }
    plog "Launching with PowStream capture ${GREEN}ON${NC} (this process only)${game:+ as ${BOLD}$game${NC}}: ${DIM}$*${NC}"
    # Two independent gates both have to be right or capture silently no-ops:
    #
    #  1. -u POWSTREAM_CAPTURE_DISABLE, NOT DISABLE= : the Vulkan loader disables
    #     an implicit layer whenever its disable_environment var is *defined at
    #     all* — an empty value still counts as "disable". Setting it to "" would
    #     silently disable the very layer we're enabling. Removing it from the
    #     child env is the only way to clear an inherited kill-switch here.
    #
    #  2. POWSTREAM_FORCE_ACTIVE=1 : the layer's streaming_active() gate (checked
    #     once at vkCreateDevice) keeps it DORMANT — inserted but hooking nothing,
    #     streaming no frames — until either the <dump>/streaming.active sentinel
    #     exists or a force flag is set. Nothing in the PowOS integration creates
    #     that sentinel (the server/sidecar don't; only the e2e harness does), so
    #     without this an explicit `powos stream launch` would capture nothing.
    #     The env flag is per-process: it dies with the game, leaves no global
    #     marker to clean up, and honours the same per-game opt-in as CAPTURE.
    exec env -u POWSTREAM_CAPTURE_DISABLE POWSTREAM_CAPTURE=1 POWSTREAM_FORCE_ACTIVE=1 \
        ${game:+POWSTREAM_GAME="$game"} "$@"
}

# The env that GUARANTEES the layer never loads — for wrappers around
# anti-cheat games (e.g. the FiveM launcher) to apply. Prints "VAR=val VAR=val".
stream_safe_env() {
    printf 'POWSTREAM_CAPTURE_DISABLE=1 VK_LOADER_LAYERS_DISABLE=%s' "$POWSTREAM_LAYER"
}

# Steam per-game enable: the launch-option string to paste into a game's
# Properties → Launch Options (Steam stores it per game — the natural opt-in).
stream_steam_option() {
    echo "Paste into the game's Steam → Properties → Launch Options:"
    echo -e "  ${BOLD}POWSTREAM_CAPTURE=1 %command%${NC}"
    echo -e "  ${DIM}Only for a game you actually stream with ATW — NEVER an anti-cheat title.${NC}"
}

# Curated registry of games where the depth/camera capture (ATW/reprojection) is
# actually developed. The layer reads engine-specific camera/projection state, so
# it only works on games it's been built + verified against — this is opt-in per
# game, never global. status: tested (validated) | dev (in development, unverified).
# id|display|status  — ids match `powos game` where applicable.
stream_supported() {
    cat <<'LIST'
gtav|Grand Theft Auto V|tested
minecraft|Minecraft (native Vulkan)|dev
rdr2|Red Dead Redemption 2|dev
cyberpunk2077|Cyberpunk 2077|dev
LIST
}
_stream_support_status() {  # echo tested|dev|"" for an id/alias
    local q="${1,,}"
    case "$q" in
        gta|gta5|gtav) q=gtav ;;
        cp2077|cyberpunk) q=cyberpunk2077 ;;
        rdr|rdr2) q=rdr2 ;;
        mc|minecraft) q=minecraft ;;
    esac
    stream_supported | awk -F'|' -v q="$q" 'tolower($1)==q{print $3}'
}

stream_games() {
    echo -e "${BOLD}PowStream capture — supported games${NC}  ${DIM}(ATW/reprojection; opt-in per game)${NC}"
    local id disp st mark on
    while IFS='|' read -r id disp st; do
        [[ -n "$id" ]] || continue
        if [[ "$st" == tested ]]; then mark="${GREEN}● tested${NC}"; else mark="${YELLOW}◐ in dev${NC}"; fi
        on=""; grep -qxF "$id" "$STREAM_GAMES_LIST" 2>/dev/null && on="  ${CYAN}[enabled]${NC}"
        printf '  %-16s %-26s %b%b\n' "$id" "$disp" "$mark" "$on"
    done < <(stream_supported)
    echo
    echo -e "  ${DIM}enable: powos stream enable <id> · then launch: powos stream launch -- <cmd>${NC}"
    echo -e "  ${DIM}Steam: powos stream steam-option (paste into the game's launch options)${NC}"
}
stream_enable() {
    [[ -n "${1:-}" ]] || { perr "usage: powos stream enable <game>"; return 1; }
    local st; st="$(_stream_support_status "$1")"
    if [[ -z "$st" ]]; then
        pwarn "'$1' isn't a known ATW-supported game — capture likely won't reproject correctly."
        pwarn "Supported: $(stream_supported | cut -d'|' -f1 | tr '\n' ' ')"
    elif [[ "$st" == dev ]]; then
        pwarn "'$1' capture is IN DEVELOPMENT (unverified) — expect rough edges."
    fi
    mkdir -p "$(dirname "$STREAM_GAMES_LIST")"; touch "$STREAM_GAMES_LIST"
    grep -qxF "$1" "$STREAM_GAMES_LIST" 2>/dev/null || echo "$1" >> "$STREAM_GAMES_LIST"
    pok "'$1' opted into capture${st:+ ($st)}."
    plog "Launch it with:  powos stream launch -- <its command>"
    plog "Steam game?      powos stream steam-option   (paste the launch option instead)"
}
stream_disable() {
    [[ -n "${1:-}" ]] || { perr "usage: powos stream disable <game>"; return 1; }
    if [[ -f "$STREAM_GAMES_LIST" ]]; then
        grep -vxF "$1" "$STREAM_GAMES_LIST" > "$STREAM_GAMES_LIST.tmp" 2>/dev/null \
            && mv "$STREAM_GAMES_LIST.tmp" "$STREAM_GAMES_LIST"
    fi
    pok "'$1' removed from the capture allowlist."
}

stream_usage() {
    cat <<EOF
PowStream — WebRTC streaming status & control

Usage: powos stream [command]

Services:
  status    Show status (services, token, connect URL, capture mode)
  start     Start the WebRTC server + detector sidecar
  stop      Stop all PowStream services
  restart   Restart all PowStream services
  logs [N]  Tail PowStream logs (default: last 100 lines)
  setup     Pre-seed the screencast portal restore token
            (run once on the local console to enable dialog-free capture)

Per-game depth/camera capture (ATW) — opt-in, never global:
  launch [--game NAME] -- <cmd>
                    Run a game with the capture layer ON for that process only.
                    --game NAME tags the detector profile (cam_profile.NAME.json);
                    needed for native games (e.g. Minecraft) that have no .exe to
                    self-name from. Omit for Steam/Proton titles.
  steam-option      Print the Steam launch option to enable capture for a game
  enable <game>     Opt a supported game into capture (allowlist record)
  disable <game>    Remove a game from the allowlist
  games             Supported games + status (GTA tested; RDR2/Cyberpunk in dev)

  ${DIM}The capture layer hooks the game (reads camera matrix, writes freecam pose).
  NEVER enable it for anti-cheat games (BattlEye/EAC) — it is a ban risk.${NC}

The PowStream overlay must be built + enabled first:
  powos overlay build powstream && powos overlay enable powstream
EOF
}

cmd_stream() {
    local sub="${1:-help}"; shift 2>/dev/null || true
    case "$sub" in
        status|st)     stream_status ;;
        start)         stream_start ;;
        stop)          stream_stop ;;
        restart)       stream_restart ;;
        logs|log)      stream_logs "${1:-100}" ;;
        setup)         stream_setup ;;
        launch|run)    stream_launch "$@" ;;
        steam-option|steam) stream_steam_option ;;
        games)         stream_games ;;
        enable|on)     stream_enable "${1:-}" ;;
        disable|off)   stream_disable "${1:-}" ;;
        safe-env)      stream_safe_env; echo ;;
        help|-h|--help) stream_usage ;;
        *) perr "Unknown: powos stream $sub"; stream_usage; return 1 ;;
    esac
}
