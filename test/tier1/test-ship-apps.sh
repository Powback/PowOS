#!/bin/bash
# Hermetic test of the ship service's "apps" kind (tools/phone/ship.sh): a commit that changes apps/<app>/ should
# get `apps/build.sh <app>` then `apps/install.sh <app> install --note "..."`, after the APK (never while one's
# out) and under the shell ship's own phone-busy rules. A fake origin (bare repo), an agent's clone B, this tree's
# ship.sh, and stubs for apps/build.sh + apps/install.sh that only log their own invocation. Temp HOME: nothing
# reaches the real phone, docker, launchd or ~/.cache.
#   test/tier1/test-ship-apps.sh        exit 0 = all pass
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/ship-apps-test.XXXXXX")
export HOME=$T/home LOG=$T/log GIT_CONFIG_GLOBAL=$T/gitconfig SHIP_DIR=$T/home/.cache/powos-ship-queue
export SHIP_QUIET_S=1 SHIP_QUIET_SHELL_S=1 SHIP_POLL_S=1
unset POWOS_SHIP_SERVICE SHIP_AGENT
Q=$SHIP_DIR
stop_runner() { local p; p=$(cat "$Q/runner.lock/pid" 2>/dev/null) && kill "$p" 2>/dev/null; pkill -f "$T/" 2>/dev/null; }
trap 'stop_runner; rm -rf "$T"' EXIT
mkdir -p "$HOME/.cache"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null; cd "$T/seed"; git checkout -q -b worktree-powos-multiplatform
mkdir -p tools/phone apps/app-api
cp "$src/tools/phone/ship.sh" tools/phone/
cat > apps/app-api/powos-app.json <<'EOF'
{"id": "app-api"}
EOF
echo "marker 0" > apps/app-api/marker.txt
# Stubs: no real Rust/wasm toolchain or phone - just record what they were called with.
printf '#!/bin/bash\necho "BUILD $1 $(git rev-parse HEAD)" >> "$LOG"\n' > apps/build.sh
printf '#!/bin/bash\necho "INSTALL $1 $2 note=$4" >> "$LOG"\n' > apps/install.sh
printf '.claude/\n' > .gitignore
chmod +x tools/phone/ship.sh apps/build.sh apps/install.sh
git add -A; git commit -qm base; git push -q origin worktree-powos-multiplatform 2>/dev/null
git rev-parse HEAD > "$HOME/.cache/powos-installed-commit"   # the phone's APK already matches base - no Kotlin changed
git clone -q -b worktree-powos-multiplatform "$T/origin.git" "$T/B" 2>/dev/null
cd "$T/B"

fails=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fails=$((fails+1)); }
req() { SHIP_REQUESTER=B bash tools/phone/ship.sh request "$@" > "$T/req.out" 2>&1; }
drained() { for _ in $(seq "${1:-30}"); do ls "$Q"/*.req >/dev/null 2>&1 || return 0; sleep 1; done; return 1; }

# A commit that only changes apps/app-api/: built + installed, with the ship note, no APK involved.
: > "$LOG"
echo "marker 1" > apps/app-api/marker.txt; git add -A; git commit -qm "app-api change"
git push -q origin HEAD:worktree-powos-multiplatform 2>/dev/null
t=$(git rev-parse HEAD)
req --note "app-api got better"
drained 40 && ok "request served" || { bad "request left queued"; cat "$Q/runner.log" 2>/dev/null; }
for _ in $(seq 20); do grep -q '^INSTALL' "$LOG" 2>/dev/null && break; sleep 1; done
grep -q "^BUILD app-api $t" "$LOG" && ok "build.sh ran for the changed app, at the shipped tip" || { bad "build.sh"; cat "$LOG"; }
grep -q "^INSTALL app-api install note=app-api got better" "$LOG" && ok "install.sh ran with the ship note" || { bad "install.sh"; cat "$LOG"; }
[ "$(grep -c '^BUILD' "$LOG")" = 1 ] && ok "built exactly once" || bad "built $(grep -c '^BUILD' "$LOG") times"
[ "$(cat "$Q/apps-live" 2>/dev/null)" = "$t" ] && ok "apps-live recorded at the shipped tip" || bad "apps-live not recorded"
grep -q "${t:0:9} apps (app-api)" "$Q/shipped.log" 2>/dev/null && ok "shipped.log has the apps line" || { bad "shipped.log"; cat "$Q/shipped.log" 2>/dev/null; }

# A second request on the SAME tip (nothing new in apps/): no second build.
: > "$LOG"
req --silent
drained 20 && ok "no-op request served" || bad "no-op request left queued"
[ -z "$(cat "$LOG" 2>/dev/null)" ] && ok "nothing rebuilt when apps/ didn't change" || { bad "rebuilt with no apps change"; cat "$LOG"; }

echo "---"
[ "$fails" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
