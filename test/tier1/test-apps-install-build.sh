#!/bin/bash
# Hermetic test of apps/install.sh's build step (friction f413): a fake app whose source is newer than out/ is built
# (apps/build.sh) before the gate and the install; with --no-build the install is refused, naming the newer file.
# Stubs for apps/build.sh, shell/dev/gate.sh and adb only log their calls: no docker, phone or Chromium.
#   test/tier1/test-apps-install-build.sh        exit 0 = all pass
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/apps-install-build.XXXXXX"); trap 'rm -rf "$T"' EXIT
export LOG=$T/log ADB=$T/adb
unset POWOS_SHIP_SERVICE
R=$T/repo; mkdir -p "$R/apps/fake/ui/widgets" "$R/apps/fake/out/ui" "$R/shell/dev"
cp "$src/apps/install.sh" "$R/apps/"
printf '#!/bin/bash\necho "BUILD $1" >> "$LOG"; touch "$1/out/ui/w.js" "$1/out/.built"\n' > "$R/apps/build.sh"
printf '#!/bin/bash\necho "GATE $*" >> "$LOG"\n' > "$R/shell/dev/gate.sh"
printf '#!/bin/bash\necho "ADB $1" >> "$LOG"\n' > "$ADB"
chmod +x "$R/apps/install.sh" "$R/apps/build.sh" "$R/shell/dev/gate.sh" "$ADB"
echo '{ "id": "fake" }' > "$R/apps/fake/powos-app.json"
touch -t 202601010000 "$R/apps/fake/powos-app.json" "$R/apps/fake/out/ui/w.js" "$R/apps/fake/out/.built"
echo 'export default 1' > "$R/apps/fake/ui/widgets/w.tsx"   # now: newer than out/
fails=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fails=$((fails+1)); }

# --no-build with a stale out/: refused, the newer file named, nothing built/gated/pushed.
: > "$LOG"
if bash "$R/apps/install.sh" fake ui --note "n" --no-build > "$T/out1" 2>&1; then bad "--no-build stale: not refused"; else ok "--no-build stale: refused"; fi
grep -q "ui/widgets/w.tsx" "$T/out1" && ok "refusal names ui/widgets/w.tsx" || { bad "refusal names the file"; cat "$T/out1"; }
[ ! -s "$LOG" ] && ok "--no-build stale: nothing built or installed" || { bad "--no-build stale ran something"; cat "$LOG"; }

# Default: built first, then gated, then pushed - in that order.
: > "$LOG"
bash "$R/apps/install.sh" fake ui --note "n" > "$T/out2" 2>&1 && ok "default install ran" || { bad "default install failed"; cat "$T/out2"; }
[ "$(cut -d' ' -f1 "$LOG" | uniq | tr '\n' ' ')" = "BUILD GATE ADB " ] && ok "build -> gate -> install" || { bad "order"; cat "$LOG"; }

# --no-build with a fresh out/ (the build above): installs without building.
: > "$LOG"
bash "$R/apps/install.sh" fake ui --no-build --note "n" > "$T/out3" 2>&1 && ok "--no-build fresh: installed" || { bad "--no-build fresh failed"; cat "$T/out3"; }
grep -q '^BUILD' "$LOG" && bad "--no-build built" || ok "--no-build: no build"
grep -q '^ADB' "$LOG" && ok "--no-build fresh: pushed" || bad "--no-build fresh: not pushed"

# A failing build refuses the install.
printf '#!/bin/bash\nexit 1\n' > "$R/apps/build.sh"; : > "$LOG"
bash "$R/apps/install.sh" fake ui --note "n" > "$T/out4" 2>&1 && bad "failed build installed" || ok "failed build refuses"
grep -q '^ADB' "$LOG" && bad "failed build pushed" || ok "failed build: nothing pushed"

[ "$fails" = 0 ] && echo "all pass" || echo "$fails failed"
exit "$fails"
