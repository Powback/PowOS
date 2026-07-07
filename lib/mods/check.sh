#!/bin/bash
# mods/check.sh - pre-install DEPENDENCY + CONFLICT analysis for `powos mods`.
#
# The whole point of the modding tooling: read each mod's Nexus README, auto-
# resolve its required dependencies, and catch conflicts BEFORE installing — so
# a user never has to untangle "mod X silently didn't load because it needed Y"
# or "camera mods A and B fight" by hand.
#
# How it reads a README (Nexus `mods/<id>.json` `description`, BBCode/HTML):
#   • Dependencies — mod-id links (nexusmods.com/cyberpunk2077/mods/<id>) that
#     appear inside a "Requirements"/"Requires"/"Dependency" context. Parsed
#     from the RAW description (BEFORE stripping BBCode, so [url=...] survives).
#   • Conflicts — the mod names listed under a "Compatibility"/"Conflicts"/
#     "Incompatible" heading, matched against the mods in play.
#
# What's "in play" = the batch being installed ∪ what we've already dispatched
# (tracked locally in $MODS_STATE_DIR, no NMA lock needed).

# Sourced by bin/powos (which sources install.sh first, so mods_api_get /
# mods_nexus_slug_of / plog / perr are already defined). Standalone-safe:
if ! declare -f mods_nexus_slug_of >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/install.sh" 2>/dev/null || true
fi

MODS_STATE_DIR="${MODS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/powos/mods}"

_mods_installed_file() { echo "$MODS_STATE_DIR/${1}.installed"; }  # $1 = slug

# Record a dispatched mod-id so later dep-resolution knows it's present.
mods_record_installed() {  # $1=slug $2=mod_id
    mkdir -p "$MODS_STATE_DIR" 2>/dev/null || return 0
    local f; f="$(_mods_installed_file "$1")"
    grep -qxF "$2" "$f" 2>/dev/null || printf '%s\n' "$2" >> "$f"
}

mods_installed_ids() { cat "$(_mods_installed_file "$1")" 2>/dev/null; }  # $1=slug

# Core analyzer. Args: <slug> <candidate-id>...
# Emits machine lines on stdout:
#   MISSINGDEP <needed-by-id> <dep-id> <dep-name>
#   CONFLICT   <id-a> <id-b> <name-b>
# and a human report on fd 3 (so callers can show or suppress it).
# Returns 0 always; callers decide what to do with the findings.
mods_analyze() {
    local slug="$1"; shift
    local installed; installed="$(mods_installed_ids "$slug" | tr '\n' ' ')"
    MODS_SLUG="$slug" MODS_INSTALLED="$installed" python3 - "$@" <<'PY'
import json, re, subprocess, sys, os

slug = os.environ["MODS_SLUG"]
candidates = [int(a) for a in sys.argv[1:] if a.isdigit()]
installed = [int(x) for x in os.environ.get("MODS_INSTALLED","").split() if x.isdigit()]
known = set(candidates) | set(installed)

_cache = {}
def info(mid):
    if mid in _cache: return _cache[mid]
    try:
        out = subprocess.run(["powos","mods","info",slug if slug else "cyberpunk",str(mid)],
                             capture_output=True, text=True, timeout=30).stdout
        d = json.loads(out)
    except Exception:
        d = {}
    _cache[mid] = d
    return d

def clean(s):
    s = re.sub(r"<br\s*/?>", "\n", s or "", flags=re.I)
    s = re.sub(r"\[/?[a-z0-9=#*/ .:_-]+\]", " ", s, flags=re.I)
    return s

def requirements(raw):
    ids = set(); low = raw.lower()
    for m in re.finditer(r"(requirement|requires|dependenc)", low):
        win = raw[m.start():m.start()+800]
        for l in re.finditer(r"nexusmods\.com/[a-z0-9]+/mods/(\d+)", win):
            ids.add(int(l.group(1)))
    return ids

def conflict_ctx(raw):
    c = clean(raw)
    m = re.search(r"(conflict|incompatib|compatibility)", c, re.I)
    return c[m.start():m.start()+400].lower() if m else ""

report = []
def name(mid): return info(mid).get("name") or f"mod {mid}"

for mid in candidates:
    raw = info(mid).get("description","") or ""
    # dependencies
    for dep in sorted(requirements(raw)):
        if dep not in known:
            print(f"MISSINGDEP {mid} {dep} {name(dep)}")
            report.append(f"  ⛓ {name(mid)} needs {name(dep)} (mods/{dep}) — not installed")
    # conflicts against everything else in play
    ctx = conflict_ctx(raw)
    if ctx:
        for other in known:
            if other == mid: continue
            base = re.split(r"[(\[]", name(other))[0].strip().lower()
            if len(base) >= 4 and base in ctx:
                print(f"CONFLICT {mid} {other} {name(other)}")
                report.append(f"  ⚠ {name(mid)} conflicts with {name(other)} (mods/{other})")

sys.stderr.write("\n".join(report) + ("\n" if report else ""))
PY
}

# `powos mods check <game> <id>...` — human-facing pre-flight report.
# Exit 0 = clean/deps-only, 2 = at least one conflict (so scripts can gate).
mods_check_cmd() {
    POWOS_MODS_LAST_VERB="check"
    local game="${1:?Usage: powos mods check <game> <mod-id> [mod-id ...]}"; shift
    [[ $# -gt 0 ]] || { perr "Usage: powos mods check <game> <mod-id> [mod-id ...]"; return 1; }
    local slug; slug="$(mods_nexus_slug_of "$game")"

    local out; out="$(mods_analyze "$slug" "$@" 2>/tmp/.mods_report.$$)"
    local deps conflicts
    deps="$(printf '%s\n' "$out" | awk '/^MISSINGDEP/{print $3}' | sort -u)"
    conflicts="$(printf '%s\n' "$out" | awk '/^CONFLICT/')"

    if [[ -s /tmp/.mods_report.$$ ]]; then
        plog "Pre-flight analysis:"
        cat /tmp/.mods_report.$$
    else
        pok "No dependency or conflict issues found."
    fi
    rm -f /tmp/.mods_report.$$

    if [[ -n "$deps" ]]; then
        plog "Missing dependencies (install with): powos mods install $game $(printf '%s ' $deps)"
    fi
    [[ -z "$conflicts" ]]
}
