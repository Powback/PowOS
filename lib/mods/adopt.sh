#!/bin/bash
# mods/adopt.sh — Adopt existing mods from a dirty game directory.
#
# Scans a modded game dir against the Steam depot baseline, identifies
# untracked files, attributes them to known mod managers or groups them
# as "unknown-mod-N", then pulls each into a staging dir and creates
# manifest entries.
#
# This is THE migration verb — the user's Cyberpunk is already modded
# and broken. `adopt` ingests that state into the manifest so verify,
# doctor, rollback, and the overlay system can manage it.
#
# Requires: core.sh sourced first.

set -uo pipefail

# This module's own directory — adopt.py (the scanner) ships right beside it,
# in both the installed image and a source checkout, exactly like vu-rcon.py.
MODS_ADOPT_PY="${MODS_ADOPT_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/adopt.py}"

# ── adopt command ──────────────────────────────────────────────────────

mods_adopt_cmd() {
    local game="${1:?Usage: powos mods adopt <game> [--dry-run]}"
    local dry_run=false
    [[ "${2:-}" == "--dry-run" ]] && dry_run=true

    mods_load_game_conf "$game" || return 1
    local game_dir
    game_dir="$(mods_game_dir "$GAME_APPID")" || {
        perr "Game not installed (appid $GAME_APPID)."
        return 1
    }

    echo -e "${BOLD}Adopt: scanning ${GAME_NAME}${NC}"
    echo "Game dir: $game_dir"
    echo ""

    # Initialize manifest if needed
    if ! $dry_run; then
        mods_manifest_init "$game" >/dev/null 2>&1
    fi

    # Run the adoption scanner. It lives in adopt.py rather than a heredoc:
    # 297 lines of Python inside this function made build/complexity.py — which
    # cannot see heredoc boundaries — score mods_adopt_cmd at CC 53, when the
    # shell around it branches eight times.
    [[ -f "$MODS_ADOPT_PY" ]] || { perr "adopt.py missing at $MODS_ADOPT_PY"; return 1; }
    python3 "$MODS_ADOPT_PY" "$game_dir" "$game" "$MODS_STAGING_DIR/$game" \
              "$MODS_MANIFEST_DIR/${game}.json" \
              "$($dry_run && echo True || echo False)" \
              "$GAME_APPID" \
              "${GAME_NEXUS_SLUG:-}"

    if ! $dry_run; then
        pok "Adoption complete. Mods are now tracked in the manifest."
        plog "Next steps:"
        echo "  1. ${BOLD}powos mods list $game${NC}      — review adopted mods"
        echo "  2. ${BOLD}powos mods verify $game${NC}    — check integrity"
        echo "  3. ${BOLD}powos mods deploy $game${NC}    — mount overlay"
        echo "  4. ${BOLD}powos mods doctor $game${NC}    — diagnose issues"
    fi
}
