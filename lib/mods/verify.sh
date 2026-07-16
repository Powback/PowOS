#!/bin/bash
# mods/verify.sh — Verify + doctor engine for the native PowOS mod manager.
#
# verify: check manifest vs disk consistency, run game-specific checks.
# doctor: deep diagnosis — conflicts, framework compat, bisect suggestions.
#
# Requires: core.sh sourced first.

set -uo pipefail

# ── verify ──────────────────────────────────────────────────────────────

mods_verify_cmd() {
    local game="${1:?Usage: powos mods verify <game>}"

    mods_load_game_conf "$game" || return 1
    local mf; mf="$(mods_manifest_path "$game")"
    [[ -f "$mf" ]] || { perr "No manifest for '$game'."; return 1; }

    echo -e "${BOLD}Verifying: ${GAME_NAME}${NC}"
    local issues=0 warnings=0

    # 1. Check staging dirs exist and file hashes match
    plog "Checking staging integrity..."
    local staging_result
    staging_result="$(python3 - "$mf" <<'PY'
import json, sys, os, hashlib

data = json.load(open(sys.argv[1]))
issues = 0
warnings = 0

for mod in data.get("mods", []):
    mod_id = mod.get("id", "?")
    staging = os.path.expanduser(mod.get("staging_dir", ""))

    if not staging or not os.path.isdir(staging):
        print(f"  FAIL: {mod_id} — staging dir missing: {staging}")
        issues += 1
        continue

    for f in mod.get("files", []):
        path = os.path.join(staging, f["path"])
        if not os.path.exists(path):
            print(f"  FAIL: {mod_id} — file missing: {f['path']}")
            issues += 1
            continue
        actual_hash = hashlib.sha256(open(path, "rb").read()).hexdigest()
        if actual_hash != f.get("sha256", ""):
            print(f"  WARN: {mod_id} — hash mismatch: {f['path']}")
            warnings += 1

print(f"RESULT:{issues}:{warnings}")
PY
    )"

    echo "$staging_result" | grep -v '^RESULT:'
    local r_issues r_warnings
    IFS=: read -r _ r_issues r_warnings <<< "$(echo "$staging_result" | grep '^RESULT:')"
    issues=$((issues + r_issues))
    warnings=$((warnings + r_warnings))

    # 2. Run game-specific verify checks
    if [[ ${#GAME_VERIFY_CHECKS[@]} -gt 0 ]]; then
        plog "Running game-specific checks..."
        local game_dir merged
        game_dir="$(mods_game_dir "$GAME_APPID" 2>/dev/null)" || game_dir=""
        merged="$(_mods_merged_dir "$game" 2>/dev/null)" || merged=""

        # Check against merged view if mounted, else staging
        local check_dir="$game_dir"
        if [[ -n "$merged" ]] && mountpoint -q "$merged" 2>/dev/null; then
            check_dir="$merged"
        fi

        for check in "${GAME_VERIFY_CHECKS[@]}"; do
            local check_type check_path
            IFS=: read -r check_type check_path <<< "$check"

            case "$check_type" in
                file_exists)
                    if [[ -n "$check_dir" && ! -f "$check_dir/$check_path" ]]; then
                        echo "  WARN: expected file not found: $check_path"
                        warnings=$((warnings + 1))
                    fi
                    ;;
                dir_not_empty)
                    if [[ -n "$check_dir" && -d "$check_dir/$check_path" ]]; then
                        local count
                        count="$(find "$check_dir/$check_path" -maxdepth 1 -type f 2>/dev/null | wc -l)"
                        if (( count == 0 )); then
                            echo "  WARN: directory empty: $check_path"
                            warnings=$((warnings + 1))
                        fi
                    fi
                    ;;
                pe_arch_64)
                    if [[ -n "$check_dir" && -f "$check_dir/$check_path" ]]; then
                        # Reuse asi_pe_arch if available
                        if type -t asi_pe_arch &>/dev/null; then
                            local arch; arch="$(asi_pe_arch "$check_dir/$check_path")"
                            if [[ "$arch" != "x64" ]]; then
                                echo "  FAIL: $check_path arch=$arch (expected x64)"
                                issues=$((issues + 1))
                            fi
                        fi
                    fi
                    ;;
            esac
        done
    fi

    # 3. Check frameworks
    plog "Checking frameworks..."
    if ! mods_check_frameworks "$game" 2>/dev/null; then
        echo "  WARN: Missing required frameworks (see above)"
        warnings=$((warnings + 1))
    fi

    # 4. Check overlay mount state
    local merged_check; merged_check="$(_mods_merged_dir "$game")"
    local manifest_says_mounted
    manifest_says_mounted="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('overlay_mounted',False))" "$mf")"
    local actually_mounted=false
    mountpoint -q "$merged_check" 2>/dev/null && actually_mounted=true

    if [[ "$manifest_says_mounted" == "True" && "$actually_mounted" == "false" ]]; then
        echo "  WARN: manifest says mounted but overlay is not (stale state after reboot?)"
        mods_manifest_set_deploy_state "$game" "false"
        warnings=$((warnings + 1))
    fi

    # Report
    echo ""
    if (( issues > 0 )); then
        perr "FAIL: $issues issue(s), $warnings warning(s)"
        mods_manifest_set_verify "$game" "fail"
        return 1
    elif (( warnings > 0 )); then
        pwarn "WARN: $warnings warning(s), no critical issues"
        mods_manifest_set_verify "$game" "warn"
        return 0
    else
        pok "PASS: all checks passed"
        mods_manifest_set_verify "$game" "pass"
        return 0
    fi
}

# ── doctor ──────────────────────────────────────────────────────────────

mods_doctor_cmd() {
    local game="${1:?Usage: powos mods doctor <game> [--ai]}"
    local use_ai=false
    [[ "${2:-}" == "--ai" ]] && use_ai=true

    echo -e "${BOLD}Doctor: ${game}${NC}"
    echo "═══════════════════════════════════════"

    local findings=""

    # 1. Run verify first
    local verify_output
    verify_output="$(mods_verify_cmd "$game" 2>&1)" || true
    findings+="## Verify Results\n$verify_output\n\n"
    echo "$verify_output"

    # 2. Manifest vs disk drift
    plog "Checking for orphaned files in staging..."
    local drift_output
    drift_output="$(python3 - "$(mods_manifest_path "$game")" "$MODS_STAGING_DIR/$game" <<'PY'
import json, sys, os

mf = sys.argv[1]
staging_base = sys.argv[2]

if not os.path.exists(mf):
    print("No manifest found.")
    sys.exit(0)

data = json.load(open(mf))
manifest_ids = {m.get("id") for m in data.get("mods", [])}

if not os.path.isdir(staging_base):
    sys.exit(0)

orphans = []
for d in os.listdir(staging_base):
    if d not in manifest_ids:
        orphans.append(d)

if orphans:
    print(f"Orphaned staging dirs (in staging but not manifest):")
    for o in orphans:
        print(f"  - {o}")
else:
    print("No orphaned staging dirs.")
PY
    )"
    findings+="## Staging Drift\n$drift_output\n\n"
    echo "$drift_output"

    # 3. Known conflict scan
    mods_load_game_conf "$game" || return 1
    if [[ ${#GAME_KNOWN_CONFLICTS[@]} -gt 0 ]]; then
        plog "Checking known conflicts..."
        # TODO: implement version-range conflict checking
        echo "  (conflict checking not yet implemented for version ranges)"
    fi

    # 4. Recent-install bisect suggestion
    plog "Checking install history..."
    local bisect_output
    bisect_output="$(python3 - "$(mods_manifest_path "$game")" <<'PY'
import json, sys
from datetime import datetime

data = json.load(open(sys.argv[1]))
mods = data.get("mods", [])

# Sort by install time, most recent first
dated = [(m, m.get("installed_at", "")) for m in mods if m.get("installed_at")]
dated.sort(key=lambda x: x[1], reverse=True)

if len(dated) < 2:
    print("Too few mods for bisect suggestion.")
    sys.exit(0)

print("Bisect suggestion — disable most-recently-installed mods first:")
for m, dt in dated[:5]:
    fw = " [framework]" if m.get("is_framework") else ""
    state = "ON" if m.get("enabled", True) else "OFF"
    print(f"  [{state}] {m.get('name','?')}{fw} — installed {dt}")
if len(dated) > 5:
    print(f"  ... and {len(dated)-5} more")
print(f"\nTry: powos mods disable {data.get('game','?')} <mod-id>")
PY
    )"
    findings+="## Bisect Suggestion\n$bisect_output\n\n"
    echo "$bisect_output"

    # 5. AI diagnosis
    if $use_ai; then
        echo ""
        plog "Sending findings to AI health agent..."
        local context="Game: $game (${GAME_NAME}, appid ${GAME_APPID})\n\n$findings"
        if type -t ai_call &>/dev/null; then
            ai_call --agent health "$context"
        else
            # Try direct powos ai call
            echo -e "$context" | powos ai --agent health 2>/dev/null || {
                pwarn "AI agent not available. Review findings above manually."
            }
        fi
    fi
}
