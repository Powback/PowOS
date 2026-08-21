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

# 5b. launch builds the right env. stream_launch exec's `env`; shadow it with a
#     stub that prints the argv so we can inspect what would run. plog → no-op so
#     it doesn't pollute the captured output.
plog(){ :; }
STUBDIR="$(mktemp -d)"
cat > "$STUBDIR/env" <<'E'
#!/usr/bin/env bash
printf '%s\n' "$@"
E
chmod +x "$STUBDIR/env"

# --game NAME sets POWSTREAM_GAME (native games have no .exe to self-name from).
out="$(PATH="$STUBDIR:$PATH" stream_launch --game minecraft -- thegame --arg 2>/dev/null)"
printf '%s\n' "$out" | grep -qx 'POWSTREAM_GAME=minecraft' && ok "--game sets POWSTREAM_GAME" || bad "--game did not set POWSTREAM_GAME"
printf '%s\n' "$out" | grep -qx 'POWSTREAM_CAPTURE=1'      && ok "launch still enables capture" || bad "launch lost POWSTREAM_CAPTURE"
printf '%s\n' "$out" | grep -qx 'thegame'                 && ok "launch passes the command through" || bad "command not passed through"

# REGRESSION: the enable path must NEVER *define* POWSTREAM_CAPTURE_DISABLE (even
# empty). The Vulkan loader disables an implicit layer whenever its
# disable_environment var exists, so `POWSTREAM_CAPTURE_DISABLE=` silently
# disabled the capture layer — capture never engaged via `powos stream launch`.
# It must instead REMOVE it from the child env (`env -u POWSTREAM_CAPTURE_DISABLE`).
printf '%s\n' "$out" | grep -q 'POWSTREAM_CAPTURE_DISABLE=' && bad "enable path defines POWSTREAM_CAPTURE_DISABLE (disables the layer!)" || ok "enable path never defines POWSTREAM_CAPTURE_DISABLE"
printf '%s\n' "$out" | grep -qx -- '-u' && printf '%s\n' "$out" | grep -qx 'POWSTREAM_CAPTURE_DISABLE' \
  && ok "enable path unsets an inherited POWSTREAM_CAPTURE_DISABLE (env -u)" || bad "enable path does not clear inherited kill-switch"

# REGRESSION (second gate): the layer's streaming_active() keeps it dormant
# (inserted, hooking nothing, no frames) until a sentinel file OR a force flag is
# present. Nothing in the PowOS integration creates the sentinel, so the enable
# path must set POWSTREAM_FORCE_ACTIVE=1 or `powos stream launch` captures nothing.
printf '%s\n' "$out" | grep -qx 'POWSTREAM_FORCE_ACTIVE=1' && ok "enable path wakes the layer (POWSTREAM_FORCE_ACTIVE=1)" || bad "enable path leaves the layer dormant (no FORCE_ACTIVE)"

# Without --game, POWSTREAM_GAME must NOT leak (Proton titles self-name from .exe).
out2="$(PATH="$STUBDIR:$PATH" stream_launch -- thegame 2>/dev/null)"
printf '%s\n' "$out2" | grep -q 'POWSTREAM_GAME' && bad "POWSTREAM_GAME set without --game" || ok "no POWSTREAM_GAME without --game"
rm -rf "$STUBDIR"

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
