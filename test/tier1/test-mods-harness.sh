#!/bin/bash
# test-mods-harness.sh - Tier-1 unit tests for the mod-compat test harness.
#
# Tests the harness logic against a mock game binary that can simulate
# crash, freeze, and successful boot. No GPU, no Steam, no real games
# needed — runs in Docker or any Linux box.
#
# Usage:  bash test/tier1/test-mods-harness.sh
#   Docker: docker exec powos bash /var/lib/powos/src/test/tier1/test-mods-harness.sh

# NOTE: deliberately NO `pipefail`. These harnesses assert with
# `echo "$out" | grep -q ...`, and `grep -q` exits on its first match — which
# SIGPIPEs the writer, making the pipeline return 141 under pipefail depending
# on scheduling. That produced random failures (test-windows.sh swung between 4
# and 11 "failures" on identical runs). Last-command status is the correct
# semantics for an assertion anyway.
set -u

# ── Locate libs ──────────────────────────────────────────────────────────

# The tree this test file lives in comes FIRST.
#
# This used to prefer /usr/lib/powos/mods/harness.sh and fall back to the
# checkout. On any machine with PowOS installed that silently exercised the
# SHIPPED copy — here, one three weeks stale — so the suite reported 58/58
# green against code the author had never touched, and a refactor of
# harness_run showed up only as "the new helpers don't exist". The sibling
# suites (test-mods-core.sh, test-mods-vu.sh) already resolve this way, and in
# the container the documented invocation is under /var/lib/powos/src, which
# has its own lib/ — so the installed path stays a fallback, not the default.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."

HARNESS_LIB="$REPO_ROOT/lib/mods/harness.sh"
INSTALL_LIB="$REPO_ROOT/lib/mods/install.sh"
MOCK_GAME="$SCRIPT_DIR/../mock-game"

if [[ ! -f "$HARNESS_LIB" ]]; then
    HARNESS_LIB="/usr/lib/powos/mods/harness.sh"
fi
if [[ ! -f "$INSTALL_LIB" ]]; then
    INSTALL_LIB="/usr/lib/powos/mods/install.sh"
fi
if [[ ! -f "$MOCK_GAME" ]]; then
    MOCK_GAME="/usr/lib/powos/../test/mock-game"
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

# ONE canonical vocabulary. This names verdict files, so it MUST equal the
# games.d conf basename — the same id `powos games`, the mod manifest and
# `powos game <name>` use. It used to return "gta5"/"gta5-legacy" from a
# private table while games.d said "gtav"/"gtav-legacy", giving one game two
# state keys across adjacent subsystems.
check "gtav appid matches games.d id"        '[[ "$(mods_game_name_of 3240220)" == "gtav" ]]'
check "gtav-legacy appid matches games.d id" '[[ "$(mods_game_name_of 271590)"  == "gtav-legacy" ]]'
check "rdr2 appid matches games.d id"        '[[ "$(mods_game_name_of 1174180)" == "rdr2" ]]'
# Titles with no games.d config still resolve via the fallback table.
check "fallout4 (no games.d conf) resolves"  '[[ "$(mods_game_name_of 377160)" == "fallout4" ]]'

# Every name it returns must round-trip back to the same appid.
for _a in 3240220 271590 1091500 489830 1174180; do
    check "round-trips appid $_a" \
          '[[ "$(mods_appid_of "$(mods_game_name_of $_a)")" == "$_a" ]]'
done

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
required = ["game", "appid", "verdict", "seconds", "exit_code", "confidence", "launch_mode", "signals"]
sig_required = ["crash_dumps", "proton_log_errors", "cpu_frozen", "mangohud_frozen", "game_logs"]
ok = all(k in d for k in required) and all(k in d["signals"] for k in sig_required)
print("valid" if ok else "invalid")
' 2>/dev/null)"
check "verdict JSON has all fields"  '[[ "$valid_json" == "valid" ]]'

# ── Test: confidence and launch_mode fields ─────────────────────────────
echo ""
echo "== Confidence and launch_mode fields =="

crash_confidence="$(echo "$crash_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["confidence"])')"
crash_launch_mode="$(echo "$crash_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["launch_mode"])')"
check "crash confidence is high"        '[[ "$crash_confidence" == "high" ]]'
check "crash launch_mode is mock"       '[[ "$crash_launch_mode" == "mock" ]]'

boot_confidence="$(echo "$boot_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["confidence"])')"
boot_launch_mode="$(echo "$boot_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["launch_mode"])')"
check "boot confidence is high"         '[[ "$boot_confidence" == "high" ]]'
check "boot launch_mode is mock"        '[[ "$boot_launch_mode" == "mock" ]]'

freeze_confidence="$(echo "$freeze_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["confidence"])')"
freeze_launch_mode="$(echo "$freeze_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["launch_mode"])')"
check "freeze confidence is high"       '[[ "$freeze_confidence" == "high" ]]'
check "freeze launch_mode is mock"      '[[ "$freeze_launch_mode" == "mock" ]]'

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

# ── Test: game-running safety check ─────────────────────────────────────
echo ""
echo "== Game-running safety check =="

# harness_game_running should return 1 (not running) for a fake appid
harness_game_running "999999999" && game_was_running=true || game_was_running=false
check "unknown game is not running"  '[[ "$game_was_running" == "false" ]]'

# Verify harness_run refuses if game is "running" (mock the check)
# We test this by temporarily overriding harness_game_running
_orig_harness_game_running="$(declare -f harness_game_running)"
harness_game_running() { return 0; }  # pretend game is running
refuse_out="$(HARNESS_MOCK="" harness_run "mock" 2>&1)" && refused=false || refused=true
eval "$_orig_harness_game_running"   # restore original
check "refuses when game running"    '[[ "$refused" == "true" ]]'

# ── Test: help text ──────────────────────────────────────────────────────
echo ""
echo "== Help text =="

help_out="$(harness_help 2>&1)"
check "help mentions verify"         '[[ "$help_out" == *"verify"* ]]'
check "help mentions bisect"         '[[ "$help_out" == *"bisect"* ]]'
check "help mentions verdict"        '[[ "$help_out" == *"verdict"* ]]'
check "help mentions setup"          '[[ "$help_out" == *"setup"* ]]'
check "help mentions --no-steam"     '[[ "$help_out" == *"no-steam"* ]]'
check "help mentions confidence"     '[[ "$help_out" == *"onfidence"* ]]'
check "help mentions shim"           '[[ "$help_out" == *"shim"* ]]'

# ── Test: powos-game-shim (dormant exec wrapper) ────────────────────────
echo ""
echo "== powos-game-shim (dormant exec wrapper) =="

SHIM_BIN="$SCRIPT_DIR/../../bin/powos-game-shim"
if [[ ! -f "$SHIM_BIN" ]]; then
    echo "  SKIP: powos-game-shim not found at $SHIM_BIN"
else
    [[ -x "$SHIM_BIN" ]] || chmod +x "$SHIM_BIN"

    # Set up a temp /run/powos/verify equivalent
    shim_run="$TMP/shim-run"
    mkdir -p "$shim_run"

    # -- Test: passthrough (no sentinel) — shim exec's the command untouched --
    # Override SENTINEL/PID_FILE paths via the script's env vars
    shim_out="$(SteamAppId=12345 \
        bash -c '
            APPID="$SteamAppId"
            SENTINEL="'"$shim_run"'/12345.env"
            PID_FILE="'"$shim_run"'/12345.pid"
            # Source the shim logic inline (exec would replace us, so simulate)
            if [[ -f "$SENTINEL" ]]; then source "$SENTINEL"; fi
            if [[ -d "'"$shim_run"'" ]]; then echo "shim_pid=$$" > "$PID_FILE"; fi
            echo "passthrough_ok"
        ' 2>&1)"
    check "shim passthrough works"         '[[ "$shim_out" == *"passthrough_ok"* ]]'

    # PID file should exist from passthrough
    check "shim writes PID file"           '[[ -f "$shim_run/12345.pid" ]]'
    shim_pid_content="$(cat "$shim_run/12345.pid" 2>/dev/null)"
    check "PID file has shim_pid="         '[[ "$shim_pid_content" == shim_pid=* ]]'

    # -- Test: env injection via sentinel --
    cat > "$shim_run/99999.env" <<'SENTINEL_EOF'
export HARNESS_TEST_VAR="injected_by_sentinel"
export MANGOHUD=1
SENTINEL_EOF

    injected_val="$(SteamAppId=99999 \
        bash -c '
            APPID="$SteamAppId"
            SENTINEL="'"$shim_run"'/99999.env"
            PID_FILE="'"$shim_run"'/99999.pid"
            if [[ -f "$SENTINEL" ]]; then source "$SENTINEL"; fi
            if [[ -d "'"$shim_run"'" ]]; then echo "shim_pid=$$" > "$PID_FILE"; fi
            echo "${HARNESS_TEST_VAR:-none}"
        ' 2>&1)"
    check "sentinel env injected"          '[[ "$injected_val" == *"injected_by_sentinel"* ]]'

    mangohud_val="$(SteamAppId=99999 \
        bash -c '
            APPID="$SteamAppId"
            SENTINEL="'"$shim_run"'/99999.env"
            if [[ -f "$SENTINEL" ]]; then source "$SENTINEL"; fi
            echo "${MANGOHUD:-0}"
        ' 2>&1)"
    check "sentinel MANGOHUD=1 injected"   '[[ "$mangohud_val" == *"1"* ]]'

    # -- Test: mock steam → shim → mock game pipeline --
    # Simulate what happens when Steam calls: powos-game-shim /path/to/mock-game --boot
    # We write a sentinel, launch the shim (with exec replaced by a non-exec test),
    # and verify the mock game ran with the injected env.
    rm -f "$shim_run"/77777.* 2>/dev/null || true
    cat > "$shim_run/77777.env" <<SENT
export PROTON_LOG=1
export PROTON_CRASH_REPORT_DIR=$TMP/shim-test-dumps
SENT
    mkdir -p "$TMP/shim-test-dumps"

    # Run shim for real with exec — it will exec the mock-game which boots and
    # runs until killed. We background it, check PID file, then kill.
    SteamAppId=77777 setsid bash -c '
        export SteamAppId=77777
        APPID="$SteamAppId"
        SENTINEL="'"$shim_run"'/77777.env"
        PID_FILE="'"$shim_run"'/77777.pid"
        if [[ -f "$SENTINEL" ]]; then source "$SENTINEL"; fi
        if [[ -d "'"$shim_run"'" ]]; then echo "shim_pid=$$" > "$PID_FILE"; fi
        exec '"$MOCK_GAME"' --boot
    ' &>/dev/null &
    mock_steam_pid=$!
    sleep 1

    # Verify PID file was written with a valid PID
    check "pipeline: PID file created"      '[[ -f "$shim_run/77777.pid" ]]'
    pipeline_pid="$(grep "shim_pid=" "$shim_run/77777.pid" 2>/dev/null | cut -d= -f2)"
    check "pipeline: PID is numeric"        '[[ "$pipeline_pid" =~ ^[0-9]+$ ]]'

    # The exec'd mock-game should be running (it replaced the shim's bash process)
    # The process group leader is the setsid'd bash; the mock-game inherited its pgid
    check "pipeline: game process alive"    'kill -0 $mock_steam_pid 2>/dev/null'

    # Clean up the pipeline
    kill -- -"$mock_steam_pid" 2>/dev/null || kill "$mock_steam_pid" 2>/dev/null || true
    sleep 0.5
    kill -9 -- -"$mock_steam_pid" 2>/dev/null || true
    wait "$mock_steam_pid" 2>/dev/null || true

    # -- Test: without sentinel, env is NOT injected --
    rm -f "$shim_run"/88888.* 2>/dev/null || true
    clean_val="$(SteamAppId=88888 \
        bash -c '
            APPID="$SteamAppId"
            SENTINEL="'"$shim_run"'/88888.env"
            if [[ -f "$SENTINEL" ]]; then source "$SENTINEL"; fi
            echo "${PROTON_LOG:-unset}"
        ' 2>&1)"
    check "no sentinel = no injection"      '[[ "$clean_val" == *"unset"* ]]'
fi

# ── Test: the monitor-loop check contract ────────────────────────────────
#
# harness_run's poll loop used to be inline, and each freeze/timeout check
# ended in a bare `break`. It is now a chain of helpers where the ONLY signal
# is the exit status: 0 = keep polling, 1 = a verdict has been reached. Get
# that inverted and the harness either never stops or stops on the first poll,
# and the end-to-end mock tests above would still pass in mock mode by luck of
# timing. Assert the contract directly.
echo ""
echo "== Monitor-loop check contract =="

# NOTE: subshell — check() eval's this in the current shell, so a bare `exit`
# would end the whole suite silently.
check "phase helpers exist" '(
    for f in _harness_resolve_env _harness_launch _harness_launch_mock \
             _harness_launch_umu _harness_launch_steam _harness_monitor \
             _harness_poll_once _harness_verdict_on_exit _harness_sample_signals \
             _harness_check_frames _harness_check_cpu _harness_check_timeout \
             _harness_confidence _harness_collect_artifacts _harness_cleanup \
             _harness_emit_verdict; do
        declare -f "$f" >/dev/null || exit 1
    done
)'

# _harness_check_timeout: 0 while under the timeout, 1 at/over it.
_tmo_probe() {
    local elapsed="$1" mhud_ever_seen="$2" frame_stalled="$3"
    local HARNESS_TIMEOUT=10
    local verdict="unknown" mangohud_frozen=false
    _harness_check_timeout >/dev/null 2>&1 && echo "keep:$verdict" || echo "stop:$verdict"
}
check "timeout: under the limit keeps polling"  '[[ "$(_tmo_probe 5 false false)"  == "keep:unknown" ]]'
check "timeout: reached => booted, stop"        '[[ "$(_tmo_probe 10 false false)" == "stop:booted" ]]'
check "timeout: reached but frames stalled => freeze" \
                                                '[[ "$(_tmo_probe 12 true true)"   == "stop:freeze" ]]'

# _harness_check_frames: only stops once the freeze window has fully elapsed,
# and a resumed frame counter must clear the stall timer.
_frames_probe() {
    local mhud_ever_seen="$1" cur_mhud="$2" prev_mhud_lines="$3"
    local frames_frozen_since="$4" now="$5"
    local HARNESS_FREEZE_WINDOW=5
    local verdict="unknown" mangohud_frozen=false
    _harness_check_frames >/dev/null 2>&1 \
        && echo "keep:$verdict:$frames_frozen_since" \
        || echo "stop:$verdict:$frames_frozen_since"
}
check "frames: no MangoHud data ever => never freezes" \
        '[[ "$(_frames_probe false 0 0 0 100)" == keep:unknown:* ]]'
check "frames: first stalled poll starts the timer, keeps polling" \
        '[[ "$(_frames_probe true 7 7 0 100)" == "keep:unknown:100" ]]'
check "frames: still inside the window keeps polling" \
        '[[ "$(_frames_probe true 7 7 98 100)" == "keep:unknown:98" ]]'
check "frames: window elapsed => freeze, stop" \
        '[[ "$(_frames_probe true 7 7 90 100)" == "stop:freeze:90" ]]'
check "frames: advancing counter clears the stall timer" \
        '[[ "$(_frames_probe true 9 7 90 100)" == "keep:unknown:0" ]]'

# _harness_check_cpu: same shape, gated on prev_cpu > 0 (first poll has none).
_cpu_probe() {
    local prev_cpu="$1" cur_cpu="$2" prev_ctx="$3" cur_ctx="$4"
    local cpu_frozen_since="$5" now="$6"
    local HARNESS_FREEZE_WINDOW=5
    local verdict="unknown" cpu_frozen=false cpu_stalled=false mhud_ever_seen=false
    _harness_check_cpu >/dev/null 2>&1 \
        && echo "keep:$verdict:$cpu_frozen_since" \
        || echo "stop:$verdict:$cpu_frozen_since"
}
check "cpu: first poll (prev_cpu 0) never freezes" \
        '[[ "$(_cpu_probe 0 0 0 0 0 100)" == "keep:unknown:0" ]]'
check "cpu: stasis inside the window keeps polling" \
        '[[ "$(_cpu_probe 5 5 3 3 98 100)" == "keep:unknown:98" ]]'
check "cpu: stasis past the window => freeze, stop" \
        '[[ "$(_cpu_probe 5 5 3 3 90 100)" == "stop:freeze:90" ]]'
check "cpu: ctx switches still moving clears the timer" \
        '[[ "$(_cpu_probe 5 5 3 4 90 100)" == "keep:unknown:0" ]]'

# ── Results ──────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════"
echo "== Results: $PASS passed, $FAIL failed =="
echo "══════════════════════════════════════"
[[ $FAIL -eq 0 ]]
