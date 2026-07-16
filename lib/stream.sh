#!/bin/bash
# stream.sh - PowStream status & control wrapper.
#
# The PowStream overlay ships user units that autostart at login:
#   powstream-webrtc-server.service  (WebRTC server, default :8080)
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
WEBRTC_PORT=8080

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

    # Connect URL
    if [[ "$ws_state" == "active" ]]; then
        local ip; ip=$(_lan_ip)
        echo ""
        echo -e "  ${CYAN}Connect:${NC} http://${ip}:${WEBRTC_PORT}/"
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
        pok "PowStream running — connect at http://${ip}:${WEBRTC_PORT}/"
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
        pok "PowStream restarted — connect at http://${ip}:${WEBRTC_PORT}/"
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

stream_usage() {
    cat <<EOF
PowStream — WebRTC streaming status & control

Usage: powos stream [command]

Commands:
  (none)    Show status (services, token, connect URL)
  start     Start the WebRTC server + detector sidecar
  stop      Stop all PowStream services
  restart   Restart all PowStream services
  logs      Tail PowStream logs (default: last 100 lines)
  logs N    Tail last N lines
  setup     Pre-seed the screencast portal restore token
            (run once on the local console to enable dialog-free capture)

The PowStream overlay must be built + enabled first:
  powos overlay build powstream && powos overlay enable powstream
EOF
}

cmd_stream() {
    local sub="${1:-status}"; shift 2>/dev/null || true
    case "$sub" in
        status|st|"")  stream_status ;;
        start)         stream_start ;;
        stop)          stream_stop ;;
        restart)       stream_restart ;;
        logs|log)      stream_logs "${1:-100}" ;;
        setup)         stream_setup ;;
        help|-h|--help) stream_usage ;;
        *) perr "Unknown: powos stream $sub"; stream_usage; return 1 ;;
    esac
}
