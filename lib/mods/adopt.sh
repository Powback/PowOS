#!/bin/bash
# mods/adopt.sh — Adopt existing mods from a dirty game directory.
#
# Scans a modded game dir against the Steam depot baseline, identifies
# untracked files, attributes them to known mod managers or groups them
# as "unknown-mod-N", then pulls each into a staging dir and creates
# manifest entries.
#
# This is THE migration verb — the user's Cyberpunk is already modded
# and broken. `adopt` ingests that state into the manifest so verify,
# doctor, rollback, and the overlay system can manage it.
#
# Requires: core.sh sourced first.

set -uo pipefail

# ── adopt command ──────────────────────────────────────────────────────

mods_adopt_cmd() {
    local game="${1:?Usage: powos mods adopt <game> [--dry-run]}"
    local dry_run=false
    [[ "${2:-}" == "--dry-run" ]] && dry_run=true

    mods_load_game_conf "$game" || return 1
    local game_dir
    game_dir="$(mods_game_dir "$GAME_APPID")" || {
        perr "Game not installed (appid $GAME_APPID)."
        return 1
    }

    echo -e "${BOLD}Adopt: scanning ${GAME_NAME}${NC}"
    echo "Game dir: $game_dir"
    echo ""

    # Initialize manifest if needed
    if ! $dry_run; then
        mods_manifest_init "$game" >/dev/null 2>&1
    fi

    # Run the adoption scanner
    python3 - "$game_dir" "$game" "$MODS_STAGING_DIR/$game" \
              "$MODS_MANIFEST_DIR/${game}.json" \
              "$($dry_run && echo True || echo False)" \
              "$GAME_APPID" \
              "${GAME_NEXUS_SLUG:-}" <<'PY'
import json, sys, os, hashlib, shutil, re
from datetime import datetime, timezone
from pathlib import Path

game_dir = sys.argv[1]
game = sys.argv[2]
staging_base = sys.argv[3]
manifest_path = sys.argv[4]
dry_run = sys.argv[5] == "True"
appid = sys.argv[6]
nexus_slug = sys.argv[7] if len(sys.argv) > 7 else ""

# ── Step 1: Build file inventory of the game directory ──────────
print("Scanning game directory...")
game_files = {}
for root, dirs, fnames in os.walk(game_dir):
    for f in fnames:
        full = os.path.join(root, f)
        rel = os.path.relpath(full, game_dir)
        try:
            st = os.stat(full)
            game_files[rel] = {
                "path": rel,
                "size": st.st_size,
                "mtime": st.st_mtime,
            }
        except OSError:
            pass

print(f"  Found {len(game_files)} files in game directory")

# ── Step 2: Build Steam depot baseline (known vanilla files) ────
# Look for Steam depot manifests to identify vanilla files
depot_files = set()
steamapps = os.path.dirname(os.path.dirname(game_dir))  # .../steamapps
depot_path = os.path.join(steamapps, "appmanifest_%s.acf" % appid)

if os.path.exists(depot_path):
    # Parse installdir size from appmanifest to detect if mods exist
    try:
        acf = open(depot_path, encoding="utf-8", errors="ignore").read()
        # Steam doesn't store per-file manifests locally in a parseable form
        # for most games. Use heuristics instead.
    except Exception:
        pass

# Heuristic baselines: files that are clearly vanilla (common patterns)
vanilla_patterns = [
    # Steam runtime files
    r"^steam_api\.dll$",
    r"^steam_api64\.dll$",
    r"^steamclient\.dll$",
    r"^steam_appid\.txt$",
    r"^installscript\.vdf$",
    # Common game executables (keep — not mods)
    r"^[^/]+\.(exe|com)$",
    # Unreal/Unity engine files deep in structure
    r"^Engine/",
    # GOG galaxy
    r"^goggame-",
]

# ── Step 3: Identify modded files using install rules ───────────
# Load game install rules to categorize files
mod_patterns = {}

# Cyberpunk-specific detection
if "1091500" in appid or "cyberpunk" in game.lower():
    mod_patterns = {
        "red4ext":       [r"red4ext/"],
        "redscript":     [r"r6/scripts/.*\.reds$"],
        "cet-mods":      [r"bin/x64/plugins/cyber_engine_tweaks/mods/"],
        "archive-mods":  [r"archive/pc/mod/"],
        "cet-framework": [r"bin/x64/plugins/cyber_engine_tweaks/.*\.(?:dll|lua)$",
                          r"bin/x64/plugins/cyber_engine_tweaks/(?!mods/)"],
        "redmod":        [r"mods/[^/]+/info\.json$"],
    }

# Skyrim-specific
elif "489830" in appid or "skyrim" in game.lower():
    mod_patterns = {
        "skse":     [r"skse64_"],
        "plugins":  [r"Data/.*\.esp$", r"Data/.*\.esm$", r"Data/.*\.esl$"],
        "meshes":   [r"Data/meshes/"],
        "textures": [r"Data/textures/"],
        "scripts":  [r"Data/scripts/"],
    }

# GTA V
elif "271590" in appid or "3240220" in appid or "gta" in game.lower():
    mod_patterns = {
        "asi-loader":  [r"dinput8\.dll$", r"ScriptHookV\.dll$"],
        "asi-mods":    [r".*\.asi$"],
        "rpf-mods":    [r"mods/.*\.rpf$"],
    }

# ── Step 4: Classify every file ─────────────────────────────────
vanilla = set()
modded = {}  # group_name -> [file_info, ...]
unclassified = []

for rel, info in game_files.items():
    # Skip obvious vanilla
    is_vanilla = False
    for pat in vanilla_patterns:
        if re.match(pat, rel, re.IGNORECASE):
            is_vanilla = True
            break
    if is_vanilla:
        vanilla.add(rel)
        continue

    # Try to classify by mod patterns
    classified = False
    for group, patterns in mod_patterns.items():
        for pat in patterns:
            if re.search(pat, rel, re.IGNORECASE):
                modded.setdefault(group, []).append(info)
                classified = True
                break
        if classified:
            break

    if not classified:
        unclassified.append(info)

# ── Step 5: Try NMA/Vortex attribution ──────────────────────────
# Check for Vortex deployment manifest
vortex_manifest = None
vortex_paths = [
    os.path.join(game_dir, "vortex.deployment.json"),
    os.path.join(game_dir, "__vortex_staging_folder"),
]
for vp in vortex_paths:
    if os.path.exists(vp):
        try:
            if vp.endswith(".json"):
                vortex_manifest = json.load(open(vp))
        except Exception:
            pass

# Check for NMA managed mods
nma_db = None
nma_paths = [
    os.path.expanduser("~/.local/share/NexusModsApp/NexusMods.DataModel.RocksDB"),
    os.path.expanduser("~/.local/share/NexusModsApp"),
]
has_nma = any(os.path.exists(p) for p in nma_paths)

# ── Step 6: Group unclassified into pseudo-mods ─────────────────
# Group nearby unclassified files by top-level directory
unknown_groups = {}
for info in unclassified:
    parts = info["path"].split("/")
    # Group by first directory component, or root
    key = parts[0] if len(parts) > 1 else "__root__"
    unknown_groups.setdefault(key, []).append(info)

# Merge small groups into "unknown-misc"
MIN_GROUP_SIZE = 1
final_unknown = {}
misc_files = []
for key, files in unknown_groups.items():
    if len(files) >= MIN_GROUP_SIZE and key != "__root__":
        final_unknown[f"unknown-{key}"] = files
    else:
        misc_files.extend(files)
if misc_files:
    final_unknown["unknown-misc"] = misc_files

# ── Step 7: Report ──────────────────────────────────────────────
print(f"\n  Vanilla files (skipped):  {len(vanilla)}")
print(f"  Classified mod files:     {sum(len(v) for v in modded.values())}")
print(f"  Unclassified mod files:   {len(unclassified)}")

if vortex_manifest:
    print(f"  Vortex deployment found:  yes")
if has_nma:
    print(f"  NMA managed mods found:   yes")

print(f"\n  Mod groups detected:")
all_groups = {}
for group, files in sorted(modded.items()):
    total_size = sum(f["size"] for f in files)
    size_mb = total_size / 1024 / 1024
    print(f"    {group:<25} {len(files):>4} files  ({size_mb:.1f} MB)")
    all_groups[group] = files

for group, files in sorted(final_unknown.items()):
    total_size = sum(f["size"] for f in files)
    size_mb = total_size / 1024 / 1024
    print(f"    {group:<25} {len(files):>4} files  ({size_mb:.1f} MB)")
    all_groups[group] = files

total_mod_files = sum(len(v) for v in all_groups.values())
total_mod_size = sum(f["size"] for v in all_groups.values() for f in v) / 1024 / 1024
print(f"\n  Total: {total_mod_files} mod files ({total_mod_size:.1f} MB) in {len(all_groups)} groups")

if dry_run:
    print(f"\n  --dry-run: no changes made. Remove --dry-run to adopt into manifest.")
    sys.exit(0)

if total_mod_files == 0:
    print(f"\n  No mod files detected — game directory appears clean.")
    sys.exit(0)

# ── Step 8: Create staging dirs and manifest entries ────────────
print(f"\nAdopting {len(all_groups)} mod groups into manifest...")

os.makedirs(staging_base, exist_ok=True)
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# Load or create manifest
if os.path.exists(manifest_path):
    manifest = json.load(open(manifest_path))
else:
    manifest = {"schema_version": 1, "game": game, "appid": int(appid),
                "game_dir": game_dir, "deploy_method": "overlayfs",
                "overlay_mounted": False, "last_deployed": None,
                "last_verified": None, "last_verify_result": None, "mods": []}

existing_ids = {m["id"] for m in manifest.get("mods", [])}
adopted = 0
priority = 100  # adopted mods get low priority (high number = low precedence)

for group, files in sorted(all_groups.items()):
    mod_id = f"adopted-{group}"
    if mod_id in existing_ids:
        print(f"  skip: {mod_id} (already in manifest)")
        continue

    # Create staging dir and copy files
    staging_dir = os.path.join(staging_base, mod_id)
    os.makedirs(staging_dir, exist_ok=True)

    file_entries = []
    copied = 0
    for finfo in files:
        src = os.path.join(game_dir, finfo["path"])
        dst = os.path.join(staging_dir, finfo["path"])
        try:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
            h = hashlib.sha256(open(dst, "rb").read()).hexdigest()
            file_entries.append({
                "path": finfo["path"],
                "sha256": h,
                "size": finfo["size"],
            })
            copied += 1
        except Exception as e:
            print(f"  warn: could not copy {finfo['path']}: {e}")

    # Determine source attribution
    source = "adopted"
    if vortex_manifest:
        source = "adopted-vortex"
    elif has_nma:
        source = "adopted-nma"

    # Determine if this is a framework group
    is_framework = group in ("red4ext", "cet-framework", "redscript", "skse",
                             "asi-loader")

    entry = {
        "id": mod_id,
        "nexus_mod_id": None,
        "nexus_file_id": None,
        "name": group.replace("-", " ").title(),
        "version": "adopted",
        "author": "",
        "source": source,
        "installed_at": now,
        "updated_at": None,
        "enabled": True,
        "priority": 0 if is_framework else priority,
        "is_framework": is_framework,
        "staging_dir": staging_dir,
        "files": file_entries,
        "depends_on": [],
        "tags": ["adopted"],
        "nexus_url": "",
    }

    manifest["mods"].append(entry)
    priority += 1
    adopted += 1
    print(f"  adopted: {mod_id} ({copied} files)")

# Sort by priority
manifest["mods"].sort(key=lambda m: m.get("priority", 10))

# Write manifest
json.dump(manifest, open(manifest_path, "w"), indent=2)
print(f"\nAdopted {adopted} mod group(s) into manifest.")
print(f"Run: powos mods verify {game}")
print(f"     powos mods deploy {game}")
PY

    if ! $dry_run; then
        pok "Adoption complete. Mods are now tracked in the manifest."
        plog "Next steps:"
        echo "  1. ${BOLD}powos mods list $game${NC}      — review adopted mods"
        echo "  2. ${BOLD}powos mods verify $game${NC}    — check integrity"
        echo "  3. ${BOLD}powos mods deploy $game${NC}    — mount overlay"
        echo "  4. ${BOLD}powos mods doctor $game${NC}    — diagnose issues"
    fi
}
