#!/bin/bash
# test-mods-harness.sh - Tier-1 unit tests for the mod-compat test harness.
#
# Tests the harness logic against a mock game binary that can simulate
# crash, freeze, and successful boot. No GPU, no Steam, no real games
# needed — runs in Docker or any Linux box.
#
# Usage:  bash test/tier1/test-mods-harness.sh
#   Docker: docker exec powos bash /var/lib/powos/src/test/tier1/test-mods-harness.sh

set -uo pipefail

# ── Locate libs ──────────────────────────────────────────────────────────

HARNESS_LIB="/usr/lib/powos/mods/harness.sh"
INSTALL_LIB="/usr/lib/powos/mods/install.sh"
MOCK_GAME="/usr/lib/powos/../test/mock-game"   # installed path

# Dev-tree fallback
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$HARNESS_LIB" ]]; then
    HARNESS_LIB="$SCRIPT_DIR/../../lib/mods/harness.sh"
fi
if [[ ! -f "$INSTALL_LIB" ]]; then
    INSTALL_LIB="$SCRIPT_DIR/../../lib/mods/install.sh"
fi
if [[ ! -f "$MOCK_GAME" ]]; then
    MOCK_GAME="$SCRIPT_DIR/../mock-game"
fi

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

echo "== test-mods-harness.sh =="

# ── Pre-flight ───────────────────────────────────────────────────────────

if [[ ! -f "$MOCK_GAME" ]]; then
    echo "SKIP: mock-game not found at $MOCK_GAME"
    exit 0
fi
if [[ ! -x "$MOCK_GAME" ]]; then
    chmod +x "$MOCK_GAME"
fi

# Source install.sh first (harness.sh expects mods_appid_of etc.)
echo "== Sourcing install lib: $INSTALL_LIB =="
# shellcheck disable=SC1090
source "$INSTALL_LIB" || { echo "cannot source install lib"; exit 1; }

echo "== Sourcing harness lib: $HARNESS_LIB =="
# shellcheck disable=SC1090
source "$HARNESS_LIB" || { echo "cannot source harness lib"; exit 1; }

check "sourcing does not enable errexit" '[[ $- != *e* ]]'

TMP=$(mktemp -d)
cleanup() { kill $(jobs -p) 2>/dev/null || true; wait 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

# Override state dirs to use temp
export HARNESS_STATE_DIR="$TMP/state"
export HARNESS_CRASH_DIR="$TMP/dumps"
export HARNESS_MANGOHUD_DIR="$TMP/mangohud"
mkdir -p "$HARNESS_STATE_DIR" "$HARNESS_CRASH_DIR" "$HARNESS_MANGOHUD_DIR"

# ── Test: mods_game_name_of ──────────────────────────────────────────────
echo ""
echo "== Game name resolution =="

check "cyberpunk appid resolves"  '[[ "$(mods_game_name_of 1091500)" == "cyberpunk2077" ]]'
check "skyrim appid resolves"     '[[ "$(mods_game_name_of 489830)" == "skyrimse" ]]'
check "unknown appid passes through" '[[ "$(mods_game_name_of 999999)" == "999999" ]]'

# ── Test: harness_cpu_ticks (on ourselves) ───────────────────────────────
echo ""
echo "== CPU ticks reading =="

# Burn some CPU first so we have nonzero ticks for our own PID
i=0; while [[ $i -lt 200000 ]]; do i=$((i+1)); done
my_pid=$$
ticks="$(harness_cpu_ticks $my_pid)"
check "cpu ticks is numeric"       '[[ "$ticks" =~ ^[0-9]+$ ]]'
check "cpu ticks is non-negative"  '[[ "$ticks" -ge 0 ]]'

# ── Test: harness_ctx_switches (on ourselves) ────────────────────────────
echo ""
echo "== Context switches reading =="

ctx="$(harness_ctx_switches $my_pid)"
check "ctx switches is numeric"    '[[ "$ctx" =~ ^[0-9]+$ ]]'
check "ctx switches is positive"   '[[ "$ctx" -gt 0 ]]'

# ── Test: CPU ticks advance ──────────────────────────────────────────────
echo ""
echo "== CPU ticks advance detection =="

t0="$(harness_cpu_ticks $my_pid)"
# Burn some CPU
i=0; while [[ $i -lt 500000 ]]; do i=$((i+1)); done
t1="$(harness_cpu_ticks $my_pid)"
check "cpu ticks advanced after work" '[[ "$t1" -gt "$t0" ]]'

# ── Test: MangoHud CSV advancing ─────────────────────────────────────────
echo ""
echo "== MangoHud CSV advancing =="

mhud_dir="$TMP/mangohud-test"
mkdir -p "$mhud_dir"

# No CSV yet
count="$(harness_mangohud_advancing "$mhud_dir" 0)"
check "no csv returns 0 count"     '[[ "$count" -eq 0 ]]'

# Create a CSV with some lines
printf "fps,frametime\n30,33.3\n60,16.6\n" > "$mhud_dir/test.csv"
count="$(harness_mangohud_advancing "$mhud_dir" 0)"
check "csv with 3 lines returns 3" '[[ "$count" -eq 3 ]]'

# Same count = not advancing
harness_mangohud_advancing "$mhud_dir" 3 && stalled=false || stalled=true
check "stalled when count unchanged" '[[ "$stalled" == "true" ]]'

# Add a line = advancing
echo "45,22.2" >> "$mhud_dir/test.csv"
harness_mangohud_advancing "$mhud_dir" 3 && advancing=true || advancing=false
check "advancing when new lines"    '[[ "$advancing" == "true" ]]'

# ── Test: CRASH detection (mock game) ────────────────────────────────────
echo ""
echo "== CRASH detection =="

export HARNESS_MOCK="$MOCK_GAME"
export HARNESS_TIMEOUT=30
export HARNESS_FREEZE_WINDOW=10
export HARNESS_POLL_INTERVAL=1
export HARNESS_BASELINE=0

# Override mods_appid_of for mock
mods_appid_of() { echo "mock"; }

crash_json="$(HARNESS_MOCK="$MOCK_GAME --crash --delay 1" harness_run "mock" 2>/dev/null)"
crash_verdict="$(echo "$crash_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["verdict"])')"
crash_code="$(echo "$crash_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["exit_code"])')"

check "crash detected"               '[[ "$crash_verdict" == "crash" ]]'
check "crash exit code is 139"        '[[ "$crash_code" == "139" ]]'

# Verify verdict file was written
crash_files="$(ls "$HARNESS_STATE_DIR"/mock-*.json 2>/dev/null | wc -l)"
check "verdict file written"          '[[ "$crash_files" -ge 1 ]]'

# ── Test: BOOTED detection (mock game, short timeout) ────────────────────
echo ""
echo "== BOOTED detection =="

rm -f "$HARNESS_STATE_DIR"/*.json 2>/dev/null || true

boot_json="$(HARNESS_MOCK="$MOCK_GAME --boot" HARNESS_TIMEOUT=5 harness_run "mock" 2>/dev/null)"
boot_verdict="$(echo "$boot_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["verdict"])')"
boot_seconds="$(echo "$boot_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["seconds"])')"

check "boot detected"                '[[ "$boot_verdict" == "booted" ]]'
check "boot ran for >= 5 seconds"     '[[ "$(echo "$boot_seconds >= 4" | bc -l 2>/dev/null || python3 -c "print(1 if $boot_seconds >= 4 else 0)")" == "1" ]]'

# ── Test: FREEZE detection (mock game) ───────────────────────────────────
echo ""
echo "== FREEZE detection =="

rm -f "$HARNESS_STATE_DIR"/*.json 2>/dev/null || true

# Freeze after 1s, detect after FREEZE_WINDOW (5s for test speed)
freeze_json="$(HARNESS_MOCK="$MOCK_GAME --freeze --delay 1" HARNESS_FREEZE_WINDOW=5 HARNESS_TIMEOUT=60 harness_run "mock" 2>/dev/null)"
freeze_verdict="$(echo "$freeze_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["verdict"])')"
freeze_cpu="$(echo "$freeze_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["signals"]["cpu_frozen"])')"

check "freeze detected"              '[[ "$freeze_verdict" == "freeze" ]]'
check "cpu_frozen signal is true"     '[[ "$freeze_cpu" == "True" ]]'

# ── Test: game log parsing ───────────────────────────────────────────────
echo ""
echo "== Game log parsing =="

# Create a fake game dir with Cyberpunk log files
cp_dir="$TMP/fakegame"
cp_prefix="$TMP/fakeprefix"
mkdir -p "$cp_dir/red4ext/logs" "$cp_prefix/pfx/drive_c"

echo '[info] RED4ext has been successfully initialized
[info] Loading plugins...
[error] FAILED_TO_LOAD: MyBrokenMod.dll
[info] Done.' > "$cp_dir/red4ext/logs/red4ext.log"

log_json="$(harness_game_logs "1091500" "$cp_dir" "$cp_prefix")"
has_error="$(echo "$log_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("yes" if "FAILED_TO_LOAD" in d.get("red4ext.log","") else "no")')"
check "red4ext fatal pattern found"  '[[ "$has_error" == "yes" ]]'

# Clean log (no errors)
echo '[info] RED4ext has been successfully initialized
[info] Loading plugins...
[info] Done.' > "$cp_dir/red4ext/logs/red4ext.log"

log_json2="$(harness_game_logs "1091500" "$cp_dir" "$cp_prefix")"
has_error2="$(echo "$log_json2" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("yes" if d.get("red4ext.log","").strip() else "no")')"
check "clean log has no fatals"      '[[ "$has_error2" == "no" ]]'

# ── Test: verdict JSON structure ─────────────────────────────────────────
echo ""
echo "== Verdict JSON structure =="

# Use the crash JSON from earlier
valid_json="$(echo "$crash_json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
required = ["game", "appid", "verdict", "seconds", "exit_code", "signals"]
sig_required = ["crash_dumps", "proton_log_errors", "cpu_frozen", "mangohud_frozen", "game_logs"]
ok = all(k in d for k in required) and all(k in d["signals"] for k in sig_required)
print("valid" if ok else "invalid")
' 2>/dev/null)"
check "verdict JSON has all fields"  '[[ "$valid_json" == "valid" ]]'

# ── Test: kill tree (simple process) ─────────────────────────────────────
echo ""
echo "== Process tree kill =="

# Use setsid so the sleeper gets its own pgid (avoid killing the test itself)
setsid sleep 3600 &
sleeper_pid=$!
sleep 0.2
check "sleeper is alive"             'kill -0 $sleeper_pid 2>/dev/null'
harness_kill_tree "$sleeper_pid" "" 2>/dev/null
sleep 1
kill -0 "$sleeper_pid" 2>/dev/null && sleeper_dead=false || sleeper_dead=true
check "sleeper killed"               '[[ "$sleeper_dead" == "true" ]]'

# ── Test: help text ──────────────────────────────────────────────────────
echo ""
echo "== Help text =="

help_out="$(harness_help 2>&1)"
check "help mentions verify"         '[[ "$help_out" == *"verify"* ]]'
check "help mentions bisect"         '[[ "$help_out" == *"bisect"* ]]'
check "help mentions verdict"        '[[ "$help_out" == *"verdict"* ]]'

# ── Results ──────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════"
echo "== Results: $PASS passed, $FAIL failed =="
echo "══════════════════════════════════════"
[[ $FAIL -eq 0 ]]
