#!/bin/bash
# mods/core.sh — Native PowOS mod manager: manifest CRUD + staging helpers.
#
# Single per-game JSON manifest is the source of truth for all mod state.
# Every mod operation (install/remove/enable/disable) reads and writes it.
#
# Requires: python3
# Sources:  nexus-api.sh (for Nexus interaction)

set -uo pipefail

# ── paths ────────────────────────────────────────────────────────────────
MODS_STATE_DIR="${MODS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/powos/mods}"
MODS_MANIFEST_DIR="$MODS_STATE_DIR/manifests"
MODS_STAGING_DIR="$MODS_STATE_DIR/staging"
MODS_SNAPSHOT_DIR="$MODS_STATE_DIR/snapshots"
MODS_CACHE_DIR="${MODS_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/powos/mods}"
MODS_DOWNLOAD_DIR="$MODS_CACHE_DIR/downloads"
MODS_GAMES_CONF_DIR="${MODS_GAMES_CONF_DIR:-/usr/lib/powos/mods/games.d}"

# ── game config loading ─────────────────────────────────────────────────
# Source a games.d/<game>.conf, populating GAME_* variables.
# Falls back to project source tree during development.

mods_load_game_conf() {
    local game="$1"
    local conf=""

    # Try installed path first, then dev source tree
    for dir in "$MODS_GAMES_CONF_DIR" \
               "${POWOS_SRC:-/var/lib/powos/src}/config/mods/games.d" \
               "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../config/mods/games.d"; do
        if [[ -f "$dir/${game}.conf" ]]; then
            conf="$dir/${game}.conf"
            break
        fi
    done

    if [[ -z "$conf" ]]; then
        perr "No game config for '$game'. Available:"
        mods_list_games
        return 1
    fi

    # Clear previous game config
    unset GAME_NAME GAME_APPID GAME_NEXUS_SLUG GAME_BACKEND \
          GAME_FRAMEWORKS GAME_INSTALL_RULES GAME_EXCLUDE_FROM_OVERLAY \
          GAME_VERIFY_CHECKS GAME_KNOWN_CONFLICTS GAME_LOAD_ORDER_TOOL 2>/dev/null || true

    source "$conf"
}

mods_list_games() {
    local dir
    for dir in "$MODS_GAMES_CONF_DIR" \
               "${POWOS_SRC:-/var/lib/powos/src}/config/mods/games.d" \
               "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../config/mods/games.d"; do
        if [[ -d "$dir" ]]; then
            for f in "$dir"/*.conf; do
                [[ -f "$f" ]] || continue
                local name; name="$(basename "$f" .conf)"
                local label=""
                label="$(grep -m1 '^GAME_NAME=' "$f" | cut -d'"' -f2)"
                printf "  %-20s %s\n" "$name" "$label"
            done
            return 0
        fi
    done
    pwarn "No games.d directory found."
}

# ── game dir resolution ─────────────────────────────────────────────────
# Resolve a Steam game's install directory from its appid.
# Reuses the same logic as asi.sh but standalone.

mods_game_dir() {
    local appid="$1"
    python3 - "$appid" "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" <<'PY'
import sys, os, re
appid = sys.argv[1]
roots = [r for r in sys.argv[2:] if r]
libs = []
for root in roots:
    lf = os.path.join(root, "steamapps", "libraryfolders.vdf")
    if os.path.exists(lf):
        txt = open(lf, encoding="utf-8", errors="ignore").read()
        libs += re.findall(r'"path"\s*"([^"]+)"', txt)
    libs.append(root)
seen = set()
for lib in libs:
    lib = lib.replace("\\\\", "/")
    if lib in seen:
        continue
    seen.add(lib)
    acf = os.path.join(lib, "steamapps", "appmanifest_%s.acf" % appid)
    if os.path.exists(acf):
        t = open(acf, encoding="utf-8", errors="ignore").read()
        m = re.search(r'"installdir"\s*"([^"]+)"', t)
        if m:
            p = os.path.join(lib, "steamapps", "common", m.group(1))
            if os.path.isdir(p):
                print(p)
                sys.exit(0)
sys.exit(1)
PY
}

# ── Flatpak Steam detection ────────────────────────────────────────────
mods_check_steam_flatpak() {
    if flatpak info com.valvesoftware.Steam &>/dev/null; then
        perr "Steam is installed as a Flatpak. Overlay deploy requires native Steam"
        perr "(rpm/system package). On Bazzite, Steam is the system package by default."
        return 1
    fi
    return 0
}

# ── manifest CRUD ───────────────────────────────────────────────────────

mods_manifest_path() { echo "$MODS_MANIFEST_DIR/${1}.json"; }

# Initialize an empty manifest for a game if it doesn't exist.
mods_manifest_init() {
    local game="$1"
    local mf; mf="$(mods_manifest_path "$game")"
    if [[ -f "$mf" ]]; then
        return 0
    fi

    mods_load_game_conf "$game" || return 1
    local game_dir
    game_dir="$(mods_game_dir "$GAME_APPID" 2>/dev/null)" || game_dir=""

    mkdir -p "$(dirname "$mf")"
    python3 - "$mf" "$game" "$GAME_APPID" "$game_dir" "${GAME_BACKEND:-overlayfs}" <<'PY'
import json, sys
mf, game, appid, game_dir, backend = sys.argv[1:6]
data = {
    "schema_version": 1,
    "game": game,
    "appid": int(appid),
    "game_dir": game_dir,
    "deploy_method": backend if backend != "overlayfs" else "overlayfs",
    "overlay_mounted": False,
    "last_deployed": None,
    "last_verified": None,
    "last_verify_result": None,
    "mods": []
}
json.dump(data, open(mf, "w"), indent=2)
PY
    plog "Created manifest for $game"
}

# Read the manifest and print it to stdout.
mods_manifest_read() {
    local game="$1"
    local mf; mf="$(mods_manifest_path "$game")"
    [[ -f "$mf" ]] || { perr "No manifest for '$game'. Run: powos mods install $game <mod>"; return 1; }
    cat "$mf"
}

# Add or update a mod entry in the manifest.
# Takes game name + mod metadata as arguments.
mods_manifest_add_mod() {
    local game="$1"
    shift
    # Remaining args passed as key=value pairs to python
    local mf; mf="$(mods_manifest_path "$game")"
    [[ -f "$mf" ]] || { mods_manifest_init "$game" || return 1; mf="$(mods_manifest_path "$game")"; }

    python3 - "$mf" "$@" <<'PY'
import json, sys, os

mf = sys.argv[1]
# Parse key=value pairs
kv = {}
for arg in sys.argv[2:]:
    k, _, v = arg.partition("=")
    kv[k] = v

data = json.load(open(mf))

# Build mod entry
mod_id = kv.get("id", "")
entry = {
    "id": mod_id,
    "nexus_mod_id": int(kv["nexus_mod_id"]) if kv.get("nexus_mod_id", "").isdigit() else None,
    "nexus_file_id": int(kv["nexus_file_id"]) if kv.get("nexus_file_id", "").isdigit() else None,
    "name": kv.get("name", ""),
    "version": kv.get("version", ""),
    "author": kv.get("author", ""),
    "source": kv.get("source", "nexus"),
    "installed_at": kv.get("installed_at", ""),
    "updated_at": None,
    "enabled": True,
    "priority": int(kv.get("priority", "10")),
    "is_framework": kv.get("is_framework", "false") == "true",
    "staging_dir": kv.get("staging_dir", ""),
    "files": json.loads(kv.get("files_json", "[]")),
    "depends_on": json.loads(kv.get("depends_on", "[]")),
    "tags": json.loads(kv.get("tags", "[]")),
    "nexus_url": kv.get("nexus_url", ""),
}

# Upsert: replace existing mod with same id, or append
mods = [m for m in data.get("mods", []) if m.get("id") != mod_id]
mods.append(entry)
# Sort by priority (lower first)
mods.sort(key=lambda m: m.get("priority", 10))
data["mods"] = mods

json.dump(data, open(mf, "w"), indent=2)
print(f"Manifest: added/updated {kv.get('name', mod_id)}")
PY
}

# Remove a mod from the manifest by id.
mods_manifest_remove_mod() {
    local game="$1" mod_id="$2"
    local mf; mf="$(mods_manifest_path "$game")"
    [[ -f "$mf" ]] || return 0

    python3 - "$mf" "$mod_id" <<'PY'
import json, sys
mf, mod_id = sys.argv[1], sys.argv[2]
data = json.load(open(mf))
before = len(data.get("mods", []))
data["mods"] = [m for m in data.get("mods", []) if m.get("id") != mod_id]
after = len(data["mods"])
json.dump(data, open(mf, "w"), indent=2)
if before > after:
    print(f"Manifest: removed {mod_id}")
else:
    print(f"Manifest: {mod_id} not found", file=sys.stderr)
    sys.exit(1)
PY
}

# Toggle enabled state of a mod.
mods_manifest_set_enabled() {
    local game="$1" mod_id="$2" enabled="$3"  # enabled: true/false
    local mf; mf="$(mods_manifest_path "$game")"
    [[ -f "$mf" ]] || { perr "No manifest for '$game'."; return 1; }

    python3 - "$mf" "$mod_id" "$enabled" <<'PY'
import json, sys
mf, mod_id, enabled = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
data = json.load(open(mf))
found = False
for m in data.get("mods", []):
    if m.get("id") == mod_id:
        m["enabled"] = enabled
        found = True
        break
if not found:
    print(f"Mod {mod_id} not found in manifest", file=sys.stderr)
    sys.exit(1)
json.dump(data, open(mf, "w"), indent=2)
state = "enabled" if enabled else "disabled"
print(f"Manifest: {mod_id} {state}")
PY
}

# Update deploy state in manifest.
mods_manifest_set_deploy_state() {
    local game="$1" mounted="$2"  # mounted: true/false
    local mf; mf="$(mods_manifest_path "$game")"
    [[ -f "$mf" ]] || return 1

    python3 - "$mf" "$mounted" <<'PY'
import json, sys
from datetime import datetime, timezone
mf, mounted = sys.argv[1], sys.argv[2] == "true"
data = json.load(open(mf))
data["overlay_mounted"] = mounted
if mounted:
    data["last_deployed"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(data, open(mf, "w"), indent=2)
PY
}

# Update verify result in manifest.
mods_manifest_set_verify() {
    local game="$1" result="$2"  # pass/warn/fail
    local mf; mf="$(mods_manifest_path "$game")"
    [[ -f "$mf" ]] || return 1

    python3 - "$mf" "$result" <<'PY'
import json, sys
from datetime import datetime, timezone
mf, result = sys.argv[1], sys.argv[2]
data = json.load(open(mf))
data["last_verified"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
data["last_verify_result"] = result
json.dump(data, open(mf, "w"), indent=2)
PY
}

# List mods in a game's manifest (human-readable).
mods_manifest_list() {
    local game="$1"
    local mf; mf="$(mods_manifest_path "$game")"
    [[ -f "$mf" ]] || { plog "No mods installed for '$game'."; return 0; }

    python3 - "$mf" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
mods = data.get("mods", [])
if not mods:
    print("  (no mods installed)")
    sys.exit(0)

print(f"  {'ID':<20} {'Name':<35} {'Version':<12} {'Pri':<5} {'State':<8} Source")
print(f"  {'─'*20} {'─'*35} {'─'*12} {'─'*5} {'─'*8} {'─'*10}")
for m in mods:
    state = "ON" if m.get("enabled", True) else "OFF"
    fw = " [fw]" if m.get("is_framework") else ""
    print(f"  {m.get('id','?'):<20} {(m.get('name','')[:33]+fw):<35} "
          f"{m.get('version','?'):<12} {m.get('priority',10):<5} {state:<8} {m.get('source','?')}")
PY
}

# Get mod count.
mods_manifest_count() {
    local game="$1"
    local mf; mf="$(mods_manifest_path "$game")"
    [[ -f "$mf" ]] || { echo "0"; return 0; }
    python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('mods',[])))" "$mf"
}

# Get list of enabled mod staging dirs in priority order (for overlay mount).
# Returns one path per line, highest-priority first (leftmost in lowerdir).
mods_manifest_enabled_staging_dirs() {
    local game="$1"
    local mf; mf="$(mods_manifest_path "$game")"
    [[ -f "$mf" ]] || return 1

    python3 - "$mf" <<'PY'
import json, sys, os
data = json.load(open(sys.argv[1]))
mods = [m for m in data.get("mods", []) if m.get("enabled", True)]
# Sort by priority descending (highest priority = leftmost in overlay = printed first)
mods.sort(key=lambda m: m.get("priority", 10), reverse=True)
for m in mods:
    d = os.path.expanduser(m.get("staging_dir", ""))
    if d and os.path.isdir(d):
        print(d)
PY
}

# ── staging ─────────────────────────────────────────────────────────────

mods_staging_path() { echo "$MODS_STAGING_DIR/$1/$2"; }  # game, mod-id

# Create a staging directory for a mod. Returns the path.
mods_staging_create() {
    local game="$1" mod_id="$2"
    local staging; staging="$(mods_staging_path "$game" "$mod_id")"
    mkdir -p "$staging"
    echo "$staging"
}

# Remove a staging directory.
mods_staging_remove() {
    local game="$1" mod_id="$2"
    local staging; staging="$(mods_staging_path "$game" "$mod_id")"
    if [[ -d "$staging" ]]; then
        rm -rf "$staging"
        plog "Removed staging: $mod_id"
    fi
}

# ── install rules engine ────────────────────────────────────────────────
# Apply GAME_INSTALL_RULES to map extracted mod files into game-relative paths.
# Input: extracted dir, staging dir, GAME_INSTALL_RULES array
# Output: files placed in staging dir with correct relative paths + files_json

mods_apply_install_rules() {
    local extract_dir="$1" staging_dir="$2"
    shift 2
    # GAME_INSTALL_RULES is expected to be set by mods_load_game_conf

    python3 - "$extract_dir" "$staging_dir" <<'PY'
import os, sys, json, shutil, fnmatch

extract_dir = sys.argv[1]
staging_dir = sys.argv[2]

# Read rules from environment
rules_raw = os.environ.get("GAME_INSTALL_RULES_JSON", "[]")
rules = json.loads(rules_raw)

files_placed = []
files_unmatched = []

for root, dirs, files in os.walk(extract_dir):
    for fname in files:
        src = os.path.join(root, fname)
        rel = os.path.relpath(src, extract_dir)

        matched = False
        for rule in rules:
            pattern, _, target = rule.partition(":")
            if not target:
                continue
            # Match against the relative path
            if fnmatch.fnmatch(rel, pattern) or fnmatch.fnmatch(fname, pattern):
                if target == ".":
                    dest_rel = rel
                else:
                    dest_rel = os.path.join(target, fname)
                dest = os.path.join(staging_dir, dest_rel)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.copy2(src, dest)
                files_placed.append(dest_rel)
                matched = True
                break

        if not matched:
            # Skip common non-mod files
            skip = {".txt", ".md", ".pdf", ".html", ".url", ".lnk",
                    ".png", ".jpg", ".jpeg", ".gif", ".bmp"}
            if os.path.splitext(fname)[1].lower() not in skip:
                files_unmatched.append(rel)

if files_unmatched:
    print(f"WARNING: {len(files_unmatched)} file(s) did not match any install rule:", file=sys.stderr)
    for f in files_unmatched[:10]:
        print(f"  {f}", file=sys.stderr)
    if len(files_unmatched) > 10:
        print(f"  ... and {len(files_unmatched)-10} more", file=sys.stderr)

# Output: JSON array of placed files with hashes
import hashlib
result = []
for rel in files_placed:
    full = os.path.join(staging_dir, rel)
    h = hashlib.sha256(open(full, "rb").read()).hexdigest()
    sz = os.path.getsize(full)
    result.append({"path": rel, "sha256": h, "size": sz})

print(json.dumps(result))
PY
}

# Convert GAME_INSTALL_RULES bash array to JSON for Python consumption.
mods_rules_to_json() {
    local json="["
    local first=true
    for rule in "${GAME_INSTALL_RULES[@]}"; do
        $first || json+=","
        first=false
        json+="\"$rule\""
    done
    json+="]"
    echo "$json"
}

# ── extract archive ─────────────────────────────────────────────────────
# Handles .zip, .7z, .rar, .tar.gz
mods_extract() {
    local archive="$1" dest="$2"
    mkdir -p "$dest"

    case "${archive,,}" in
        *.zip)
            unzip -qo "$archive" -d "$dest" 2>/dev/null || {
                # Try 7z as fallback (handles some broken zips)
                7z x -y -o"$dest" "$archive" >/dev/null 2>&1 || { perr "Failed to extract: $archive"; return 1; }
            }
            ;;
        *.7z)
            7z x -y -o"$dest" "$archive" >/dev/null 2>&1 || { perr "Failed to extract: $archive"; return 1; }
            ;;
        *.rar)
            if command -v unrar &>/dev/null; then
                unrar x -y -o+ "$archive" "$dest" >/dev/null 2>&1
            elif command -v 7z &>/dev/null; then
                7z x -y -o"$dest" "$archive" >/dev/null 2>&1
            else
                perr "No unrar or 7z available for .rar extraction."
                return 1
            fi
            ;;
        *.tar.gz|*.tgz)
            tar xzf "$archive" -C "$dest" 2>/dev/null || { perr "Failed to extract: $archive"; return 1; }
            ;;
        *.tar)
            tar xf "$archive" -C "$dest" 2>/dev/null || { perr "Failed to extract: $archive"; return 1; }
            ;;
        *)
            perr "Unknown archive format: $archive"
            return 1
            ;;
    esac
}

# ── high-level install ──────────────────────────────────────────────────
# The main install verb: download, extract, apply rules, stage, update manifest.

mods_install_mod() {
    local game="$1" mod_ref="$2"
    local nexus_mod_id="" nexus_file_id="" nxm_key="" nxm_expires=""

    mods_load_game_conf "$game" || return 1
    mods_manifest_init "$game" || return 1

    local slug="${GAME_NEXUS_SLUG:-$game}"

    # Parse mod reference
    if [[ "$mod_ref" =~ ^[0-9]+$ ]]; then
        # Numeric = Nexus mod ID
        nexus_mod_id="$mod_ref"
    elif [[ "$mod_ref" == nxm://* ]]; then
        # nxm:// URL
        local parsed; parsed="$(nexus_parse_nxm "$mod_ref")"
        read -r slug nexus_mod_id nexus_file_id nxm_key nxm_expires <<< "$parsed"
    elif [[ -f "$mod_ref" ]]; then
        # Local file
        _mods_install_local "$game" "$mod_ref"
        return $?
    else
        perr "Unknown mod reference: $mod_ref"
        perr "Use: Nexus mod ID (number), nxm:// URL, or local file path"
        return 1
    fi

    # Get mod info from Nexus
    local mod_info
    mod_info="$(nexus_mod_info "$slug" "$nexus_mod_id")" || {
        perr "Failed to fetch mod info for $slug/$nexus_mod_id"
        return 1
    }

    local mod_name mod_version mod_author
    read -r mod_name mod_version mod_author < <(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(d.get('name','Unknown'), d.get('version','?'), d.get('author','?'))
" <<< "$mod_info")

    plog "Installing: ${BOLD}$mod_name${NC} v$mod_version by $mod_author"

    # Resolve file ID if not provided
    if [[ -z "$nexus_file_id" ]]; then
        nexus_file_id="$(nexus_resolve_file_id "$slug" "$nexus_mod_id")" || {
            perr "No downloadable files found for mod $nexus_mod_id"
            return 1
        }
    fi

    local mod_id="mod-${nexus_mod_id}"

    # Create snapshot before install
    mods_snapshot_create "$game" "install" 2>/dev/null || true

    # Download
    local archive
    archive="$(nexus_download "$slug" "$nexus_mod_id" "$nexus_file_id" \
        "$MODS_DOWNLOAD_DIR/$game" "$nxm_key" "$nxm_expires")" || return 1

    # Stage: extract + apply rules
    local staging; staging="$(mods_staging_create "$game" "$mod_id")"
    local extract_tmp; extract_tmp="$(mktemp -d)"

    plog "Extracting and staging..."
    mods_extract "$archive" "$extract_tmp" || { rm -rf "$extract_tmp"; mods_staging_remove "$game" "$mod_id"; return 1; }

    # Apply install rules
    local files_json
    GAME_INSTALL_RULES_JSON="$(mods_rules_to_json)" \
        files_json="$(mods_apply_install_rules "$extract_tmp" "$staging")" || {
        rm -rf "$extract_tmp"
        mods_staging_remove "$game" "$mod_id"
        perr "Failed to apply install rules"
        return 1
    }
    rm -rf "$extract_tmp"

    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Update manifest
    mods_manifest_add_mod "$game" \
        "id=$mod_id" \
        "nexus_mod_id=$nexus_mod_id" \
        "nexus_file_id=$nexus_file_id" \
        "name=$mod_name" \
        "version=$mod_version" \
        "author=$mod_author" \
        "source=nexus" \
        "installed_at=$ts" \
        "priority=10" \
        "staging_dir=$staging" \
        "files_json=$files_json" \
        "nexus_url=https://www.nexusmods.com/$slug/mods/$nexus_mod_id" || {
        mods_staging_remove "$game" "$mod_id"
        return 1
    }

    local n_files; n_files="$(python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))" <<< "$files_json")"
    pok "Staged: $mod_name ($n_files files)"
    plog "Run ${BOLD}powos mods deploy $game${NC} to activate"
}

# Install a local archive file (not from Nexus).
_mods_install_local() {
    local game="$1" file="$2"
    local basename; basename="$(basename "$file")"
    local mod_id="local-$(echo "$basename" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/\.\(zip\|7z\|rar\|tar\.gz\)$//')"

    plog "Installing local mod: ${BOLD}$basename${NC}"

    mods_manifest_init "$game" || return 1
    mods_snapshot_create "$game" "install" 2>/dev/null || true

    local staging; staging="$(mods_staging_create "$game" "$mod_id")"
    local extract_tmp; extract_tmp="$(mktemp -d)"

    mods_extract "$file" "$extract_tmp" || { rm -rf "$extract_tmp"; mods_staging_remove "$game" "$mod_id"; return 1; }

    local files_json
    GAME_INSTALL_RULES_JSON="$(mods_rules_to_json)" \
        files_json="$(mods_apply_install_rules "$extract_tmp" "$staging")" || {
        rm -rf "$extract_tmp"
        mods_staging_remove "$game" "$mod_id"
        return 1
    }
    rm -rf "$extract_tmp"

    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mods_manifest_add_mod "$game" \
        "id=$mod_id" \
        "name=$basename" \
        "source=local" \
        "installed_at=$ts" \
        "priority=10" \
        "staging_dir=$staging" \
        "files_json=$files_json"

    pok "Staged: $basename"
}

# ── remove ──────────────────────────────────────────────────────────────

mods_remove_mod() {
    local game="$1" mod_id="$2"
    mods_snapshot_create "$game" "remove" 2>/dev/null || true
    mods_staging_remove "$game" "$mod_id"
    mods_manifest_remove_mod "$game" "$mod_id"
    pok "Removed: $mod_id"
    plog "Run ${BOLD}powos mods deploy $game${NC} to apply"
}

# ── enable / disable ───────────────────────────────────────────────────

mods_enable_mod() {
    local game="$1" mod_id="$2"
    mods_manifest_set_enabled "$game" "$mod_id" "true"
    pok "Enabled: $mod_id"
    plog "Run ${BOLD}powos mods deploy $game${NC} to apply"
}

mods_disable_mod() {
    local game="$1" mod_id="$2"
    mods_manifest_set_enabled "$game" "$mod_id" "false"
    pok "Disabled: $mod_id"
    plog "Run ${BOLD}powos mods deploy $game${NC} to apply"
}

# ── framework management ───────────────────────────────────────────────
# Check that required frameworks are installed for a game.
# Returns 0 if all required frameworks present, 1 if missing.

mods_check_frameworks() {
    local game="$1"
    mods_load_game_conf "$game" || return 1
    [[ ${#GAME_FRAMEWORKS[@]} -gt 0 ]] || return 0

    local mf; mf="$(mods_manifest_path "$game")"
    local missing=()

    for fw_spec in "${GAME_FRAMEWORKS[@]}"; do
        local fw_name fw_nexus_id fw_required
        IFS=: read -r fw_name fw_nexus_id fw_required <<< "$fw_spec"
        [[ "$fw_required" == "required" ]] || continue

        # Check if framework is in manifest
        if [[ -f "$mf" ]]; then
            local found
            found="$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
nid = int(sys.argv[2]) if sys.argv[2].isdigit() else 0
found = any(
    m.get('nexus_mod_id') == nid or m.get('id') == f'fw-{sys.argv[3]}'
    for m in data.get('mods', [])
)
print('yes' if found else 'no')
" "$mf" "$fw_nexus_id" "$fw_name")"
            [[ "$found" == "yes" ]] && continue
        fi

        missing+=("$fw_name (nexus:$fw_nexus_id)")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        pwarn "Missing required frameworks for $game:"
        for m in "${missing[@]}"; do
            pwarn "  - $m"
        done
        return 1
    fi
    return 0
}

# Install all required frameworks for a game.
mods_install_frameworks() {
    local game="$1"
    mods_load_game_conf "$game" || return 1
    [[ ${#GAME_FRAMEWORKS[@]} -gt 0 ]] || return 0

    local slug="${GAME_NEXUS_SLUG:-$game}"

    for fw_spec in "${GAME_FRAMEWORKS[@]}"; do
        local fw_name fw_nexus_id fw_required
        IFS=: read -r fw_name fw_nexus_id fw_required <<< "$fw_spec"

        # Skip if already installed
        local mod_id="fw-${fw_name}"
        local staging; staging="$(mods_staging_path "$game" "$mod_id")"
        [[ -d "$staging" ]] && continue

        # Skip non-Nexus frameworks (id=0 means manual install)
        [[ "$fw_nexus_id" == "0" ]] && {
            pwarn "Framework $fw_name requires manual install (not on Nexus)"
            continue
        }

        plog "Installing framework: ${BOLD}$fw_name${NC}"

        local file_id
        file_id="$(nexus_resolve_file_id "$slug" "$fw_nexus_id")" || {
            perr "Failed to resolve file for framework $fw_name"
            [[ "$fw_required" == "required" ]] && return 1
            continue
        }

        local archive
        archive="$(nexus_download "$slug" "$fw_nexus_id" "$file_id" \
            "$MODS_DOWNLOAD_DIR/$game")" || {
            [[ "$fw_required" == "required" ]] && return 1
            continue
        }

        staging="$(mods_staging_create "$game" "$mod_id")"
        local extract_tmp; extract_tmp="$(mktemp -d)"
        mods_extract "$archive" "$extract_tmp" || { rm -rf "$extract_tmp"; continue; }

        local files_json
        GAME_INSTALL_RULES_JSON="$(mods_rules_to_json)" \
            files_json="$(mods_apply_install_rules "$extract_tmp" "$staging")" || {
            rm -rf "$extract_tmp"
            continue
        }
        rm -rf "$extract_tmp"

        local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local mod_info
        mod_info="$(nexus_mod_info "$slug" "$fw_nexus_id" 2>/dev/null)" || mod_info="{}"
        local fw_version; fw_version="$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('version','?'))" <<< "$mod_info")"

        mods_manifest_add_mod "$game" \
            "id=$mod_id" \
            "nexus_mod_id=$fw_nexus_id" \
            "nexus_file_id=$file_id" \
            "name=$fw_name" \
            "version=$fw_version" \
            "source=nexus" \
            "installed_at=$ts" \
            "priority=0" \
            "is_framework=true" \
            "staging_dir=$staging" \
            "files_json=$files_json" \
            "nexus_url=https://www.nexusmods.com/$slug/mods/$fw_nexus_id"

        pok "Framework installed: $fw_name v$fw_version"
    done
}

# ── status ──────────────────────────────────────────────────────────────

mods_status_cmd() {
    local game="${1:-}"

    if [[ -z "$game" ]]; then
        # Show status for all games with manifests
        echo -e "${BOLD}PowOS Mods Status${NC}"
        echo "═══════════════════════════════════════"
        local found=false
        for mf in "$MODS_MANIFEST_DIR"/*.json; do
            [[ -f "$mf" ]] || continue
            found=true
            python3 - "$mf" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
game = data.get("game", "?")
n = len(data.get("mods", []))
enabled = sum(1 for m in data.get("mods", []) if m.get("enabled", True))
deployed = "mounted" if data.get("overlay_mounted") else "not deployed"
verify = data.get("last_verify_result", "never")
print(f"  {game:<25} {n} mods ({enabled} enabled), {deployed}, verify: {verify}")
PY
        done
        $found || plog "No games managed. Install mods with: powos mods install <game> <mod-id>"
        return 0
    fi

    # Status for a specific game
    mods_load_game_conf "$game" || return 1
    echo -e "${BOLD}${GAME_NAME} (appid ${GAME_APPID})${NC}"
    echo "═══════════════════════════════════════"

    local game_dir
    game_dir="$(mods_game_dir "$GAME_APPID" 2>/dev/null)" || game_dir="(not installed)"
    echo -e "  Game dir:    $game_dir"

    local mf; mf="$(mods_manifest_path "$game")"
    if [[ ! -f "$mf" ]]; then
        echo -e "  Status:      No mods managed"
        return 0
    fi

    python3 - "$mf" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
mods = data.get("mods", [])
enabled = [m for m in mods if m.get("enabled", True)]
disabled = [m for m in mods if not m.get("enabled", True)]
frameworks = [m for m in mods if m.get("is_framework")]
content = [m for m in mods if not m.get("is_framework")]

print(f"  Deploy:      {data.get('deploy_method', '?')}, "
      f"{'mounted' if data.get('overlay_mounted') else 'not mounted'}")
if data.get("last_deployed"):
    print(f"  Last deploy: {data['last_deployed']}")
if data.get("last_verified"):
    print(f"  Last verify: {data['last_verified']} ({data.get('last_verify_result', '?')})")

print(f"\n  Frameworks:  {len(frameworks)}")
for m in frameworks:
    state = "ON" if m.get("enabled", True) else "OFF"
    print(f"    [{state}] {m.get('name','?')} v{m.get('version','?')}")

print(f"\n  Content mods: {len(content)} ({len([m for m in content if m.get('enabled', True)])} enabled)")
for m in content:
    state = "ON" if m.get("enabled", True) else "OFF"
    print(f"    [{state}] {m.get('name','?')} v{m.get('version','?')} (pri:{m.get('priority',10)})")
PY
}
