#!/bin/bash
# mods/e2e.sh - `powos mods e2e`: drive a modded game and assert on what it does.
#
# The step past `powos mods verify`. Verify answers "did it boot and keep
# running" for any Steam game, from outside the process. That is the right
# question for a mod-compatibility sweep and the wrong one for "does this mod
# work" — a mod can load cleanly, run for the full timeout, and do nothing.
#
# e2e answers the second question. It launches the game the same way verify
# does, then adds the three things verify has no way to do:
#
#   * INPUT   — virtual controllers created through /dev/uinput, so the game
#               is driven the way a player drives it.
#   * STATE   — a channel into the running game that reports what it currently
#               believes: positions, health, scene, players. This is the part
#               that makes assertions possible, and the part each game has to
#               provide (see lib/mods/e2e/CONTRACT.md).
#   * VERDICT — named cases that pass or fail individually, with screenshots
#               and state snapshots kept as evidence.
#
# Everything game-specific lives in two files: config/mods/games.d/<game>.conf
# and lib/mods/e2e/scenarios/<game>.py. Adding a game is those two.
#
# Implementation is Python (lib/mods/e2e/); this file is the CLI face.

set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}/common.sh" 2>/dev/null || {
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
    plog()  { echo -e "${CYAN}[e2e]${NC} $*"; }
    pok()   { echo -e "${GREEN}[e2e]${NC} $*"; }
    pwarn() { echo -e "${YELLOW}[e2e]${NC} $*"; }
    perr()  { echo -e "${RED}[e2e]${NC} $*" >&2; }
}

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e"

e2e_help() {
    cat <<EOH
${BOLD}powos mods e2e${NC} — end-to-end test a modded game

  ${BOLD}powos mods e2e <game>${NC}              Launch, drive and assert. Exit 0 on pass.
  ${BOLD}powos mods e2e <game> --probe${NC}      Check every prerequisite, launch nothing
  ${BOLD}powos mods e2e <game> --no-launch${NC}  Use a game that is already running
  ${BOLD}powos mods e2e <game> --keep-running${NC}  Leave the game up afterwards
  ${BOLD}powos mods e2e list${NC}                Games with an e2e scenario
  ${BOLD}powos mods e2e selftest${NC}            Test the harness itself
  ${BOLD}powos mods e2e prove <game>${NC}        Run the scenario against a fake game and
                                      confirm every case FAILS when broken
  ${BOLD}powos mods e2e pads [--count N]${NC}    Create virtual controllers and take
                                      commands on a FIFO (manual poking)

Exit codes: 0 pass · 1 a case failed · 2 the harness or environment failed ·
3 nothing was actually observed (all cases skipped).

Evidence, screenshots and verdict.json land in
${DIM}\$XDG_STATE_HOME/powos/mods/e2e/<game>-<timestamp>/${NC}

${BOLD}Adding a game${NC} — see ${DIM}$E2E_DIR/CONTRACT.md${NC}. In short: the game
must expose live state somehow (a debug endpoint in the mod, a browser-engine
UI, or a JSON file it writes), and you write a conf plus a scenario.
EOH
}

e2e_python() {
    command -v python3 >/dev/null || { perr "python3 is required."; return 2; }
    python3 "$E2E_DIR/run.py" "$@"
}

e2e_list_cmd() {
    echo -e "${BOLD}Games with an e2e scenario${NC}"
    local found=0 f name conf
    for f in "$E2E_DIR"/scenarios/*.py; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f" .py)"
        [[ "$name" == "__init__" ]] && continue
        conf=""
        for d in "${MODS_GAMES_CONF_DIR:-}" \
                 "/usr/lib/powos/mods/games.d" \
                 "$(dirname "$E2E_DIR")/../../config/mods/games.d"; do
            [[ -n "$d" && -f "$d/$name.conf" ]] && { conf="$d/$name.conf"; break; }
        done
        if [[ -n "$conf" ]]; then
            echo -e "  ${GREEN}●${NC} $name  ${DIM}$conf${NC}"
        else
            echo -e "  ${YELLOW}○${NC} $name  ${DIM}scenario present, no games.d conf${NC}"
        fi
        found=1
    done
    [[ $found -eq 1 ]] || echo -e "  ${DIM}none${NC}"
}

e2e_dispatch() {
    case "${1:-help}" in
        -h|--help|help) e2e_help ;;
        list|ls)        shift; e2e_list_cmd "$@" ;;
        selftest)       shift; python3 "$E2E_DIR/selftest.py" "$@" ;;
        prove)          shift; python3 "$E2E_DIR/mockgame.py" "$@" ;;
        pads)           shift; python3 "$E2E_DIR/pads.py" "$@" ;;
        *)              e2e_python "$@" ;;
    esac
}
