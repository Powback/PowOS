#!/bin/bash
# test-mods-core.sh - Tier-1 unit tests for the native PowOS mod manager.
#
# Tests manifest CRUD, install-rules mapping, snapshot create/restore,
# and nexus-api URL construction. No network, no GPU, no real games —
# runs in Docker or any Linux box with python3.
#
# Usage:  bash test/tier1/test-mods-core.sh
#   Docker: docker exec powos bash /var/lib/powos/src/test/tier1/test-mods-core.sh

set -uo pipefail

# ── Locate libs ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."

CORE_LIB="$REPO_ROOT/lib/mods/core.sh"
NEXUS_LIB="$REPO_ROOT/lib/mods/nexus-api.sh"
INSTALL_LIB="$REPO_ROOT/lib/mods/install.sh"
SNAPSHOT_LIB="$REPO_ROOT/lib/mods/snapshot.sh"
DEPLOY_LIB="$REPO_ROOT/lib/mods/deploy.sh"
VERIFY_LIB="$REPO_ROOT/lib/mods/verify.sh"
ADOPT_LIB="$REPO_ROOT/lib/mods/adopt.sh"

# Installed-path fallback
for lib in CORE_LIB NEXUS_LIB INSTALL_LIB SNAPSHOT_LIB DEPLOY_LIB VERIFY_LIB ADOPT_LIB; do
    if [[ ! -f "${!lib}" ]]; then
        eval "$lib=\"/usr/lib/powos/mods/$(basename "${!lib}")\""
    fi
done

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
skip() { echo "  skip - $1"; SKIP=$((SKIP+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

echo "== test-mods-core.sh =="

# ── Pre-flight ───────────────────────────────────────────────────────────

for lib in "$INSTALL_LIB" "$CORE_LIB" "$NEXUS_LIB" "$SNAPSHOT_LIB"; do
    if [[ ! -f "$lib" ]]; then
        echo "SKIP: $lib not found"
        exit 0
    fi
done

if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not found"
    exit 0
fi

# ── Setup temp environment ───────────────────────────────────────────────

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Override all paths to temp dir
export MODS_STATE_DIR="$TMP/state"
export MODS_MANIFEST_DIR="$TMP/state/manifests"
export MODS_STAGING_DIR="$TMP/state/staging"
export MODS_SNAPSHOT_DIR="$TMP/state/snapshots"
export MODS_CACHE_DIR="$TMP/cache"
export MODS_DOWNLOAD_DIR="$TMP/cache/downloads"
export MODS_GAMES_CONF_DIR="$REPO_ROOT/config/mods/games.d"
export MODS_MOUNT_BASE="$TMP/mounts"
export HOME="$TMP/home"
export POWOS_NEXUS_KEY_FILE="$TMP/home/.config/powos/nexus.key"
mkdir -p "$TMP/home/.config/powos"

# Source libs (install.sh provides logging helpers)
echo "== Sourcing libs =="
source "$INSTALL_LIB" || { echo "cannot source install lib"; exit 1; }
source "$NEXUS_LIB" || { echo "cannot source nexus-api lib"; exit 1; }
source "$CORE_LIB" || { echo "cannot source core lib"; exit 1; }
source "$SNAPSHOT_LIB" || { echo "cannot source snapshot lib"; exit 1; }
source "$DEPLOY_LIB" 2>/dev/null || true  # may fail without fuse-overlayfs
source "$VERIFY_LIB" 2>/dev/null || true
source "$ADOPT_LIB" 2>/dev/null || true

check "sourcing does not enable errexit" '[[ $- != *e* ]]'

# ═══════════════════════════════════════════════════════════════════════
# 1. GAME CONFIG LOADING
# ═══════════════════════════════════════════════════════════════════════
echo "== Game config loading =="

check "load cyberpunk2077 config" 'mods_load_game_conf cyberpunk2077 >/dev/null 2>&1'
check "GAME_NAME set" '[[ "$GAME_NAME" == "Cyberpunk 2077" ]]'
check "GAME_APPID set" '[[ "$GAME_APPID" == "1091500" ]]'
check "GAME_NEXUS_SLUG set" '[[ "$GAME_NEXUS_SLUG" == "cyberpunk2077" ]]'
check "GAME_FRAMEWORKS not empty" '[[ ${#GAME_FRAMEWORKS[@]} -gt 0 ]]'
check "GAME_INSTALL_RULES not empty" '[[ ${#GAME_INSTALL_RULES[@]} -gt 0 ]]'

check "load skyrimse config" 'mods_load_game_conf skyrimse >/dev/null 2>&1'
check "skyrimse GAME_NAME" '[[ "$GAME_NAME" == "Skyrim Special Edition" ]]'
check "skyrimse has LOOT" '[[ "${GAME_LOAD_ORDER_TOOL:-}" == "loot" ]]'

check "load gtav config (ASI backend)" 'mods_load_game_conf gtav >/dev/null 2>&1'
check "gtav GAME_BACKEND=asi" '[[ "${GAME_BACKEND:-}" == "asi" ]]'

check "invalid game fails" '! mods_load_game_conf nonexistent_game >/dev/null 2>&1'

# ═══════════════════════════════════════════════════════════════════════
# 2. MANIFEST CRUD
# ═══════════════════════════════════════════════════════════════════════
echo "== Manifest CRUD =="

# Create a mock game dir so manifest init succeeds for game_dir resolution
MOCK_GAME_DIR="$TMP/home/.local/share/Steam/steamapps/common/Cyberpunk 2077"
mkdir -p "$MOCK_GAME_DIR"
mkdir -p "$TMP/home/.local/share/Steam/steamapps"
cat > "$TMP/home/.local/share/Steam/steamapps/libraryfolders.vdf" <<'VDF'
"libraryfolders"
{
    "0"
    {
        "path"    "/tmp/test-mods-home/.local/share/Steam"
    }
}
VDF
# Symlink for Steam detection
ln -sf "$TMP/home/.local/share/Steam" "$TMP/home/.steam" 2>/dev/null || true
mkdir -p "$TMP/home/.steam"
ln -sf "$TMP/home/.local/share/Steam" "$TMP/home/.steam/steam" 2>/dev/null || true

# Write a valid appmanifest
cat > "$TMP/home/.local/share/Steam/steamapps/appmanifest_1091500.acf" <<'ACF'
"AppState"
{
    "appid"     "1091500"
    "installdir"    "Cyberpunk 2077"
    "name"      "Cyberpunk 2077"
}
ACF

# Init
check "manifest init" 'mods_manifest_init cyberpunk2077 >/dev/null 2>&1'
check "manifest file created" '[[ -f "$MODS_MANIFEST_DIR/cyberpunk2077.json" ]]'
check "manifest has schema_version" 'python3 -c "import json; d=json.load(open(\"$MODS_MANIFEST_DIR/cyberpunk2077.json\")); assert d[\"schema_version\"]==1"'
check "manifest has game" 'python3 -c "import json; d=json.load(open(\"$MODS_MANIFEST_DIR/cyberpunk2077.json\")); assert d[\"game\"]==\"cyberpunk2077\""'
check "manifest has appid" 'python3 -c "import json; d=json.load(open(\"$MODS_MANIFEST_DIR/cyberpunk2077.json\")); assert d[\"appid\"]==1091500"'
check "manifest mods empty" 'python3 -c "import json; d=json.load(open(\"$MODS_MANIFEST_DIR/cyberpunk2077.json\")); assert len(d[\"mods\"])==0"'

# Add mod
check "add mod" 'mods_manifest_add_mod cyberpunk2077 \
    "id=mod-12345" "nexus_mod_id=12345" "nexus_file_id=67890" \
    "name=Test Mod" "version=1.0" "author=Tester" "source=nexus" \
    "installed_at=2026-07-16T00:00:00Z" "priority=10" \
    "staging_dir=$MODS_STAGING_DIR/cyberpunk2077/mod-12345" \
    "files_json=[{\"path\":\"archive/pc/mod/test.archive\",\"sha256\":\"abc123\",\"size\":1024}]" \
    >/dev/null 2>&1'

check "manifest has 1 mod" '[[ "$(mods_manifest_count cyberpunk2077)" == "1" ]]'

# Add second mod
check "add second mod" 'mods_manifest_add_mod cyberpunk2077 \
    "id=mod-99999" "name=Another Mod" "version=2.0" "source=local" \
    "installed_at=2026-07-16T01:00:00Z" "priority=20" \
    "staging_dir=$MODS_STAGING_DIR/cyberpunk2077/mod-99999" \
    "files_json=[]" \
    >/dev/null 2>&1'

check "manifest has 2 mods" '[[ "$(mods_manifest_count cyberpunk2077)" == "2" ]]'

# Add framework
check "add framework" 'mods_manifest_add_mod cyberpunk2077 \
    "id=fw-red4ext" "nexus_mod_id=2060" "name=RED4ext" "version=1.25" \
    "source=nexus" "installed_at=2026-07-16T00:00:00Z" "priority=0" \
    "is_framework=true" \
    "staging_dir=$MODS_STAGING_DIR/cyberpunk2077/fw-red4ext" \
    "files_json=[]" \
    >/dev/null 2>&1'

check "manifest has 3 entries" '[[ "$(mods_manifest_count cyberpunk2077)" == "3" ]]'

# Verify priority ordering (frameworks first)
check "framework sorted first" 'python3 -c "
import json
d=json.load(open(\"$MODS_MANIFEST_DIR/cyberpunk2077.json\"))
assert d[\"mods\"][0][\"id\"]==\"fw-red4ext\", f\"got {d[\"mods\"][0][\"id\"]}\"
assert d[\"mods\"][0][\"priority\"]==0
"'

# Disable
check "disable mod" 'mods_manifest_set_enabled cyberpunk2077 mod-12345 false >/dev/null 2>&1'
check "mod disabled in manifest" 'python3 -c "
import json
d=json.load(open(\"$MODS_MANIFEST_DIR/cyberpunk2077.json\"))
m=[x for x in d[\"mods\"] if x[\"id\"]==\"mod-12345\"][0]
assert m[\"enabled\"]==False
"'

# Enable
check "enable mod" 'mods_manifest_set_enabled cyberpunk2077 mod-12345 true >/dev/null 2>&1'
check "mod enabled in manifest" 'python3 -c "
import json
d=json.load(open(\"$MODS_MANIFEST_DIR/cyberpunk2077.json\"))
m=[x for x in d[\"mods\"] if x[\"id\"]==\"mod-12345\"][0]
assert m[\"enabled\"]==True
"'

# Remove
check "remove mod" 'mods_manifest_remove_mod cyberpunk2077 mod-99999 >/dev/null 2>&1'
check "manifest has 2 mods after remove" '[[ "$(mods_manifest_count cyberpunk2077)" == "2" ]]'
check "removed mod is gone" 'python3 -c "
import json
d=json.load(open(\"$MODS_MANIFEST_DIR/cyberpunk2077.json\"))
ids=[m[\"id\"] for m in d[\"mods\"]]
assert \"mod-99999\" not in ids
"'

# Remove nonexistent mod fails
check "remove nonexistent fails" '! mods_manifest_remove_mod cyberpunk2077 mod-nonexistent >/dev/null 2>&1'

# Upsert (update existing)
check "upsert mod" 'mods_manifest_add_mod cyberpunk2077 \
    "id=mod-12345" "name=Test Mod Updated" "version=2.0" "source=nexus" \
    "installed_at=2026-07-16T02:00:00Z" "priority=15" \
    "staging_dir=$MODS_STAGING_DIR/cyberpunk2077/mod-12345" \
    "files_json=[]" \
    >/dev/null 2>&1'
check "still 2 mods after upsert" '[[ "$(mods_manifest_count cyberpunk2077)" == "2" ]]'
check "upsert updated version" 'python3 -c "
import json
d=json.load(open(\"$MODS_MANIFEST_DIR/cyberpunk2077.json\"))
m=[x for x in d[\"mods\"] if x[\"id\"]==\"mod-12345\"][0]
assert m[\"version\"]==\"2.0\", f\"got {m[\"version\"]}\"
"'

# List (smoke test — just check it doesn't crash)
check "manifest list runs" 'mods_manifest_list cyberpunk2077 >/dev/null 2>&1'

# Deploy state
check "set deploy state" 'mods_manifest_set_deploy_state cyberpunk2077 true >/dev/null 2>&1'
check "deploy state set" 'python3 -c "
import json
d=json.load(open(\"$MODS_MANIFEST_DIR/cyberpunk2077.json\"))
assert d[\"overlay_mounted\"]==True
assert d[\"last_deployed\"] is not None
"'

# Verify state
check "set verify state" 'mods_manifest_set_verify cyberpunk2077 pass >/dev/null 2>&1'
check "verify state set" 'python3 -c "
import json
d=json.load(open(\"$MODS_MANIFEST_DIR/cyberpunk2077.json\"))
assert d[\"last_verify_result\"]==\"pass\"
assert d[\"last_verified\"] is not None
"'

# ═══════════════════════════════════════════════════════════════════════
# 3. STAGING
# ═══════════════════════════════════════════════════════════════════════
echo "== Staging =="

check "create staging dir" '[[ -n "$(mods_staging_create cyberpunk2077 test-mod)" ]]'
check "staging dir exists" '[[ -d "$MODS_STAGING_DIR/cyberpunk2077/test-mod" ]]'
mods_staging_remove cyberpunk2077 test-mod >/dev/null 2>&1
check "staging dir removed" '[[ ! -d "$MODS_STAGING_DIR/cyberpunk2077/test-mod" ]]'

# ═══════════════════════════════════════════════════════════════════════
# 4. INSTALL RULES ENGINE
# ═══════════════════════════════════════════════════════════════════════
echo "== Install rules engine =="

# Create a mock extracted mod archive for Cyberpunk
MOCK_EXTRACT="$TMP/mock-extract"
mkdir -p "$MOCK_EXTRACT/archive/pc/mod"
mkdir -p "$MOCK_EXTRACT/r6/scripts/mymod"
mkdir -p "$MOCK_EXTRACT/red4ext/plugins"
mkdir -p "$MOCK_EXTRACT/bin/x64/plugins/cyber_engine_tweaks/mods/mymod"

echo "test archive data" > "$MOCK_EXTRACT/archive/pc/mod/mymod.archive"
echo "script data" > "$MOCK_EXTRACT/r6/scripts/mymod/init.reds"
echo "dll data" > "$MOCK_EXTRACT/red4ext/plugins/mymod.dll"
echo "lua data" > "$MOCK_EXTRACT/bin/x64/plugins/cyber_engine_tweaks/mods/mymod/init.lua"
echo "readme" > "$MOCK_EXTRACT/README.md"

MOCK_STAGING="$TMP/mock-staging"
mkdir -p "$MOCK_STAGING"

# Load cyberpunk config for rules
mods_load_game_conf cyberpunk2077 >/dev/null 2>&1

# Apply rules
RULES_OUTPUT="$(GAME_INSTALL_RULES_JSON="$(mods_rules_to_json)" \
    mods_apply_install_rules "$MOCK_EXTRACT" "$MOCK_STAGING" 2>/dev/null)"

check "rules output is valid JSON" 'echo "$RULES_OUTPUT" | python3 -c "import json,sys; json.loads(sys.stdin.read())"'

# Check files were placed correctly
check "archive placed" '[[ -f "$MOCK_STAGING/archive/pc/mod/mymod.archive" ]]'
check "reds script placed" '[[ -f "$MOCK_STAGING/r6/scripts/init.reds" ]]'
check "README not staged (skipped)" '[[ ! -f "$MOCK_STAGING/README.md" ]]'

# Check files_json has SHA-256 hashes
check "output has sha256" 'echo "$RULES_OUTPUT" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
assert len(data) > 0, \"no files placed\"
assert all(\"sha256\" in f for f in data), \"missing sha256\"
assert all(len(f[\"sha256\"])==64 for f in data), \"sha256 wrong length\"
"'

# ═══════════════════════════════════════════════════════════════════════
# 5. SNAPSHOT CREATE/RESTORE
# ═══════════════════════════════════════════════════════════════════════
echo "== Snapshots =="

# Reset deploy state for snapshot
mods_manifest_set_deploy_state cyberpunk2077 false >/dev/null 2>&1

check "create snapshot" 'mods_snapshot_create cyberpunk2077 install >/dev/null 2>&1'
check "snapshot dir exists" '[[ -d "$MODS_SNAPSHOT_DIR/cyberpunk2077" ]]'

SNAP_COUNT="$(ls -1 "$MODS_SNAPSHOT_DIR/cyberpunk2077"/*.json 2>/dev/null | wc -l)"
check "one snapshot created" '[[ "$SNAP_COUNT" == "1" ]]'

# Verify snapshot content
SNAP_FILE="$(ls -1t "$MODS_SNAPSHOT_DIR/cyberpunk2077"/*.json | head -1)"
check "snapshot has timestamp" 'python3 -c "
import json
d=json.load(open(\"$SNAP_FILE\"))
assert \"timestamp\" in d
assert d[\"operation\"]==\"install\"
"'
check "snapshot has manifest copy" 'python3 -c "
import json
d=json.load(open(\"$SNAP_FILE\"))
m=d[\"manifest_before\"]
assert len(m[\"mods\"])==2, f\"expected 2 mods, got {len(m[\"mods\"])}\"
"'

# Modify manifest then restore
mods_manifest_add_mod cyberpunk2077 \
    "id=mod-disposable" "name=Will Be Rolled Back" "version=1.0" \
    "staging_dir=$MODS_STAGING_DIR/cyberpunk2077/mod-disposable" \
    "files_json=[]" >/dev/null 2>&1
check "3 mods before restore" '[[ "$(mods_manifest_count cyberpunk2077)" == "3" ]]'

check "restore snapshot" 'mods_snapshot_restore cyberpunk2077 latest >/dev/null 2>&1'
check "2 mods after restore" '[[ "$(mods_manifest_count cyberpunk2077)" == "2" ]]'

# Snapshot list (smoke test)
check "snapshot list runs" 'mods_snapshot_list cyberpunk2077 >/dev/null 2>&1'

# Snapshot pruning
for i in $(seq 1 12); do
    mods_snapshot_create cyberpunk2077 "prune-test-$i" >/dev/null 2>&1
done
SNAP_COUNT="$(ls -1 "$MODS_SNAPSHOT_DIR/cyberpunk2077"/*.json 2>/dev/null | wc -l)"
check "snapshots pruned to max 10" '(( SNAP_COUNT <= 10 ))'

# ═══════════════════════════════════════════════════════════════════════
# 6. NEXUS API URL CONSTRUCTION (no network)
# ═══════════════════════════════════════════════════════════════════════
echo "== Nexus API helpers (offline) =="

# nxm:// URL parsing
PARSED="$(nexus_parse_nxm "nxm://cyberpunk2077/mods/12345/files/67890?key=abc123&expires=9999999999")"
check "parse nxm slug" 'echo "$PARSED" | cut -d" " -f1 | grep -q "cyberpunk2077"'
check "parse nxm mod_id" 'echo "$PARSED" | cut -d" " -f2 | grep -q "12345"'
check "parse nxm file_id" 'echo "$PARSED" | cut -d" " -f3 | grep -q "67890"'
check "parse nxm key" 'echo "$PARSED" | cut -d" " -f4 | grep -q "abc123"'
check "parse nxm expires" 'echo "$PARSED" | cut -d" " -f5 | grep -q "9999999999"'

# Parse nxm without key/expires (bare URL)
PARSED_BARE="$(nexus_parse_nxm "nxm://skyrimspecialedition/mods/30379/files/111222")"
check "parse bare nxm slug" 'echo "$PARSED_BARE" | cut -d" " -f1 | grep -q "skyrimspecialedition"'
check "parse bare nxm mod_id" 'echo "$PARSED_BARE" | cut -d" " -f2 | grep -q "30379"'
check "parse bare nxm file_id" 'echo "$PARSED_BARE" | cut -d" " -f3 | grep -q "111222"'

# API key management (no network)
echo "test-api-key-000000000000000000000000000000000000000000000000000000000000000000000000" > "$POWOS_NEXUS_KEY_FILE"
check "nexus_key reads key" '[[ "$(nexus_key)" == *"test-api-key"* ]]'

rm -f "$POWOS_NEXUS_KEY_FILE"
check "nexus_key fails without file" '! nexus_key >/dev/null 2>&1'

nexus_key_save "saved-test-key-0000000000000000000000000000000000000000000000000000"
check "nexus_key_save creates file" '[[ -f "$POWOS_NEXUS_KEY_FILE" ]]'
check "nexus_key_save mode 600" '[[ "$(stat -c %a "$POWOS_NEXUS_KEY_FILE")" == "600" ]]'

# rules_to_json
mods_load_game_conf cyberpunk2077 >/dev/null 2>&1
RULES_JSON="$(mods_rules_to_json)"
check "rules_to_json is valid JSON" 'python3 -c "import json; json.loads(\"$(echo "$RULES_JSON" | sed "s/\"/\\\\\\\\\"/g")\")" 2>/dev/null || python3 -c "import json; json.loads(r'\''$RULES_JSON'\'')"'

# ═══════════════════════════════════════════════════════════════════════
# 7. STATUS COMMAND (smoke test)
# ═══════════════════════════════════════════════════════════════════════
echo "== Status =="

# Re-init manifest for status
mods_manifest_init cyberpunk2077 >/dev/null 2>&1
mods_manifest_add_mod cyberpunk2077 \
    "id=mod-12345" "name=Test Mod" "version=1.0" "source=nexus" \
    "staging_dir=$MODS_STAGING_DIR/cyberpunk2077/mod-12345" \
    "files_json=[]" >/dev/null 2>&1

check "status all runs" 'mods_status_cmd >/dev/null 2>&1'
check "status game runs" 'mods_status_cmd cyberpunk2077 >/dev/null 2>&1'

# ═══════════════════════════════════════════════════════════════════════
# 8. EXTRACT
# ═══════════════════════════════════════════════════════════════════════
echo "== Archive extraction =="

# Create a test zip
EXTRACT_SRC="$TMP/test-extract-src"
EXTRACT_DST="$TMP/test-extract-dst"
mkdir -p "$EXTRACT_SRC"
echo "hello" > "$EXTRACT_SRC/test.txt"
mkdir -p "$EXTRACT_SRC/sub"; echo "world" > "$EXTRACT_SRC/sub/nested.txt"

if command -v zip &>/dev/null; then
    (cd "$EXTRACT_SRC" && zip -qr "$TMP/test.zip" .)
    check "extract zip" 'mods_extract "$TMP/test.zip" "$EXTRACT_DST" >/dev/null 2>&1'
    check "zip content extracted" '[[ -f "$EXTRACT_DST/test.txt" ]]'
    check "zip nested content" '[[ -f "$EXTRACT_DST/sub/nested.txt" ]]'
else
    skip "extract zip (zip not installed)"
fi

# ═══════════════════════════════════════════════════════════════════════
# 9. ADOPT (dry-run scan of a mock dirty game dir)
# ═══════════════════════════════════════════════════════════════════════
echo "== Adopt =="

# Create a "dirty" Cyberpunk game dir with modded files
ADOPT_GAME="$TMP/home/.local/share/Steam/steamapps/common/Cyberpunk 2077"
mkdir -p "$ADOPT_GAME/archive/pc/mod"
mkdir -p "$ADOPT_GAME/r6/scripts"
mkdir -p "$ADOPT_GAME/bin/x64/plugins/cyber_engine_tweaks/mods/coolmod"
echo "modded archive" > "$ADOPT_GAME/archive/pc/mod/coolmod.archive"
echo "script" > "$ADOPT_GAME/r6/scripts/coolmod.reds"
echo "lua script" > "$ADOPT_GAME/bin/x64/plugins/cyber_engine_tweaks/mods/coolmod/init.lua"
# Vanilla files (should be skipped)
echo "vanilla" > "$ADOPT_GAME/steam_api64.dll"
echo "vanilla exe" > "$ADOPT_GAME/Cyberpunk2077.exe"

# Re-init manifest for adopt test (fresh)
rm -f "$MODS_MANIFEST_DIR/cyberpunk2077.json"
mods_manifest_init cyberpunk2077 >/dev/null 2>&1

if type -t mods_adopt_cmd &>/dev/null; then
    ADOPT_DRY="$(mods_adopt_cmd cyberpunk2077 --dry-run 2>/dev/null)"
    check "adopt dry-run succeeds" 'echo "$ADOPT_DRY" | grep -q "dry-run"'
    check "adopt detects mod files" 'echo "$ADOPT_DRY" | grep -q "mod files"'
    check "adopt dry-run no manifest changes" '[[ "$(mods_manifest_count cyberpunk2077)" == "0" ]]'

    # Real adopt
    mods_adopt_cmd cyberpunk2077 >/dev/null 2>&1
    check "adopt creates manifest entries" '[[ "$(mods_manifest_count cyberpunk2077)" -gt 0 ]]'
    check "adopt creates staging dirs" 'ls "$MODS_STAGING_DIR/cyberpunk2077"/adopted-* >/dev/null 2>&1'

    # Verify adopted mods have source=adopted
    check "adopted mods tagged" 'python3 -c "
import json
d=json.load(open(\"$MODS_MANIFEST_DIR/cyberpunk2077.json\"))
assert any(\"adopted\" in m.get(\"source\",\"\") for m in d[\"mods\"])
"'
else
    skip "adopt (adopt.sh not loaded)"
fi

# ═══════════════════════════════════════════════════════════════════════
# 10. MOUNT HELPER (syntax check)
# ═══════════════════════════════════════════════════════════════════════
echo "== Mount helper =="

MOUNT_HELPER="$REPO_ROOT/bin/powos-mods-mount"
if [[ -f "$MOUNT_HELPER" ]]; then
    check "mount helper syntax" 'bash -n "$MOUNT_HELPER"'
    check "mount helper is executable" '[[ -x "$MOUNT_HELPER" ]]'
    check "mount helper check subcommand" 'bash "$MOUNT_HELPER" check >/dev/null 2>&1'
    # Injection test (should fail)
    check "mount helper rejects injection" '! bash "$MOUNT_HELPER" umount "/tmp/powos-mods/test;rm -rf /merged" 2>/dev/null'
else
    skip "mount helper (not found)"
fi

# ═══════════════════════════════════════════════════════════════════════
# 11. GAME SHIM (syntax check)
# ═══════════════════════════════════════════════════════════════════════
echo "== Game shim =="

GAME_SHIM="$REPO_ROOT/bin/powos-game-shim"
if [[ -f "$GAME_SHIM" ]]; then
    check "game shim syntax" 'bash -n "$GAME_SHIM"'
    check "game shim is executable" '[[ -x "$GAME_SHIM" ]]'
else
    skip "game shim (not found)"
fi

# ═══════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
[[ $FAIL -eq 0 ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
