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
  freeze                  Freeze it now with Steam (0% CPU, kept in RAM)  → powos-sleep-gui (unified sleep)
  thaw                    Thaw it and raise its window (what launching it does while it runs)
  stop [--steam]          Close it (its whole launch chain, wineserver too) within ~3 s, then wait (<=20 s) for
                          Steam's exit steps (cloud sync: never killed mid-sync, left to Steam: exit 4); --steam closes Steam
                          as well: asked to shut down, killed after 6 s (a frozen or dying client never stalls it)
  status                  (a Steam game outside the mod registry) running / frozen, CPU of its tree
  compat [status]         Which way it runs: native Linux build / ARM64 Proton / x86 Proton, what each launch measured
  compat auto|native|arm64|x86   Pick: auto = the fastest that worked (native, arm64, x86 until measured), or pin one
                          (written while Steam is off: at its next start)   → powos-steam-compat
  scale [auto|100|85|70|50]   Its render scale in % (Unity/Unreal: fewer pixels drawn, stretched to the screen);
                          auto = from its measured fps; from its next launch   → powos-steam-compat scale
  preboot [on|off|default]   Its Wine session booted while Steam prepares the launch (ARM64 Proton games;
                          default = POWOS_WINE_PREBOOT in ~/.config/powos/steam-env, off)   → powos-steam-compat preboot
  aot [status|on|off]     Mono AOT images (legacy-Mono Unity games, off by default): on places the images built off the
                          phone (tools/games/mono-aot.sh) beside the game's assemblies, skipping any whose assembly
                          changed since; off removes exactly those (manifest), never a game file   (from its next launch)
  window borderless|default   A Unity game that forces exclusive full screen (Besiege) runs windowed at the screen's
                          size instead (its own settings set at each launch, at scale 100); default puts its own back
                          → ~/.local/share/powos/unity-screen --window

A Steam game out of sight for 15 s is frozen with Steam on its own and launching it again resumes it at once
(units/phone/steam.json "games": "pause", docs/UNIFIED-SLEEP.md); freeze/thaw do it by hand.

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

    # A running Steam game's verbs (any installed Steam game, by name or appid - the mod registry not needed).
    case "${1:-}" in
        freeze|thaw|compat|scale|window|preboot|aot|stop|close) _game_steam_verb "$name" "$@"; return $? ;;
    esac

    _game_need_mods

    local id
    id="$(game_resolve "$name" 2>/dev/null || true)"
    if [[ -z "$id" ]] && [[ "${1:-status}" == status ]] && _game_steam_appid "$name" >/dev/null; then
        _game_sleep_dispatch "$name" status
        return $?
    fi
    [[ -n "$id" ]] || { _game_unknown "$name"; return 1; }

    local verb="${1:-status}"; shift 2>/dev/null || true

    case "$verb" in
        status)   game_status_cmd "$id" ;;
        help|-h|--help) game_help ;;

        # `mod` is the sub-noun so `game <n> mod install` reads naturally;
        # `mods` is accepted because everyone types it.
        mod|mods)  _game_mod "$id" "$@" ;;

        # mods_deploy_cmd, mods_undeploy_cmd, mods_setup_cmd, mods_rollback_cmd, mods_adopt_cmd, mods_export_cmd,
        # mods_import_cmd; harness_verify_cmd, harness_bisect_cmd.
        deploy|undeploy|setup|rollback|adopt|export|import) powos_game_call "mods_${verb}_cmd" "$id" "$@" ;;
        verify|bisect) powos_game_call "harness_${verb}_cmd" "$id" "$@" ;;

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

        play|launch) _game_play "$id" ;;

        *) perr "Unknown: powos game $id $verb"; game_help; return 1 ;;
    esac
}

_game_unknown() {
    perr "Unknown game: $1"
    echo
    plog "Known games:"
    game_registry_ids | sed 's/^/    /'
    echo "    bf3   (Venice Unleashed)"
    plog "Aliases like 'gta', 'cyberpunk' or a Steam appid also work."
}

# powos game <id> mod <verb> [mod...]
_game_mod() {
    local id="$1" mverb="${2:-list}" _m
    shift; shift 2>/dev/null || true
    case "$mverb" in
        install)   powos_game_call mods_install_smart_cmd "$id" "$@" ;;
        list|ls)   powos_game_call mods_manifest_list "$id" ;;
        # These act per-mod, so the facade loops the same way the
        # `powos mods` dispatcher does.
        enable)    for _m in "$@"; do powos_game_call mods_enable_mod  "$id" "$_m" || return 1; done ;;
        disable)   for _m in "$@"; do powos_game_call mods_disable_mod "$id" "$_m" || return 1; done ;;
        remove|rm) for _m in "$@"; do powos_game_call mods_remove_mod  "$id" "$_m" || return 1; done ;;
        *) perr "Unknown: powos game $id mod $mverb"; game_help; return 1 ;;
    esac
}

_game_play() {
    local id="$1" appid
    appid="$(game_conf_get "$id" GAME_APPID 2>/dev/null || true)"
    if [[ -z "$appid" ]]; then
        perr "No Steam appid for $id — can't launch it."
        return 1
    fi
    plog "Launching $id (steam appid $appid)…"
    xdg-open "steam://rungameid/$appid" >/dev/null 2>&1 \
        || { perr "Couldn't hand off to Steam."; return 1; }
}

# powos game <name> freeze|thaw|compat|stop|close: an installed Steam game, by name or appid.
_game_steam_verb() {
    local name="$1" verb="$2" app
    case "$verb" in freeze|thaw) _game_sleep_dispatch "$name" "$verb"; return $? ;; esac
    app="$(_game_steam_appid "$name")" || { perr "No installed Steam game called $name"; return 1; }
    case "$verb" in
        compat) _game_compat "$app" "${3:-status}" ;;
        scale)
            command -v powos-steam-compat >/dev/null || { perr "powos-steam-compat isn't installed (package steam)"; return 1; }
            powos-steam-compat scale "$app" ${3:+"$3"} ;;
        preboot)
            command -v powos-steam-compat >/dev/null || { perr "powos-steam-compat isn't installed (package steam)"; return 1; }
            powos-steam-compat preboot "$app" ${3:+"$3"} ;;
        window)
            local us="${XDG_DATA_HOME:-$HOME/.local/share}/powos/unity-screen"
            [[ -x "$us" ]] || { perr "unity-screen isn't installed ($us; a rooted deploy copies it)"; return 1; }
            "$us" --window "$app" "${3:-}" ;;
        aot) _game_aot "$app" "${3:-status}" ;;
        *) _game_steam_close "$app" "$([[ "${3:-}" == --steam ]] && echo 1 || echo 0)" ;;
    esac
}

# ── A running Steam game's sleep (unified sleep: lib/apps/powos-sleep-gui, docs/UNIFIED-SLEEP.md) ──────────────
# The facade owns nothing here: the session's watcher (powos-sleep-gui) freezes and thaws; this finds the game.

# Steam's library folders (the default one and every "path" in libraryfolders.vdf).
_game_steam_libs() {
    local s="${XDG_DATA_HOME:-$HOME/.local/share}/Steam"
    echo "$s/steamapps"
    awk -F'"' '$2 == "path" {print $4 "/steamapps"}' "$s/steamapps/libraryfolders.vdf" 2>/dev/null
}

# <name or appid> -> appid of an installed Steam game ("broforce", "Broforce", "274190").
_game_steam_appid() {
    local q="$1" lib f
    [[ "$q" =~ ^[0-9]+$ ]] && { echo "$q"; return 0; }
    while read -r lib; do
        for f in "$lib"/appmanifest_*.acf; do
            [[ -f "$f" ]] || continue
            if awk -F'"' -v q="$(tr '[:upper:]' '[:lower:]' <<<"$q")" \
                '$2 == "name" {n = tolower($4); if (n ~ /^proton|steam linux runtime|steamworks|^fex$/) exit 1
                 gsub(/[^a-z0-9]/, "", n); g = q; gsub(/[^a-z0-9]/, "", g)
                 exit !(n == g || index(n, g) == 1)}' "$f"; then
                f=${f##*appmanifest_}; echo "${f%.acf}"; return 0
            fi
        done
    done < <(_game_steam_libs | sort -u)
    return 1
}

# The game's launcher process (Steam's reaper SteamLaunch AppId=<appid>), if it runs.
# The one under the running Steam first: a launcher left behind by a dead Steam (ppid 1) isn't the game Steam runs.
# Not the install script evaluator Steam runs before each launch (`SteamLaunch AppId=<id> Install=1 --`): that one
# isn't the game (freeze/thaw said "running" while only the evaluator ran).
_game_steam_reaper() {  # bin/powos: errexit + pipefail
    local s p a
    s="$(cat "$HOME/.steam/steam.pid" 2>/dev/null || true)"
    for p in $(pgrep -f "SteamLaunch AppId=$1( --|\$)" || true); do
        a=$p
        while [[ -n "$a" && "$a" -gt 1 ]]; do
            [[ "$a" == "$s" ]] && { echo "$p"; return 0; }
            a="$(awk '{print $4}' "/proc/$a/stat" 2>/dev/null || true)"
        done
    done
    pgrep -f "SteamLaunch AppId=$1( --|\$)" | head -1 || true
}

# ── Mono AOT images (docs/research/broforce-engine-init.md lever 2; built by tools/games/mono-aot.sh) ──────────────
# Unity 2017.4's Mono opens "<assembly>.dll" beside each assembly (aot-runtime.c load_aot_module) and ignores it on a
# GUID / AOT version / runtime mismatch. The store holds what the build made; `on` places them in the game dir.
#   store  $POWOS_MONO_AOT_DIR/<appid>/ (default ~/.local/share/powos/mono-aot/<appid>/)
#          images/<path in game dir>.dll   images.tsv: <image path> \t <sha256 of its assembly> \t <GUID>
#          installed.tsv: <image path> \t <sha256 of the placed image>   (what `off` removes; nothing else)
_game_aot_store() { echo "${POWOS_MONO_AOT_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/powos/mono-aot}/$1"; }

_game_steam_dir() {  # <appid> -> the game's install dir
    local lib d
    while read -r lib; do
        [[ -f "$lib/appmanifest_$1.acf" ]] || continue
        d=$(awk -F'"' '$2 == "installdir" {print $4; exit}' "$lib/appmanifest_$1.acf")
        [[ -n "$d" && -d "$lib/common/$d" ]] && { echo "$lib/common/$d"; return 0; }
    done < <(_game_steam_libs | sort -u)
    return 1
}

_game_aot() {  # <appid> status|on|off
    local app=$1 st g rel sha guid n=0 stale=0 placed=0 kept=0 cur
    st=$(_game_aot_store "$app")
    g=$(_game_steam_dir "$app") || { perr "Steam game $app isn't installed"; return 1; }
    case "$2" in
        status)
            if [[ -s "$st/installed.tsv" ]]; then
                pok "aot on: $(wc -l < "$st/installed.tsv") images in $g"
            else
                if [[ -f "$st/images.tsv" ]]; then plog "aot off ($(wc -l < "$st/images.tsv") images built in $st)"
                else plog "aot off (nothing built: tools/games/mono-aot.sh all $app)"; fi
            fi ;;
        on)
            [[ -f "$st/images.tsv" ]] || { perr "No AOT images for $app in $st (build them: tools/games/mono-aot.sh all $app)"; return 1; }
            _game_aot "$app" off >/dev/null || return 1
            : > "$st/installed.tsv.new"
            while IFS=$'\t' read -r rel sha guid; do
                [[ -n "$rel" && "$rel" != *..* && -f "$st/images/$rel" ]] || continue
                n=$((n + 1))
                # A changed assembly (a game update: new GUID too) makes its image stale: Mono would ignore it, so
                # don't place it at all.
                cur=$(sha256sum < "$g/${rel%.dll}" 2>/dev/null | cut -d' ' -f1 || true)
                [[ "$cur" == "$sha" ]] || { stale=$((stale + 1)); continue; }
                # A file of that name that isn't ours (the game's own) is never replaced.
                [[ -e "$g/$rel" ]] && { kept=$((kept + 1)); continue; }
                ln "$st/images/$rel" "$g/$rel" 2>/dev/null || cp "$st/images/$rel" "$g/$rel" || continue
                printf '%s\t%s\n' "$rel" "$(sha256sum < "$g/$rel" | cut -d' ' -f1)" >> "$st/installed.tsv.new"
                placed=$((placed + 1))
            done < "$st/images.tsv"
            mv "$st/installed.tsv.new" "$st/installed.tsv"
            local msg="aot on: $placed of $n images placed in $g"
            (( stale )) && msg+=", $stale stale (assembly changed: rebuild with tools/games/mono-aot.sh all $app)"
            (( kept )) && msg+=", $kept not placed (a file of that name is already there)"
            pok "$msg"
            [[ $placed -gt 0 ]] ;;
        off)
            [[ -f "$st/installed.tsv" ]] || { plog "aot off (nothing placed)"; return 0; }
            while IFS=$'\t' read -r rel sha; do
                [[ -n "$rel" && "$rel" != *..* ]] || continue
                [[ -e "$g/$rel" ]] || continue
                if [[ "$(sha256sum < "$g/$rel" | cut -d' ' -f1)" == "$sha" ]]; then rm -f "$g/$rel"; n=$((n + 1))
                else pwarn "kept $g/$rel: changed since aot on placed it"; fi
            done < "$st/installed.tsv"
            rm -f "$st/installed.tsv"
            pok "aot off: $n images removed from $g" ;;
        *) perr "powos game <name> aot [status|on|off]"; return 2 ;;
    esac
}

# Which way a Steam game runs (native Linux build / ARM64 Proton / x86 Proton): the steam package's per-game policy.
_game_compat() {  # <appid> status|auto|native|arm64|x86|<tool name>
    command -v powos-steam-compat >/dev/null || { perr "powos-steam-compat isn't installed (package steam)"; return 1; }
    case "$2" in
        status) powos-steam-compat status "$1" ;;
        *) powos-steam-compat set "$1" "$2" ;;
    esac
}

_game_sleep_dispatch() {
    local name="$1" verb="$2" appid reaper
    appid="$(_game_steam_appid "$name")" || { perr "No installed Steam game called $name"; return 1; }
    reaper="$(_game_steam_reaper "$appid")"
    case "$verb" in
        freeze) _game_freeze "$name ($appid)" "$appid" "$reaper" ;;
        thaw)   _game_thaw "$name ($appid)" "$appid" "$reaper" ;;
        status) _game_sleep_status "$name ($appid)" "$reaper" ;;
    esac
}

_game_freeze() {  # <label> <appid> <reaper>
    local r
    [[ -n "$3" ]] || { perr "$1 isn't running."; return 1; }
    r="$(powos-sleep-gui sleep "$2")" || return 1
    case $r in
        *pending*) pok "$1: its window minimized, frozen with Steam in a moment" ;;
        *'"ok": true'*) pok "$1: frozen with Steam" ;;
        *) perr "$1: not frozen: $r"; return 1 ;;
    esac
}

_game_thaw() {  # <label> <appid> <reaper>
    local r
    [[ -n "$3" ]] || { perr "$1 isn't running (start it: steam steam://rungameid/$2)."; return 1; }
    r="$(powos-sleep-gui resume "$2")" || return 1
    case $r in
        *'"running": true'*) pok "$1: $r" ;;
        *) perr "$1: not resumed (not a game of the running Steam): $r"; return 1 ;;
    esac
}

_game_sleep_status() {  # <label> <reaper>
    local cg pids t0 t1
    [[ -n "$2" ]] || { echo "$1: not running"; return 0; }
    cg="$(cat "/proc/$2/cgroup" 2>/dev/null)"
    pids="$(_game_tree "$2")"
    t0="$(_game_ticks $pids)"; sleep 2; t1="$(_game_ticks $pids)"
    printf '%s: running, %s; its tree %s processes, %s%% of a core (2 s)\n' "$1" \
        "$([[ $cg == *powos/sleep/* ]] && echo "FROZEN with Steam (${cg##*/sleep/})" || echo awake)" \
        "$(wc -w <<<"$pids" | tr -d ' ')" "$(( (t1 - t0) * 100 / $(getconf CLK_TCK) / 2 ))"
}

# Every process of a Steam game's launch: the trees of its reapers (also one a dead Steam left, ppid 1) and any process
# of ours whose environment names the game or its Proton prefix (wineserver outlives the chain, reparented to 1).
# One ps + one grep, no per-process forks: it runs in _game_steam_close's loop.
_game_launch_pids() {  # <appid>
    local roots
    roots=$(pgrep -f "SteamLaunch AppId=$1( |\$)" | tr '\n' ' ' || true)
    [[ -n "$roots" ]] && _game_descendants $roots
    grep -lzx -e "SteamAppId=$1" -e "SteamGameId=$1" -e "STEAM_COMPAT_APP_ID=$1" -e "WINEPREFIX=.*/compatdata/$1/pfx/*" \
        /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3 || true
}

# Steam itself: its client's tree, launchers (/usr/bin/steam, Valve's steam.sh: it restarts a killed client) and
# every program run from Steam's dir (web helpers, FEX's wineserver) - by the program's path, so a shell that merely
# names a Steam file isn't one.
_game_steam_pids() {
    local s; s="$(cat "$HOME/.steam/steam.pid" 2>/dev/null || true)"
    [[ -n "$s" && -d /proc/$s ]] && _game_descendants "$s"
    pgrep -u "$(id -u)" -f "^[^ ]*/\.local/share/Steam/|^\./steam( |\$)|^[^ ]*sh [^ ]*(/usr/bin/steam|/Steam/steam\.sh)( |\$)" || true
}

# <pid>...: them and all their descendants, one per line (one ps call).
_game_descendants() {
    ps -e -o pid=,ppid= 2>/dev/null | awk -v r=" $* " '{c[$2] = c[$2] " " $1}
        END {n = split(r, q, " "); for (i = 1; i <= n; i++) {p = q[i]; if (p == "" || s[p]++) continue; print p
             m = split(c[p], k, " "); for (j = 1; j <= m; j++) q[++n] = k[j]}}' || true
}

# _game_steam_close <appid> <1: Steam too>: the game closed gracefully, then Steam's exit steps for it awaited; Steam
# (with --steam) asked to shut down only after them. TERM the game's chain; what is left after 2 s is KILLed - unless
# Steam's log says a cloud sync of the game runs (_game_steam_exit_state): that is never killed. Once the chain is
# gone, Steam's exit steps (cloud sync, "App Running" cleared) are awaited, all within ~20 s. A sync still running
# then: the game is left for Steam to finish (exit 4, logged) - killing it or Steam mid-sync left Broforce held on a
# sync-conflict question 11-08 ~03:20 ("Steam is asking something"), which then SKIPped every game check.
# Steam: thawed (a frozen client never answers), asked with -shutdown, KILLed after 6 s; then one more sweep for
# anything a launcher started meanwhile. Every wait is bounded and only stats /proc (and the log every 0.5 s).
# _gsc_steam_chain: Steam's client pid and its ancestors, space-separated - kept alive when only the game closes.
_gsc_steam_chain() {
    local a; a="$(cat "$HOME/.steam/steam.pid" 2>/dev/null || true)"
    while [[ -n "$a" && "$a" -gt 1 ]]; do printf '%s ' "$a"; a="$(awk '{print $4}' "/proc/$a/stat" 2>/dev/null || true)"; done
}

# _game_steam_exit_state <appid> <since: epoch s> [<log dir>]: what Steam's logs (console_log + content_log, the ones
# bf-ask.sh reads) say about APP's exit, one word:
#   sync         its newest GameAction (of the last 10 min) is "<Action> changed task to SynchronizingCloud": a cloud
#                sync of the game runs (an ExitApp's upload, or a launch's download) - never kill the game meanwhile
#   ask <what>   its newest GameAction waits on the user ("waiting for user response to <what>") - nobody answers it here
#   running      Steam's newest "AppID APP state changed : ..." still says Running (Steam hasn't finished the exit)
#   done         Steam logged APP's exit (a state change without Running, or a finished action) since <since>
#   quiet        nothing about APP since <since> (Steam hasn't noticed yet, or it is frozen)
# HACK: Steam's logs are the signal - Steam publishes no cloud-sync/exit event a client can subscribe to (its CEF UI's
# SteamClient.Apps.RegisterForGameActionStart/End is the real API, inside steamwebhelper only). Real fix: a Steam UI
# plugin reporting game actions over the session bus (the same one powos-sleep-gui's SteamLaunches waits for).
# The awk program of _game_steam_exit_state (app, since, recent: its -v variables).
_GSES_AWK='
    { if (!match($0, /^\[[0-9-]+ [0-9:]+\]/)) next; ts = substr($0, 2, RLENGTH - 2) }
    index($0, "GameAction [AppID " app ", ActionID ") && ts >= recent { at = ts; act = $0 }
    index($0, "AppID " app " state changed : ") { st = $0; sts = ts }
    index($0, "AppID " app " ") && ts >= since { heard = 1 }
    END {
        if (act ~ /changed task to SynchronizingCloud/) { print "sync"; exit }
        if (act ~ /waiting for user response to /) { w = act; sub(/.*waiting for user response to /, "", w); print "ask " substr(w, 1, 80); exit }
        if (st != "") { s = st; sub(/.*state changed : /, "", s); n = split(s, p, "->"); s = p[n]
                        if (s ~ /Running/) { print "running"; exit } }
        if (heard || (st != "" && sts >= since) || (act != "" && at >= since)) print "done"; else print "quiet"
    }'
_game_steam_exit_state() {
    local app=$1 d=${3:-${POWOS_STEAM_LOGS:-$HOME/.local/share/Steam/logs}}
    { tail -c 1048576 "$d/console_log.txt" 2>/dev/null; echo; tail -c 262144 "$d/content_log.txt" 2>/dev/null; } | tr -d '\r' \
        | awk -v app="$app" -v since="$(date -d "@$2" '+%F %T')" -v recent="$(date -d "@$(( $2 - 600 ))" '+%F %T')" "$_GSES_AWK"
}

_game_steam_close() {
    local app=$1 all=$2 t0 g s="" left how="" st me=" $$ ${BASHPID:-} $PPID "  # me: never kill ourselves (_gsc_set)
    t0=$(date +%s%N)
    # The game alone: Steam's client and its launchers stay, even when one carries the game's SteamAppId (a game that
    # started Steam itself passes its environment on) - powos-app-quit (a swiped game's card) relies on this.
    [[ $all == 1 ]] || me+="$(_gsc_steam_chain)"
    g=$(_gsc_set $(_game_launch_pids "$app"))
    [[ -n "$g" ]] && kill -TERM $g 2>/dev/null || true
    left=$(_gsc_game_wait "$app" "$g" "$(( t0 / 1000000000 - 1 ))")
    st=${left%%|*}; left=${left#*|}
    if [[ $st == sync ]]; then
        pok "$app: left to Steam - its cloud sync still runs after $(( ($(date +%s%N) - t0) / 1000000 )) ms (game pids: ${left:-none}); not killed$([[ $all == 1 ]] && echo ', Steam not shut down')"
        return 4
    fi
    [[ $st == ask* ]] && how="Steam asks: ${st#ask }"
    if [[ $all == 1 ]]; then
        s=$(_gsc_set $(_game_steam_pids))
        [[ -z "$s" ]] || { _gsc_steam_shutdown; how="${how:+$how, }Steam asked to shut down"; }
        left=$(_gsc_wait "$left" "$s")
        [[ -n "$left" && -n "$s" ]] && how="${how:+$how, }killed after 6 s"
    fi
    left=$(_gsc_sweep "$app" "$all" "$left")
    if [[ -n "$left" ]]; then
        perr "still running after $(( ($(date +%s%N) - t0) / 1000000 )) ms: $(ps -o pid=,stat=,comm= -p "$(echo $left | tr ' ' ,)" 2>/dev/null | tr '\n' ';')"
        return 1
    fi
    pok "$app$([[ $all == 1 ]] && echo ' + Steam') closed in $(( ($(date +%s%N) - t0) / 1000000 )) ms${how:+ ($how)}"
}

# _gsc_game_wait <appid> <game pids> <since epoch>: up to ~20 s for the game's chain to end and Steam to finish its exit
# steps for it; KILLs what is left at 2 s unless Steam's log says a cloud sync of the game runs. Prints
# "<last state>|<pids left>" (state: _game_steam_exit_state's word; "sync" + pids = left to Steam).
_gsc_game_wait() {
    local i left st=quiet gone=0 killed=0
    for i in $(seq "${POWOS_GAME_STOP_TICKS:-200}"); do  # 0.1 s ticks: ~20 s
        left=$(_gsc_alive $2)
        (( i % 5 == 1 )) && st=$(_game_steam_exit_state "$1" "$3")
        if [[ -z "$left" ]]; then
            _gsc_exit_over "$st" $(( ++gone )) && break
        elif (( i >= 20 && killed == 0 )) && [[ $st != sync ]]; then
            kill -KILL $left 2>/dev/null || true; killed=1
        fi
        sleep 0.1
    done
    echo "$st|$left"
}

# <pid>...: the set, sorted, without $me (_game_steam_close's shell and its parent), on one line.
_gsc_set() {
    local p
    for p in "$@"; do [[ "$me" == *" $p "* ]] || echo "$p"; done | sort -un | tr '\n' ' '
}
# <pid>...: those still running (a zombie has ended: its parent just hasn't reaped it yet).
_gsc_alive() { local p st; for p in $*; do st=$(cat "/proc/$p/stat" 2>/dev/null) || continue; st=${st##*) }
    [[ ${st%% *} == Z ]] || printf '%s ' "$p"; done; return 0; }

# Steam thawed (a frozen client never answers) and asked to shut down.
_gsc_steam_shutdown() {
    timeout 2 dbus-send --session --print-reply=literal --reply-timeout=1500 --dest=dev.powos.Sleep /Gui \
        dev.powos.Sleep.Gui.Wake string:steam >/dev/null 2>&1 || true
    # The forwarder can hang on a dying client (or start a new one): bounded, and swept with the rest.
    (timeout -k 1 3 steam -shutdown >/dev/null 2>&1 </dev/null &)
}

# _gsc_exit_over <state> <0.1 s ticks since the game's chain ended>: are Steam's exit steps for it over? Steam logs
# "Game process removed" a moment before an exit sync starts: "done" counts after 1 s, silence after 2 s; "running"
# (exit steps not logged done) is awaited 5 s - a frozen Steam logs nothing more; a sync is never over; ask: over.
_gsc_exit_over() {
    case $1 in
        sync) return 1 ;;
        running) (( $2 > 50 )) ;;
        done) (( $2 > 10 )) ;;
        quiet) (( $2 > 20 )) ;;
    esac
}

# <game pids left> <steam pids>: up to 6 s for them to end, the game's KILLed at 2 s; prints what is left.
_gsc_wait() {
    local i left
    for i in $(seq 60); do
        left=$(_gsc_alive $1 $2)
        [[ -z "$left" ]] && break
        (( i == 20 )) && { kill -KILL $(_gsc_alive $1) 2>/dev/null || true; }
        sleep 0.1
    done
    echo "$left"
}

# <appid> <1: Steam too> <left>: KILL the rest and what a launcher started meanwhile (3 rounds); prints what is left.
_gsc_sweep() {
    local i left=$3
    for i in 1 2 3; do
        left=$(_gsc_alive $left $(_gsc_set $(_game_launch_pids "$1"; [[ $2 != 1 ]] || _game_steam_pids)))
        [[ -z "$left" ]] && break
        kill -KILL $left 2>/dev/null || true; sleep 0.3
    done
    echo "$left"
}

_game_tree() {
    local -a todo=("$1") out=()
    local p
    while (( ${#todo[@]} )); do
        p=${todo[0]}; todo=("${todo[@]:1}"); out+=("$p")
        todo+=($(pgrep -P "$p" || true))
    done
    echo "${out[*]}"
}

_game_ticks() {
    local n=0 p f
    for p in "$@"; do
        f=$(cat "/proc/$p/stat" 2>/dev/null) || continue
        f=${f##*) }; set -- $f; n=$(( n + ${12} + ${13} ))
    done
    echo "$n"
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
