#!/bin/bash
# test-mods-vu.sh - Tier-1 unit tests for the Venice Unleashed module.
#
# Covers config round-trip, BF3 discovery, the d3dcompiler_47 detection that
# the whole module exists for, launcher/desktop generation, uninstall
# semantics (instance dir survives unless --purge), and the tool-registry
# wiring in install.sh. No network, no Wine, no BF3 — everything that would
# touch those is exercised through its guard clauses instead.
#
# Usage:  bash test/tier1/test-mods-vu.sh
#   Docker: docker exec powos bash /var/lib/powos/src/test/tier1/test-mods-vu.sh

# NOTE: deliberately NO `pipefail`. These harnesses assert with
# `echo "$out" | grep -q ...`, and `grep -q` exits on its first match — which
# SIGPIPEs the writer, making the pipeline return 141 under pipefail depending
# on scheduling. That produced random failures (test-windows.sh swung between 4
# and 11 "failures" on identical runs). Last-command status is the correct
# semantics for an assertion anyway.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."

VU_LIB="$REPO_ROOT/lib/mods/vu.sh"
INSTALL_LIB="$REPO_ROOT/lib/mods/install.sh"
for lib in VU_LIB INSTALL_LIB; do
    [[ -f "${!lib}" ]] || eval "$lib=\"/usr/lib/powos/mods/$(basename "${!lib}")\""
done

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
skip() { echo "  skip - $1"; SKIP=$((SKIP+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

echo "== test-mods-vu.sh =="

[[ -f "$VU_LIB" ]] || { echo "FATAL: vu.sh not found at $VU_LIB"; exit 1; }

# ── Sandbox ──────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Point HOME at the sandbox BEFORE sourcing. vu_detect_bf3() scans real Steam
# library paths under $HOME ($HOME/Games, $HOME/.local/share/Steam/...); left
# unsandboxed, a genuine BF3 install on the dev box is discovered and flips the
# "no install" assertions (green in CI's empty container, red on a gamer's box).
# Overriding HOME makes discovery hermetic regardless of what's installed.
export HOME="$TMP/home"
mkdir -p "$HOME"

export VU_ROOT="$TMP/vu"
export VU_CLIENT_DIR="$VU_ROOT/client"
export VU_INSTANCE_DIR="$VU_ROOT/instance"
export VU_PREFIX="$VU_ROOT/prefix"
export VU_WRAPPER="$TMP/bin/venice-unleashed"
export VU_DESKTOP="$TMP/applications/venice-unleashed.desktop"
export VU_CONF="$TMP/config/vu.conf"
export MODLIST_COMPAT_DIR="$TMP/compat"

source "$VU_LIB" >/dev/null 2>&1

# Silence the presentation helpers so test output stays readable. Must come
# AFTER sourcing — vu.sh pulls in common.sh, which defines them.
plog() { :; }; pok() { :; }; pwarn() { :; }; perr() { :; }

echo
echo "-- config round-trip --"

check "conf_get on missing file fails" '! vu_conf_get gamepath 2>/dev/null'
vu_conf_set gamepath /a/b
check "conf_set creates the file"      '[[ -f "$VU_CONF" ]]'
check "conf_get reads it back"         '[[ "$(vu_conf_get gamepath)" == "/a/b" ]]'
vu_conf_set branch dev
check "second key coexists"            '[[ "$(vu_conf_get branch)" == "dev" ]]'
check "first key survives"             '[[ "$(vu_conf_get gamepath)" == "/a/b" ]]'
vu_conf_set gamepath /c/d
check "overwrite replaces, not appends" '[[ "$(vu_conf_get gamepath)" == "/c/d" ]]'
check "overwrite leaves one line"      '[[ "$(grep -c "^gamepath=" "$VU_CONF")" -eq 1 ]]'
check "overwrite preserves other keys" '[[ "$(vu_conf_get branch)" == "dev" ]]'

echo
echo "-- BF3 discovery --"

rm -f "$VU_CONF"
check "no config, no install -> fails" '! vu_detect_bf3 2>/dev/null'

mkdir -p "$TMP/bf3"
vu_conf_set gamepath "$TMP/bf3"
check "configured path is used"        '[[ "$(vu_detect_bf3)" == "$TMP/bf3" ]]'

vu_conf_set gamepath "$TMP/does-not-exist"
check "stale configured path ignored"  '! vu_detect_bf3 2>/dev/null'

echo
echo "-- client presence --"

check "not installed initially"        '! vu_installed'
mkdir -p "$VU_CLIENT_DIR"
touch "$VU_CLIENT_DIR/vu.com"
check "vu.com counts as installed"     'vu_installed'
rm -f "$VU_CLIENT_DIR/vu.com"; touch "$VU_CLIENT_DIR/vu.exe"
check "vu.exe alone also counts"       'vu_installed'

echo
echo "-- d3dcompiler_47 detection (the whole point of the module) --"

check "absent when no prefix"          '! vu_has_d3dcompiler'
mkdir -p "$VU_PREFIX/pfx"
check "absent when no winetricks.log"  '! vu_has_d3dcompiler'
echo "vcrun2022" > "$VU_PREFIX/pfx/winetricks.log"
check "absent when log lacks the verb" '! vu_has_d3dcompiler'
echo "d3dcompiler_47" >> "$VU_PREFIX/pfx/winetricks.log"
check "present once winetricks logs it" 'vu_has_d3dcompiler'
# Guard against a substring false-positive.
echo "d3dcompiler_47_extra" > "$VU_PREFIX/pfx/winetricks.log"
check "substring does NOT false-match" '! vu_has_d3dcompiler'

echo
echo "-- runtime resolution --"

check "no GE-Proton -> vu_proton empty" '[[ -z "$(vu_proton || true)" ]]'
mkdir -p "$MODLIST_COMPAT_DIR/GE-Proton9-1/files/bin"
touch "$MODLIST_COMPAT_DIR/GE-Proton9-1/proton"
check "non-executable proton ignored"   '[[ -z "$(vu_proton || true)" ]]'
chmod +x "$MODLIST_COMPAT_DIR/GE-Proton9-1/proton"
check "executable proton resolves"      '[[ "$(vu_proton)" == "$MODLIST_COMPAT_DIR/GE-Proton9-1/proton" ]]'
mkdir -p "$MODLIST_COMPAT_DIR/GE-Proton11-3/files/bin"
touch "$MODLIST_COMPAT_DIR/GE-Proton11-3/proton"; chmod +x "$MODLIST_COMPAT_DIR/GE-Proton11-3/proton"
check "newest GE-Proton wins (version sort)" '[[ "$(vu_proton)" == *GE-Proton11-3* ]]'
check "vu_wine empty without wine binary" '[[ -z "$(vu_wine || true)" ]]'
touch "$MODLIST_COMPAT_DIR/GE-Proton11-3/files/bin/wine"
chmod +x "$MODLIST_COMPAT_DIR/GE-Proton11-3/files/bin/wine"
check "vu_wine resolves from newest"    '[[ "$(vu_wine)" == *GE-Proton11-3/files/bin/wine ]]'

echo
echo "-- launcher + desktop generation --"

vu_conf_set gamepath "$TMP/bf3"
vu_write_wrapper >/dev/null 2>&1
check "wrapper written"                '[[ -f "$VU_WRAPPER" ]]'
check "wrapper executable"             '[[ -x "$VU_WRAPPER" ]]'
check "wrapper is valid bash"          'bash -n "$VU_WRAPPER"'
check "wrapper bakes client dir"       'grep -q "$VU_CLIENT_DIR" "$VU_WRAPPER"'
check "wrapper sets STEAM_COMPAT_DATA_PATH" 'grep -q STEAM_COMPAT_DATA_PATH "$VU_WRAPPER"'
check "wrapper passes -gamepath"       'grep -q -- "-gamepath" "$VU_WRAPPER"'
check "wrapper handles dev branch"     'grep -q -- "-updateBranch dev" "$VU_WRAPPER"'

vu_write_desktop >/dev/null 2>&1
check "desktop entry written"          '[[ -f "$VU_DESKTOP" ]]'
check "desktop Exec points at wrapper" 'grep -q "^Exec=$VU_WRAPPER" "$VU_DESKTOP"'
check "desktop is a Game"              'grep -q "Categories=Game" "$VU_DESKTOP"'

echo
echo "-- branch verb --"

rm -f "$VU_CONF"
check "defaults to prod"               '[[ "$(vu_branch_cmd)" == "prod" ]]'
vu_branch_cmd dev >/dev/null 2>&1
check "set dev persists"               '[[ "$(vu_branch_cmd)" == "dev" ]]'
vu_branch_cmd prod >/dev/null 2>&1
check "set back to prod persists"      '[[ "$(vu_branch_cmd)" == "prod" ]]'
check "bogus branch rejected"          '! vu_branch_cmd nonsense >/dev/null 2>&1'

echo
echo "-- guard clauses (no Wine/BF3 required) --"

rm -f "$VU_CONF"
rm -rf "$VU_CLIENT_DIR"
check "activate refuses w/o client"    '! vu_activate_cmd >/dev/null 2>&1'
check "server start refuses w/o client" '! vu_server_start >/dev/null 2>&1'

mkdir -p "$VU_CLIENT_DIR"; touch "$VU_CLIENT_DIR/vu.com"
rm -f "$VU_CONF"
check "activate refuses w/o gamepath"  '! vu_activate_cmd >/dev/null 2>&1'

vu_conf_set gamepath "$TMP/bf3"
mkdir -p "$VU_INSTANCE_DIR"
check "server start refuses w/o key"   '! vu_server_start >/dev/null 2>&1'

echo
echo "-- status renders without crashing in every state --"

check "status runs clean (bare)"       'vu_status_cmd >/dev/null 2>&1'
check "server status runs clean"       'vu_server_status >/dev/null 2>&1'
rm -rf "$VU_CLIENT_DIR" "$VU_PREFIX"; rm -f "$VU_CONF"
check "status runs clean (nothing set)" 'vu_status_cmd >/dev/null 2>&1'
# Capture first: `cmd | grep -q` exits the pipeline 141 under pipefail because
# grep -q closes the pipe before the producer finishes writing.
STATUS_OUT="$(vu_status_cmd 2>/dev/null)"
check "status mentions d3dcompiler"    'grep -q d3dcompiler <<< "$STATUS_OUT"'

echo
echo "-- uninstall semantics --"

mkdir -p "$VU_CLIENT_DIR" "$VU_INSTANCE_DIR" "$VU_PREFIX" "$(dirname "$VU_WRAPPER")"
touch "$VU_CLIENT_DIR/vu.com" "$VU_INSTANCE_DIR/server.key" "$VU_WRAPPER"
vu_conf_set gamepath "$TMP/bf3"
vu_uninstall_cmd >/dev/null 2>&1
check "uninstall removes client"       '[[ ! -d "$VU_CLIENT_DIR" ]]'
check "uninstall removes prefix"       '[[ ! -d "$VU_PREFIX" ]]'
check "uninstall removes wrapper"      '[[ ! -f "$VU_WRAPPER" ]]'
check "uninstall KEEPS server.key"     '[[ -f "$VU_INSTANCE_DIR/server.key" ]]'
check "uninstall KEEPS config"         '[[ -f "$VU_CONF" ]]'

vu_uninstall_cmd --purge >/dev/null 2>&1
check "--purge removes instance dir"   '[[ ! -d "$VU_INSTANCE_DIR" ]]'
check "--purge removes config"         '[[ ! -f "$VU_CONF" ]]'

echo
echo "-- help is the agent's instruction manual, so it must be complete --"

HELP="$(vu_help 2>/dev/null)"
for verb in install activate d3dcompiler branch play server status uninstall; do
    check "help documents '$verb'"     'grep -q "powos mods vu $verb" <<< "$HELP"'
done
check "help states d3dcompiler is EVERY branch" 'grep -qi "every branch" <<< "$HELP"'
check "help lists the harmony port"    'grep -q "7948" <<< "$HELP"'
check "help lists the frostbite port"  'grep -q "25200" <<< "$HELP"'
check "help lists the rcon port"       'grep -q "47200" <<< "$HELP"'
check "help links the docs"            'grep -q "docs.veniceunleashed.net" <<< "$HELP"'

echo
echo "-- server mods: identification + ModList wiring (no network) --"

# Isolated mod sandbox; reassign the globals the mod functions read.
MODTEST="$TMP/modtest"
VU_MODS_DIR="$MODTEST/Admin/Mods"
VU_MODLIST="$MODTEST/Admin/ModList.txt"
_mreset() { rm -rf "$MODTEST"; mkdir -p "$VU_MODS_DIR"; }

# A repo that ships ONE mod, and one that ships TWO.
SINGLE="$TMP/src-single"; mkdir -p "$SINGLE/ext"
echo '{"Name":"SoloMod","Version":"1.0.0"}' > "$SINGLE/mod.json"
MULTI="$TMP/src-multi"; mkdir -p "$MULTI/ModA/ext" "$MULTI/ModB/ext"
echo '{"Name":"ModA","Version":"1.0.0"}' > "$MULTI/ModA/mod.json"
echo '{"name":"ModB","Version":"2.0.0"}' > "$MULTI/ModB/mod.json"   # lowercase key

# mod.json name extraction (VU uses "Name"; tolerate "name")
check "modjson_name reads Name"        '[[ "$(vu_modjson_name "$SINGLE/mod.json")" == "SoloMod" ]]'
check "modjson_name reads lowercase"   '[[ "$(vu_modjson_name "$MULTI/ModB/mod.json")" == "ModB" ]]'
check "modjson_name empty on missing"  '[[ -z "$(vu_modjson_name "$TMP/nope.json" 2>/dev/null)" ]]'

# discovery
check "find_mods: one in single repo"  '[[ "$(vu_find_mods "$SINGLE" | wc -l)" -eq 1 ]]'
check "find_mods: two in multi repo"   '[[ "$(vu_find_mods "$MULTI" | wc -l)" -eq 2 ]]'
check "find_mods: none in empty tree"  '[[ -z "$(vu_find_mods "$TMP/home")" ]]'

# single-mod install auto-selects, places files, and enables in ModList
_mreset
check "install single: rc 0"           'vu_mod_install_cmd "$SINGLE" </dev/null'
check "install single: folder placed"  '[[ -f "$VU_MODS_DIR/SoloMod/mod.json" ]]'
check "install single: provenance kept" '[[ -f "$VU_MODS_DIR/SoloMod/.powos-source" ]]'
check "install single: enabled in list" 'vu_modlist_has SoloMod'

# THE CONSTRAINT: a multi-mod repo, non-interactive, no selection → refuse,
# install NOTHING (never auto-all).
_mreset
check "multi w/o selection: refuses"   '! vu_mod_install_cmd "$MULTI" </dev/null 2>/dev/null'
check "multi w/o selection: installs nothing" '[[ -z "$(ls -A "$VU_MODS_DIR")" ]]'

# --only selection installs ONLY that mod
_mreset
vu_mod_install_cmd "$MULTI" --only ModB </dev/null >/dev/null 2>&1
check "--only ModB: placed"            '[[ -d "$VU_MODS_DIR/ModB" ]]'
check "--only ModB: ModA NOT placed"  '[[ ! -d "$VU_MODS_DIR/ModA" ]]'
check "--only ModB: only ModB enabled" 'vu_modlist_has ModB && ! vu_modlist_has ModA'

# unknown name is an error, not a silent no-op
_mreset
check "unknown --only name errors"     '! vu_mod_install_cmd "$MULTI" --only Nope </dev/null 2>/dev/null'
check "stray positional is rejected"   '! vu_mod_install_cmd "$MULTI" ModA ModB </dev/null 2>/dev/null'

# --all is the explicit opt-in to take everything
_mreset
vu_mod_install_cmd "$MULTI" --all </dev/null >/dev/null 2>&1
check "--all: both placed"             '[[ -d "$VU_MODS_DIR/ModA" && -d "$VU_MODS_DIR/ModB" ]]'

# --disabled places files but leaves ModList untouched
_mreset
vu_mod_install_cmd "$SINGLE" --disabled </dev/null >/dev/null 2>&1
check "--disabled: placed"             '[[ -d "$VU_MODS_DIR/SoloMod" ]]'
check "--disabled: NOT in ModList"     '! vu_modlist_has SoloMod'

# enable / disable / remove lifecycle
check "enable adds to ModList"         'vu_mod_enable_cmd SoloMod >/dev/null && vu_modlist_has SoloMod'
check "disable keeps folder"           'vu_mod_disable_cmd SoloMod >/dev/null && ! vu_modlist_has SoloMod && [[ -d "$VU_MODS_DIR/SoloMod" ]]'
check "remove deletes folder"          'vu_mod_remove_cmd SoloMod >/dev/null && [[ ! -d "$VU_MODS_DIR/SoloMod" ]]'

# ModList is idempotent (no duplicate lines)
_mreset; vu_modlist_add Dup; vu_modlist_add Dup
check "modlist add is idempotent"      '[[ "$(grep -c "^Dup$" "$VU_MODLIST")" -eq 1 ]]'

# not-a-mod source is rejected
_mreset; mkdir -p "$TMP/notamod"; echo hi > "$TMP/notamod/readme.txt"
check "rejects source with no mod.json" '! vu_mod_install_cmd "$TMP/notamod" </dev/null 2>/dev/null'

# mod help + parent help document the surface (help<->dispatch contract)
MHELP="$(vu_mod_help 2>/dev/null)"
for v in install list enable disable remove update; do
    check "mod help documents '$v'"    'grep -q "$v" <<< "$MHELP"'
done
check "mod help explains gh: source"   'grep -q "gh:owner/repo" <<< "$MHELP"'
check "mod help explains choose-not-all" 'grep -qi "never" <<< "$MHELP" || grep -qi "not installed wholesale" <<< "$MHELP"'
check "mod help header is 'vu mod' not 'server mod'" 'grep -q "powos mods vu mod" <<< "$MHELP" && ! grep -q "server mod" <<< "$MHELP"'
check "main help documents 'vu mod'"   'grep -q "powos mods vu mod" <<< "$(vu_help)"'
check "server help points at 'vu mod'"  'grep -q "vu mod" <<< "$(vu_server_help)"'
check "vu mod dispatches (real path)"   'vu_mod_cmd help >/dev/null 2>&1'

echo
echo "-- tool-registry wiring in install.sh --"

if [[ -f "$INSTALL_LIB" ]]; then
    # install.sh defines MODS_* paths against $HOME; sandbox them.
    ( export HOME="$TMP/home"; mkdir -p "$HOME"
      source "$INSTALL_LIB" >/dev/null 2>&1
      t=0
      known="$(mods_known_tools)"
      grep -q venice-unleashed <<< "$known" || t=1
      [[ "$(mods_normalize_name vu)" == "venice-unleashed" ]] || t=1
      [[ "$(mods_normalize_name venice)" == "venice-unleashed" ]] || t=1
      [[ "$(mods_normalize_name "venice unleashed")" == "venice-unleashed" ]] || t=1
      [[ "$(mods_binary_of venice-unleashed)" == *venice-unleashed ]] || t=1
      exit $t )
    check "install.sh registers venice-unleashed" '[[ $? -eq 0 ]]'
else
    skip "install.sh not found — registry wiring untested"
fi

echo
echo "== Results: $PASS passed, $FAIL failed, $SKIP skipped =="
if [[ $FAIL -gt 0 ]]; then echo "TESTS FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
