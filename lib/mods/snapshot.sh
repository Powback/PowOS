#!/bin/bash
# mods/snapshot.sh — Snapshot create/restore/list for the native PowOS mod manager.
#
# Every state-changing operation (install, remove, enable, disable) creates
# a snapshot before applying changes. Snapshots store:
#   - Full manifest copy
#   - Files in the overlay upper layer (if mounted)
#
# Requires: core.sh sourced first.

set -uo pipefail

MODS_SNAPSHOT_MAX="${MODS_SNAPSHOT_MAX:-10}"

# ── create ──────────────────────────────────────────────────────────────

mods_snapshot_create() {
    local game="$1" operation="${2:-unknown}"
    local mf; mf="$(mods_manifest_path "$game")"
    [[ -f "$mf" ]] || return 0  # nothing to snapshot

    local snap_dir="$MODS_SNAPSHOT_DIR/$game"
    mkdir -p "$snap_dir"

    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local snap_file="$snap_dir/${ts}.json"

    # Collect upper layer files if overlay is mounted
    local upper; upper="$(_mods_upper_dir "$game" 2>/dev/null)" || upper=""
    local upper_files="[]"
    if [[ -d "$upper" ]] && [[ -n "$(ls -A "$upper" 2>/dev/null)" ]]; then
        upper_files="$(python3 -c "
import os, json, sys, hashlib
upper = sys.argv[1]
files = []
for root, dirs, fnames in os.walk(upper):
    for f in fnames:
        full = os.path.join(root, f)
        rel = os.path.relpath(full, upper)
        try:
            h = hashlib.sha256(open(full, 'rb').read()).hexdigest()
            sz = os.path.getsize(full)
            files.append({'path': rel, 'sha256': h, 'size': sz})
        except Exception:
            pass
print(json.dumps(files))
" "$upper")"
    fi

    # Build snapshot
    python3 - "$snap_file" "$mf" "$ts" "$operation" "$upper_files" <<'PY'
import json, sys

snap_file, mf, ts, operation, upper_json = sys.argv[1:6]
manifest = json.load(open(mf))
upper_files = json.loads(upper_json)

snapshot = {
    "timestamp": ts,
    "operation": operation,
    "manifest_before": manifest,
    "upper_files": upper_files
}

json.dump(snapshot, open(snap_file, "w"), indent=2)
PY

    # Prune old snapshots
    local count
    count="$(ls -1 "$snap_dir"/*.json 2>/dev/null | wc -l)"
    if (( count > MODS_SNAPSHOT_MAX )); then
        local to_remove=$((count - MODS_SNAPSHOT_MAX))
        ls -1t "$snap_dir"/*.json | tail -"$to_remove" | xargs rm -f
    fi
}

# ── list ────────────────────────────────────────────────────────────────

mods_snapshot_list() {
    local game="${1:?Usage: powos mods rollback <game> --list}"
    local snap_dir="$MODS_SNAPSHOT_DIR/$game"

    if [[ ! -d "$snap_dir" ]] || [[ -z "$(ls -A "$snap_dir" 2>/dev/null)" ]]; then
        plog "No snapshots for $game."
        return 0
    fi

    echo -e "${BOLD}Snapshots for $game${NC}"
    echo "─────────────────────────────────────────────"

    for snap in $(ls -1t "$snap_dir"/*.json 2>/dev/null); do
        python3 - "$snap" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
ts = data.get("timestamp", "?")
op = data.get("operation", "?")
n_mods = len(data.get("manifest_before", {}).get("mods", []))
n_upper = len(data.get("upper_files", []))
print(f"  {ts}  {op:<12}  {n_mods} mods  {n_upper} upper files")
PY
    done
}

# ── restore ─────────────────────────────────────────────────────────────

mods_snapshot_restore() {
    local game="$1" target="${2:-latest}"
    local snap_dir="$MODS_SNAPSHOT_DIR/$game"

    if [[ ! -d "$snap_dir" ]]; then
        perr "No snapshots for $game."
        return 1
    fi

    local snap_file=""
    if [[ "$target" == "latest" ]]; then
        snap_file="$(ls -1t "$snap_dir"/*.json 2>/dev/null | head -1)"
    else
        # Find by timestamp prefix
        snap_file="$(ls -1 "$snap_dir"/${target}*.json 2>/dev/null | head -1)"
    fi

    if [[ -z "$snap_file" || ! -f "$snap_file" ]]; then
        perr "Snapshot not found: $target"
        mods_snapshot_list "$game"
        return 1
    fi

    plog "Restoring from snapshot: $(basename "$snap_file" .json)"

    # Unmount overlay first
    mods_deploy_unmount "$game" 2>/dev/null || true

    # Restore manifest
    local mf; mf="$(mods_manifest_path "$game")"
    python3 - "$snap_file" "$mf" <<'PY'
import json, sys
snap = json.load(open(sys.argv[1]))
manifest = snap.get("manifest_before", {})
json.dump(manifest, open(sys.argv[2], "w"), indent=2)
print(f"Manifest restored: {len(manifest.get('mods', []))} mods")
PY

    # Verify staging dirs exist
    local missing=0
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        if [[ ! -d "$dir" ]]; then
            pwarn "Staging dir missing (mod may need re-download): $dir"
            missing=$((missing + 1))
        fi
    done < <(python3 -c "
import json, sys, os
data = json.load(open(sys.argv[1]))
for m in data.get('mods', []):
    d = os.path.expanduser(m.get('staging_dir', ''))
    if d: print(d)
" "$mf")

    if (( missing > 0 )); then
        pwarn "$missing mod(s) need re-download. Run: powos mods verify $game"
    fi

    # Clear upper layer
    local upper; upper="$(_mods_upper_dir "$game")"
    if [[ -d "$upper" ]]; then
        rm -rf "$upper"
        mkdir -p "$upper"
    fi

    pok "Rollback complete."
    plog "Run ${BOLD}powos mods deploy $game${NC} to remount."
}

# ── rollback command ────────────────────────────────────────────────────

mods_rollback_cmd() {
    local game="${1:?Usage: powos mods rollback <game> [--list|--to <timestamp>]}"
    shift

    case "${1:-}" in
        --list)
            mods_snapshot_list "$game"
            ;;
        --to)
            local target="${2:?Usage: powos mods rollback <game> --to <timestamp>}"
            mods_snapshot_restore "$game" "$target"
            ;;
        "")
            mods_snapshot_restore "$game" "latest"
            ;;
        *)
            perr "Unknown option: $1"
            perr "Usage: powos mods rollback <game> [--list|--to <timestamp>]"
            return 1
            ;;
    esac
}
