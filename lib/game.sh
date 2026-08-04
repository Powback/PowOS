#!/bin/bash
# game.sh - Game-centric facade: `powos game <name> <verb>`
#
# WHY THIS EXISTS: "I have BF3 — what can PowOS do with it?" had no single
# answer. Game-scoped work was scattered across `powos mods <verb> <game>`
# (10 verbs), `powos mods vu` (Venice Unleashed), and `powos games` (which
# confusingly meant the DISK PARTITION, not your games).
#
# This is a FACADE, deliberately. It dispatches to the existing subsystems and
# owns no state of its own — `powos mods <verb> <game>` keeps working
# unchanged for scripts and muscle memory. Two spellings, one implementation.
#
# Naming contract:
#   powos game  <name> <verb>   ONE game (this file)
#   powos games [list]          the COLLECTION (game_list_cmd, below)
#   powos games storage <verb>  the POWOS-GAMES disk partition (lib/games.sh)
#
# The registry is config/mods/games.d/*.conf — the same source of truth the
# mod manager uses — plus Venice Unleashed, which is a standalone client
# rather than a games.d entry.
#
# NOTE: sourced into bin/powos — must NOT set -e/-u/pipefail at top level.

source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh" 2>/dev/null || {
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
    plog()  { echo -e "${CYAN}[game]${NC} $*"; }
    pok()   { echo -e "${GREEN}[game]${NC} $*"; }
    pwarn() { echo -e "${YELLOW}[game]${NC} $*"; }
    perr()  { echo -e "${RED}[game]${NC} $*" >&2; }
}

GAME_LIB_DIR="${GAME_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ── Registry ──────────────────────────────────────────────────────────────────

# Defer to core.sh's definition so the facade sees EXACTLY the games the mod
# manager sees. The fallback only applies when core.sh isn't loaded (e.g. the
# bare listing, which deliberately avoids pulling in the whole mod manager).
game_conf_dirs() {
    if declare -f mods_games_conf_dirs >/dev/null 2>&1; then
        mods_games_conf_dirs
        return
    fi
    echo "${MODS_GAMES_CONF_DIR:-/usr/lib/powos/mods/games.d}"
    echo "${POWOS_SRC:-/var/lib/powos/src}/config/mods/games.d"
    echo "$GAME_LIB_DIR/../config/mods/games.d"
}

game_conf_path() {
    local id="$1" dir
    while read -r dir; do
        [[ -f "$dir/${id}.conf" ]] && { printf '%s' "$dir/${id}.conf"; return 0; }
    done < <(game_conf_dirs)
    return 1
}

game_registry_ids() {
    local dir f
    while read -r dir; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/*.conf; do
            [[ -f "$f" ]] || continue
            basename "$f" .conf
        done
        return 0   # first directory that exists wins, matching core.sh
    done < <(game_conf_dirs)
}

# Read one key out of a game conf without sourcing it (cheap + no var bleed).
game_conf_get() {
    local id="$1" key="$2" conf
    conf="$(game_conf_path "$id" 2>/dev/null)" || return 1
    local line
    line="$(grep -m1 "^${key}=" "$conf" 2>/dev/null)" || return 1
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    printf '%s' "$line"
}

game_is_vu() {
    case "${1,,}" in
        bf3|battlefield3|"battlefield 3"|vu|venice|venice-unleashed|"venice unleashed") return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve any spelling a user might type to a canonical games.d id.
#
# Order matters: an exact conf name wins, then the mod manager's existing
# alias table (mods_appid_of) is used to reach the conf by appid. That keeps
# ONE alias table in the tree instead of a second one drifting here.
game_resolve() {
    local want="$1"
    [[ -n "$want" ]] || return 1

    # 1. Already canonical.
    game_conf_path "$want" >/dev/null 2>&1 && { printf '%s' "$want"; return 0; }

    # 2. Alias/appid via the mod manager's table.
    local appid=""
    if declare -f mods_appid_of >/dev/null 2>&1; then
        appid="$(mods_appid_of "$want" 2>/dev/null || true)"
    elif [[ "$want" =~ ^[0-9]+$ ]]; then
        appid="$want"
    fi
    if [[ -n "$appid" ]]; then
        local id
        while read -r id; do
            [[ "$(game_conf_get "$id" GAME_APPID 2>/dev/null)" == "$appid" ]] \
                && { printf '%s' "$id"; return 0; }
        done < <(game_registry_ids)
    fi
    return 1
}

# ── Listing (`powos games` / `powos game` with no name) ───────────────────────

# Best-effort state for one game. Never fails the listing — a broken manifest
# or a missing subsystem must not stop you seeing the rest of your games.
_game_state_summary() {
    local id="$1" count="" deployed=""

    if declare -f mods_manifest_count >/dev/null 2>&1; then
        count="$(mods_manifest_count "$id" 2>/dev/null || true)"
    fi
    [[ -n "$count" ]] || count=0

    local mf=""
    if declare -f mods_manifest_path >/dev/null 2>&1; then
        mf="$(mods_manifest_path "$id" 2>/dev/null || true)"
    fi
    if [[ -n "$mf" && -f "$mf" ]]; then
        deployed="$(python3 -c 'import json,sys
try: print("yes" if json.load(open(sys.argv[1])).get("overlay_mounted") else "no")
except Exception: print("")' "$mf" 2>/dev/null || true)"
    fi

    local s
    if [[ "$count" == "0" ]]; then
        s="${DIM}no mods${NC}"
    else
        s="$count mod$([[ "$count" == "1" ]] || echo s)"
        case "$deployed" in
            yes) s="$s, ${GREEN}deployed${NC}" ;;
            no)  s="$s, ${YELLOW}not deployed${NC}" ;;
        esac
    fi
    printf '%s' "$s"
}

game_list_cmd() {
    echo -e "${BOLD}Games${NC}"
    echo    "════════════════════════════════════════"

    local any=false id label
    while read -r id; do
        [[ -n "$id" ]] || continue
        any=true
        label="$(game_conf_get "$id" GAME_NAME 2>/dev/null || true)"
        printf "  %-16s %-38s %b\n" "$id" "${label:-$id}" "$(_game_state_summary "$id")"
    done < <(game_registry_ids)

    # Venice Unleashed isn't a games.d entry — it's a whole standalone client.
    if declare -f vu_installed >/dev/null 2>&1 && vu_installed 2>/dev/null; then
        any=true
        local vu_state="client installed"
        vu_has_d3dcompiler 2>/dev/null \
            || vu_state="${YELLOW}d3dcompiler missing${NC}"
        printf "  %-16s %-38s %b\n" "bf3" "Battlefield 3 (Venice Unleashed)" "$vu_state"
    fi

    # FiveM (GTA V multiplayer) — server+client stack, shown if an engine exists.
    if declare -f fivem_server_installed >/dev/null 2>&1 || [[ -f "${POWOS_LIB:-$GAME_LIB_DIR}/mods/fivem.sh" ]]; then
        _game_need_fivem 2>/dev/null || true
        if declare -f fivem_server_installed >/dev/null 2>&1; then
            local fm_state="${DIM}not installed${NC}"
            if fivem_server_installed legacy 2>/dev/null || fivem_server_installed enhanced 2>/dev/null; then
                any=true; fm_state="server ready"
            fi
            printf "  %-16s %-38s %b\n" "fivem" "GTA V multiplayer (Legacy + Enhanced)" "$fm_state"
        fi
    fi

    $any || echo -e "  ${DIM}No games configured.${NC}"

    echo
    echo -e "  ${DIM}powos game <name>            what PowOS can do with one game${NC}"
    echo -e "  ${DIM}powos games storage status   the shared POWOS-GAMES partition${NC}"
    echo
}

# ── Per-game facade ───────────────────────────────────────────────────────────

_game_need_mods() {
    local m="${POWOS_LIB:-$GAME_LIB_DIR}/mods"
    # shellcheck source=/dev/null
    for f in core.sh install.sh; do
        [[ -f "$m/$f" ]] && source "$m/$f"
    done
}

_game_need_vu() {
    local m="${POWOS_LIB:-$GAME_LIB_DIR}/mods"
    # shellcheck source=/dev/null
    [[ -f "$m/modlist.sh" ]] && source "$m/modlist.sh"
    [[ -f "$m/vu.sh" ]] && source "$m/vu.sh"
}

# FiveM (GTA V multiplayer) is a server+client stack of its own, not a games.d
# game and not the SP ASI flow that `powos game gtav` drives.
game_is_fivem() {
    case "${1,,}" in
        fivem|fxserver|cfx|"fivem legacy"|fivem-legacy|"fivem enhanced"|fivem-enhanced) return 0 ;;
    esac
    return 1
}
_game_need_fivem() {
    local m="${POWOS_LIB:-$GAME_LIB_DIR}/mods"
    # shellcheck source=/dev/null
    [[ -f "$m/fivem.sh" ]] && source "$m/fivem.sh"
}
_game_fivem_dispatch() {
    _game_need_fivem
    declare -f cmd_mods_fivem >/dev/null 2>&1 || { perr "FiveM module unavailable."; return 1; }
    cmd_mods_fivem "$@"
}

# `powos game bf3 <verb>` — Venice Unleashed owns its own verb set, so hand
# the whole thing to it rather than pretending BF3 is a games.d game.
_game_vu_dispatch() {
    local verb="${1:-status}"; shift 2>/dev/null || true
    _game_need_vu
    declare -f cmd_mods_vu >/dev/null 2>&1 || { perr "Venice Unleashed module unavailable."; return 1; }
    case "$verb" in
        # Facade spellings that differ from VU's own.
        mod|mods) perr "Venice Unleashed mods are VEXT mods, not Nexus mods — see docs.veniceunleashed.net"; return 1 ;;
        *) cmd_mods_vu "$verb" "$@" ;;
    esac
}

game_status_cmd() {
    local id="$1"
    local label; label="$(game_conf_get "$id" GAME_NAME 2>/dev/null || true)"
    local appid; appid="$(game_conf_get "$id" GAME_APPID 2>/dev/null || true)"
    local backend; backend="$(game_conf_get "$id" GAME_BACKEND 2>/dev/null || true)"
    local slug; slug="$(game_conf_get "$id" GAME_NEXUS_SLUG 2>/dev/null || true)"

    echo -e "${BOLD}${label:-$id}${NC}"
    echo    "════════════════════════════════════════"
    echo -e "  id:        $id"
    [[ -n "$appid"   ]] && echo -e "  steam:     $appid"
    [[ -n "$backend" ]] && echo -e "  backend:   $backend"
    [[ -n "$slug"    ]] && echo -e "  nexus:     $slug"
    echo -e "  mods:      $(_game_state_summary "$id")"
    echo

    # Defer the detailed view to the subsystem that owns it.
    if declare -f mods_status_cmd >/dev/null 2>&1; then
        mods_status_cmd "$id" 2>/dev/null || true
    fi
}

game_help() {
    cat <<EOF
${BOLD}powos game${NC} — everything PowOS can do with ONE game

  powos game                       List your games (same as 'powos games')
  powos game <name>                What PowOS knows about this game
  powos game <name> <verb> [args]  Act on it

Verbs (thin wrappers — each dispatches to the subsystem that owns it):
  status                  Registry info + mod/deploy state
  mod install <id…>       Install Nexus mod(s)          → powos mods install
  mod list                Installed mods                → powos mods list
  mod enable|disable <id> Toggle a mod
  mod remove <id…>        Remove mod(s)
  deploy | undeploy       Mount/unmount the mod overlay
  setup                   protontricks + WINEDLLOVERRIDES for the prefix
  verify                  Headless launch → crash/freeze/booted verdict
  snapshot | rollback     Snapshot / restore a mod loadout
  adopt                   Absorb a manually-modded game dir
  export | import         Portable mod list
  play                    Launch the game

Names: any spelling the mod manager accepts — canonical id (gtav), alias
(gta, gta5), or Steam appid (3240220). 'bf3' / 'vu' routes to Venice
Unleashed, which has its own verbs (see 'powos mods vu help').

'fivem' routes to the GTA V multiplayer stack (server + client, Legacy &
Enhanced) — a separate thing from 'gtav' (single-player ASI mods). See
'powos game fivem help'.

${BOLD}This is a facade.${NC} 'powos mods <verb> <game>' does the same work and
keeps working — use whichever reads better. Storage lives elsewhere:
'powos games storage' for the shared POWOS-GAMES partition.
EOF
}

cmd_game() {
    local name="${1:-}"; shift 2>/dev/null || true

    # Bare `powos game` == the collection listing.
    case "$name" in
        ""|list|ls)      _game_need_mods; _game_need_vu; game_list_cmd; return $? ;;
        help|-h|--help)  game_help; return 0 ;;
    esac

    # Venice Unleashed is a client, not a games.d game.
    if game_is_vu "$name"; then
        _game_vu_dispatch "$@"
        return $?
    fi

    # FiveM (GTA V multiplayer): server + client, its own verb set.
    if game_is_fivem "$name"; then
        _game_fivem_dispatch "$@"
        return $?
    fi

    _game_need_mods

    local id
    id="$(game_resolve "$name" 2>/dev/null || true)"
    if [[ -z "$id" ]]; then
        perr "Unknown game: $name"
        echo
        plog "Known games:"
        game_registry_ids | sed 's/^/    /'
        echo "    bf3   (Venice Unleashed)"
        plog "Aliases like 'gta', 'cyberpunk' or a Steam appid also work."
        return 1
    fi

    local verb="${1:-status}"; shift 2>/dev/null || true

    case "$verb" in
        status)   game_status_cmd "$id" ;;
        help|-h|--help) game_help ;;

        # `mod` is the sub-noun so `game <n> mod install` reads naturally;
        # `mods` is accepted because everyone types it.
        mod|mods)
            local mverb="${1:-list}"; shift 2>/dev/null || true
            local _m
            case "$mverb" in
                install)   powos_game_call mods_install_smart_cmd "$id" "$@" ;;
                list|ls)   powos_game_call mods_manifest_list "$id" ;;
                # These act per-mod, so the facade loops the same way the
                # `powos mods` dispatcher does.
                enable)    for _m in "$@"; do powos_game_call mods_enable_mod  "$id" "$_m" || return 1; done ;;
                disable)   for _m in "$@"; do powos_game_call mods_disable_mod "$id" "$_m" || return 1; done ;;
                remove|rm) for _m in "$@"; do powos_game_call mods_remove_mod  "$id" "$_m" || return 1; done ;;
                *) perr "Unknown: powos game $id mod $mverb"; game_help; return 1 ;;
            esac ;;

        deploy)    powos_game_call mods_deploy_cmd    "$id" "$@" ;;
        undeploy)  powos_game_call mods_undeploy_cmd  "$id" "$@" ;;
        setup)     powos_game_call mods_setup_cmd     "$id" "$@" ;;
        verify)    powos_game_call harness_verify_cmd "$id" "$@" ;;
        bisect)    powos_game_call harness_bisect_cmd "$id" "$@" ;;
        rollback)  powos_game_call mods_rollback_cmd  "$id" "$@" ;;
        adopt)     powos_game_call mods_adopt_cmd     "$id" "$@" ;;
        export)    powos_game_call mods_export_cmd    "$id" "$@" ;;
        import)    powos_game_call mods_import_cmd    "$id" "$@" ;;

        snapshot)
            if [[ "${1:-}" == "list" ]]; then
                powos_game_call mods_snapshot_list "$id"
            else
                powos_game_call mods_snapshot_create "$id" "${1:-manual}"
            fi ;;
        snapshots) powos_game_call mods_snapshot_list "$id" ;;

        # asi_dispatch takes <verb> <game> [args] — keep that order.
        asi)
            local averb="${1:-list}"; shift 2>/dev/null || true
            powos_game_call asi_dispatch "$averb" "$id" "$@" ;;

        play|launch)
            local appid; appid="$(game_conf_get "$id" GAME_APPID 2>/dev/null || true)"
            if [[ -z "$appid" ]]; then
                perr "No Steam appid for $id — can't launch it."
                return 1
            fi
            plog "Launching $id (steam appid $appid)…"
            xdg-open "steam://rungameid/$appid" >/dev/null 2>&1 \
                || { perr "Couldn't hand off to Steam."; return 1; } ;;

        *) perr "Unknown: powos game $id $verb"; game_help; return 1 ;;
    esac
}

# Source the module that provides FN on demand, then call it. Keeps `powos
# game` startup cheap (the listing needs almost nothing) while giving a clear
# error instead of "command not found" when a subsystem is missing.
powos_game_call() {
    local fn="$1"; shift
    if ! declare -f "$fn" >/dev/null 2>&1; then
        local m="${POWOS_LIB:-$GAME_LIB_DIR}/mods" f
        for f in core.sh install.sh deploy.sh snapshot.sh adopt.sh portable.sh harness.sh asi.sh; do
            [[ -f "$m/$f" ]] && source "$m/$f"
            declare -f "$fn" >/dev/null 2>&1 && break
        done
    fi
    if ! declare -f "$fn" >/dev/null 2>&1; then
        perr "Internal: $fn not available (subsystem not installed?)"
        return 1
    fi
    "$fn" "$@"
}
