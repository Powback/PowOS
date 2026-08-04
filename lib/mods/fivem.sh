#!/usr/bin/env bash
# mods/fivem.sh - PowOS FiveM (GTA V multiplayer) manager: server + client, for
# BOTH the Legacy and Enhanced editions.
#
# FiveM has two entirely separate lineages that do NOT cross-play:
#   • legacy   — the original GTA V PC build. Mature; the whole QBCore/ESX/
#                txAdmin ecosystem lives here. No BattlEye. Runs great on Linux.
#   • enhanced — the March-2025 "Enhanced" GTA V build; FiveM support entered
#                Early Access 2026-07-21. Server rebranded "Cfx Server" (~50%
#                less RAM/player, 120Hz). New, ecosystem still porting.
#
# So EDITION is a first-class dimension: server dirs, client prefixes, artifact
# channels, ports and the sv_enforceGameBuild convar all key off it. Legacy is
# the out-of-the-box default; Enhanced's Early-Access Linux artifact URL is
# config-driven (it is still moving), so pointing at a new build is a config
# value, not a code change.
#
# SERVER  — native Linux FXServer/Cfx-Server artifact (fx.tar.xz) run under
#           txAdmin in a tmux session. The artifact is just the engine; server
#           data (server.cfg, resources, txData) lives separately so updating =
#           swap the engine, keep the car.
# CLIENT  — the FiveM client is Windows-only; on Linux it runs under GE-Proton
#           in a dedicated prefix per edition (same mechanism as `powos mods vu`),
#           with the Windows VM/dual-boot as the fallback. (Phase 2.)
#
# Entry point: cmd_mods_fivem "$@"   (dispatched from bin/powos + install.sh)

# ── Shared helpers (fallback defs when sourced standalone / in tests) ─────────
if ! declare -f plog >/dev/null 2>&1; then
    : "${CYAN:=$'\033[0;36m'}" "${YELLOW:=$'\033[0;33m'}" "${RED:=$'\033[0;31m'}"
    : "${GREEN:=$'\033[0;32m'}" "${BOLD:=$'\033[1m'}" "${DIM:=$'\033[2m'}" "${NC:=$'\033[0m'}"
    plog()  { echo -e "${CYAN}[fivem]${NC} $*"; }
    pwarn() { echo -e "${YELLOW}[fivem]${NC} $*"; }
    perr()  { echo -e "${RED}[fivem]${NC} $*" >&2; }
fi
POWOS_TAG=fivem

# ── Paths ─────────────────────────────────────────────────────────────────────

FIVEM_ROOT="${FIVEM_ROOT:-$HOME/Games/FiveM}"
FIVEM_CONF="${FIVEM_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/powos/fivem.conf}"

# Per-edition layout: <root>/<edition>/{engine,data,client,prefix}
#   engine  — the extracted fx.tar.xz artifact (swappable)
#   data    — server.cfg, resources/, txData/  (persistent "car")
#   client  — the Windows FiveM client files (Phase 2)
#   prefix  — the client's GE-Proton prefix     (Phase 2)
fivem_edition_dir() { printf '%s/%s' "$FIVEM_ROOT" "$(fivem_edition_norm "$1")"; }
fivem_engine_dir()  { printf '%s/engine' "$(fivem_edition_dir "$1")"; }
fivem_data_dir()    { printf '%s/data'   "$(fivem_edition_dir "$1")"; }

# ── Edition model ─────────────────────────────────────────────────────────────

# Canonicalise an edition token. classic/legacy/l → legacy; enhanced/e/next → enhanced.
fivem_edition_norm() {
    case "${1,,}" in
        ""|legacy|classic|l|leg|old)          printf 'legacy' ;;
        enhanced|enh|e|next|nextgen|new)       printf 'enhanced' ;;
        *) return 1 ;;
    esac
}

# The default edition (config `edition`, else legacy).
fivem_default_edition() {
    local e; e="$(fivem_conf_get edition 2>/dev/null)"
    fivem_edition_norm "${e:-legacy}" 2>/dev/null || printf 'legacy'
}

# sv_enforceGameBuild value baked into a scaffolded server.cfg. Legacy commonly
# pins a known-good build; Enhanced uses its own. Overridable via config
# `<edition>_gamebuild`.
fivem_gamebuild() {
    local edition; edition="$(fivem_edition_norm "$1")"
    local v; v="$(fivem_conf_get "${edition}_gamebuild" 2>/dev/null)"
    if [[ -n "$v" ]]; then printf '%s' "$v"; return; fi
    case "$edition" in
        legacy)   printf '3095' ;;   # a widely-used stable legacy build
        enhanced) printf '3570' ;;   # placeholder for the Enhanced line
    esac
}

# Per-edition ports so BOTH editions can run side by side. Overridable via
# config `<edition>_port` (game) and `<edition>_txport` (txAdmin web).
fivem_game_port() {
    local edition; edition="$(fivem_edition_norm "$1")"
    local v; v="$(fivem_conf_get "${edition}_port" 2>/dev/null)"
    [[ -n "$v" ]] && { printf '%s' "$v"; return; }
    [[ "$edition" == enhanced ]] && printf '30121' || printf '30120'
}
fivem_tx_port() {
    local edition; edition="$(fivem_edition_norm "$1")"
    local v; v="$(fivem_conf_get "${edition}_txport" 2>/dev/null)"
    [[ -n "$v" ]] && { printf '%s' "$v"; return; }
    [[ "$edition" == enhanced ]] && printf '40121' || printf '40120'
}

# ── Artifact resolution ───────────────────────────────────────────────────────

# The Linux server artifact URL for <edition> <build>.
#   legacy   — the stable build_proot_linux channel.
#   enhanced — config-driven base (`enhanced_artifact_base`, or $FIVEM_ENHANCED_BASE),
#              because the Early-Access Enhanced Linux channel is still moving.
FIVEM_LEGACY_BASE="${FIVEM_LEGACY_BASE:-https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master}"
# Provisional default — the likely Enhanced channel; override in fivem.conf if it moves.
FIVEM_ENHANCED_BASE="${FIVEM_ENHANCED_BASE:-https://runtime.fivem.net/artifacts/fivem/build_proot_linux_enhanced/master}"

fivem_artifact_base() {
    local edition; edition="$(fivem_edition_norm "$1")" || return 1
    if [[ "$edition" == enhanced ]]; then
        local c; c="$(fivem_conf_get enhanced_artifact_base 2>/dev/null)"
        printf '%s' "${c:-$FIVEM_ENHANCED_BASE}"
    else
        local c; c="$(fivem_conf_get legacy_artifact_base 2>/dev/null)"
        printf '%s' "${c:-$FIVEM_LEGACY_BASE}"
    fi
}

fivem_artifact_url() {
    local edition="$1" build="$2" base
    base="$(fivem_artifact_base "$edition")" || return 1
    [[ -n "$build" ]] || return 2
    printf '%s/%s/fx.tar.xz' "${base%/}" "$build"
}

# Best-effort: scrape the artifacts listing for the LATEST RECOMMENDED build
# number. Returns empty on failure (caller then requires --build).
fivem_latest_build() {
    local edition base html
    edition="$(fivem_edition_norm "$1")" || return 1
    base="$(fivem_artifact_base "$edition")"
    command -v curl >/dev/null 2>&1 || return 1
    html="$(curl -fsSL --max-time 15 "$base/" 2>/dev/null)" || return 1
    # Links look like ./<build>-<hash>/fx.tar.xz ; the recommended one is tagged.
    # Grab the highest build number present as a safe fallback.
    printf '%s' "$html" | grep -oE '[0-9]{3,6}-[0-9a-f]{6,}/fx\.tar\.xz' \
        | grep -oE '^[0-9]+' | sort -n | tail -1
}

# ── Config (key=value, parsed without eval) ───────────────────────────────────

fivem_conf_get() {
    local key="$1"
    [[ -f "$FIVEM_CONF" ]] || return 1
    local line
    line="$(grep -m1 "^${key}=" "$FIVEM_CONF" 2>/dev/null)" || return 1
    printf '%s' "${line#*=}"
}

fivem_conf_set() {
    local key="$1" val="$2"
    mkdir -p "$(dirname "$FIVEM_CONF")"
    touch "$FIVEM_CONF"
    if grep -q "^${key}=" "$FIVEM_CONF" 2>/dev/null; then
        local tmp; tmp="$(mktemp)"
        grep -v "^${key}=" "$FIVEM_CONF" > "$tmp"
        printf '%s=%s\n' "$key" "$val" >> "$tmp"
        mv "$tmp" "$FIVEM_CONF"
    else
        printf '%s=%s\n' "$key" "$val" >> "$FIVEM_CONF"
    fi
}

# ── Server ────────────────────────────────────────────────────────────────────

fivem_tmux_session() { printf 'fivem-%s' "$(fivem_edition_norm "$1")"; }

fivem_server_installed() { [[ -x "$(fivem_engine_dir "$1")/run.sh" ]]; }
fivem_server_running() {
    command -v tmux >/dev/null 2>&1 || return 1
    tmux has-session -t "$(fivem_tmux_session "$1")" 2>/dev/null
}

# Download + extract the server engine for <edition> [build].
fivem_server_install() {
    local edition build url engine tmp
    edition="$(fivem_edition_norm "$1")" || { perr "unknown edition '$1' (legacy|enhanced)"; return 1; }
    build="$2"
    if [[ -z "$build" ]]; then
        plog "Resolving latest ${edition} build…"
        build="$(fivem_latest_build "$edition")"
    fi
    if [[ -z "$build" ]]; then
        perr "Could not resolve a build number for ${edition}."
        echo "  Pass one explicitly:  powos game fivem server install --edition ${edition} --build <N>"
        echo "  Find it on the artifacts page: $(fivem_artifact_base "$edition")/"
        [[ "$edition" == enhanced ]] && echo "  (Enhanced is Early-Access; set 'enhanced_artifact_base' in $FIVEM_CONF if the URL has moved.)"
        return 1
    fi
    url="$(fivem_artifact_url "$edition" "$build")" || { perr "no artifact base for ${edition}"; return 1; }
    engine="$(fivem_engine_dir "$edition")"
    plog "Installing ${BOLD}${edition}${NC} server engine (build ${build})"
    echo -e "  ${DIM}$url${NC}"
    mkdir -p "$engine" || return 1
    tmp="$(mktemp -d)" || return 1
    if ! curl -fL --progress-bar -o "$tmp/fx.tar.xz" "$url"; then
        perr "download failed — check the build number / artifact base."
        rm -rf "$tmp"; return 1
    fi
    if ! tar -xJf "$tmp/fx.tar.xz" -C "$engine"; then
        perr "extract failed (need xz-utils / tar with xz)."
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    chmod +x "$engine/run.sh" 2>/dev/null || true
    fivem_conf_set "${edition}_build" "$build"
    plog "Installed to ${DIM}$engine${NC}"
    fivem_scaffold_data "$edition"
    echo "  Next: powos game fivem server up --edition ${edition}"
}

# Create a minimal server data dir (server.cfg) if absent. txAdmin can also
# generate a full recipe; this just guarantees a runnable baseline.
fivem_scaffold_data() {
    local edition data cfg gb port
    edition="$(fivem_edition_norm "$1")"
    data="$(fivem_data_dir "$edition")"
    mkdir -p "$data/resources"
    cfg="$data/server.cfg"
    [[ -f "$cfg" ]] && return 0
    gb="$(fivem_gamebuild "$edition")"
    port="$(fivem_game_port "$edition")"
    local lic; lic="$(fivem_conf_get license 2>/dev/null)"
    cat > "$cfg" <<EOF
# PowOS-scaffolded FiveM ${edition} server.cfg — edit freely.
endpoint_add_tcp "0.0.0.0:${port}"
endpoint_add_udp "0.0.0.0:${port}"
sv_maxclients 48
sv_enforceGameBuild ${gb}
sv_hostname "PowOS ${edition} server"
sets sv_projectName "PowOS FiveM (${edition})"
# Get a key at https://portal.cfx.re/  then: powos game fivem license <key>
sv_licenseKey ${lic:-CHANGEME}
# Add your resources below (ensure/start ...). txAdmin manages this for you.
EOF
    plog "Scaffolded ${DIM}$cfg${NC}"
    [[ -z "$lic" ]] && pwarn "No Cfx license set — 'powos game fivem license <key>' (portal.cfx.re)."
}

# Start the server under txAdmin in a tmux session.
fivem_server_up() {
    local edition engine data sess txport
    edition="$(fivem_edition_norm "$1")" || { perr "unknown edition"; return 1; }
    command -v tmux >/dev/null 2>&1 || { perr "tmux is required to run the server."; return 1; }
    fivem_server_installed "$edition" || { perr "no ${edition} engine — run: powos game fivem server install --edition ${edition}"; return 1; }
    if fivem_server_running "$edition"; then plog "${edition} server already running."; return 0; fi
    engine="$(fivem_engine_dir "$edition")"
    data="$(fivem_data_dir "$edition")"
    sess="$(fivem_tmux_session "$edition")"
    txport="$(fivem_tx_port "$edition")"
    mkdir -p "$data"
    plog "Starting ${BOLD}${edition}${NC} server (txAdmin on :${txport})"
    # run.sh from the data dir; no +exec → txAdmin monitor mode manages server.cfg.
    tmux new-session -d -s "$sess" -c "$data" \
        "'$engine/run.sh' +set txAdminPort ${txport} +set serverProfile default; exec bash"
    sleep 1
    if fivem_server_running "$edition"; then
        plog "Up. txAdmin: ${BOLD}http://localhost:${txport}${NC}   console: powos game fivem server console --edition ${edition}"
    else
        perr "server did not stay up — attach with: tmux attach -t $sess"
        return 1
    fi
}

fivem_server_down() {
    local edition sess
    edition="$(fivem_edition_norm "$1")" || return 1
    sess="$(fivem_tmux_session "$edition")"
    if fivem_server_running "$edition"; then
        tmux kill-session -t "$sess" 2>/dev/null
        plog "${edition} server stopped."
    else
        plog "${edition} server was not running."
    fi
}

fivem_server_console() {
    local edition sess
    edition="$(fivem_edition_norm "$1")" || return 1
    sess="$(fivem_tmux_session "$edition")"
    fivem_server_running "$edition" || { perr "${edition} server not running."; return 1; }
    exec tmux attach -t "$sess"
}

# ── Client (Phase 2 — honest stub) ────────────────────────────────────────────

fivem_client_cmd() {
    local edition; edition="$(fivem_edition_norm "${1:-$(fivem_default_edition)}")"
    cat <<EOF
${BOLD}FiveM client (${edition})${NC} — not wired yet (Phase 2).

The FiveM client is Windows-only. On PowOS you have two paths:
  1. GE-Proton prefix (like 'powos mods vu') — planned: a per-edition prefix at
     $(fivem_edition_dir "$edition")/prefix. Tracked for the next phase.
  2. Windows now — run FiveM in your Windows VM or bare metal:
       powos vm windows --gpu      # VM (FiveM has no kernel anti-cheat)
       powos boot windows          # bare metal

Server hosting works today: powos game fivem server up --edition ${edition}
EOF
}

# ── Status ────────────────────────────────────────────────────────────────────

fivem_status_cmd() {
    local e mark_yes="${GREEN}●${NC}" mark_no="${DIM}○${NC}"
    echo -e "${BOLD}PowOS FiveM${NC}  ${DIM}(GTA V multiplayer — server + client)${NC}"
    echo -e "  Root:     ${DIM}${FIVEM_ROOT}${NC}"
    local defe; defe="$(fivem_default_edition)"
    echo -e "  Default:  ${BOLD}${defe}${NC} edition   ${DIM}(config: edition=)${NC}"
    local lic; lic="$(fivem_conf_get license 2>/dev/null)"
    echo -e "  License:  $([[ -n "$lic" && "$lic" != CHANGEME ]] && echo "${mark_yes} set" || echo "${mark_no} not set  ${DIM}(powos game fivem license <key>)${NC}")"
    echo
    for e in legacy enhanced; do
        local inst run build gp tp
        inst=$(fivem_server_installed "$e" && echo "$mark_yes" || echo "$mark_no")
        run=$(fivem_server_running "$e" && echo "${GREEN}running${NC}" || echo "${DIM}stopped${NC}")
        build="$(fivem_conf_get "${e}_build" 2>/dev/null)"
        gp="$(fivem_game_port "$e")"; tp="$(fivem_tx_port "$e")"
        echo -e "  ${BOLD}${e}${NC} server: ${inst} engine ${build:+(build $build) }· ${run} · game :${gp} · txAdmin :${tp}"
    done
    echo
    echo -e "  ${DIM}Client is Phase 2 — 'powos game fivem client' for options.${NC}"
}

# ── Help ──────────────────────────────────────────────────────────────────────

fivem_help() {
    cat <<EOF
$(echo -e "${BOLD}powos game fivem${NC}") — FiveM (GTA V multiplayer): server + client, Legacy & Enhanced

Editions (do NOT cross-play): ${BOLD}legacy${NC} (mature, default) · ${BOLD}enhanced${NC} (Early Access)
Pick with --edition legacy|enhanced (or set a default: fivem edition <e>).

${BOLD}Status / config${NC}
  fivem status                         Server state for both editions
  fivem edition <legacy|enhanced>      Set the default edition
  fivem license <key>                  Store your Cfx server license (portal.cfx.re)

${BOLD}Server${NC} (native Linux, txAdmin, runs today)
  fivem server install [--edition E] [--build N]   Download+extract the engine
  fivem server up      [--edition E]                Start under txAdmin (tmux)
  fivem server down    [--edition E]                Stop
  fivem server console [--edition E]                Attach to the live console
  fivem server status                               (= fivem status)

${BOLD}Client${NC}
  fivem client [--edition E]           How to play (Phase 2 — GE-Proton / Windows VM)

Examples
  powos game fivem server install --edition legacy
  powos game fivem license cfxk_XXXXXXXX
  powos game fivem server up
  powos game fivem server install --edition enhanced --build 12345

Notes
  • Enhanced's Linux artifact channel is still moving (EA since 2026-07-21). If a
    download 404s, set 'enhanced_artifact_base' in ${FIVEM_CONF} to the current
    channel from the artifacts page, or pass --build.
  • Both editions get their own ports/dirs, so they can run side by side.
EOF
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

# Pull a --edition/-e VALUE out of the args, echo it, and print the remaining
# args (NUL-safe enough for our simple tokens) on the following lines is
# overkill; instead we mutate a global array. Keep it simple: parse in-place.
_fivem_take_edition() {  # sets _FE to edition (default), strips --edition/-e from _FARGS
    _FE="$(fivem_default_edition)"
    local out=() i=0 argv=("$@")
    while (( i < ${#argv[@]} )); do
        case "${argv[i]}" in
            --edition|-e) _FE="$(fivem_edition_norm "${argv[i+1]}")" || { perr "bad edition '${argv[i+1]}'"; return 1; }; ((i+=2)) ;;
            --enhanced)   _FE="enhanced"; ((i++)) ;;
            --legacy|--classic) _FE="legacy"; ((i++)) ;;
            *) out+=("${argv[i]}"); ((i++)) ;;
        esac
    done
    _FARGS=("${out[@]}")
}

cmd_mods_fivem() {
    local sub="${1:-status}"; shift 2>/dev/null || true
    local _FE _FARGS
    case "$sub" in
        ""|status)   fivem_status_cmd ;;
        help|-h|--help) fivem_help ;;
        edition)     [[ -n "$1" ]] && { fivem_edition_norm "$1" >/dev/null || { perr "bad edition"; return 1; }; fivem_conf_set edition "$(fivem_edition_norm "$1")"; plog "default edition = $(fivem_edition_norm "$1")"; } || fivem_conf_get edition ;;
        license)     [[ -n "$1" ]] && { fivem_conf_set license "$1"; plog "license stored."; } || { perr "usage: fivem license <key>"; return 1; } ;;
        server)
            local ssub="${1:-status}"; shift 2>/dev/null || true
            _fivem_take_edition "$@" || return 1
            case "$ssub" in
                install) fivem_server_install "$_FE" "$( [[ "${_FARGS[0]}" == --build ]] && echo "${_FARGS[1]}" )" ;;
                up|start)   fivem_server_up "$_FE" ;;
                down|stop)  fivem_server_down "$_FE" ;;
                console|attach) fivem_server_console "$_FE" ;;
                status|"")  fivem_status_cmd ;;
                *) perr "unknown: fivem server $ssub"; fivem_help; return 1 ;;
            esac ;;
        client|play)
            _fivem_take_edition "$@" || return 1
            fivem_client_cmd "$_FE" ;;
        *) perr "unknown: fivem $sub"; fivem_help; return 1 ;;
    esac
}
