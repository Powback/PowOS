#!/usr/bin/env bash
# lib/mods/portable.sh — export / import a game's mod list as a portable file.
#
# Fills the Phase-3 "share mod lists" gap from docs/MODDING-V2.md: `export`
# already had no implementation and `import` did not exist at all.
#
#   powos mods export <game> [--out FILE]     manifest → portable JSON
#   powos mods import <file> [--game G] [--dry-run] [--no-deploy]
#
# The portable file is deliberately MACHINE-INDEPENDENT: it keeps the Nexus
# mod/file ids, name, version, priority, enabled flag and framework flag, and
# DROPS everything local (game_dir, staging paths, per-file hashes, install
# timestamps). That means a list exported on one box re-installs cleanly on
# another straight from Nexus — which is the whole point of sharing.
#
# Import reuses the existing install path (mods_install_mod) and framework
# resolver, so it inherits all the per-game install rules; it never reinvents
# them. --dry-run prints the plan and touches nothing (fully offline).

# Logging helpers come from install.sh when sourced via the dispatcher; define
# no-op fallbacks so this file is also usable/testable stand-alone.
type -t plog  >/dev/null 2>&1 || plog()  { echo "$*" >&2; }
type -t perr  >/dev/null 2>&1 || perr()  { echo "Error: $*" >&2; }
type -t pok   >/dev/null 2>&1 || pok()   { echo "$*" >&2; }
type -t pwarn >/dev/null 2>&1 || pwarn() { echo "Warning: $*" >&2; }

# schema version of the export format (bump if the shape changes)
MODS_EXPORT_SCHEMA="${MODS_EXPORT_SCHEMA:-1}"

# ── export ───────────────────────────────────────────────────────────────
# powos mods export <game> [--out FILE]
mods_export_cmd() {
    local game="" out=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out|-o)   out="${2:?--out needs a path}"; shift 2 ;;
            -h|--help)  echo "Usage: powos mods export <game> [--out FILE]"; return 0 ;;
            -*)         perr "Unknown flag: $1"; return 1 ;;
            *)          if [[ -z "$game" ]]; then game="$1"; shift
                        else perr "Unexpected argument: $1"; return 1; fi ;;
        esac
    done
    [[ -n "$game" ]] || { perr "Usage: powos mods export <game> [--out FILE]"; return 1; }

    local mf; mf="$(mods_manifest_path "$game")"
    [[ -f "$mf" ]] || { perr "No manifest for '$game'. Nothing to export."; return 1; }

    # best-effort portable slug (lets another machine resolve the game by name)
    local slug=""
    if mods_load_game_conf "$game" >/dev/null 2>&1; then slug="${GAME_NEXUS_SLUG:-}"; fi

    local json
    json="$(python3 - "$mf" "$game" "$slug" "$MODS_EXPORT_SCHEMA" <<'PY'
import json, sys, datetime
mf, game, slug, schema = sys.argv[1:5]
d = json.load(open(mf))
mods = []
for m in d.get("mods", []):
    mods.append({
        "id":            m.get("id", ""),
        "nexus_mod_id":  m.get("nexus_mod_id"),
        "nexus_file_id": m.get("nexus_file_id"),
        "name":          m.get("name", ""),
        "version":       m.get("version", ""),
        "author":        m.get("author", ""),
        "source":        m.get("source", "nexus"),
        "priority":      m.get("priority", 10),
        "enabled":       m.get("enabled", True),
        "is_framework":  m.get("is_framework", False),
        "nexus_url":     m.get("nexus_url", ""),
        "depends_on":    m.get("depends_on", []),
        "tags":          m.get("tags", []),
    })
out = {
    "powos_mods_export": int(schema),
    "game":        d.get("game", game),
    "appid":       d.get("appid"),
    "nexus_slug":  slug or None,
    "exported_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mod_count":   len(mods),
    "mods":        mods,
}
print(json.dumps(out, indent=2))
PY
)" || { perr "Failed to serialize manifest for '$game'"; return 1; }

    local n; n="$(mods_manifest_count "$game" 2>/dev/null || echo "?")"
    if [[ -n "$out" ]]; then
        printf '%s\n' "$json" > "$out" || { perr "Cannot write to $out"; return 1; }
        pok "Exported $n mods → $out"
    else
        printf '%s\n' "$json"
    fi
}

# ── import ───────────────────────────────────────────────────────────────
# powos mods import <file> [--game GAME] [--dry-run] [--no-deploy]
mods_import_cmd() {
    local file="" game_override="" dry=false deploy=true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --game|-g)    game_override="${2:?--game needs a name}"; shift 2 ;;
            --dry-run|-n) dry=true; shift ;;
            --no-deploy)  deploy=false; shift ;;
            -h|--help)    echo "Usage: powos mods import <file> [--game GAME] [--dry-run] [--no-deploy]"; return 0 ;;
            -*)           perr "Unknown flag: $1"; return 1 ;;
            *)            if [[ -z "$file" ]]; then file="$1"; shift
                          else perr "Unexpected argument: $1"; return 1; fi ;;
        esac
    done
    [[ -n "$file" ]] || { perr "Usage: powos mods import <file> [--game GAME] [--dry-run] [--no-deploy]"; return 1; }
    [[ -f "$file" ]] || { perr "File not found: $file"; return 1; }

    # validate the file and pull the header (game, slug, count) in one shot
    local hdr
    hdr="$(python3 - "$file" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("ERR\tinvalid JSON: %s" % e); sys.exit(2)
if not isinstance(d, dict) or "powos_mods_export" not in d:
    print("ERR\tnot a PowOS mods export file (missing 'powos_mods_export')"); sys.exit(2)
print("OK\t%s\t%s\t%d" % (d.get("game", "") or "", d.get("nexus_slug", "") or "", len(d.get("mods", []))))
PY
)" || { perr "${hdr#*$'\t'}"; return 1; }

    local _ok game slug count
    IFS=$'\t' read -r _ok game slug count <<< "$hdr"
    [[ -n "$game_override" ]] && game="$game_override"
    [[ -n "$game" ]] || { perr "Export file names no game — pass --game <name>."; return 1; }

    # ── plan (always shown; the only output in --dry-run) ──
    plog "Import plan for '${game}' — ${count} mod(s) from $(basename "$file"):"
    python3 - "$file" <<'PY' >&2
import json, sys
d = json.load(open(sys.argv[1]))
for m in d.get("mods", []):
    nid  = m.get("nexus_mod_id")
    tag  = "framework" if m.get("is_framework") else ("nexus" if nid is not None else m.get("source", "?"))
    state = "on " if m.get("enabled", True) else "off"
    ref  = ("#%s" % nid) if nid is not None else "(no nexus id — will skip)"
    print("   [%s] %-9s %-6s %s  %s" % (state, tag, ref, m.get("name", "")[:40], m.get("version", "")))
PY

    if $dry; then
        plog "(dry-run — nothing installed)"
        return 0
    fi

    # ── apply ──
    mods_load_game_conf "$game" >/dev/null 2>&1 || {
        perr "Unknown game '$game' — no config in games.d/. Cannot import."
        return 1
    }

    if ! mods_check_frameworks "$game" 2>/dev/null; then
        plog "Installing required frameworks first…"
        mods_install_frameworks "$game" || { perr "Framework install failed."; return 1; }
    fi

    local installed=0 skipped=0 failed=0
    # feed nexus id + enabled flag per non-framework mod (frameworks are handled
    # by the resolver above; re-installing them here would be redundant).
    while IFS=$'\t' read -r nmid enabled name; do
        [[ -z "$nmid" || "$nmid" == "null" ]] && { pwarn "Skipping '$name' (no Nexus id — local/adopted mod can't be re-fetched)"; skipped=$((skipped+1)); continue; }
        if mods_install_mod "$game" "$nmid"; then
            installed=$((installed+1))
            # replay the shared list's enabled/disabled intent
            if [[ "$enabled" == "false" ]]; then
                mods_manifest_set_enabled "$game" "mod-${nmid}" false >/dev/null 2>&1 || true
            fi
        else
            pwarn "Failed to install Nexus mod #$nmid ($name)"; failed=$((failed+1))
        fi
    done < <(python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for m in d.get("mods", []):
    if m.get("is_framework"):
        continue
    nid = m.get("nexus_mod_id")
    print("\t".join([
        str(nid) if nid is not None else "",
        "true" if m.get("enabled", True) else "false",
        m.get("name", ""),
    ]))
PY
)

    pok "Imported: ${installed} installed, ${skipped} skipped, ${failed} failed."
    [[ $failed -gt 0 ]] && return 1

    if $deploy; then
        plog "Deploying…"
        mods_deploy_cmd "$game" || { perr "Deploy failed — mods are installed; run 'powos mods deploy $game'."; return 1; }
    else
        plog "Skipped deploy (--no-deploy). Run 'powos mods deploy $game' when ready."
    fi
    return 0
}
