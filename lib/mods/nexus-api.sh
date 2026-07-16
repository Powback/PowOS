#!/bin/bash
# mods/nexus-api.sh — Nexus Mods REST API helpers (extracted + deduplicated).
#
# Single source of truth for all Nexus API interaction. Previously duplicated
# across install.sh, vortex.sh, and asi.sh.
#
# Requires: curl, python3, jq (optional, python3 fallback)
# Env:      POWOS_NEXUS_KEY_FILE (default: ~/.config/powos/nexus.key)
#           POWOS_NEXUS_UA       (default: powos-mods/2.0)

set -uo pipefail

POWOS_NEXUS_KEY_FILE="${POWOS_NEXUS_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/powos/nexus.key}"
POWOS_NEXUS_UA="${POWOS_NEXUS_UA:-powos-mods/2.0}"
POWOS_NEXUS_BASE="https://api.nexusmods.com/v1"

# ── rate-limit state ────────────────────────────────────────────────────
_NEXUS_RL_DAILY_REMAINING=""
_NEXUS_RL_HOURLY_REMAINING=""

# ── key management ──────────────────────────────────────────────────────

nexus_key() {
    [[ -f "$POWOS_NEXUS_KEY_FILE" ]] || {
        perr "No Nexus API key at $POWOS_NEXUS_KEY_FILE."
        perr "Get one at: https://www.nexusmods.com/users/myaccount?tab=api+access"
        perr "Then run: powos mods setup nexus"
        return 1
    }
    cat "$POWOS_NEXUS_KEY_FILE"
}

nexus_key_save() {
    local key="$1"
    mkdir -p "$(dirname "$POWOS_NEXUS_KEY_FILE")"
    printf '%s' "$key" > "$POWOS_NEXUS_KEY_FILE"
    chmod 600 "$POWOS_NEXUS_KEY_FILE"
}

nexus_key_validate() {
    local resp
    resp="$(nexus_api_get "/users/validate.json")" || return 1
    python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
name = d.get('name', '?')
premium = d.get('is_premium', False)
print(f'Authenticated as: {name} ({\"premium\" if premium else \"free\"})')
" <<< "$resp"
}

nexus_is_premium() {
    local resp
    resp="$(nexus_api_get "/users/validate.json" 2>/dev/null)" || return 1
    python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d.get('is_premium', False) else 1)
" <<< "$resp"
}

# ── core API call ───────────────────────────────────────────────────────

# GET with API key, rate-limit tracking, retry on 429.
# Prints JSON body to stdout, returns nonzero on HTTP error.
# Rate-limit headers are captured and warnings emitted when low.
nexus_api_get() {
    local path="$1"
    local key; key="$(nexus_key)" || return 1

    # Refuse if we know we're out of quota
    if [[ "$_NEXUS_RL_DAILY_REMAINING" == "0" ]] || [[ "$_NEXUS_RL_HOURLY_REMAINING" == "0" ]]; then
        perr "Nexus API rate limit exhausted. Wait and retry."
        return 1
    fi

    local header_file; header_file="$(mktemp)"
    local http_code body
    body="$(curl -sS -w '%{http_code}' \
        -D "$header_file" \
        -H "apikey: $key" \
        -H "User-Agent: $POWOS_NEXUS_UA" \
        -H "Accept: application/json" \
        "${POWOS_NEXUS_BASE}${path}")" || { rm -f "$header_file"; return 1; }

    http_code="${body: -3}"
    body="${body:0:${#body}-3}"

    # Parse rate-limit headers
    _NEXUS_RL_DAILY_REMAINING="$(grep -i '^x-rl-daily-remaining:' "$header_file" 2>/dev/null | tr -d '[:space:]' | cut -d: -f2)"
    _NEXUS_RL_HOURLY_REMAINING="$(grep -i '^x-rl-hourly-remaining:' "$header_file" 2>/dev/null | tr -d '[:space:]' | cut -d: -f2)"
    rm -f "$header_file"

    # Warn when running low
    if [[ -n "$_NEXUS_RL_DAILY_REMAINING" ]] && (( _NEXUS_RL_DAILY_REMAINING < 100 )); then
        pwarn "Nexus API: ${_NEXUS_RL_DAILY_REMAINING} daily requests remaining"
    fi

    case "$http_code" in
        2[0-9][0-9]) printf '%s' "$body"; return 0 ;;
        429)
            perr "Nexus API rate limited (429). Try again later."
            return 1
            ;;
        401|403)
            perr "Nexus API auth failed ($http_code). Check your API key."
            return 1
            ;;
        *)
            perr "Nexus API error: HTTP $http_code on $path"
            return 1
            ;;
    esac
}

# ── high-level helpers ──────────────────────────────────────────────────

# Mod metadata (name, version, author, description, category, endorsements)
nexus_mod_info() {
    local slug="$1" mod_id="$2"
    nexus_api_get "/games/$slug/mods/$mod_id.json"
}

# File list for a mod. Category IDs: 1=MAIN 2=UPDATE 3=OPTIONAL 4=OLD 5=MISC
nexus_mod_files() {
    local slug="$1" mod_id="$2"
    nexus_api_get "/games/$slug/mods/$mod_id/files.json"
}

# CDN download links (premium only without key+expires)
nexus_download_link() {
    local slug="$1" mod_id="$2" file_id="$3" key="${4:-}" expires="${5:-}"
    local path="/games/$slug/mods/$mod_id/files/$file_id/download_link.json"
    if [[ -n "$key" && -n "$expires" ]]; then
        path="${path}?key=${key}&expires=${expires}"
    fi
    nexus_api_get "$path"
}

# Recently updated mods (for update checking)
nexus_updated_mods() {
    local slug="$1" period="${2:-1m}"  # 1d, 1w, 1m
    nexus_api_get "/games/$slug/mods/updated.json?period=$period"
}

# ── file-id resolution ──────────────────────────────────────────────────
# Given a mod, pick the best file to download:
#   1. Primary main file (is_primary=true, category=1)
#   2. Newest main file (category=1, sorted by uploaded)
#   3. Newest file of any category
# Returns: file_id on stdout, 0 on success, 1 if no files.

nexus_resolve_file_id() {
    local slug="$1" mod_id="$2"
    local files_json
    files_json="$(nexus_mod_files "$slug" "$mod_id")" || return 1
    python3 - <<'PY' <<< "$files_json"
import json, sys
data = json.loads(sys.stdin.read())
files = data.get("files", [])
if not files:
    sys.exit(1)

# Sort by upload time descending
files.sort(key=lambda f: f.get("uploaded_timestamp", 0), reverse=True)

# 1. Primary main file
for f in files:
    if f.get("is_primary", False) and f.get("category_id") == 1:
        print(f["file_id"])
        sys.exit(0)

# 2. Newest main file
for f in files:
    if f.get("category_id") == 1:
        print(f["file_id"])
        sys.exit(0)

# 3. Newest file
print(files[0]["file_id"])
PY
}

# ── download a mod file ─────────────────────────────────────────────────
# Premium: direct API download.
# Free: returns 1 with a message to use the browser.
# Output: path to downloaded file on stdout.

nexus_download() {
    local slug="$1" mod_id="$2" file_id="$3" dest_dir="$4"
    local key="${5:-}" expires="${6:-}"

    mkdir -p "$dest_dir"

    # Get file info for the filename
    local files_json filename
    files_json="$(nexus_mod_files "$slug" "$mod_id")" || return 1
    filename="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
fid = int(sys.argv[1])
for f in data.get('files', []):
    if f['file_id'] == fid:
        print(f.get('file_name', f'mod-{fid}.zip'))
        sys.exit(0)
print(f'mod-{fid}.zip')
" "$file_id" <<< "$files_json")"

    local dest="$dest_dir/$filename"

    # Skip if already downloaded
    if [[ -f "$dest" ]]; then
        plog "Already downloaded: $filename"
        echo "$dest"
        return 0
    fi

    # Get CDN URL
    local link_json cdn_url
    link_json="$(nexus_download_link "$slug" "$mod_id" "$file_id" "$key" "$expires")" || {
        if [[ -z "$key" ]]; then
            perr "Free account: download requires browser handoff."
            perr "Open: https://www.nexusmods.com/$slug/mods/$mod_id?tab=files"
            perr "Click 'Download with Manager' — powos will receive the nxm:// callback."
        fi
        return 1
    }

    cdn_url="$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
if isinstance(data, list) and data:
    print(data[0].get('URI', ''))
elif isinstance(data, dict):
    print(data.get('URI', ''))
" <<< "$link_json")"

    if [[ -z "$cdn_url" ]]; then
        perr "No download URL returned from Nexus API."
        return 1
    fi

    plog "Downloading: $filename"
    if ! curl -fL --progress-bar "$cdn_url" -o "$dest"; then
        rm -f "$dest"
        perr "Download failed: $filename"
        return 1
    fi

    echo "$dest"
}

# ── nxm:// URL parsing ──────────────────────────────────────────────────
# Parse nxm://game/mods/modId/files/fileId?key=...&expires=...
# Returns: slug mod_id file_id key expires (space-separated)

nexus_parse_nxm() {
    local url="$1"
    python3 -c "
import sys, re
from urllib.parse import urlparse, parse_qs
url = sys.argv[1]
# nxm://skyrimspecialedition/mods/12345/files/67890?key=abc&expires=123
url = url.replace('nxm://', 'http://')
p = urlparse(url)
slug = p.hostname or ''
parts = p.path.strip('/').split('/')
mod_id = parts[1] if len(parts) > 1 else ''
file_id = parts[3] if len(parts) > 3 else ''
qs = parse_qs(p.query)
key = qs.get('key', [''])[0]
expires = qs.get('expires', [''])[0]
print(f'{slug} {mod_id} {file_id} {key} {expires}')
" "$url"
}
