#!/usr/bin/env bash
# test-fivem.sh — unit tests for lib/mods/fivem.sh (FiveM server/client manager).
# Pure logic only: edition model, artifact URLs, ports, gamebuild, config, and
# the dispatcher. Downloads/tmux/txAdmin need a real GTA license + network and
# are out of scope here (same posture as the vu suite).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FIVEM="$ROOT/lib/mods/fivem.sh"
[ -f "$FIVEM" ] || { echo "FAIL: $FIVEM missing"; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
# Run an expression in a sandboxed env with fivem.sh sourced; echo its stdout.
fx() { FIVEM_CONF="$SBX/fivem.conf" FIVEM_ROOT="$SBX/root" bash -c "source '$FIVEM'; $1" 2>/dev/null; }

SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT

echo "== fivem: syntax =="
bash -n "$FIVEM" && ok "parses" || { bad "syntax error"; echo "fivem: $pass/$((pass+fail))"; exit 1; }

echo "== edition model =="
[ "$(fx 'fivem_edition_norm classic')" = legacy ]   && ok "classic → legacy"   || bad "classic norm"
[ "$(fx 'fivem_edition_norm "" ')" = legacy ]        && ok "empty → legacy"     || bad "empty norm"
[ "$(fx 'fivem_edition_norm enhanced')" = enhanced ] && ok "enhanced → enhanced" || bad "enhanced norm"
[ "$(fx 'fivem_edition_norm next')" = enhanced ]     && ok "next → enhanced"    || bad "next norm"
fx 'fivem_edition_norm bogus' >/dev/null 2>&1 && bad "accepted bogus edition" || ok "rejects bogus edition"

echo "== artifact URLs =="
u="$(fx 'fivem_artifact_url legacy 12345')"
[ "$u" = "https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/12345/fx.tar.xz" ] \
    && ok "legacy artifact URL" || bad "legacy URL: $u"
u="$(fx 'fivem_artifact_url enhanced 999')"
case "$u" in */999/fx.tar.xz) ok "enhanced artifact URL shape" ;; *) bad "enhanced URL: $u" ;; esac
# enhanced base is overridable via config
u="$(fx 'fivem_conf_set enhanced_artifact_base https://x.example/e; fivem_artifact_url enhanced 7')"
[ "$u" = "https://x.example/e/7/fx.tar.xz" ] && ok "enhanced base override honored" || bad "enhanced override: $u"

echo "== ports are per-edition + overridable =="
[ "$(fx 'fivem_game_port legacy')" = 30120 ]   && ok "legacy game port"   || bad "legacy game port"
[ "$(fx 'fivem_game_port enhanced')" = 30121 ] && ok "enhanced game port" || bad "enhanced game port"
[ "$(fx 'fivem_tx_port legacy')" = 40120 ]     && ok "legacy tx port"     || bad "legacy tx port"
[ "$(fx 'fivem_tx_port enhanced')" != "$(fx 'fivem_tx_port legacy')" ] && ok "tx ports differ" || bad "tx ports collide"
[ "$(fx 'fivem_conf_set legacy_port 30130; fivem_game_port legacy')" = 30130 ] && ok "port override" || bad "port override"

echo "== gamebuild per edition + override =="
[ -n "$(fx 'fivem_gamebuild legacy')" ]   && ok "legacy gamebuild set"   || bad "legacy gamebuild"
[ -n "$(fx 'fivem_gamebuild enhanced')" ] && ok "enhanced gamebuild set" || bad "enhanced gamebuild"
[ "$(fx 'fivem_conf_set legacy_gamebuild 2802; fivem_gamebuild legacy')" = 2802 ] && ok "gamebuild override" || bad "gamebuild override"

echo "== config + default edition =="
[ "$(fx 'fivem_default_edition')" = legacy ] && ok "default edition = legacy" || bad "default edition"
[ "$(fx 'fivem_conf_set edition enhanced; fivem_default_edition')" = enhanced ] && ok "default edition follows config" || bad "default edition config"
[ "$(fx 'fivem_conf_set license K123; fivem_conf_get license')" = K123 ] && ok "conf get/set roundtrip" || bad "conf roundtrip"

echo "== edition arg parsing (_fivem_take_edition) =="
[ "$(fx '_fivem_take_edition --enhanced foo; echo $_FE')" = enhanced ] && ok "--enhanced parsed" || bad "--enhanced"
[ "$(fx '_fivem_take_edition -e legacy bar; echo $_FE')" = legacy ]    && ok "-e legacy parsed"  || bad "-e legacy"
[ "$(fx '_fivem_take_edition --build 5; echo "${_FARGS[*]}"')" = "--build 5" ] && ok "non-edition args preserved" || bad "arg passthrough"

echo "== dispatcher renders + routes =="
fx 'cmd_mods_fivem help'   >/dev/null && ok "help runs"    || bad "help"
fx 'cmd_mods_fivem status' >/dev/null && ok "status runs"  || bad "status"
fx 'cmd_mods_fivem'        >/dev/null && ok "bare = status" || bad "bare"
fx 'cmd_mods_fivem server status' >/dev/null && ok "server status runs" || bad "server status"
fx 'cmd_mods_fivem client --enhanced' >/dev/null && ok "client stub runs" || bad "client stub"
[ "$(fx 'cmd_mods_fivem edition enhanced >/dev/null; fivem_conf_get edition')" = enhanced ] && ok "edition subcmd persists" || bad "edition subcmd"
fx 'cmd_mods_fivem bogus' >/dev/null 2>&1 && bad "accepted bogus subcommand" || ok "rejects bogus subcommand"

echo "== help documents server + client + editions (agent-discoverability) =="
h="$(fx 'cmd_mods_fivem help')"
for tok in "server install" "server up" license "legacy" "enhanced" "client"; do
    printf '%s' "$h" | grep -qi -- "$tok" && ok "help mentions '$tok'" || bad "help missing '$tok'"
done

echo
echo "fivem: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
