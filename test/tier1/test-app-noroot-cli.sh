#!/bin/bash
# Hermetic test of `powos app` on a phone without root (gh#13): no spacetime CLI, no cargo, no builder, no
# powos-runtime/supervisor on PATH, POWOS_LOOPBACK_DIR set (what SessionService gives a no-root session).
#   1. `powos app check` / `runtime` / `services`: a capability table, never a traceback (execvp powos-runtime);
#   2. `build --ui` of a scaffold with a module: says the UI's ui/bindings come from the module's build and why that
#      can't run here - not bun's `Could not resolve: "../bindings"`;
#   3. a UI-only app ("module": null) installs into POWOS_APPS_DIR with no SpacetimeDB at all (the launcher lists
#      files/apps itself there).
# A stub `bun` stands in for the bundler (writes each entry as .js): no network, no node_modules.
#   test/tier1/test-app-noroot-cli.sh        exit 0 = all pass
set -uo pipefail
src=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/app-noroot.XXXXXX"); trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fails=$((fails+1)); }

# A PATH with only what a fresh no-root image has for this: python3, sh tools - and the stub bun.
B=$T/bin; mkdir -p "$B"
for t in python3 sh bash env cat mkdir cp rm mv ls dirname basename uname; do
  p=$(command -v "$t") && ln -sf "$p" "$B/$t"
done
cat > "$B/bun" <<'EOF'
#!/bin/sh
# bun build <entries...> --outdir D ...: each entry -> D/<entry>.js
[ "$1" = build ] || exit 1; shift
out=""; ents=""
while [ $# -gt 0 ]; do
  case "$1" in --outdir) out=$2; shift 2;; --*) shift 2;; *) ents="$ents $1"; shift;; esac
done
for e in $ents; do
  grep -q '"\.\./bindings"' "$e" && [ ! -d bindings ] && { echo "error: Could not resolve: \"../bindings\"" >&2; exit 1; }
  mkdir -p "$out/$(dirname "$e")"; echo "// $e" > "$out/${e%.*}.js"
done
EOF
chmod +x "$B/bun"
# powos-app alone (+ its templates): an install whose lib/apps has no powos-runtime/powos-supervisor beside it.
L=$T/lib; mkdir -p "$L"; cp "$src/lib/apps/powos-app" "$L/"; cp -R "$src/lib/apps/templates" "$L/"
APP=$L/powos-app
run() { env -i HOME="$T/home" PATH="$B" POWOS_LOOPBACK_DIR="$T/loopback" POWOS_APPS_DIR="$T/apps" \
  POWOS_APP_BUILDER_CONF="$T/builder" python3 "$APP" "$@"; }
mkdir -p "$T/home"

# 1. check / runtime / services
out=$(run check 2>&1); rc=$?
[ $rc = 0 ] && ok "check exits 0" || bad "check rc=$rc: $out"
echo "$out" | grep -q Traceback && bad "check: traceback" || ok "check: no traceback"
echo "$out" | grep -qE '^install +no +no spacetime CLI' && ok "check: install row says no spacetime CLI" || bad "check install row: $out"
echo "$out" | grep -qE '^build module +no ' && ok "check: module build row says no" || bad "check module row: $out"
echo "$out" | grep -qE '^services +yes .*powos-noroot-services' && ok "check: services via the PowOS app" || bad "check services row: $out"
out=$(run runtime 2>&1); echo "$out" | grep -q Traceback && bad "runtime: traceback" || ok "runtime: no traceback"
out=$(run runtime local.x 2>&1); echo "$out" | grep -q "no powos-runtime here" && ok "runtime <id>: says why" || bad "runtime <id>: $out"
out=$(run services 2>&1); { [ $? = 0 ] && ! echo "$out" | grep -q Traceback; } && ok "services: table" || bad "services: $out"
# The baked source tree has powos-runtime beside powos-app but not on PATH (the no-root image): found, run.
APP=$src/lib/apps/powos-app
out=$(run check 2>&1); echo "$out" | grep -qE '^sandbox ' && ok "check: sibling powos-runtime check runs" || bad "sibling runtime: $out"
out=$(run services 2>&1); echo "$out" | grep -q "powos-noroot-services" && ok "services (no root): the PowOS app's, not the supervisor's" || bad "services no root: $out"
APP=$L/powos-app

# 2. build --ui with a module and no bindings
run new tally --dir "$T/tally" > /dev/null 2>&1 || bad "new tally"
out=$(run build "$T/tally" --ui 2>&1); rc=$?
[ $rc != 0 ] && ok "build --ui without bindings fails" || bad "build --ui passed without bindings"
echo "$out" | grep -q "Could not resolve" && bad "build --ui: bun's raw error" || ok "build --ui: not bun's raw error"
echo "$out" | grep -q "ui/bindings, made from the module" && ok "build --ui: names the bindings + module" || bad "build --ui msg: $out"
echo "$out" | grep -q '"module": null' && ok "build --ui: offers UI-only" || bad "build --ui: no UI-only hint"

# 3. a UI-only app installs with no SpacetimeDB
mkdir -p "$T/w/ui/widgets"
cat > "$T/w/powos-app.json" <<'EOF'
{ "id": "local.w", "name": "W", "version": "0.1.0", "ui": { "dir": "out/ui/" }, "module": null,
  "widgets": [ { "id": "main", "kind": "island", "entry": "widgets/main.js", "size": "2x2" } ] }
EOF
echo 'export default () => null' > "$T/w/ui/widgets/main.tsx"
out=$(run install "$T/w" 2>&1); rc=$?
[ $rc = 0 ] && ok "UI-only install without spacetime" || bad "UI-only install rc=$rc: $out"
[ -f "$T/apps/local.w/current/ui/widgets/main.js" ] && ok "installed into POWOS_APPS_DIR" || bad "not in apps dir: $(ls -R "$T/apps" 2>&1 | head)"
[ -f "$T/apps/local.w/current/powos-app.json" ] && ok "manifest installed" || bad "no manifest"

# Rooted (no POWOS_LOOPBACK_DIR): a missing spacetime CLI still refuses - the registry is the way in there.
out=$(env -i HOME="$T/home" PATH="$B" POWOS_APPS_DIR="$T/apps2" POWOS_APP_BUILDER_CONF="$T/builder" \
  python3 "$APP" install "$T/w" 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "no spacetime CLI" && ok "rooted: still needs the registry" || bad "rooted install: rc=$rc $out"

[ "$fails" = 0 ] && echo "all pass" || echo "$fails failed"
exit "$fails"
