#!/bin/bash
# mods/harness.sh - Headless mod-compatibility test harness for PowOS.
#
# Launches a Steam game and monitors it for crash/freeze/successful boot,
# emitting a machine-readable verdict JSON. Designed to validate mod installs
# incrementally instead of "install 30 mods and pray."
#
# Launch modes (in priority order):
#   1. PRIMARY: `steam -applaunch <appid>` via the running Steam client.
#      Satisfies Steamworks DRM, uses the user's Proton + launch options.
#      Requires the powos-game-shim to be installed in the game's launch
#      options (`powos mods verify setup <game>`). The shim sources a
#      per-run env sentinel to inject MangoHud/PROTON_LOG/etc.
#   2. SECONDARY: `umu-run` (--no-steam flag). DRM-free games only.
#      Reproduces Steam Linux Runtime + Proton env standalone.
#   3. MOCK: --mock flag with a test binary (CI/Docker, no GPU needed).
#
# CLI:
#   powos mods verify       <game> [--timeout N] [--baseline] [--no-steam] [--mock PATH]
#   powos mods verify setup <game>   One-time shim injection into Steam launch options
#   powos mods bisect       <game> [--timeout N]
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
HARNESS_RUN_DIR="${HARNESS_RUN_DIR:-/run/powos/verify}"

# ─── Defaults ─────────────────────────────────────────────────────────────

HARNESS_TIMEOUT=120        # seconds before declaring BOOTED (survived = good)
HARNESS_FREEZE_WINDOW=15   # seconds of no frame progress = FREEZE
HARNESS_POLL_INTERVAL=3    # seconds between liveness samples
HARNESS_MOCK=""            # path to mock game binary (for CI)
HARNESS_BASELINE=0         # if 1, back up saves before launch
HARNESS_NO_STEAM=0         # if 1, use umu-run instead of steam -applaunch

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
pat = r'"' + appid + r'"\s*\{[^}]*"name"\s*"([^"]+)"'
m = re.search(pat, txt)
if not m:
    sys.exit(1)
name = m.group(1)
for d in [os.path.join(steam, "compatibilitytools.d"),
          os.path.join(steam, "steamapps", "common")]:
    p = os.path.join(d, name)
    if os.path.isdir(p):
        print(p); sys.exit(0)
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
print(os.path.join(steam, "steamapps", "compatdata", appid))
PY
}

# ─── Safety: game already running? ───────────────────────────────────────

# Check if the game is already running. Returns 0 (true) if running.
harness_game_running() {
    local appid="$1"
    # Method 1: check for shim PID file from a previous run
    [[ -f "$HARNESS_RUN_DIR/${appid}.pid" ]] && {
        local old_pid
        old_pid="$(grep 'shim_pid=' "$HARNESS_RUN_DIR/${appid}.pid" 2>/dev/null | cut -d= -f2)"
        [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null && return 0
    }
    # Method 2: scan /proc for processes with STEAM_COMPAT_DATA_PATH containing the appid
    python3 - "$appid" <<'PY' 2>/dev/null && return 0
import sys, os
appid = sys.argv[1]
for pid in os.listdir("/proc"):
    if not pid.isdigit(): continue
    try:
        env = open(f"/proc/{pid}/environ", "rb").read()
        if f"compatdata/{appid}".encode() in env:
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
PY
    return 1
}

# ─── Steam client management ─────────────────────────────────────────────

# Check if Steam is running.
harness_steam_running() {
    pgrep -x steam >/dev/null 2>&1
}

# Start Steam silently and wait for it to be ready.
harness_ensure_steam() {
    if harness_steam_running; then
        return 0
    fi
    plog "Starting Steam client..."
    steam -silent &>/dev/null &
    # Wait up to 30s for Steam to be ready
    local i=0
    while [[ $i -lt 30 ]]; do
        harness_steam_running && { plog "Steam is ready"; return 0; }
        sleep 1
        i=$((i + 1))
    done
    perr "Steam did not start within 30s"
    return 1
}

# ─── Shim setup: inject powos-game-shim into launch options ──────────────

# One-time setup: prepend powos-game-shim to a game's Steam launch options.
# Edits localconfig.vdf while Steam is CLOSED.
harness_setup_shim() {
    local appid="$1"
    local shim_cmd="powos-game-shim %command%"

    # Check if Steam is running — we can't edit localconfig.vdf while it's open
    if harness_steam_running; then
        perr "Steam must be closed to edit launch options."
        perr "Close Steam, then run: powos mods verify setup $(mods_game_name_of "$appid" 2>/dev/null || echo "$appid")"
        return 1
    fi

    local steam_root
    steam_root="$(harness_steam_root)" || { perr "Steam not found"; return 1; }

    python3 - "$appid" "$steam_root" "$shim_cmd" <<'PY'
import sys, os, re, glob

appid, steam, shim = sys.argv[1], sys.argv[2], sys.argv[3]

for lc_path in glob.glob(os.path.join(steam, "userdata", "*", "config", "localconfig.vdf")):
    with open(lc_path, encoding="utf-8", errors="ignore") as f:
        content = f.read()

    # Find the Apps section for this appid
    pat = r'("' + appid + r'"\s*\{[^}]*)'
    m = re.search(pat, content, re.DOTALL)
    if not m:
        # App section doesn't exist — skip this user
        continue

    block = m.group(1)

    # Check if shim is already installed
    if "powos-game-shim" in block:
        print(f"Shim already installed for appid {appid}")
        sys.exit(0)

    # Check for existing LaunchOptions
    lo_match = re.search(r'"LaunchOptions"\s*"([^"]*)"', block)
    if lo_match:
        existing = lo_match.group(1)
        new_opts = shim.replace("%command%", existing + " %command%") if existing else shim
        new_block = block.replace(f'"LaunchOptions"\t\t"{existing}"', f'"LaunchOptions"\t\t"{new_opts}"')
        new_block = new_block.replace(f'"LaunchOptions"  "{existing}"', f'"LaunchOptions"  "{new_opts}"')
        # Handle various whitespace
        new_block = re.sub(
            r'"LaunchOptions"\s*"' + re.escape(existing) + '"',
            f'"LaunchOptions"\t\t"{new_opts}"',
            block
        )
    else:
        # No LaunchOptions — add it
        new_block = block.rstrip("}").rstrip() + f'\n\t\t\t\t\t"LaunchOptions"\t\t"{shim}"\n'

    content = content.replace(block, new_block)
    with open(lc_path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"Shim installed for appid {appid} in {lc_path}")
    sys.exit(0)

print(f"No Steam user config found for appid {appid}", file=sys.stderr)
sys.exit(1)
PY
}

# ─── PID discovery under steam -applaunch ────────────────────────────────

# Find the game PID after steam -applaunch. Uses two methods:
# 1. Read the PID file written by the shim (/run/powos/verify/<appid>.pid)
# 2. Fallback: scan /proc for STEAM_COMPAT_DATA_PATH containing the appid
harness_discover_game_pid() {
    local appid="$1" timeout="${2:-30}"
    local pid_file="$HARNESS_RUN_DIR/${appid}.pid"
    local i=0

    while [[ $i -lt $timeout ]]; do
        # Method 1: shim PID file
        if [[ -f "$pid_file" ]]; then
            local shim_pid
            shim_pid="$(grep 'shim_pid=' "$pid_file" 2>/dev/null | cut -d= -f2)"
            if [[ -n "$shim_pid" ]] && kill -0 "$shim_pid" 2>/dev/null; then
                echo "$shim_pid"
                return 0
            fi
        fi

        # Method 2: /proc scan for compatdata/<appid>
        local found_pid
        found_pid="$(python3 - "$appid" <<'PY' 2>/dev/null)" || true
import sys, os
appid = sys.argv[1]
for pid in sorted(os.listdir("/proc"), key=lambda x: int(x) if x.isdigit() else 0, reverse=True):
    if not pid.isdigit(): continue
    try:
        env = open(f"/proc/{pid}/environ", "rb").read()
        if f"compatdata/{appid}".encode() in env:
            # Prefer the game process, not wineserver — check cmdline
            cmd = open(f"/proc/{pid}/cmdline", "rb").read().decode("utf-8", errors="ignore")
            if "wineserver" not in cmd:
                print(pid)
                sys.exit(0)
    except Exception:
        pass
sys.exit(1)
PY
        if [[ -n "$found_pid" ]]; then
            echo "$found_pid"
            return 0
        fi

        sleep 1
        i=$((i + 1))
    done
    return 1
}

# ─── Liveness monitoring ─────────────────────────────────────────────────

# Read combined CPU ticks (utime + stime) for a PID.
harness_cpu_ticks() {
    local pid="$1"
    local stat_file="/proc/$pid/stat"
    [[ -f "$stat_file" ]] || { echo "0"; return 1; }
    python3 - "$stat_file" <<'PY'
import sys
try:
    with open(sys.argv[1]) as f:
        data = f.read()
    rest = data[data.rfind(')') + 2:]
    fields = rest.split()
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

# Check if MangoHud is available on the system.
harness_has_mangohud() {
    command -v mangohud >/dev/null 2>&1 || \
    [[ -f "/usr/lib/mangohud/libMangoHud.so" ]] || \
    [[ -f "/usr/lib64/mangohud/libMangoHud.so" ]] || \
    flatpak info org.freedesktop.Platform.VulkanLayer.MangoHud >/dev/null 2>&1
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
    if not os.path.exists(full_path) and pfx_c:
        alt = os.path.join(pfx_c, entry["path"])
        if os.path.exists(alt):
            full_path = alt
    key = os.path.basename(entry["path"])
    if os.path.exists(full_path):
        try:
            content = open(full_path, encoding="utf-8", errors="ignore").read()
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

harness_kill_tree() {
    local pid="$1" prefix_path="${2:-}"

    if [[ -n "$prefix_path" ]] && command -v wineserver >/dev/null 2>&1; then
        WINEPREFIX="$prefix_path/pfx" wineserver -k 2>/dev/null || true
        sleep 2
    fi

    local pgid
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" || true
    if [[ -n "$pgid" ]] && [[ "$pgid" != "0" ]]; then
        kill -- -"$pgid" 2>/dev/null || true
        sleep 2
        kill -9 -- -"$pgid" 2>/dev/null || true
    else
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
#      HARNESS_MOCK, HARNESS_BASELINE, HARNESS_NO_STEAM
# Stdout: verdict JSON only
harness_run() {
    # All log output to stderr; only the verdict JSON goes to stdout.
    plog()  { echo -e "${CYAN:-}[harness]${NC:-} $*" >&2; }
    pok()   { echo -e "${GREEN:-}[harness]${NC:-} $*" >&2; }
    pwarn() { echo -e "${YELLOW:-}[harness]${NC:-} $*" >&2; }

    local appid="$1"
    local game_exe="${2:-}"
    local ts
    ts="$(date -u +%Y%m%dT%H%M%SZ)"

    local game_dir="" prefix_path="" proton_path="" launch_opts=""
    local game_pid="" exit_code=0
    local verdict="unknown" elapsed=0
    local crash_dumps="" proton_log_errors="" cpu_frozen=false mangohud_frozen=false
    local game_log_json="{}"
    local has_mangohud=false
    local confidence="high"  # downgraded when signals are missing/disagree
    local launch_mode="mock"

    # Prepare directories
    mkdir -p "$HARNESS_STATE_DIR" "$HARNESS_CRASH_DIR" "$HARNESS_MANGOHUD_DIR" \
             "$HARNESS_RUN_DIR" 2>/dev/null || true
    rm -f "$HARNESS_CRASH_DIR"/*.dmp 2>/dev/null || true

    # ── Safety: refuse if game already running ──
    if [[ -z "$HARNESS_MOCK" ]] && harness_game_running "$appid"; then
        perr "Game (appid $appid) is already running!"
        perr "Close the game first, then re-run verify."
        perr "Note: verify wants the desktop idle-ish (gamescope nested window"
        perr "on a hidden workspace still composites — avoid heavy desktop work)."
        return 1
    fi

    if [[ -n "$HARNESS_MOCK" ]]; then
        # ── Mock mode ──
        plog "Mock mode: using $HARNESS_MOCK"
        game_dir="/tmp/powos-harness-mock-gamedir"
        prefix_path="/tmp/powos-harness-mock-prefix"
        mkdir -p "$game_dir" "$prefix_path/pfx/drive_c/users/steamuser"
        launch_mode="mock"
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

        # Check MangoHud availability
        if harness_has_mangohud; then
            has_mangohud=true
            plog "MangoHud:    available (frame-based freeze detection)"
        else
            has_mangohud=false
            confidence="medium"
            pwarn "MangoHud not found — using CPU-only freeze detection (lower confidence)"
            pwarn "Install MangoHud for frame-based freeze detection (catches busy-spin hangs)"
        fi
    fi

    # ── Backup saves if --baseline ──
    local saves_backup=""
    if [[ "$HARNESS_BASELINE" == "1" ]]; then
        saves_backup="/tmp/powos-harness-saves-$appid-$ts"
        harness_backup_saves "$prefix_path" "$saves_backup"
    fi

    # ── Build the launch command / strategy ──

    if [[ -n "$HARNESS_MOCK" ]]; then
        # ── Mock: direct launch ──
        # shellcheck disable=SC2206
        local launch_cmd=($HARNESS_MOCK)
        plog "Launching mock game (timeout: ${HARNESS_TIMEOUT}s)..."
        setsid "${launch_cmd[@]}" &>/dev/null &
        game_pid=$!
        launch_mode="mock"

    elif [[ "$HARNESS_NO_STEAM" == "1" ]]; then
        # ── Secondary path: umu-run (DRM-free only) ──
        if ! command -v umu-run >/dev/null 2>&1; then
            perr "umu-run not found. Install umu-launcher: pip install umu-launcher"
            return 1
        fi
        local umu_env=(
            "WINEPREFIX=$prefix_path/pfx"
            "GAMEID=$appid"
            "UMU_RUNTIME_UPDATE=0"
            "PROTON_LOG=1"
            "PROTON_LOG_DIR=/tmp"
            "PROTON_CRASH_REPORT_DIR=$HARNESS_CRASH_DIR"
        )
        if [[ "$has_mangohud" == "true" ]]; then
            umu_env+=(
                "MANGOHUD=1"
                "MANGOHUD_CONFIG=no_display,output_folder=$HARNESS_MANGOHUD_DIR,autostart_log=3,log_duration=0,log_interval=500"
            )
        fi
        [[ -n "$proton_path" ]] && umu_env+=("PROTONPATH=$proton_path")

        if [[ -z "$game_exe" ]]; then
            game_exe="$(find "$game_dir" -maxdepth 2 -name '*.exe' -type f 2>/dev/null | head -1)" || true
        fi
        [[ -z "$game_exe" ]] && { perr "No game exe found"; return 1; }

        plog "Launching via umu-run (timeout: ${HARNESS_TIMEOUT}s)..."
        setsid env "${umu_env[@]}" umu-run "$game_exe" &>/dev/null &
        game_pid=$!
        launch_mode="umu-run"

    else
        # ── Primary path: steam -applaunch with shim ──
        harness_ensure_steam || return 1

        # Check shim is installed
        local current_opts
        current_opts="$(harness_launch_options "$appid" 2>/dev/null)" || current_opts=""
        if [[ "$current_opts" != *"powos-game-shim"* ]]; then
            perr "powos-game-shim not found in launch options for appid $appid"
            perr "Run first: powos mods verify setup $(mods_game_name_of "$appid" 2>/dev/null || echo "$appid")"
            perr "Or use --no-steam for DRM-free games"
            return 1
        fi

        # Write the env sentinel for the shim to source
        local sentinel="$HARNESS_RUN_DIR/${appid}.env"
        {
            echo "export PROTON_LOG=1"
            echo "export PROTON_LOG_DIR=/tmp"
            echo "export PROTON_CRASH_REPORT_DIR=$HARNESS_CRASH_DIR"
            if [[ "$has_mangohud" == "true" ]]; then
                echo "export MANGOHUD=1"
                echo "export MANGOHUD_CONFIG=no_display,output_folder=$HARNESS_MANGOHUD_DIR,autostart_log=3,log_duration=0,log_interval=500"
            fi
        } > "$sentinel"

        # Clean old PID file
        rm -f "$HARNESS_RUN_DIR/${appid}.pid" 2>/dev/null || true

        plog "Launching via steam -applaunch $appid (timeout: ${HARNESS_TIMEOUT}s)..."
        steam -applaunch "$appid" &>/dev/null &

        # Discover the game PID (shim writes it, or /proc scan)
        plog "Waiting for game process..."
        game_pid="$(harness_discover_game_pid "$appid" 30)" || {
            perr "Could not find game process within 30s"
            rm -f "$sentinel" 2>/dev/null || true
            return 1
        }
        launch_mode="steam"
        plog "Found game PID: $game_pid"
    fi

    plog "Game PID: $game_pid (pgid: $(ps -o pgid= -p $game_pid 2>/dev/null | tr -d ' ' || echo '?'))"

    # ── Monitor loop ──
    # Freeze heuristic (PM correction):
    #   PRIMARY: MangoHud frame progress (catches busy-spin freezes where CPU advances)
    #   SECONDARY: CPU ticks + context switches stasis (catches wait-hangs)
    #   BOOTED = frames advancing AND survived full timeout
    local prev_cpu=0 prev_ctx=0
    local prev_mhud_lines=0
    local frames_frozen_since=0 cpu_frozen_since=0
    local mhud_ever_seen=false
    local wall_start
    wall_start="$(date +%s)"

    while true; do
        sleep "$HARNESS_POLL_INTERVAL"
        local now
        now="$(date +%s)"
        elapsed=$((now - wall_start))

        # Check if process is still alive
        if ! kill -0 "$game_pid" 2>/dev/null; then
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
        local cur_ctx
        cur_ctx="$(harness_ctx_switches "$game_pid" 2>/dev/null)" || cur_ctx=0

        # ── MangoHud CSV check (PRIMARY freeze signal) ──
        local cur_mhud
        cur_mhud="$(harness_mangohud_advancing "$HARNESS_MANGOHUD_DIR" "$prev_mhud_lines" 2>/dev/null)" || cur_mhud="$prev_mhud_lines"

        if [[ "$cur_mhud" -gt 0 ]]; then
            mhud_ever_seen=true
        fi

        # ── Freeze detection (revised heuristic) ──
        local frame_stalled=false cpu_stalled=false

        # PRIMARY: frames not advancing (MangoHud). Catches BOTH wait-hangs AND busy-spins.
        if [[ "$mhud_ever_seen" == "true" ]] && [[ "$cur_mhud" -eq "$prev_mhud_lines" ]]; then
            frame_stalled=true
            if [[ "$frames_frozen_since" -eq 0 ]]; then
                frames_frozen_since="$now"
            elif [[ $((now - frames_frozen_since)) -ge $HARNESS_FREEZE_WINDOW ]]; then
                verdict="freeze"
                mangohud_frozen=true
                plog "No frame progress for ${HARNESS_FREEZE_WINDOW}s (MangoHud) → FREEZE"
                break
            fi
        else
            frames_frozen_since=0
        fi

        # SECONDARY: CPU ticks + context switches stasis (fallback when MangoHud unavailable)
        if [[ "$prev_cpu" -gt 0 ]] && [[ "$cur_cpu" -eq "$prev_cpu" ]] \
            && [[ "$cur_ctx" -eq "$prev_ctx" ]]; then
            cpu_stalled=true
            if [[ "$cpu_frozen_since" -eq 0 ]]; then
                cpu_frozen_since="$now"
            elif [[ $((now - cpu_frozen_since)) -ge $HARNESS_FREEZE_WINDOW ]]; then
                verdict="freeze"
                cpu_frozen=true
                # If MangoHud isn't available, this is the only signal — lower confidence
                if [[ "$mhud_ever_seen" != "true" ]]; then
                    plog "No CPU/ctxsw activity for ${HARNESS_FREEZE_WINDOW}s (no MangoHud) → FREEZE"
                else
                    plog "No CPU/ctxsw activity for ${HARNESS_FREEZE_WINDOW}s → FREEZE"
                fi
                break
            fi
        else
            cpu_frozen_since=0
        fi

        prev_cpu="$cur_cpu"
        prev_ctx="$cur_ctx"
        prev_mhud_lines="$cur_mhud"

        # ── Timeout = BOOTED ──
        # BOOTED requires frames advancing (if MangoHud available) AND surviving timeout
        if [[ $elapsed -ge $HARNESS_TIMEOUT ]]; then
            if [[ "$mhud_ever_seen" == "true" ]] && [[ "$frame_stalled" == "true" ]]; then
                # Reached timeout but frames aren't advancing — not a clean boot
                verdict="freeze"
                mangohud_frozen=true
                plog "Timeout reached but frames stalled → FREEZE"
            else
                verdict="booted"
                plog "Survived ${HARNESS_TIMEOUT}s → BOOTED"
            fi
            break
        fi
    done

    # ── Determine confidence ──
    if [[ "$has_mangohud" != "true" ]] && [[ -z "$HARNESS_MOCK" ]]; then
        confidence="medium"
    fi
    # Signals disagree: MangoHud says frozen but CPU advancing, or vice versa
    if [[ "$cpu_frozen" == "true" ]] && [[ "$mangohud_frozen" != "true" ]] \
        && [[ "$mhud_ever_seen" == "true" ]]; then
        confidence="low"
    fi
    if [[ "$mangohud_frozen" == "true" ]] && [[ "$cpu_frozen" != "true" ]]; then
        # This is actually the expected case for busy-spin hangs — still high confidence
        confidence="high"
    fi

    # ── Collect crash artifacts ──
    local dump_list
    dump_list="$(find "$HARNESS_CRASH_DIR" -name '*.dmp' 2>/dev/null | tr '\n' ',')"
    dump_list="${dump_list%,}"

    local proton_log="/tmp/steam-${appid}.log"
    if [[ -f "$proton_log" ]]; then
        proton_log_errors="$(grep -E 'err:seh:|Unhandled exception|page fault' "$proton_log" 2>/dev/null | head -5 | tr '\n' '; ')" || true
        proton_log_errors="${proton_log_errors%;}"
    fi

    game_log_json="$(harness_game_logs "$appid" "$game_dir" "$prefix_path" 2>/dev/null)" || game_log_json="{}"

    # ── Kill game if still running ──
    if kill -0 "$game_pid" 2>/dev/null; then
        plog "Killing game process tree..."
        harness_kill_tree "$game_pid" "$prefix_path"
    fi

    # ── Clean up sentinel ──
    rm -f "$HARNESS_RUN_DIR/${appid}.env" "$HARNESS_RUN_DIR/${appid}.pid" 2>/dev/null || true

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
              "$cpu_frozen" "$mangohud_frozen" "$game_log_json" \
              "$confidence" "$launch_mode" <<'PY'
import sys, json

vf, game, appid, verdict, elapsed, exit_code, dumps, proton_errs, \
    cpu_frozen, mhud_frozen, game_logs_raw, confidence, launch_mode = sys.argv[1:14]

result = {
    "game": game,
    "appid": appid,
    "verdict": verdict,
    "seconds": float(elapsed),
    "exit_code": int(exit_code),
    "confidence": confidence,
    "launch_mode": launch_mode,
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

# Mod toggle interface:
#   1. PRIMARY: overlayfs remount (via rework task's API) — fast, ~1s per toggle
#   2. LEGACY: file rename (.harness-disabled suffix) for unmanaged installs
harness_mod_disable() {
    local mod="$1"
    # TODO: check for overlayfs remount API from the rework task (task-28a069d6)
    # For now, fall back to file rename
    [[ -f "$mod" ]] && mv "$mod" "${mod}.harness-disabled" 2>/dev/null || true
}

harness_mod_enable() {
    local mod="$1"
    [[ -f "${mod}.harness-disabled" ]] && mv "${mod}.harness-disabled" "$mod" 2>/dev/null || true
}

harness_bisect() {
    local appid="$1"
    local game_name
    game_name="$(mods_game_name_of "$appid" 2>/dev/null)" || game_name="$appid"
    local game_dir
    game_dir="$(harness_game_dir "$appid" 2>/dev/null)" || {
        perr "Cannot find game directory for appid $appid"
        return 1
    }

    # Discover mods
    local manifest=""
    if declare -F asi_manifest_path >/dev/null 2>&1; then
        manifest="$(asi_manifest_path "$appid" 2>/dev/null)" || true
    fi

    local mod_list=()

    if [[ -n "$manifest" ]] && [[ -f "$manifest" ]]; then
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

    harness_bisect_recursive "$appid" "${mod_list[@]}"
}

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
        pok "Found the breaking mod: ${BOLD:-}$(basename "${mods[0]}")${NC:-}"
        echo "${mods[0]}"
        return 0
    fi

    local half=$((count / 2))
    local first_half=("${mods[@]:0:$half}")
    local second_half=("${mods[@]:$half}")

    plog ""
    plog "Bisecting: disabling first ${#first_half[@]} of $count mods..."

    for m in "${first_half[@]}"; do
        harness_mod_disable "$m"
    done

    local test_json
    test_json="$(harness_run "$appid")"
    local test_verdict
    test_verdict="$(echo "$test_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["verdict"])')"

    for m in "${first_half[@]}"; do
        harness_mod_enable "$m"
    done

    if [[ "$test_verdict" == "booted" ]]; then
        plog "Game booted with second half only → breaker is in the first half"
        harness_bisect_recursive "$appid" "${first_half[@]}"
    else
        plog "Game still broken → breaker is in the second half"
        harness_bisect_recursive "$appid" "${second_half[@]}"
    fi
}

# ─── CLI dispatch ─────────────────────────────────────────────────────────

harness_dispatch() {
    case "${1:-help}" in
        verify|test|check)     shift; harness_verify_cmd "$@" ;;
        bisect|find|search)    shift; harness_bisect_cmd "$@" ;;
        history|results|log)   shift; harness_history_cmd "$@" ;;
        setup)                 shift; harness_setup_cmd "$@" ;;
        help|--help|-h)        harness_help ;;
        *)                     perr "Unknown: powos mods verify $1"; harness_help; return 1 ;;
    esac
}

harness_verify_cmd() {
    local game="" timeout="" baseline=0 mock="" no_steam=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout|-t) shift; timeout="${1:-}" ;;
            --baseline|-b) baseline=1 ;;
            --mock) shift; mock="${1:-}" ;;
            --no-steam) no_steam=1 ;;
            --help|-h) harness_help; return 0 ;;
            setup)
                shift
                harness_setup_cmd "$@"
                return $?
                ;;
            -*) perr "Unknown flag: $1"; return 1 ;;
            *) [[ -z "$game" ]] && game="$1" || { perr "Unexpected arg: $1"; return 1; } ;;
        esac
        shift
    done

    [[ -z "$game" ]] && { perr "Usage: powos mods verify <game> [--timeout N] [--baseline] [--no-steam] [--mock PATH]"; return 1; }

    local appid
    appid="$(mods_appid_of "$game" 2>/dev/null)" || appid="$game"

    [[ -n "$timeout" ]] && HARNESS_TIMEOUT="$timeout"
    [[ "$baseline" -eq 1 ]] && HARNESS_BASELINE=1
    [[ -n "$mock" ]] && HARNESS_MOCK="$mock"
    [[ "$no_steam" -eq 1 ]] && HARNESS_NO_STEAM=1

    harness_run "$appid"
}

harness_setup_cmd() {
    local game="${1:-}"
    [[ -z "$game" ]] && { perr "Usage: powos mods verify setup <game>"; return 1; }

    local appid
    appid="$(mods_appid_of "$game" 2>/dev/null)" || appid="$game"

    harness_setup_shim "$appid"
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
    local BOLD=$'\033[1m' DIM=$'\033[2m' GREEN=$'\033[0;32m' RED=$'\033[0;31m'
    local YELLOW=$'\033[0;33m' NC=$'\033[0m'
    cat <<EOF
${BOLD}powos mods verify${NC} — headless mod-compatibility test harness

Launch a game in its Steam/Proton environment, monitor for crash/freeze,
and emit a machine-readable verdict.

${BOLD}Setup (one-time, per game):${NC}
  powos mods verify setup <game>               Install powos-game-shim into
                                                the game's Steam launch options.
                                                Steam must be CLOSED.

${BOLD}Verify (test a game boots):${NC}
  powos mods verify <game>                     Launch via Steam (default, 120s)
  powos mods verify <game> --timeout 60        Custom timeout
  powos mods verify <game> --baseline          Back up saves first
  powos mods verify <game> --no-steam          Use umu-run (DRM-free games only)
  powos mods verify <game> --mock /path/to/bin Use a mock binary (CI testing)

${BOLD}Bisect (find the breaking mod):${NC}
  powos mods bisect <game>                     Binary-search the mod set
  powos mods bisect <game> --timeout 60        Custom per-round timeout

${BOLD}History:${NC}
  powos mods verify history [game]             Show past verdicts

${BOLD}Verdicts:${NC}
  ${GREEN}booted${NC}   Game survived the timeout with frames advancing — it works
  ${RED}crash${NC}    Process exited with nonzero code
  ${YELLOW}freeze${NC}   Process alive but no frame progress (MangoHud) or CPU activity

${BOLD}Confidence:${NC}
  high     MangoHud available, signals agree
  medium   No MangoHud — CPU-only detection (misses busy-spin freezes)
  low      Signals disagree (investigate manually)

Verdict JSON is saved to:
  ~/.local/state/powos/mods/verify/<game>-<timestamp>.json

${BOLD}How it works:${NC}
  PRIMARY: launches via \`steam -applaunch\` with the powos-game-shim
  injecting MangoHud/PROTON_LOG/crash-report env. Satisfies Steamworks DRM.
  Frame progress (MangoHud CSV) is the primary freeze signal; CPU ticks +
  context switches are secondary. Game-specific logs (red4ext.log for CP2077)
  provide additional diagnostics.

  SECONDARY (--no-steam): launches via umu-run for DRM-free games.

${BOLD}Requirements:${NC}
  Real hardware:  Steam running, powos-game-shim setup, MangoHud (recommended)
  DRM-free:       umu-launcher (--no-steam mode)
  CI/Docker:      --mock flag with a test binary (no GPU needed)

${BOLD}Safety:${NC}
  - Refuses to run if the game is already running
  - Desktop should be idle-ish (gamescope nested window still composites)
  - --baseline backs up and restores saves automatically
EOF
}

# Resolve human-readable game name from appid.
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
