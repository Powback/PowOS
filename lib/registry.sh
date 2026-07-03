#!/bin/bash
# registry.sh - configure root's container-registry pull credentials so bootc
# can pull PRIVATE base images (e.g. your own ghcr.io/<you>/powos).
#
#   powos registry login  [host]    # default host: ghcr.io (reuses gh token there)
#   powos registry logout [host]
#   powos registry status
#
# Writes /etc/ostree/auth.json (root, 0600) — the file bootc/ostree read for
# registry auth. Run as your normal user (NOT sudo): for ghcr.io it reuses your
# `gh` token, and it uses sudo only for the final privileged file write.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
reg_log()  { echo -e "${CYAN}[registry]${NC} $*"; }
reg_ok()   { echo -e "${GREEN}[registry]${NC} $*"; }
reg_warn() { echo -e "${YELLOW}[registry]${NC} $*"; }
reg_err()  { echo -e "${RED}[registry]${NC} $*" >&2; }

AUTH_FILE="${POWOS_OSTREE_AUTH:-/etc/ostree/auth.json}"

registry_login() {
    local host="${1:-ghcr.io}" user="" token=""

    if [[ "$host" == "ghcr.io" ]] && command -v gh >/dev/null 2>&1 && gh auth status -h github.com >/dev/null 2>&1; then
        user="$(gh api user -q .login 2>/dev/null)"
        token="$(gh auth token 2>/dev/null)"
        [[ -n "$user" && -n "$token" ]] && reg_log "Reusing your gh login ($user) for ghcr.io"
        if [[ -n "$token" ]] && ! gh auth status -h github.com 2>&1 | grep -q 'read:packages'; then
            reg_warn "Your gh token may lack 'read:packages' — if pulls 401, run:"
            reg_warn "  gh auth refresh -h github.com -s read:packages"
        fi
    fi
    if [[ -z "$token" ]]; then
        read -rp "Username for $host: " user
        read -rsp "Token/password for $host: " token; echo
    fi
    [[ -n "$user" && -n "$token" ]] || { reg_err "Need a username and token."; return 1; }

    # Merge into the (root-owned) auth file without clobbering other hosts.
    local existing tmp
    existing="$(sudo cat "$AUTH_FILE" 2>/dev/null || echo '{}')"
    tmp="$(mktemp)"; chmod 600 "$tmp"
    if ! REG_HOST="$host" REG_USER="$user" REG_TOKEN="$token" REG_EXISTING="$existing" \
         python3 - "$tmp" <<'PY'
import base64, json, os, sys
tmp = sys.argv[1]
try:    data = json.loads(os.environ.get("REG_EXISTING") or "{}")
except Exception: data = {}
if not isinstance(data, dict): data = {}
data.setdefault("auths", {})
b64 = base64.b64encode(f'{os.environ["REG_USER"]}:{os.environ["REG_TOKEN"]}'.encode()).decode()
data["auths"][os.environ["REG_HOST"]] = {"auth": b64}
open(tmp, "w").write(json.dumps(data, indent=2) + "\n")
PY
    then reg_err "Failed to build auth file."; rm -f "$tmp"; return 1; fi

    sudo mkdir -p "$(dirname "$AUTH_FILE")"
    sudo install -o root -g root -m 600 "$tmp" "$AUTH_FILE"
    rm -f "$tmp"
    reg_ok "Saved credentials for $host → $AUTH_FILE"
    reg_ok "bootc can now pull private images from $host (e.g. 'powos driver testing')."
}

registry_logout() {
    local host="${1:-ghcr.io}"
    [[ -e "$AUTH_FILE" ]] || { reg_ok "No auth file; nothing to do."; return 0; }
    local existing tmp; existing="$(sudo cat "$AUTH_FILE" 2>/dev/null || echo '{}')"
    tmp="$(mktemp)"; chmod 600 "$tmp"
    REG_HOST="$host" REG_EXISTING="$existing" python3 - "$tmp" <<'PY'
import json, os, sys
try: data = json.loads(os.environ.get("REG_EXISTING") or "{}")
except Exception: data = {}
(data.get("auths") or {}).pop(os.environ["REG_HOST"], None)
open(sys.argv[1], "w").write(json.dumps(data, indent=2) + "\n")
PY
    sudo install -o root -g root -m 600 "$tmp" "$AUTH_FILE"; rm -f "$tmp"
    reg_ok "Removed credentials for $host."
}

registry_status() {
    if [[ ! -e "$AUTH_FILE" ]]; then
        echo "No registry credentials configured ($AUTH_FILE absent)."
        echo "  powos registry login ghcr.io"
        return 0
    fi
    echo "Configured hosts ($AUTH_FILE):"
    sudo cat "$AUTH_FILE" 2>/dev/null | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
[print("  •", h) for h in (d.get("auths") or {})]' 2>/dev/null || echo "  (unreadable)"
}

cmd_registry() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        login)          registry_login "$@" ;;
        logout)         registry_logout "$@" ;;
        status|"")      registry_status ;;
        *) reg_err "Usage: powos registry {login|logout|status} [host]"; return 1 ;;
    esac
}
