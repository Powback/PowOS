#!/usr/bin/env bash
# powos-core carries the shared composed module prebuilt (razr 11-14: "no composed module here (apps/composed,
# /usr/lib/powos/apps/composed)" - CLI and home's compose UI alike; with no Rust on the phone nothing could build it).
# Stages the package (POWOS_CORE_STAGE, a composed build stand-in via POWOS_CORE_COMPOSED), runs its package() the way
# makepkg does, then composes a widget from the packaged copy: the folder must carry the prebuilt wasm + stamp +
# bindings, so `powos app install` builds no module. A build without it, or with a stale stamp, is refused.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { echo "  PASS: $*"; pass=$((pass+1)); }
bad() { echo "  FAIL: $*"; fail=$((fail+1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/cl/dist"; echo 'console.log("cli")' > "$T/cl/dist/cli.js"; echo 'export {}' > "$T/cl/dist/index.js"
fake_composed() { bash "$ROOT/test/tier1/fixtures/fake-composed.sh" "$1" ${2:+stale}; }  # dir [stale]
fake_composed "$T/comp"
stage() { CLAUDE_LOGIN_DIR="$T/cl" CLAUDE_LOGIN_NO_CLONE=1 POWOS_CORE_STAGE="$1" "$ROOT/targets/android/build-powos-core.sh" 2>&1; }

out=$(POWOS_CORE_COMPOSED="$T/comp" stage "$T/w") && ok "staged" || bad "build-powos-core.sh didn't stage: $out"
mkdir -p "$T/srcdir" "$T/pkgdir"
for f in powos-src claude-login composed; do [ -f "$T/w/$f.tar" ] && tar -C "$T/srcdir" -xf "$T/w/$f.tar"; done
cp "$T/w/phone-files.sh" "$T/srcdir/" 2>/dev/null
( srcdir=$T/srcdir pkgdir=$T/pkgdir; . "$T/w/PKGBUILD" && package ) > "$T/pkg.log" 2>&1 || bad "package() failed: $(tail -5 "$T/pkg.log")"
C=$T/pkgdir/usr/lib/powos/apps/composed
for f in module/Cargo.toml module/src/lib.rs out/module.wasm out/.module.sha out/bindings/index.ts; do
  [ -s "$C/$f" ] && ok "powos-core has /usr/lib/powos/apps/composed/$f" || bad "powos-core lacks /usr/lib/powos/apps/composed/$f"
done
grep -q composed.tar "$T/w/PKGBUILD" && ok "PKGBUILD sources the composed build" || bad "PKGBUILD has no composed.tar"

# The packaged copy is what powos compose finds on a phone (no Rust): the folder gets the prebuilt module.
d=$T/app
r=$(POWOS_COMPOSED_DIR="$C" POWOS_APPAPI_STATE="$T/state" POWOS_COMPOSE_AI=off POWOS_COMPOSE_SPECS="$ROOT/tools/app-api/examples" \
  python3 "$ROOT/lib/apps/powos-compose" widget "which hue rooms are on" --no-install --dir "$d" 2>&1) || bad "compose failed: $r"
{ cmp -s "$d/out/module.wasm" "$C/out/module.wasm" && [ -f "$d/ui/bindings/index.ts" ] && [ -f "$d/out/.module.sha" ]; } &&
  ok "a composed widget carries the packaged prebuilt module (no Rust build)" || bad "composed folder lacks the prebuilt module: $r"
echo "$r" | grep -q "no prebuilt one" && bad "compose says no prebuilt: $r" || ok "compose found the prebuilt build"

# No composed build, or a stale one: refused (a package without it left composing needing Rust).
out=$(stage "$T/w2") && bad "staged without a composed build" || ok "refuses without a composed build"
fake_composed "$T/stale" 1
out=$(POWOS_CORE_COMPOSED="$T/stale" stage "$T/w3") && bad "staged a stale composed build" || ok "refuses a stale composed stamp"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
