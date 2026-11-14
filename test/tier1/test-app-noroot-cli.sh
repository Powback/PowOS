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

# ... and removes with none (11-10: "no spacetime CLI here" and the widget stayed on the phone).
out=$(run remove local.w 2>&1); rc=$?
{ [ $rc = 0 ] && [ ! -e "$T/apps/local.w" ]; } && ok "UI-only remove without spacetime" || bad "UI-only remove rc=$rc: $out"

# 3b. `powos app new --template ui` (razr 11-14: a UI-only app meant deleting module/ and ui/lib by hand): page +
# widget, "module": null, no ../bindings import anywhere - builds and installs with no Rust and no SpacetimeDB.
out=$(run new note --template ui --dir "$T/note" 2>&1) && ok "new --template ui" || bad "new --template ui: $out"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["module"] is None and m["page"]["entry"] == "pages/main.js" and [w["entry"] for w in m["widgets"]] == ["widgets/main.js"], m' \
  "$T/note/powos-app.json" 2>/dev/null && ok "ui template: module null, a page and a widget" || bad "ui manifest: $(cat "$T/note/powos-app.json" 2>&1)"
[ ! -e "$T/note/module" ] && ok "ui template: no module/" || bad "ui template has module/"
(cd "$T/note/ui" && ! command grep -rq '"../bindings"' .) && ok "ui template: no bindings import" || bad "ui template imports bindings"
out=$(run build "$T/note" 2>&1); rc=$?
{ [ $rc = 0 ] && [ -f "$T/note/out/ui/widgets/main.js" ] && [ -f "$T/note/out/ui/pages/main.js" ]; } && ok "ui template builds" || bad "ui template build rc=$rc: $out"
out=$(run install "$T/note" 2>&1); rc=$?
{ [ $rc = 0 ] && [ -f "$T/apps/local.note/current/ui/pages/main.js" ]; } && ok "ui template installs without spacetime" || bad "ui template install rc=$rc: $out"
run remove local.note >/dev/null 2>&1

# 4. A module with no Rust and no builder (gh#13 A3): the toolchain packs (rust, + dev for gcc) are offered, added only
# on a yes, then the module builds with the pack's toolchain offline, its prebuilt crates seeding the target dir.
# The stub keeps each pack's install apart: $T/rust is the rust pack (POWOS_RUST), $T/dev-added the dev pack.
cat > "$B/powos-pack" <<EOF
#!/bin/sh
echo "powos-pack \$*" >> "$T/pack.log"
case "\$1 \$2" in
  "status dev") [ -e "$T/dev-added" ] ;;
  "status rust") [ -e "$T/rust/cargo/bin/cargo" ] ;;
  "need dev") touch "$T/dev-added" ;;
  "need rust") mkdir -p "$T/rust/cargo/bin" "$T/rust/sys/lib/rustlib/wasm32-unknown-unknown" "$T/rust/app-target/seeded"
  printf '#!/bin/sh\necho $T/rust/sys\n' > "$T/rust/cargo/bin/rustc"
  printf '#!/bin/sh\necho "cargo \$* CARGO_HOME=\$CARGO_HOME" >> $T/cargo.log; d=\$CARGO_TARGET_DIR/wasm32-unknown-unknown/release; mkdir -p \$d; echo w > \$d/powos_app_tally.wasm\n' > "$T/rust/cargo/bin/cargo"
  chmod +x "$T/rust/cargo/bin/"* ;;
esac
EOF
chmod +x "$B/powos-pack"; for t in grep chmod touch; do ln -sf "$(command -v $t)" "$B/$t"; done
rust() { run "$@" 2>&1 </dev/null; }
run() { env -i HOME="$T/home" PATH="$B" POWOS_LOOPBACK_DIR="$T/loopback" POWOS_APPS_DIR="$T/apps" POWOS_RUST="$T/rust" \
  POWOS_APP_BUILDER_CONF="$T/builder" ${ADD:+POWOS_APP_ADD_TOOLCHAIN=1} python3 "$APP" "$@"; }
out=$(rust build "$T/tally" --module); rc=$?
{ [ $rc != 0 ] && echo "$out" | grep -q "add the dev + rust packs" && echo "$out" | grep -q "powos app builder user@host"; } &&
  ok "no toolchain: both choices shown" || bad "no toolchain msg rc=$rc: $out"
grep -q "need" "$T/pack.log" 2>/dev/null && bad "the pack was added without a yes" || ok "no download without a yes"
# The razr (11-14): dev added before the toolchain had a pack of its own - only rust is offered and added.
touch "$T/dev-added"
out=$(rust build "$T/tally" --module); rc=$?
{ [ $rc != 0 ] && echo "$out" | grep -q "add the rust pack " ; } && ok "dev already in: only the rust pack offered" || bad "dev-in msg rc=$rc: $out"
out=$(ADD=1 rust build "$T/tally" --module)
{ grep -q "need rust" "$T/pack.log" && ! grep -q "need dev" "$T/pack.log"; } && ok "a yes adds the rust pack (dev kept)" || bad "packs: $(cat "$T/pack.log") $out"
grep -q -- "--offline.*CARGO_HOME=$T/rust/cargo" "$T/cargo.log" 2>/dev/null && ok "the module builds offline with the pack's cargo" || bad "cargo: $(cat "$T/cargo.log" 2>&1) / $out"
[ -e "$T/home/.cache/powos/app-target/seeded" ] && ok "the prebuilt crates seed the target dir" || bad "target not seeded"
[ -f "$T/tally/out/module.wasm" ] && ok "out/module.wasm" || bad "no module.wasm: $out"
# A fresh phone: a yes adds both.
rm -rf "$T/rust" "$T/dev-added" "$T/tally/out" "$T/pack.log"
out=$(ADD=1 rust build "$T/tally" --module)
{ grep -q "need dev" "$T/pack.log" && grep -q "need rust" "$T/pack.log" && [ -f "$T/tally/out/module.wasm" ]; } &&
  ok "a yes on a fresh phone adds dev + rust, then builds" || bad "fresh: $(cat "$T/pack.log") $out"

# Rooted (no POWOS_LOOPBACK_DIR): a missing spacetime CLI still refuses - the registry is the way in there.
out=$(env -i HOME="$T/home" PATH="$B" POWOS_APPS_DIR="$T/apps2" POWOS_APP_BUILDER_CONF="$T/builder" \
  python3 "$APP" install "$T/w" 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "no spacetime CLI" && ok "rooted: still needs the registry" || bad "rooted install: rc=$rc $out"

[ "$fails" = 0 ] && echo "all pass" || echo "$fails failed"
exit "$fails"
