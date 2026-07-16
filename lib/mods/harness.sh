#!/bin/bash
# mods/harness.sh - Headless mod-compatibility test harness for PowOS.
#
# Launches a Steam game in its EXACT Proton environment (via umu-launcher),
# monitors it for crash/freeze/successful boot, and emits a machine-readable
# verdict JSON. Designed to validate mod installs incrementally instead of
# "install 30 mods and pray."
#
# CLI:
#   powos mods verify  <game> [--timeout N] [--baseline] [--mock]
#   powos mods bisect  <game> [--timeout N]
#
# Sourced AFTER mods/install.sh, so it reuses: plog/pok/pwarn/perr,
# mods_appid_of, and the Steam path helpers.

set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}/common.sh" 2>/dev/null || {
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
    plog()  { echo -e "${CYAN}[harness]${NC} $*"; }
    pok()   { echo -e "${GREEN}[harness]${NC} $*"; }
    pwarn() { echo -e "${YELLOW}[harness]${NC} $*"; }
    perr()  { echo -e "${RED}[harness]${NC} $*" >&2; }
}
POWOS_TAG=harness

# ─── Paths ────────────────────────────────────────────────────────────────

HARNESS_STATE_DIR="${HARNESS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/powos/mods/verify}"
HARNESS_CRASH_DIR="${HARNESS_CRASH_DIR:-/tmp/powos-harness-dumps}"
HARNESS_MANGOHUD_DIR="${HARNESS_MANGOHUD_DIR:-/tmp/powos-harness-mangohud}"

# ─── Defaults ─────────────────────────────────────────────────────────────

HARNESS_TIMEOUT=120        # seconds before declaring BOOTED (survived = good)
HARNESS_FREEZE_WINDOW=15   # seconds of zero CPU/ctxsw delta = FREEZE
HARNESS_POLL_INTERVAL=3    # seconds between liveness samples
HARNESS_MOCK=""            # path to mock game binary (for CI)
HARNESS_BASELINE=0         # if 1, back up saves before launch

# ─── Steam env resolution ────────────────────────────────────────────────

# Find Steam root directory.
harness_steam_root() {
    local d
    for d in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"; do
        [[ -d "$d/steamapps" ]] && { echo "$d"; return 0; }
    done
    return 1
}

# Resolve game install directory from appid (reuse asi.sh helper if available).
harness_game_dir() {
    local appid="$1"
    if declare -F asi_game_dir >/dev/null 2>&1; then
        asi_game_dir "$appid"
        return $?
    fi
    # Inline fallback: parse libraryfolders.vdf
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
    if lib in seen: continue
    seen.add(lib)
    acf = os.path.join(lib, "steamapps", "appmanifest_%s.acf" % appid)
    if os.path.exists(acf):
        t = open(acf, encoding="utf-8", errors="ignore").read()
        m = re.search(r'"installdir"\s*"([^"]+)"', t)
        if m:
            p = os.path.join(lib, "steamapps", "common", m.group(1))
            if os.path.isdir(p):
                print(p); sys.exit(0)
sys.exit(1)
PY
}

# Resolve Proton version for an appid from config.vdf CompatToolMapping.
harness_proton_path() {
    local appid="$1"
    local steam_root
    steam_root="$(harness_steam_root)" || return 1
    python3 - "$appid" "$steam_root" <<'PY'
import sys, os, re
appid, steam = sys.argv[1], sys.argv[2]
cfg_path = os.path.join(steam, "config", "config.vdf")
if not os.path.exists(cfg_path):
    sys.exit(1)
txt = open(cfg_path, encoding="utf-8", errors="ignore").read()
# Find CompatToolMapping block, extract per-appid proton name
pat = r'"' + appid + r'"\s*\{[^}]*"name"\s*"([^"]+)"'
m = re.search(pat, txt)
if not m:
    sys.exit(1)
name = m.group(1)
# Search for the proton install
for d in [os.path.join(steam, "compatibilitytools.d"),
          os.path.join(steam, "steamapps", "common")]:
    p = os.path.join(d, name)
    if os.path.isdir(p):
        print(p); sys.exit(0)
# Try partial match (e.g., "proton_experimental" → "Proton - Experimental")
for d in [os.path.join(steam, "compatibilitytools.d"),
          os.path.join(steam, "steamapps", "common")]:
    if not os.path.isdir(d): continue
    for entry in os.listdir(d):
        if name.replace("_", "").lower() in entry.replace(" ", "").replace("-", "").lower():
            print(os.path.join(d, entry)); sys.exit(0)
sys.exit(1)
PY
}

# Extract user launch options for an appid from localconfig.vdf.
harness_launch_options() {
    local appid="$1"
    local steam_root
    steam_root="$(harness_steam_root)" || return 1
    python3 - "$appid" "$steam_root" <<'PY'
import sys, os, re, glob
appid, steam = sys.argv[1], sys.argv[2]
for lc in glob.glob(os.path.join(steam, "userdata", "*", "config", "localconfig.vdf")):
    txt = open(lc, encoding="utf-8", errors="ignore").read()
    # Find the Apps block for this appid, extract LaunchOptions
    pat = r'"' + appid + r'"\s*\{[^}]*"LaunchOptions"\s*"([^"]*)"'
    m = re.search(pat, txt, re.DOTALL)
    if m:
        print(m.group(1)); sys.exit(0)
PY
}

# Resolve the Wine prefix (compatdata) for an appid.
harness_prefix_path() {
    local appid="$1"
    local steam_root
    steam_root="$(harness_steam_root)" || { echo ""; return 1; }
    # Check all library folders
    python3 - "$appid" "$steam_root" <<'PY'
import sys, os, re
appid, steam = sys.argv[1], sys.argv[2]
lf = os.path.join(steam, "steamapps", "libraryfolders.vdf")
libs = [steam]
if os.path.exists(lf):
    txt = open(lf, encoding="utf-8", errors="ignore").read()
    libs += re.findall(r'"path"\s*"([^"]+)"', txt)
for lib in libs:
    p = os.path.join(lib.replace("\\\\", "/"), "steamapps", "compatdata", appid)
    if os.path.isdir(p):
        print(p); sys.exit(0)
# Default location
print(os.path.join(steam, "steamapps", "compatdata", appid))
PY
}

# ─── Liveness monitoring ─────────────────────────────────────────────────

# Read combined CPU ticks (utime + stime) for a PID.
# Returns 0 if the process doesn't exist.
harness_cpu_ticks() {
    local pid="$1"
    local stat_file="/proc/$pid/stat"
    [[ -f "$stat_file" ]] || { echo "0"; return 1; }
    python3 - "$stat_file" <<'PY'
import sys
try:
    with open(sys.argv[1]) as f:
        data = f.read()
    # The comm field (field 2) is in parens and can contain spaces/parens.
    # Everything after the LAST ')' is fields 3+ (state, ppid, pgrp, ...).
    rest = data[data.rfind(')') + 2:]
    fields = rest.split()
    # fields[0]=state, [1]=ppid, ..., [11]=utime, [12]=stime (0-indexed from field 3)
    print(int(fields[11]) + int(fields[12]))
except Exception:
    print("0")
PY
}

# Read total context switches (voluntary + nonvoluntary) for a PID.
harness_ctx_switches() {
    local pid="$1"
    local status_file="/proc/$pid/status"
    [[ -f "$status_file" ]] || { echo "0"; return 1; }
    python3 - "$status_file" <<'PY'
import sys
total = 0
try:
    with open(sys.argv[1]) as f:
        for line in f:
            if "ctxt_switches" in line:
                total += int(line.split()[-1])
    print(total)
except Exception:
    print("0")
PY
}

# Check if MangoHud CSV has new lines since last check.
# Args: $1=mangohud_dir  $2=last_known_line_count
# Returns: new line count (stdout), exit 0 if advancing, 1 if stalled.
harness_mangohud_advancing() {
    local mhud_dir="$1" last_count="${2:-0}"
    local csv
    csv="$(ls -t "$mhud_dir"/*.csv 2>/dev/null | head -1)" || { echo "$last_count"; return 1; }
    [[ -n "$csv" ]] || { echo "$last_count"; return 1; }
    local count
    count="$(wc -l < "$csv" 2>/dev/null)" || count=0
    echo "$count"
    [[ "$count" -gt "$last_count" ]] && return 0 || return 1
}

# ─── Game log awareness ──────────────────────────────────────────────────

# Known per-game log files and fatal patterns.
# Returns JSON: {"file": "content_or_empty", ...}
harness_game_logs() {
    local appid="$1" game_dir="$2" prefix_path="$3"
    python3 - "$appid" "$game_dir" "$prefix_path" <<'PY'
import sys, os, json, re

appid, game_dir, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
pfx_c = os.path.join(prefix, "pfx", "drive_c") if os.path.isdir(os.path.join(prefix, "pfx")) else ""

# Per-game log definitions: {appid: [{path_relative_to_game_dir, fatal_patterns}]}
GAME_LOGS = {
    "1091500": [  # Cyberpunk 2077
        {"path": "red4ext/logs/red4ext.log",
         "fatal": [r"\[error\]", r"FAILED_TO_LOAD", r"MISSING_DEPENDENCY"]},
        {"path": "bin/x64/plugins/cyber_engine_tweaks/cyber_engine_tweaks.log",
         "fatal": [r"\[error\]", r"FATAL", r"crash"]},
        {"path": "r6/logs/redscript_rCURRENT.log",
         "fatal": [r"ERROR", r"FAILED"]},
    ],
    "489830": [  # Skyrim SE
        {"path": "SKSE/skse64.log",
         "fatal": [r"couldn't load plugin", r"error"]},
    ],
}

result = {}
logs = GAME_LOGS.get(appid, [])
for entry in logs:
    full_path = os.path.join(game_dir, entry["path"])
    # Also check under prefix drive_c
    if not os.path.exists(full_path) and pfx_c:
        alt = os.path.join(pfx_c, entry["path"])
        if os.path.exists(alt):
            full_path = alt
    key = os.path.basename(entry["path"])
    if os.path.exists(full_path):
        try:
            content = open(full_path, encoding="utf-8", errors="ignore").read()
            # Extract fatal lines
            fatal_lines = []
            for pat in entry["fatal"]:
                for line in content.splitlines():
                    if re.search(pat, line, re.IGNORECASE):
                        fatal_lines.append(line.strip())
            result[key] = "\n".join(fatal_lines[:10]) if fatal_lines else ""
        except Exception:
            result[key] = ""
    else:
        result[key] = ""

print(json.dumps(result))
PY
}

# ─── Process tree management ─────────────────────────────────────────────

# Kill an entire process group gracefully, then forcefully.
harness_kill_tree() {
    local pid="$1" prefix_path="${2:-}"

    # 1. Try wineserver -k for graceful Wine shutdown
    if [[ -n "$prefix_path" ]] && command -v wineserver >/dev/null 2>&1; then
        WINEPREFIX="$prefix_path/pfx" wineserver -k 2>/dev/null || true
        sleep 2
    fi

    # 2. Get the process group and SIGTERM it
    local pgid
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" || true
    if [[ -n "$pgid" ]] && [[ "$pgid" != "0" ]]; then
        kill -- -"$pgid" 2>/dev/null || true
        sleep 2
        # 3. SIGKILL survivors
        kill -9 -- -"$pgid" 2>/dev/null || true
    else
        # Fallback: kill just the PID
        kill "$pid" 2>/dev/null || true
        sleep 2
        kill -9 "$pid" 2>/dev/null || true
    fi
}

# ─── Save protection ─────────────────────────────────────────────────────

harness_backup_saves() {
    local prefix_path="$1" backup_dir="$2"
    local saves_src="$prefix_path/pfx/drive_c/users/steamuser"
    if [[ -d "$saves_src" ]]; then
        mkdir -p "$backup_dir"
        # Back up common save locations
        for d in "Saved Games" "AppData/Local" "AppData/Roaming" "Documents/My Games"; do
            [[ -d "$saves_src/$d" ]] && cp -a "$saves_src/$d" "$backup_dir/" 2>/dev/null || true
        done
        plog "Saves backed up to $backup_dir"
    fi
}

harness_restore_saves() {
    local prefix_path="$1" backup_dir="$2"
    local saves_dst="$prefix_path/pfx/drive_c/users/steamuser"
    if [[ -d "$backup_dir" ]] && [[ -d "$saves_dst" ]]; then
        for d in "$backup_dir"/*/; do
            [[ -d "$d" ]] && cp -a "$d" "$saves_dst/" 2>/dev/null || true
        done
        plog "Saves restored from $backup_dir"
    fi
}

# ─── Core: launch + monitor + verdict ────────────────────────────────────

# Launch a game and monitor it. Emit a verdict.
# Args: appid [game_exe_override]
# Env: HARNESS_TIMEOUT, HARNESS_FREEZE_WINDOW, HARNESS_POLL_INTERVAL,
#      HARNESS_MOCK, HARNESS_BASELINE
# Stdout: verdict JSON
harness_run() {
    # All plog/pok/pwarn/perr go to stderr; only the verdict JSON goes to stdout.
    local _plog_orig
    _plog_orig="$(declare -f plog)"
    plog()  { echo -e "${CYAN:-}[harness]${NC:-} $*" >&2; }
    pok()   { echo -e "${GREEN:-}[harness]${NC:-} $*" >&2; }
    pwarn() { echo -e "${YELLOW:-}[harness]${NC:-} $*" >&2; }

    local appid="$1"
    local game_exe="${2:-}"
    local ts
    ts="$(date -u +%Y%m%dT%H%M%SZ)"

    # ── Resolve paths ──
    local game_dir="" prefix_path="" proton_path="" launch_opts=""
    local game_pid="" exit_code=0
    local verdict="unknown" elapsed=0
    local crash_dumps="" proton_log_errors="" cpu_frozen=false mangohud_frozen=false
    local game_log_json="{}"

    # Prepare directories
    mkdir -p "$HARNESS_STATE_DIR" "$HARNESS_CRASH_DIR" "$HARNESS_MANGOHUD_DIR"
    # Clean crash dir for this run
    rm -f "$HARNESS_CRASH_DIR"/*.dmp 2>/dev/null || true

    if [[ -n "$HARNESS_MOCK" ]]; then
        # ── Mock mode: use the provided mock binary ──
        plog "Mock mode: using $HARNESS_MOCK" >&2
        game_dir="/tmp/powos-harness-mock-gamedir"
        prefix_path="/tmp/powos-harness-mock-prefix"
        mkdir -p "$game_dir" "$prefix_path/pfx/drive_c/users/steamuser"
    else
        # ── Real mode: resolve Steam environment ──
        game_dir="$(harness_game_dir "$appid")" || {
            perr "Cannot find game directory for appid $appid"
            return 1
        }
        prefix_path="$(harness_prefix_path "$appid")"
        proton_path="$(harness_proton_path "$appid" 2>/dev/null)" || true
        launch_opts="$(harness_launch_options "$appid" 2>/dev/null)" || true
        plog "Game dir:    $game_dir"
        plog "Prefix:      $prefix_path"
        [[ -n "$proton_path" ]] && plog "Proton:      $proton_path"
        [[ -n "$launch_opts" ]] && plog "Launch opts: $launch_opts"
    fi

    # ── Backup saves if --baseline ──
    local saves_backup=""
    if [[ "$HARNESS_BASELINE" == "1" ]]; then
        saves_backup="/tmp/powos-harness-saves-$appid-$ts"
        harness_backup_saves "$prefix_path" "$saves_backup"
    fi

    # ── Build the launch command ──
    local launch_cmd=()

    if [[ -n "$HARNESS_MOCK" ]]; then
        # shellcheck disable=SC2206
        launch_cmd=($HARNESS_MOCK)
    elif command -v umu-run >/dev/null 2>&1; then
        # Use umu-launcher (preferred)
        local umu_env=(
            "WINEPREFIX=$prefix_path/pfx"
            "GAMEID=$appid"
            "UMU_RUNTIME_UPDATE=0"
            "PROTON_LOG=1"
            "PROTON_LOG_DIR=/tmp"
            "PROTON_CRASH_REPORT_DIR=$HARNESS_CRASH_DIR"
            "MANGOHUD=1"
            "MANGOHUD_CONFIG=no_display,output_folder=$HARNESS_MANGOHUD_DIR,autostart_log=3,log_duration=0,log_interval=500"
        )
        [[ -n "$proton_path" ]] && umu_env+=("PROTONPATH=$proton_path")

        if [[ -z "$game_exe" ]]; then
            # Try to find the main exe from the appmanifest
            game_exe="$(find "$game_dir" -maxdepth 2 -name '*.exe' -type f 2>/dev/null | head -1)" || true
        fi
        [[ -z "$game_exe" ]] && { perr "No game exe found"; return 1; }

        launch_cmd=(env "${umu_env[@]}" umu-run "$game_exe")
    else
        perr "umu-run not found. Install umu-launcher: pip install umu-launcher"
        return 1
    fi

    # ── Launch the game in the background ──
    plog "Launching game (timeout: ${HARNESS_TIMEOUT}s)..."
    local start_time
    start_time="$(date +%s)"

    # Use setsid so we get a new process group for clean kill
    setsid "${launch_cmd[@]}" &>/dev/null &
    game_pid=$!

    plog "Game PID: $game_pid (pgid: $(ps -o pgid= -p $game_pid 2>/dev/null | tr -d ' ' || echo '?'))"

    # ── Monitor loop ──
    local prev_cpu=0 prev_ctx=0 frozen_since=0
    local prev_mhud_lines=0
    local wall_start
    wall_start="$(date +%s)"

    while true; do
        sleep "$HARNESS_POLL_INTERVAL"
        local now
        now="$(date +%s)"
        elapsed=$((now - wall_start))

        # Check if process is still alive
        if ! kill -0 "$game_pid" 2>/dev/null; then
            # Process exited
            wait "$game_pid" 2>/dev/null
            exit_code=$?
            if [[ $exit_code -ne 0 ]]; then
                verdict="crash"
                plog "Process exited with code $exit_code after ${elapsed}s → CRASH"
            else
                verdict="booted"
                plog "Process exited cleanly after ${elapsed}s"
            fi
            break
        fi

        # ── CPU ticks delta ──
        local cur_cpu
        cur_cpu="$(harness_cpu_ticks "$game_pid" 2>/dev/null)" || cur_cpu=0

        # ── Context switches delta ──
        local cur_ctx
        cur_ctx="$(harness_ctx_switches "$game_pid" 2>/dev/null)" || cur_ctx=0

        # ── MangoHud CSV check ──
        local cur_mhud
        cur_mhud="$(harness_mangohud_advancing "$HARNESS_MANGOHUD_DIR" "$prev_mhud_lines" 2>/dev/null)" || cur_mhud="$prev_mhud_lines"

        # ── Freeze detection ──
        local stalled=false
        if [[ "$prev_cpu" -gt 0 ]] && [[ "$cur_cpu" -eq "$prev_cpu" ]] \
            && [[ "$cur_ctx" -eq "$prev_ctx" ]]; then
            stalled=true
        fi

        if [[ "$stalled" == "true" ]]; then
            if [[ "$frozen_since" -eq 0 ]]; then
                frozen_since="$now"
            elif [[ $((now - frozen_since)) -ge $HARNESS_FREEZE_WINDOW ]]; then
                verdict="freeze"
                cpu_frozen=true
                plog "No CPU/ctxsw activity for ${HARNESS_FREEZE_WINDOW}s → FREEZE"
                break
            fi
        else
            frozen_since=0
        fi

        # MangoHud freeze (supplementary signal)
        if [[ "$cur_mhud" -eq "$prev_mhud_lines" ]] && [[ "$prev_mhud_lines" -gt 0 ]] \
            && [[ "$elapsed" -gt 30 ]]; then
            mangohud_frozen=true
        fi

        prev_cpu="$cur_cpu"
        prev_ctx="$cur_ctx"
        prev_mhud_lines="$cur_mhud"

        # ── Timeout = BOOTED ──
        if [[ $elapsed -ge $HARNESS_TIMEOUT ]]; then
            verdict="booted"
            plog "Survived ${HARNESS_TIMEOUT}s → BOOTED"
            break
        fi
    done

    # ── Collect crash artifacts ──
    local dump_list
    dump_list="$(find "$HARNESS_CRASH_DIR" -name '*.dmp' 2>/dev/null | tr '\n' ',')"
    dump_list="${dump_list%,}"

    # Proton log errors
    local proton_log="/tmp/steam-${appid}.log"
    if [[ -f "$proton_log" ]]; then
        proton_log_errors="$(grep -E 'err:seh:|Unhandled exception|page fault' "$proton_log" 2>/dev/null | head -5 | tr '\n' '; ')" || true
        proton_log_errors="${proton_log_errors%;}"
    fi

    # Game-specific logs
    game_log_json="$(harness_game_logs "$appid" "$game_dir" "$prefix_path" 2>/dev/null)" || game_log_json="{}"

    # ── Kill game if still running ──
    if kill -0 "$game_pid" 2>/dev/null; then
        plog "Killing game process tree..."
        harness_kill_tree "$game_pid" "$prefix_path"
    fi

    # ── Restore saves if we backed them up ──
    if [[ -n "$saves_backup" ]] && [[ -d "$saves_backup" ]]; then
        harness_restore_saves "$prefix_path" "$saves_backup"
        rm -rf "$saves_backup"
    fi

    # ── Emit verdict JSON ──
    local game_name
    game_name="$(mods_game_name_of "$appid" 2>/dev/null)" || game_name="$appid"

    local verdict_file="$HARNESS_STATE_DIR/${game_name}-${ts}.json"

    python3 - "$verdict_file" "$game_name" "$appid" "$verdict" "$elapsed" \
              "$exit_code" "$dump_list" "$proton_log_errors" \
              "$cpu_frozen" "$mangohud_frozen" "$game_log_json" <<'PY'
import sys, json

vf, game, appid, verdict, elapsed, exit_code, dumps, proton_errs, \
    cpu_frozen, mhud_frozen, game_logs_raw = sys.argv[1:12]

result = {
    "game": game,
    "appid": appid,
    "verdict": verdict,
    "seconds": float(elapsed),
    "exit_code": int(exit_code),
    "signals": {
        "crash_dumps": [d for d in dumps.split(",") if d],
        "proton_log_errors": [e.strip() for e in proton_errs.split(";") if e.strip()],
        "cpu_frozen": cpu_frozen == "true",
        "mangohud_frozen": mhud_frozen == "true",
        "game_logs": json.loads(game_logs_raw) if game_logs_raw.strip() else {},
    },
}

with open(vf, "w") as f:
    json.dump(result, f, indent=2)
print(json.dumps(result, indent=2))
PY
    local rc=$?
    plog "Verdict saved to $verdict_file"
    return $rc
}

# ─── Bisect: binary-search for the breaking mod ──────────────────────────

# Given a list of mods, binary-search to find which one(s) break the game.
# Uses harness_run as the oracle.
#
# Strategy: disable half the mods, run verify. If BOOTED, the breaker is
# in the disabled set. Recurse until we find the single breaking mod.
#
# Mod toggle interface: expects functions or files.
# For now, uses a simple approach: reads a mod list file, renames mod files
# to disable them (.disabled suffix), and restores after each test.
harness_bisect() {
    local appid="$1"
    local game_name
    game_name="$(mods_game_name_of "$appid" 2>/dev/null)" || game_name="$appid"
    local game_dir
    game_dir="$(harness_game_dir "$appid" 2>/dev/null)" || {
        perr "Cannot find game directory for appid $appid"
        return 1
    }

    # Discover mods: look for a mod manifest (ASI-style JSON)
    local manifest=""
    if declare -F asi_manifest_path >/dev/null 2>&1; then
        manifest="$(asi_manifest_path "$appid" 2>/dev/null)" || true
    fi

    local mod_list=()

    if [[ -n "$manifest" ]] && [[ -f "$manifest" ]]; then
        # Read mod entries from ASI manifest
        mapfile -t mod_list < <(python3 - "$manifest" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
for entry in data.get("entries", []):
    if entry.get("file"):
        print(entry["file"])
PY
)
    else
        # Fallback: discover mod files in known locations
        # Cyberpunk: red4ext/plugins/*, bin/x64/plugins/*, archive/pc/mod/*
        # Generic: *.asi, *.dll in game root
        local search_dirs=("$game_dir")
        case "$appid" in
            1091500) search_dirs+=("$game_dir/red4ext/plugins" "$game_dir/bin/x64/plugins" "$game_dir/archive/pc/mod") ;;
        esac
        for d in "${search_dirs[@]}"; do
            [[ -d "$d" ]] || continue
            while IFS= read -r f; do
                mod_list+=("$f")
            done < <(find "$d" -maxdepth 2 \( -name '*.asi' -o -name '*.dll' -o -name '*.archive' \) -type f 2>/dev/null)
        done
    fi

    if [[ ${#mod_list[@]} -eq 0 ]]; then
        perr "No mods found to bisect"
        return 1
    fi

    plog "Found ${#mod_list[@]} mod(s) to bisect:"
    for m in "${mod_list[@]}"; do
        plog "  $(basename "$m")"
    done

    # First: verify current state is actually broken
    plog ""
    plog "Step 0: Verifying game is currently broken..."
    local baseline_json
    baseline_json="$(harness_run "$appid")"
    local baseline_verdict
    baseline_verdict="$(echo "$baseline_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["verdict"])')"

    if [[ "$baseline_verdict" == "booted" ]]; then
        pok "Game boots fine! Nothing to bisect."
        return 0
    fi
    plog "Confirmed broken (verdict: $baseline_verdict). Starting bisect..."

    # Bisect loop
    harness_bisect_recursive "$appid" "${mod_list[@]}"
}

# Recursive bisect worker. Disables a subset, tests, narrows down.
harness_bisect_recursive() {
    local appid="$1"
    shift
    local mods=("$@")
    local count=${#mods[@]}

    if [[ $count -eq 0 ]]; then
        plog "No mods left to test"
        return 0
    fi

    if [[ $count -eq 1 ]]; then
        pok "Found the breaking mod: ${BOLD}$(basename "${mods[0]}")${NC}"
        echo "${mods[0]}"
        return 0
    fi

    local half=$((count / 2))
    local first_half=("${mods[@]:0:$half}")
    local second_half=("${mods[@]:$half}")

    plog ""
    plog "Bisecting: disabling first ${#first_half[@]} of $count mods..."

    # Disable first half
    for m in "${first_half[@]}"; do
        [[ -f "$m" ]] && mv "$m" "${m}.harness-disabled" 2>/dev/null || true
    done

    # Test
    local test_json
    test_json="$(harness_run "$appid")"
    local test_verdict
    test_verdict="$(echo "$test_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["verdict"])')"

    # Re-enable first half
    for m in "${first_half[@]}"; do
        [[ -f "${m}.harness-disabled" ]] && mv "${m}.harness-disabled" "$m" 2>/dev/null || true
    done

    if [[ "$test_verdict" == "booted" ]]; then
        # Breaker is in the disabled (first) half
        plog "Game booted with second half only → breaker is in the first half"
        harness_bisect_recursive "$appid" "${first_half[@]}"
    else
        # Breaker is in the second half (or there are multiple breakers)
        plog "Game still broken → breaker is in the second half"
        harness_bisect_recursive "$appid" "${second_half[@]}"
    fi
}

# ─── CLI dispatch ─────────────────────────────────────────────────────────

harness_dispatch() {
    case "${1:-help}" in
        verify|test|check)
            shift
            harness_verify_cmd "$@"
            ;;
        bisect|find|search)
            shift
            harness_bisect_cmd "$@"
            ;;
        history|results|log)
            shift
            harness_history_cmd "$@"
            ;;
        help|--help|-h)
            harness_help
            ;;
        *)
            perr "Unknown: powos mods verify $1"
            harness_help
            return 1
            ;;
    esac
}

harness_verify_cmd() {
    local game="" timeout="" baseline=0 mock=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout|-t) shift; timeout="${1:-}" ;;
            --baseline|-b) baseline=1 ;;
            --mock) shift; mock="${1:-}" ;;
            --help|-h) harness_help; return 0 ;;
            -*) perr "Unknown flag: $1"; return 1 ;;
            *) [[ -z "$game" ]] && game="$1" || { perr "Unexpected arg: $1"; return 1; } ;;
        esac
        shift
    done

    [[ -z "$game" ]] && { perr "Usage: powos mods verify <game> [--timeout N] [--baseline] [--mock PATH]"; return 1; }

    local appid
    appid="$(mods_appid_of "$game" 2>/dev/null)" || appid="$game"

    [[ -n "$timeout" ]] && HARNESS_TIMEOUT="$timeout"
    [[ "$baseline" -eq 1 ]] && HARNESS_BASELINE=1
    [[ -n "$mock" ]] && HARNESS_MOCK="$mock"

    harness_run "$appid"
}

harness_bisect_cmd() {
    local game="" timeout=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout|-t) shift; timeout="${1:-}" ;;
            --help|-h) harness_help; return 0 ;;
            -*) perr "Unknown flag: $1"; return 1 ;;
            *) [[ -z "$game" ]] && game="$1" || { perr "Unexpected arg: $1"; return 1; } ;;
        esac
        shift
    done

    [[ -z "$game" ]] && { perr "Usage: powos mods bisect <game> [--timeout N]"; return 1; }

    local appid
    appid="$(mods_appid_of "$game" 2>/dev/null)" || appid="$game"

    [[ -n "$timeout" ]] && HARNESS_TIMEOUT="$timeout"

    harness_bisect "$appid"
}

harness_history_cmd() {
    local game="${1:-}"
    if [[ -n "$game" ]]; then
        local name
        name="$(mods_game_name_of "$(mods_appid_of "$game" 2>/dev/null)" 2>/dev/null)" || name="$game"
        ls -la "$HARNESS_STATE_DIR/${name}-"*.json 2>/dev/null || plog "No results for $game"
    else
        ls -la "$HARNESS_STATE_DIR/"*.json 2>/dev/null || plog "No results yet"
    fi
}

harness_help() {
    local BOLD=$'\033[1m' DIM=$'\033[2m' NC=$'\033[0m'
    cat <<EOF
${BOLD}powos mods verify${NC} — headless mod-compatibility test harness

Launch a game in its Steam/Proton environment, monitor for crash/freeze,
and emit a machine-readable verdict.

${BOLD}Verify (test a game boots):${NC}
  powos mods verify <game>                     Launch + monitor (120s timeout)
  powos mods verify <game> --timeout 60        Custom timeout
  powos mods verify <game> --baseline          Back up saves first
  powos mods verify <game> --mock /path/to/bin Use a mock binary (CI testing)

${BOLD}Bisect (find the breaking mod):${NC}
  powos mods bisect <game>                     Binary-search the mod set
  powos mods bisect <game> --timeout 60        Custom per-round timeout

${BOLD}History:${NC}
  powos mods verify history [game]             Show past verdicts

${BOLD}Verdicts:${NC}
  ${GREEN}booted${NC}   Game survived the timeout — it works
  ${RED}crash${NC}    Process exited with nonzero code
  ${YELLOW}freeze${NC}   Process alive but no CPU/context-switch activity

Verdict JSON is saved to:
  ~/.local/state/powos/mods/verify/<game>-<timestamp>.json

${BOLD}How it works:${NC}
  Uses umu-launcher to reproduce the exact Steam+Proton environment.
  Monitors /proc/<pid>/stat for CPU ticks, /proc/<pid>/status for
  context switches, MangoHud CSV for frame output, and game-specific
  logs (e.g., red4ext.log for Cyberpunk 2077). On real hardware,
  gamescope --nested keeps the game off your desktop.

${BOLD}Requirements:${NC}
  Real hardware: umu-launcher, gamescope (optional), MangoHud (optional)
  CI/Docker:     --mock flag with a test binary (no GPU needed)
EOF
}

# Resolve human-readable game name from appid (reverse of mods_appid_of).
mods_game_name_of() {
    case "$1" in
        1091500) echo "cyberpunk2077" ;;
        489830)  echo "skyrimse" ;;
        377160)  echo "fallout4" ;;
        1716740) echo "starfield" ;;
        292030)  echo "witcher3" ;;
        1086940) echo "bg3" ;;
        3240220) echo "gta5" ;;
        271590)  echo "gta5-legacy" ;;
        1174180) echo "rdr2" ;;
        *) echo "$1" ;;
    esac
}
