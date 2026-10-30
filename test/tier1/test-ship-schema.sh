#!/bin/bash
# Hermetic test: a schema change ships atomically (2026-10-30 19:31, powos-agents' work.try_line: the module was
# published to the phone before the shell's bindings had the column - home's board subscription stopped decoding).
#   - apps/vendor.sh --check: the committed shell/vendor/<db>.js must be exactly what apps/<app>/module builds;
#   - the ship service's apps step refuses a module whose bindings weren't regenerated in it (old: published anyway);
#   - module + regenerated bindings: the bindings are pushed first, then the module (as the service), checked against
#     the phone's schemas before the push (--publishing the app) and after the publish;
#   - bindings that wouldn't decode the phone's modules: the whole tip is refused (no push, no publish);
#   - apps/install.sh refuses a vendored module's publish outside the ship service (--direct: logged).
# A fake origin (bare repo), an agent's clone, this tree's ship.sh + vendor.sh + install.sh; stubs for the module
# build (VENDOR_GEN: the "bindings" are the module source, commented), build/install, push.sh, the phone's bindings
# check and mail. Temp HOME: nothing reaches the real phone, docker, launchd or ~/.cache.
#   test/tier1/test-ship-schema.sh        exit 0 = all pass
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/ship-schema-test.XXXXXX")
export HOME=$T/home LOG=$T/log GIT_CONFIG_GLOBAL=$T/gitconfig SHIP_DIR=$T/home/.cache/powos-ship-queue
export SHIP_QUIET_S=1 SHIP_QUIET_SHELL_S=1 SHIP_POLL_S=1 SHIP_GATE_FIRST=1
export VENDOR_GEN=$T/gen SHIP_BINDINGS_CHECK=$T/bcheck
unset POWOS_SHIP_SERVICE SHIP_AGENT
Q=$SHIP_DIR
stop_runner() { local p; p=$(cat "$Q/runner.lock/pid" 2>/dev/null) && kill "$p" 2>/dev/null; pkill -f "$T/" 2>/dev/null; }
trap 'stop_runner; rm -rf "$T"' EXIT
mkdir -p "$HOME/.cache"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main
# The module "build": its bindings are the module source, commented (any change to it is a schema change here).
printf '#!/bin/bash\nsed "s|^|// |" "apps/$1/module/src/lib.rs" > "$3"\n' > "$T/gen"
printf '#!/bin/bash\necho "BCHECK $*" >> "$LOG"\n[ ! -e "$HOME/bindings-bad" ] || { echo "bindings: powos-agents on the phone lacks work.x - fix: ..." >&2; exit 1; }\n' > "$T/bcheck"
chmod +x "$T/gen" "$T/bcheck"

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null; cd "$T/seed"; git checkout -q -b worktree-powos-multiplatform
mkdir -p tools/phone apps/agents/module/src apps/plain/module shell/vendor
cp "$src/tools/phone/ship.sh" tools/phone/; cp "$src/apps/vendor.sh" "$src/apps/install.sh" apps/
echo 'powos-agents.js   generated              apps/agents: `apps/vendor.sh agents`' > shell/vendor/VERSIONS
echo '{"id": "dev.powos.agents", "name": "Agents"}' > apps/agents/powos-app.json
echo '[package]' > apps/agents/module/Cargo.toml; echo 'table work { id, title }' > apps/agents/module/src/lib.rs
sed 's|^|// |' apps/agents/module/src/lib.rs > shell/vendor/powos-agents.js
echo '{"id": "dev.powos.plain"}' > apps/plain/powos-app.json; echo '[package]' > apps/plain/module/Cargo.toml
printf '#!/bin/bash\necho "BUILD $1" >> "$LOG"\n' > apps/build.sh
printf '#!/bin/bash\necho "PUSH $*" >> "$LOG"\n' > shell/push.sh
printf '#!/bin/bash\necho "MAIL $(cat "$1")" >> "$LOG"\n' > tools/phone/user.sh
printf '.claude/\n' > .gitignore
chmod +x tools/phone/*.sh apps/*.sh shell/push.sh
git add -A; git commit -qm base; git push -q origin worktree-powos-multiplatform 2>/dev/null
git rev-parse HEAD > "$HOME/.cache/powos-installed-commit"   # the phone's APK matches base
git clone -q -b worktree-powos-multiplatform "$T/origin.git" "$T/B" 2>/dev/null
cd "$T/B"
# The ship's apps/install.sh: a stub that logs (the real one is tested at the end).
printf '#!/bin/bash\necho "INSTALL $1 $2 svc=${POWOS_SHIP_SERVICE:-}" >> "$LOG"\n' > apps/install.sh
git commit -qam "install stub"; git push -q origin HEAD:worktree-powos-multiplatform 2>/dev/null

fails=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fails=$((fails+1)); }
req() { SHIP_REQUESTER=B bash tools/phone/ship.sh request "$@" > "$T/req.out" 2>&1; }
drained() { for _ in $(seq "${1:-30}"); do ls "$Q"/*.req >/dev/null 2>&1 || return 0; sleep 1; done; return 1; }
settle() { for _ in $(seq 30); do [ -n "$(cat "$Q/runner.lock/pid" 2>/dev/null)" ] || return 0; sleep 1; done; }

# 0. apps/vendor.sh --check itself.
out=$(apps/vendor.sh --check agents 2>&1) && echo "$out" | grep -q "is what apps/agents/module builds" && ok "vendor --check: committed bindings match" || bad "vendor --check match: $out"
echo 'table work { id, title, try_line }' > apps/agents/module/src/lib.rs
out=$(apps/vendor.sh --check agents 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "REFUSED - shell/vendor/powos-agents.js isn't what apps/agents/module builds" && ok "vendor --check: a module ahead of its bindings refused" || bad "vendor --check mismatch rc $rc: $out"
git checkout -q apps/agents/module/src/lib.rs
[ "$(apps/vendor.sh --changed HEAD~1 HEAD)" = "" ] && ok "vendor --changed: nothing" || bad "vendor --changed"

# A. The incident: the module changed (a new column), its bindings NOT regenerated. Old ship.sh: built + published.
: > "$LOG"
echo 'table work { id, title, try_line }' > apps/agents/module/src/lib.rs
git commit -qam "agents: work.try_line (bindings forgotten)"; git push -q origin HEAD:worktree-powos-multiplatform 2>/dev/null; tA=$(git rev-parse HEAD)
req --note "AI page: try line"
drained 40 && settle
! grep -q '^INSTALL agents' "$LOG" && ok "A: module without its regenerated bindings NOT published" || { bad "A: published anyway"; cat "$LOG"; tail -5 "$Q/runner.log"; }
[ "$(cat "$Q/failed-apps" 2>/dev/null)" = "$tA" ] && ok "A: tip marked failed-apps" || { bad "A: failed-apps"; tail -5 "$Q/runner.log"; }
grep -q '^MAIL.*apps:agents.*FAILED' "$LOG" && ok "A: coder mailed" || { bad "A: no mail"; cat "$LOG"; }
grep -q "REFUSED - shell/vendor/powos-agents.js isn't what apps/agents/module builds" "$Q"/done/*-apps.log 2>/dev/null && ok "A: the apps log says why (vendor --check)" || bad "A: apps log"

# B. The fix: module + regenerated bindings in ONE commit - bindings pushed first, then the module, as the service.
: > "$LOG"
"$VENDOR_GEN" agents --out shell/vendor/powos-agents.js
git commit -qam "agents: powos-agents.js regenerated"; git push -q origin HEAD:worktree-powos-multiplatform 2>/dev/null; tB=$(git rev-parse HEAD)
req --note "AI page: try line, for real"
drained 40 && settle
for _ in $(seq 20); do grep -q '^INSTALL' "$LOG" && break; sleep 1; done
p=$(grep -n '^PUSH .*vendor/powos-agents.js' "$LOG" | head -1 | cut -d: -f1); i=$(grep -n '^INSTALL agents install svc=1' "$LOG" | head -1 | cut -d: -f1)
[ -n "$p" ] && [ -n "$i" ] && [ "$p" -lt "$i" ] && ok "B: bindings pushed, THEN the module published (by the service)" || { bad "B: order/marks"; cat "$LOG"; tail -8 "$Q/runner.log"; }
b1=$(grep -n '^BCHECK --no-publish --vendor shell/vendor --publishing agents' "$LOG" | head -1 | cut -d: -f1)
[ -n "$b1" ] && [ -n "$p" ] && [ "$b1" -lt "$p" ] && ok "B: phone schemas checked before the push (ahead of agents allowed)" || { bad "B: pre-push check"; cat "$LOG"; }
b2=$(grep -n '^BCHECK --no-publish --vendor shell/vendor$' "$LOG" | tail -1 | cut -d: -f1)
[ -n "$b2" ] && [ -n "$i" ] && [ "$b2" -gt "$i" ] && ok "B: and again after the publish" || { bad "B: post-publish check"; cat "$LOG"; }
[ "$(cat "$Q/apps-live" 2>/dev/null)" = "$tB" ] && [ "$(cat "$Q/live" 2>/dev/null)" = "$tB" ] && ok "B: live + apps-live at the tip" || bad "B: records"

# C. Bindings that wouldn't decode the phone's modules: the tip is refused - nothing pushed, nothing published.
: > "$LOG"; touch "$HOME/bindings-bad"
echo 'table work { id, title, try_line, owner }' > apps/agents/module/src/lib.rs; "$VENDOR_GEN" agents --out shell/vendor/powos-agents.js
git commit -qam "agents: owner"; git push -q origin HEAD:worktree-powos-multiplatform 2>/dev/null; tC=$(git rev-parse HEAD)
req --note "owner column"
for _ in $(seq 40); do [ "$(cat "$Q/failed" 2>/dev/null)" = "$tC" ] && break; sleep 1; done; settle
! grep -q '^PUSH .*vendor' "$LOG" && ! grep -q '^INSTALL' "$LOG" && ok "C: mismatched bindings: no push, no publish" || { bad "C: shipped anyway"; cat "$LOG"; }
grep -q '^MAIL.*REFUSED' "$LOG" && grep -q "shell ship REFUSED - the bindings and the modules" "$Q/runner.log" && ok "C: refused, logged + mailed" || { bad "C: refusal"; cat "$LOG"; tail -5 "$Q/runner.log"; }
rm -f "$HOME/bindings-bad"; stop_runner; rm -f "$Q"/*.req

# D. apps/install.sh (the real one): a vendored module's publish outside the service is refused; --direct is logged;
#    a module no shell binding reads is published with a loud warning.
cp "$src/apps/install.sh" "$T/install.sh"; mkdir -p "$T/inst/apps"; cp "$T/install.sh" "$T/inst/apps/install.sh"
cp -R apps/agents apps/plain "$T/inst/apps/"; mkdir -p "$T/inst/shell/vendor"; cp shell/vendor/VERSIONS "$T/inst/shell/vendor/"
out=$(bash "$T/inst/apps/install.sh" agents publish --note x 2>&1); rc=$?
[ $rc = 3 ] && echo "$out" | grep -q "REFUSED - apps/agents's module is the shell's powos-agents database" && ok "D: direct publish of a vendored module refused" || bad "D: refusal rc $rc: $out"
out=$(bash "$T/inst/apps/install.sh" agents publish --direct --note x 2>&1); rc=$?
[ $rc != 3 ] && grep -q 'apps/install.sh --direct .* agents publish' "$Q/direct.log" && ok "D: --direct passes, logged" || bad "D: --direct rc $rc: $out"
out=$(bash "$T/inst/apps/install.sh" plain publish --note x 2>&1); rc=$?
[ $rc != 3 ] && echo "$out" | grep -q "WARNING - publishing apps/plain's module" && ok "D: other modules: a loud warning" || bad "D: warning rc $rc: $out"
out=$(POWOS_SHIP_SERVICE=1 bash "$T/inst/apps/install.sh" agents publish --note x 2>&1); rc=$?
[ $rc != 3 ] && ! echo "$out" | grep -qE 'REFUSED|WARNING' && ok "D: the ship service publishes quietly" || bad "D: service rc $rc: $out"

echo "---"
[ "$fails" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
