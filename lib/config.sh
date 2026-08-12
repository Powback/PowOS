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

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
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
claude-endpoint|custom|now|Claude authority URL every PowOS agent calls (e.g. http://claude-auth.pow)
claude-token|custom|now|Token sent to that authority — any non-empty value; it stops the CLI forking the OAuth grant
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

# ── claude endpoint / token ───────────────────────────────────────
#
# ONE machine-wide source of truth for where PowOS agents send Anthropic calls.
# lib/ai/agent.sh reads this file at call time, so `powos ai`, the manager and
# the desktop widget all agree regardless of the environment they inherited.
#
# It exists because this used to live only in the environment, in five
# uncoordinated copies. When the authority moved off-box only ~/.bashrc was
# updated, so the widget — which inherits plasmashell's environment from session
# start — kept calling a dead local proxy and failed with connection refused.
#
# Keep CFG_ENDPOINT_FILE in sync with POWOS_AI_ENDPOINT_FILE in lib/ai/agent.sh;
# test-ai-endpoint.sh fails if the two ever disagree.
CFG_ENDPOINT_FILE="${POWOS_AI_ENDPOINT_FILE:-/etc/powos/ai/endpoint.conf}"
# Mirrored for things PowOS does not run itself — the raw `claude` CLI, editors,
# anything reading plain env. Written under the invoking user's HOME (not root's,
# which is where it would land when set_ is called through sudo).
cfg_endpoint_user_env() {
    local h="$HOME"
    [[ -n "${SUDO_USER:-}" ]] && h="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    echo "$h/.config/environment.d/50-powos-claude.conf"
}

cfg_endpoint_read() {  # cfg_endpoint_read <KEY>
    [[ -r "$CFG_ENDPOINT_FILE" ]] || return 0
    awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$CFG_ENDPOINT_FILE" 2>/dev/null
}

# Rewrite both keys together. Writing one at a time would drop the other, since
# the file is regenerated rather than patched.
cfg_endpoint_write() {  # cfg_endpoint_write <url> <token>
    local url="$1" token="$2" tmp
    tmp=$(mktemp) || return 1
    {
        echo "# Written by 'powos config claude-endpoint' / 'claude-token'."
        echo "# Read by lib/ai/agent.sh at call time. Environment overrides this."
        echo "ANTHROPIC_BASE_URL=$url"
        echo "ANTHROPIC_AUTH_TOKEN=$token"
    } > "$tmp"
    sudo mkdir -p "$(dirname "$CFG_ENDPOINT_FILE")" || { rm -f "$tmp"; return 1; }
    sudo cp "$tmp" "$CFG_ENDPOINT_FILE" || { rm -f "$tmp"; return 1; }
    sudo chmod 0644 "$CFG_ENDPOINT_FILE"
    rm -f "$tmp"

    local uenv; uenv="$(cfg_endpoint_user_env)"
    mkdir -p "$(dirname "$uenv")" 2>/dev/null && {
        {
            echo "# Mirror of $CFG_ENDPOINT_FILE for tools PowOS does not launch"
            echo "# itself (raw \`claude\`, editors). Change it with:"
            echo "#   powos config claude-endpoint <url>"
            echo "ANTHROPIC_BASE_URL=$url"
            echo "ANTHROPIC_AUTH_TOKEN=$token"
        } > "$uenv" 2>/dev/null
    }
    # Update the live session too, so newly-launched apps pick it up without a
    # logout. Already-running processes keep their old copy — nothing can change
    # another process's environment, which is why the file above is the fix.
    systemctl --user set-environment \
        "ANTHROPIC_BASE_URL=$url" "ANTHROPIC_AUTH_TOKEN=$token" 2>/dev/null || true
}

get_claude_endpoint() {
    local v; v=$(cfg_endpoint_read ANTHROPIC_BASE_URL)
    echo "${v:-(unset)}"
}
validate_claude_endpoint() { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }
set_claude_endpoint() {
    local token; token=$(cfg_endpoint_read ANTHROPIC_AUTH_TOKEN)
    # A blank token is not a neutral default: without it the CLI runs its own
    # OAuth refresh and forks the rotating grant, which revokes the whole token
    # family. The value itself is irrelevant — the authority replaces the header.
    [[ -n "$token" ]] || token="proxy-managed"
    cfg_endpoint_write "$1" "$token" || { cerr "claude-endpoint: write failed"; return 1; }
    cok "claude-endpoint: $1"
    cfg_endpoint_note
}
get_claude_token() {
    local v; v=$(cfg_endpoint_read ANTHROPIC_AUTH_TOKEN)
    echo "${v:-(unset)}"
}
validate_claude_token() { [[ -n "$1" && "$1" != *[[:space:]]* ]]; }
set_claude_token() {
    local url; url=$(cfg_endpoint_read ANTHROPIC_BASE_URL)
    [[ -n "$url" ]] || { cerr "set claude-endpoint first: powos config claude-endpoint <url>"; return 1; }
    cfg_endpoint_write "$url" "$1" || { cerr "claude-token: write failed"; return 1; }
    cok "claude-token: set"
    cfg_endpoint_note
}
cfg_endpoint_note() {
    echo "  New agents and terminals use this immediately."
    echo "  Already-running GUI apps (the desktop widget) keep the old value until"
    echo "  Plasma restarts: systemctl --user restart plasma-plasmashell.service"
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
