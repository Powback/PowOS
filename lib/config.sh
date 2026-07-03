#!/bin/bash
# config.sh - one place to flip PowOS settings: `powos config`.
#
#   powos config                    # list every known setting + current state
#   powos config <name>             # show one setting
#   powos config <name> <value>     # set it AND apply it (sudo where needed)
#   powos config --json             # machine-readable (for GUIs/widgets)
#
# Two kinds of settings, both behind the same front door:
#   service-backed  applied immediately via systemctl (e.g. ssh)
#   file-backed     KEY=value in /etc/powos/config (the powos.conf template
#                   pattern); consumers read it at boot/service start, so some
#                   need a service restart or reboot — each says which.
#
# Adding a setting = one entry in cfg_registry() + a get_/set_ pair. Keep it
# boring; this is meant to be the substrate a future installer/GUI drives.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
clog()  { echo -e "${CYAN}[config]${NC} $*"; }
cok()   { echo -e "${GREEN}[config]${NC} $*"; }
cerr()  { echo -e "${RED}[config]${NC} $*" >&2; }

POWOS_CONF="/etc/powos/config"
POWOS_CONF_TEMPLATE="/etc/powos/etc/powos.conf"

# name|values|description  (one per line — the whole registry)
cfg_registry() {
    cat <<'EOF'
ssh|on,off|SSH server (sshd) — remote shell access to this machine
cachefs|on,off|CacheFS lazy /home (experimental) — needs reboot to take effect
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

# ── settings: get_<name> prints on/off, set_<name> applies on|off ─

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

cfg_known() { cfg_registry | cut -d'|' -f1; }

cfg_list() {
    local as_json="${1:-}" line name values desc val first=true
    [[ "$as_json" == "--json" ]] && echo "{"
    while IFS='|' read -r name values desc; do
        val=$("get_$name")
        if [[ "$as_json" == "--json" ]]; then
            $first || echo ","
            first=false
            printf '  "%s": {"value": "%s", "options": "%s", "description": "%s"}' \
                "$name" "$val" "$values" "$desc"
        else
            printf "  ${BOLD}%-10s${NC} %-4s  ${DIM}%s${NC}\n" "$name" "$val" "$desc"
        fi
    done < <(cfg_registry)
    [[ "$as_json" == "--json" ]] && { echo ""; echo "}"; }
    return 0
}

cmd_config() {
    local name="${1:-}" value="${2:-}"

    case "$name" in
        ""|--json)
            [[ -z "$name" ]] && echo -e "${BOLD}PowOS Settings${NC}  ${DIM}(powos config <name> on|off to change)${NC}"
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
        echo "$name = $("get_$name")"
        return 0
    fi

    if [[ "$value" != "on" && "$value" != "off" ]]; then
        cerr "value must be on|off (got: $value)"
        return 1
    fi

    "set_$name" "$value"
}
