#!/usr/bin/env bash
# test-stream-capture.sh — PowStream capture must be PER-GAME opt-in, never
# session-global (a global enable loads the game-memory-hooking Vulkan layer into
# every title, incl. anti-cheat = ban risk). Guards the safety-critical bits of
# lib/stream.sh's per-game controls.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export POWOS_LIB="$ROOT/lib"
export XDG_CONFIG_HOME="$(mktemp -d)"; trap 'rm -rf "$XDG_CONFIG_HOME"' EXIT

# minimal helper stubs if common.sh doesn't provide them
source "$ROOT/lib/common.sh" 2>/dev/null || true
for fn in plog pok perr pwarn; do declare -f "$fn" >/dev/null 2>&1 || eval "$fn(){ :; }"; done
source "$ROOT/lib/stream.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

echo "== stream capture: per-game safety =="

# 1. The kill-switch env for anti-cheat launchers is exactly right.
env="$(stream_safe_env)"
[[ "$env" == *"POWSTREAM_CAPTURE_DISABLE=1"* ]] && ok "safe-env disables capture" || bad "safe-env missing DISABLE"
[[ "$env" == *"VK_LOADER_LAYERS_DISABLE=VK_LAYER_POWSTREAM_capture"* ]] && ok "safe-env disables the loader layer" || bad "safe-env missing loader disable"

# 2. Supported registry: GTA tested, RDR2/Cyberpunk in dev, aliases resolve.
[[ "$(_stream_support_status gta)" == tested ]]        && ok "gta → tested"        || bad "gta status"
[[ "$(_stream_support_status gtav)" == tested ]]       && ok "gtav → tested"       || bad "gtav status"
[[ "$(_stream_support_status gta5)" == tested ]]       && ok "gta5 alias → tested" || bad "gta5 alias"
[[ "$(_stream_support_status rdr2)" == dev ]]          && ok "rdr2 → dev"          || bad "rdr2 status"
[[ "$(_stream_support_status cyberpunk)" == dev ]]     && ok "cyberpunk alias → dev" || bad "cyberpunk alias"
[[ "$(_stream_support_status cyberpunk2077)" == dev ]] && ok "cyberpunk2077 → dev" || bad "cyberpunk2077 status"
[[ -z "$(_stream_support_status randomgame)" ]]        && ok "unknown game → no status" || bad "unknown status"

# 3. enable records to the allowlist; warns on dev/unknown (still records).
stream_enable gta >/dev/null 2>&1
grep -qx gta "$STREAM_GAMES_LIST" 2>/dev/null && ok "enable records the game" || bad "enable did not record"
warn="$(stream_enable somerandom 2>&1)"
printf '%s' "$warn" | grep -qi "known" && ok "enable warns on unsupported game" || bad "no unsupported warning"

# 4. steam-option prints the per-game launch string (not a global export).
so="$(stream_steam_option)"
printf '%s' "$so" | grep -q 'POWSTREAM_CAPTURE=1 %command%' && ok "steam-option is per-game (%command%)" || bad "steam-option wrong"

# 5. launch requires a command (no accidental no-op).
stream_launch >/dev/null 2>&1 && bad "launch ran with no command" || ok "launch guards empty command"

# 6. The overlay must NOT ship a global enable (mirrors test-powstream-overlay).
if grep -qE "^[[:space:]]*POWSTREAM_CAPTURE=1" "$ROOT/sources/powstream/build.sh"; then
    # allowed only inside the heredoc as a COMMENTED example
    grep -E "POWSTREAM_CAPTURE=1" "$ROOT/sources/powstream/build.sh" | grep -qvE '^\s*#' \
        && bad "build.sh still writes a global POWSTREAM_CAPTURE=1" || ok "build.sh global enable is commented only"
else
    ok "build.sh has no active global POWSTREAM_CAPTURE=1"
fi

echo
echo "stream-capture: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
