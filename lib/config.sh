#!/bin/bash
# config.sh - one place to flip PowOS settings: `powos config`.
#
#   powos config                    # list every known setting + current state
#   powos config <name>             # show one setting
#   powos config <name> <value>     # set it AND apply it (sudo where needed)
#   powos config --json             # machine-readable (for GUIs/widgets)
#
# Settings are registry-driven (cfg_registry below): each is either a fixed
# choice list (on/off, stable/testing) or free-form with a validate_<name>()
# gate (sizes, seconds). The "applies" column is shown to the user and is
# honest about WHEN a change takes effect: now / reboot / service restart.
#
# Adding a setting = one registry line + get_/set_ pair (+ validate_ if
# free-form). Keep it boring; this is meant to be the substrate a future
# installer/GUI drives.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
clog()  { echo -e "${CYAN}[config]${NC} $*"; }
cok()   { echo -e "${GREEN}[config]${NC} $*"; }
cerr()  { echo -e "${RED}[config]${NC} $*" >&2; }

POWOS_CONF="/etc/powos/config"
POWOS_CONF_TEMPLATE="/etc/powos/etc/powos.conf"

# name|values|applies|description
#   values: comma list of choices, or "custom" (validated by validate_<name>)
#   applies: when the change takes effect (shown verbatim to the user)
cfg_registry() {
    cat <<'EOF'
ssh|on,off|now|SSH server (sshd) — remote shell access to this machine
driver|stable,testing|reboot|NVIDIA driver channel — tested vs newest published image
auto-update|on,off|now|Stage OS updates in the background; they apply at your next reboot
ramsize|custom|reboot|RAM overlay size, e.g. 8G or 24G (kernel arg rd.powos.ramsize)
sync-interval|custom|now|RAM→disk layer sync interval in seconds (default 60)
nvidia-persistence|on,off|now|Keep the NVIDIA GPU initialized between uses (consistent idle state)
cachefs|on,off|reboot|CacheFS lazy /home (experimental)
EOF
}

# ── file-backed helpers ───────────────────────────────────────────

# Read KEY from /etc/powos/config (last assignment wins), empty if unset.
cfg_file_get() {
    [[ -r "$POWOS_CONF" ]] || return 0
    awk -F= -v k="$1" '$1==k { v=$2 } END { if (v!="") print v }' "$POWOS_CONF"
}

# Write KEY=value into /etc/powos/config (root-owned): replace or append.
# Seeds the file from the shipped template on first write.
cfg_file_set() {
    local key="$1" val="$2"
    sudo bash -c "
        if [[ ! -f '$POWOS_CONF' ]]; then
            mkdir -p /etc/powos
            cp '$POWOS_CONF_TEMPLATE' '$POWOS_CONF' 2>/dev/null || touch '$POWOS_CONF'
        fi
        if grep -q '^$key=' '$POWOS_CONF'; then
            sed -i 's|^$key=.*|$key=$val|' '$POWOS_CONF'
        else
            echo '$key=$val' >> '$POWOS_CONF'
        fi
    "
}

# ── ssh ───────────────────────────────────────────────────────────

get_ssh() {
    if systemctl is-active sshd.service &>/dev/null || systemctl is-active sshd.socket &>/dev/null; then
        echo on
    else
        echo off
    fi
}
set_ssh() {
    if [[ "$1" == "on" ]]; then
        sudo systemctl enable --now sshd.service && cok "ssh: on (listening on port 22)"
    else
        sudo systemctl disable --now sshd.service sshd.socket 2>/dev/null
        cok "ssh: off (not listening, won't start at boot)"
    fi
}

# ── driver channel (delegates to lib/driver.sh for the actual rebase) ─

get_driver() {
    # Derive from the booted/staged image tag; non-root friendly.
    local ref
    ref=$(rpm-ostree status --json 2>/dev/null |
        python3 -c '
import json, sys
try: s = json.load(sys.stdin)
except Exception: sys.exit(0)
for d in s.get("deployments", []):
    if d.get("booted"):
        print(d.get("container-image-reference") or ""); break' 2>/dev/null)
    case "$ref" in
        *-testing*) echo testing ;;
        *)          echo stable ;;
    esac
}
set_driver() {
    # cmd_driver owns the rebase + honesty about reboot/rollback.
    # shellcheck source=/dev/null
    source "${POWOS_LIB:-/usr/lib/powos}/driver.sh"
    cmd_driver "$1"
}

# ── auto-update (rpm-ostreed stage policy + timer; never auto-reboots) ─

get_auto_update() {
    if systemctl is-enabled rpm-ostreed-automatic.timer &>/dev/null &&
       grep -q '^AutomaticUpdatePolicy=stage' /etc/rpm-ostreed.conf 2>/dev/null; then
        echo on
    else
        echo off
    fi
}
set_auto_update() {
    if [[ "$1" == "on" ]]; then
        sudo sed -i 's|^#\?AutomaticUpdatePolicy=.*|AutomaticUpdatePolicy=stage|' /etc/rpm-ostreed.conf
        sudo systemctl reload rpm-ostreed 2>/dev/null || true
        sudo systemctl enable --now rpm-ostreed-automatic.timer && \
            cok "auto-update: on — updates stage in the background, apply at your next reboot (never reboots on its own)"
    else
        sudo sed -i 's|^AutomaticUpdatePolicy=.*|AutomaticUpdatePolicy=none|' /etc/rpm-ostreed.conf
        sudo systemctl reload rpm-ostreed 2>/dev/null || true
        sudo systemctl disable --now rpm-ostreed-automatic.timer
        cok "auto-update: off — update manually with 'powos upgrade'"
    fi
}

# ── ramsize (kernel arg; new deployments only → reboot to apply) ──

get_ramsize() {
    local v
    v=$(grep -o 'rd.powos.ramsize=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2)
    echo "${v:-8G}"
}
validate_ramsize() { [[ "$1" =~ ^[0-9]+[GgMm]$ ]]; }
set_ramsize() {
    local cur; cur=$(get_ramsize)
    clog "kernel arg rd.powos.ramsize: $cur → $1"
    if sudo rpm-ostree kargs --replace="rd.powos.ramsize=$1" 2>/dev/null ||
       sudo rpm-ostree kargs --append="rd.powos.ramsize=$1"; then
        cok "ramsize: $1 — takes effect on next reboot (current session stays at $cur)"
    else
        cerr "failed to update kernel args"
        return 1
    fi
}

# ── sync-interval (file-backed; layer-sync service reads it via env) ─

get_sync_interval() {
    local v; v=$(cfg_file_get POWOS_SYNC_INTERVAL)
    echo "${v:-60}"
}
validate_sync_interval() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 10 )); }
set_sync_interval() {
    cfg_file_set POWOS_SYNC_INTERVAL "$1" || return 1
    if systemctl is-active powos-layer-sync.service &>/dev/null; then
        sudo systemctl restart powos-layer-sync.service && cok "sync-interval: ${1}s (daemon restarted)"
    else
        cok "sync-interval: ${1}s (daemon not running on this install; applies when it does)"
    fi
}

# ── nvidia-persistence ────────────────────────────────────────────

get_nvidia_persistence() {
    systemctl is-active nvidia-persistenced.service &>/dev/null && echo on || echo off
}
set_nvidia_persistence() {
    if ! systemctl list-unit-files nvidia-persistenced.service &>/dev/null; then
        cerr "nvidia-persistenced not present (non-NVIDIA base image?)"
        return 1
    fi
    if [[ "$1" == "on" ]]; then
        sudo systemctl enable --now nvidia-persistenced.service && cok "nvidia-persistence: on"
    else
        sudo systemctl disable --now nvidia-persistenced.service && cok "nvidia-persistence: off"
    fi
}

# ── cachefs ───────────────────────────────────────────────────────

get_cachefs() {
    local v; v=$(cfg_file_get POWOS_CACHEFS_ENABLED)
    [[ "$v" == "true" ]] && echo on || echo off
}
set_cachefs() {
    local v=false; [[ "$1" == "on" ]] && v=true
    cfg_file_set POWOS_CACHEFS_ENABLED "$v" && \
        cok "cachefs: $1 — takes effect after reboot (experimental; see docs)"
}

# ── command ───────────────────────────────────────────────────────

# get_/set_/validate_ function names use _ where setting names use -
cfg_fn() { echo "${2//-/_}" | sed "s/^/$1_/"; }

cfg_known() { cfg_registry | cut -d'|' -f1; }

cfg_list() {
    local as_json="${1:-}" name values applies desc val first=true
    [[ "$as_json" == "--json" ]] && echo "{"
    while IFS='|' read -r name values applies desc; do
        val=$("$(cfg_fn get "$name")")
        if [[ "$as_json" == "--json" ]]; then
            $first || echo ","
            first=false
            printf '  "%s": {"value": "%s", "options": "%s", "applies": "%s", "description": "%s"}' \
                "$name" "$val" "$values" "$applies" "$desc"
        else
            printf "  ${BOLD}%-19s${NC} %-8s ${DIM}[%s]${NC} ${DIM}%s${NC}\n" \
                "$name" "$val" "$applies" "$desc"
        fi
    done < <(cfg_registry)
    [[ "$as_json" == "--json" ]] && { echo ""; echo "}"; }
    return 0
}

cmd_config() {
    local name="${1:-}" value="${2:-}"

    case "$name" in
        ""|--json)
            [[ -z "$name" ]] && echo -e "${BOLD}PowOS Settings${NC}  ${DIM}(powos config <name> <value> to change; [when it applies])${NC}"
            cfg_list "$name"
            return 0
            ;;
        --help|-h)
            sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            return 0
            ;;
    esac

    if ! cfg_known | grep -qx "$name"; then
        cerr "unknown setting: $name"
        clog "known: $(cfg_known | tr '\n' ' ')"
        return 1
    fi

    if [[ -z "$value" ]]; then
        echo "$name = $("$(cfg_fn get "$name")")"
        return 0
    fi

    # Validate against the registry: fixed choice list, or validate_<name>().
    local values
    values=$(cfg_registry | awk -F'|' -v n="$name" '$1==n { print $2 }')
    if [[ "$values" == "custom" ]]; then
        if ! "$(cfg_fn validate "$name")" "$value"; then
            cerr "invalid value for $name: $value"
            return 1
        fi
    elif ! tr ',' '\n' <<<"$values" | grep -qx "$value"; then
        cerr "value must be one of: $values (got: $value)"
        return 1
    fi

    "$(cfg_fn set "$name")" "$value"
}
