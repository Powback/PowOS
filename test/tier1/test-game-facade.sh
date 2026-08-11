#!/bin/bash
# test-game-facade.sh - Tier-1 tests for `powos game <name> <verb>`.
#
# The facade owns no state — its whole job is name resolution and dispatch,
# so that's what these test: does every spelling of a game reach the right
# canonical id, does the collection listing survive missing subsystems, and
# does every verb the help promises actually resolve to a real function.
#
# That last one matters most: a facade that documents a verb it can't
# dispatch is worse than no facade. This suite is the guard against the exact
# class of bug found in `powos mods` (help promised `snapshot`; nothing was
# wired to it).
#
# Usage:  bash test/tier1/test-game-facade.sh

# NOTE: deliberately NO `pipefail`. These harnesses assert with
# `echo "$out" | grep -q ...`, and `grep -q` exits on its first match — which
# SIGPIPEs the writer, making the pipeline return 141 under pipefail depending
# on scheduling. That produced random failures (test-windows.sh swung between 4
# and 11 "failures" on identical runs). Last-command status is the correct
# semantics for an assertion anyway.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
GAME_LIB="$REPO_ROOT/lib/game.sh"
[[ -f "$GAME_LIB" ]] || GAME_LIB="/usr/lib/powos/game.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
skip() { echo "  skip - $1"; SKIP=$((SKIP+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

echo "== test-game-facade.sh =="
[[ -f "$GAME_LIB" ]] || { echo "FATAL: game.sh not found"; exit 1; }

export POWOS_LIB="$REPO_ROOT/lib"
source "$GAME_LIB" >/dev/null 2>&1
# install.sh carries the alias table (mods_appid_of) the resolver leans on.
source "$REPO_ROOT/lib/mods/core.sh"    >/dev/null 2>&1 || true
( export HOME="$(mktemp -d)"; : )  # keep install.sh's HOME-derived paths tame
source "$REPO_ROOT/lib/mods/install.sh" >/dev/null 2>&1 || true

plog() { :; }; pok() { :; }; pwarn() { :; }; perr() { :; }

echo
echo "-- registry --"

IDS="$(game_registry_ids | tr '\n' ' ')"
check "registry is non-empty"          '[[ -n "$IDS" ]]'
for g in cyberpunk2077 gtav gtav-legacy rdr2 skyrimse; do
    check "registry contains $g"       'grep -qw "$g" <<< "$IDS"'
done
check "conf path resolves for gtav"    'game_conf_path gtav >/dev/null'
check "conf path fails for nonsense"   '! game_conf_path nonsense-game >/dev/null 2>&1'

echo
echo "-- conf reading (no sourcing, no var bleed) --"

check "reads GAME_NAME"    '[[ "$(game_conf_get gtav GAME_NAME)" == "Grand Theft Auto V Enhanced" ]]'
check "reads GAME_APPID"   '[[ "$(game_conf_get gtav GAME_APPID)" == "3240220" ]]'
check "reads GAME_BACKEND" '[[ "$(game_conf_get gtav GAME_BACKEND)" == "asi" ]]'
check "strips surrounding quotes" '[[ "$(game_conf_get gtav GAME_NEXUS_SLUG)" == "gta5enhanced" ]]'
check "missing key fails"  '! game_conf_get gtav NO_SUCH_KEY >/dev/null 2>&1'
# Reading a conf must not leak GAME_* into the caller.
unset GAME_NAME 2>/dev/null || true
game_conf_get gtav GAME_APPID >/dev/null 2>&1
check "does not leak GAME_NAME into caller" '[[ -z "${GAME_NAME:-}" ]]'

echo
echo "-- name resolution --"

check "canonical id passes through"    '[[ "$(game_resolve gtav)" == "gtav" ]]'
check "alias gta -> gtav"              '[[ "$(game_resolve gta)" == "gtav" ]]'
check "alias gta5 -> gtav"             '[[ "$(game_resolve gta5)" == "gtav" ]]'
check "alias gta5-legacy -> gtav-legacy" '[[ "$(game_resolve gta5-legacy)" == "gtav-legacy" ]]'
check "alias cyberpunk -> cyberpunk2077" '[[ "$(game_resolve cyberpunk)" == "cyberpunk2077" ]]'
check "alias cp2077 -> cyberpunk2077"  '[[ "$(game_resolve cp2077)" == "cyberpunk2077" ]]'
check "alias skyrim -> skyrimse"       '[[ "$(game_resolve skyrim)" == "skyrimse" ]]'
check "appid 3240220 -> gtav"          '[[ "$(game_resolve 3240220)" == "gtav" ]]'
check "appid 1091500 -> cyberpunk2077" '[[ "$(game_resolve 1091500)" == "cyberpunk2077" ]]'
check "appid 271590 -> gtav-legacy"    '[[ "$(game_resolve 271590)" == "gtav-legacy" ]]'
check "unknown name fails"             '! game_resolve notagame >/dev/null 2>&1'
check "empty name fails"               '! game_resolve "" >/dev/null 2>&1'
# Enhanced vs Legacy are different Nexus catalogs — conflating them would
# silently install mods for the wrong SKU.
check "gta and gta5-legacy do NOT collide" \
      '[[ "$(game_resolve gta)" != "$(game_resolve gta5-legacy)" ]]'

echo
echo "-- Venice Unleashed is a client, not a games.d game --"

for n in bf3 vu venice venice-unleashed BF3 VU; do
    check "game_is_vu recognises '$n'" 'game_is_vu "$n"'
done
check "game_is_vu rejects gtav"        '! game_is_vu gtav'
check "vu is NOT in the games.d registry" '! grep -qw bf3 <<< "$IDS"'

echo
echo "-- collection listing --"

OUT="$(game_list_cmd 2>/dev/null)"
check "listing runs clean"             '[[ -n "$OUT" ]]'
check "listing shows canonical ids"    'grep -q cyberpunk2077 <<< "$OUT"'
check "listing shows human labels"     'grep -q "Grand Theft Auto V Enhanced" <<< "$OUT"'
check "listing points at 'powos game'" 'grep -q "powos game <name>" <<< "$OUT"'
check "listing points at storage"      'grep -q "powos games storage" <<< "$OUT"'
# The listing must survive a subsystem being absent — you should always be
# able to see your games even if the mod manager can't load.
( unset -f mods_manifest_count mods_manifest_path 2>/dev/null || true
  game_list_cmd >/dev/null 2>&1 )
check "listing survives missing mods subsystem" '[[ $? -eq 0 ]]'

echo
echo "-- every verb the help promises must dispatch --"
#
# Guard against the class of bug found in `powos mods`, where help documented
# `snapshot` but nothing was wired to it.

HELP="$(game_help 2>/dev/null)"
for verb in status deploy undeploy setup verify snapshot rollback adopt export import play; do
    check "help documents '$verb'" 'grep -qw "$verb" <<< "$HELP"'
done

# Each backing function must exist somewhere in lib/.
for fn in mods_install_smart_cmd mods_manifest_list mods_enable_mod mods_disable_mod \
          mods_remove_mod mods_deploy_cmd mods_undeploy_cmd mods_setup_cmd \
          harness_verify_cmd harness_bisect_cmd mods_snapshot_create mods_snapshot_list \
          mods_rollback_cmd mods_adopt_cmd mods_export_cmd mods_import_cmd \
          mods_status_cmd asi_dispatch; do
    check "backing fn exists: $fn" 'grep -rqn "^${fn}()" "$REPO_ROOT/lib/"'
done

echo
echo "-- dispatch through the real CLI --"

POWOS="$REPO_ROOT/bin/powos"
if [[ -x "$POWOS" ]]; then
    TMPH="$(mktemp -d)"
    run() { HOME="$TMPH" "$POWOS" "$@" 2>&1; }

    OUT="$(run game)"
    check "powos game (bare) lists games"   'grep -q cyberpunk2077 <<< "$OUT"'
    # Bare `powos games` shows usage (it is the COLLECTION+storage namespace and
    # a bare invocation is ambiguous); `powos games list` is the listing verb,
    # routed through the singular/plural bridge added in 6a00abd.
    OUT="$(run games)"
    check "powos games (bare) shows usage"  'grep -qi "powos games" <<< "$OUT"'
    OUT="$(run games list)"
    check "powos games list lists games"    'grep -q cyberpunk2077 <<< "$OUT"'
    # The bridge: `powos games <name>` must reach the per-game view rather than
    # erroring "Unknown games command" — the singular/plural trap.
    OUT="$(run games gtav)"
    check "powos games <name> bridges to the per-game view" 'grep -q "id:        gtav" <<< "$OUT"'
    OUT="$(run game gta)"
    check "powos game gta resolves to gtav" 'grep -q "id:        gtav" <<< "$OUT"'
    OUT="$(run game notagame)"
    check "unknown game is a clean error"   'grep -q "Unknown game" <<< "$OUT"'
    check "unknown game lists what IS known" 'grep -q cyberpunk2077 <<< "$OUT"'
    OUT="$(run game bf3)"
    check "powos game bf3 routes to VU"     'grep -q "Venice Unleashed" <<< "$OUT"'

    # `games storage` and the legacy bare verbs must reach the same place.
    OUT="$(run games storage status)"
    check "games storage status hits the disk subsystem" 'grep -q "POWOS-GAMES status" <<< "$OUT"'
    OUT="$(run games status)"
    check "legacy 'games status' still works"            'grep -q "POWOS-GAMES status" <<< "$OUT"'

    # Regression: `local` at top-level script scope printed an error and still
    # exited 0. These verbs are the ones that were broken.
    for c in "mods enable cyberpunk2077 1" "mods disable cyberpunk2077 1" \
             "mods install cyberpunk2077 1" "mods remove cyberpunk2077 1" \
             "mods snapshot cyberpunk2077"; do
        OUT="$(run $c)"
        check "no top-level 'local' error: powos $c" \
              '! grep -q "local: can only be used in a function" <<< "$OUT"'
    done
    rm -rf "$TMPH"
else
    skip "bin/powos not executable — CLI dispatch untested"
fi

echo
echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
if [[ $FAIL -gt 0 ]]; then echo "TESTS FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
