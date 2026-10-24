#!/bin/bash
# Builds a PowOS app's module (Rust -> wasm, in an arm64 Rust container: no Rust toolchain on the Mac or the phone)
# and its TypeScript client bindings, with the SpacetimeDB CLI pinned in targets/android/pkgs/spacetimedb-bin.
#   apps/build.sh <app|dir>    e.g. apps/build.sh counter, apps/build.sh ~/Projects/hue-rooms (any app folder)
# Output: apps/<app>/out/module.wasm, and its TS bindings in apps/<app>/ui/bindings/ (the UI imports them; no UI:
# out/bindings/, for apps/vendor.sh).
# An app without a module (UI only: "module": null, e.g. stickman) skips that half. An app with an assets.sh runs it
# first: it fetches what the UI ships but git doesn't keep (stickman: MuJoCo's wasm, a trained brain).
# Installing on the phone: apps/install.sh <app> (the module published, the UI and manifest in place, the registry).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
APP=${1:?usage: apps/build.sh <app>}
# An app of the repo (apps/<app>) or any app folder by its path (a composed one: powos compose ... --no-install).
case $APP in */*) D=$(cd "$APP" && pwd) ;; *) D=$HERE/$APP ;; esac
[ -f "$D/module/Cargo.toml" ] || [ -d "$D/ui" ] || { echo "build.sh: $D has neither module/Cargo.toml nor ui/" >&2; exit 1; }
[ -x "$D/assets.sh" ] && "$D/assets.sh"
mkdir -p "$D/out"
# The module source's hash, as `powos app build` keeps it in out/.module.sha (lib/apps/powos-app tree_hash: target/
# and Cargo.lock skipped).
src_sha() {
  python3 - "$D/module" <<'PY'
import hashlib, os, sys
d, h = sys.argv[1], hashlib.sha256()
for root, dirs, files in os.walk(d):
    dirs[:] = sorted(x for x in dirs if os.path.relpath(os.path.join(root, x), d) not in ("target", "Cargo.lock"))
    for f in sorted(files):
        p = os.path.join(root, f); rel = os.path.relpath(p, d)
        if rel in ("target", "Cargo.lock"): continue
        h.update(rel.encode() + b"\0"); h.update(open(p, "rb").read())
print(h.hexdigest())
PY
}
# A folder outside apps/ that already carries this module's build (a composed app: powos compose copies the shared
# apps/composed build in, wasm + stamp + bindings) keeps it: only its UI is built.
prebuilt=""
if [ "${D#"$HERE"/}" = "$D" ] && [ -f "$D/out/module.wasm" ] && [ -f "$D/module/Cargo.toml" ] &&
   [ "$(cat "$D/out/.module.sha" 2>/dev/null)" = "$(src_sha)" ] && { [ ! -d "$D/ui" ] || [ -d "$D/ui/bindings" ]; }; then
  prebuilt=1; echo "module: this build already (out/.module.sha) - not rebuilt"
fi
if [ -f "$D/module/Cargo.toml" ] && [ -z "$prebuilt" ]; then
# The complexity lint (tools/lint/rust-complexity.sh: clippy, cognitive 10 / 60 lines / 4 args / nesting 3; old debt in
# tools/lint/rust-complexity-baseline.txt, which only shrinks): a module over it isn't built. Exit 2 (no docker) warns.
cx=0; "$HERE/../tools/lint/rust-complexity.sh" "$(basename "$D")" || cx=$?
if [ "$cx" = 1 ]; then echo "build: refusing $(basename "$D") - the complexity lint failed (above)" >&2; exit 4; fi
VER=$(sed -n 's/^pkgver=//p' "$HERE/../targets/android/pkgs/spacetimedb-bin/PKGBUILD")
SUM=$(sed -n "s/^sha256sums=('\(.*\)')/\1/p" "$HERE/../targets/android/pkgs/spacetimedb-bin/PKGBUILD")
mkdir -p "$D/out"
# The cargo registry and the CLI download persist in a volume (one Rust toolchain image, reused by every app).
docker run --rm --platform linux/arm64 --cpus 6 --memory 8g -v powos-apps-cargo:/cache -v "$D:/app" \
  -e CARGO_HOME=/cache/cargo -e VER="$VER" -e SUM="$SUM" -e HOST_UID="$(id -u)" rust:1-bookworm bash -c '
  set -euo pipefail
  S=/cache/spacetime-$VER
  if [ ! -x $S/spacetimedb-standalone ]; then
    mkdir -p $S && curl -sSL -o /tmp/s.tgz https://github.com/clockworklabs/SpacetimeDB/releases/download/v$VER/spacetime-aarch64-unknown-linux-gnu.tar.gz
    echo "$SUM  /tmp/s.tgz" | sha256sum -c - >/dev/null && tar xzf /tmp/s.tgz -C $S
  fi
  rustup target list --installed | grep -q wasm32-unknown-unknown || rustup target add wasm32-unknown-unknown >/dev/null
  cd /app/module
  CARGO_TARGET_DIR=/cache/target-$(basename "$(dirname "$PWD")") cargo build --release --target wasm32-unknown-unknown -q
  W=/cache/target-$(basename "$(dirname "$PWD")")/wasm32-unknown-unknown/release/$(sed -n "s/^name = \"\(.*\)\"/\1/p" Cargo.toml | head -1 | tr - _).wasm
  cp "$W" /app/out/module.wasm
  # The TS bindings: the UI imports ui/bindings; an app without a UI keeps them in out/bindings (apps/vendor.sh).
  B=/app/out/bindings; [ -d /app/ui ] && B=/app/ui/bindings
  rm -rf $B && $S/spacetimedb-cli generate --lang typescript --out-dir $B --bin-path /app/out/module.wasm -y >/dev/null
  chown -R $HOST_UID /app/out $B 2>/dev/null || true
  ls -la /app/out/module.wasm'
# The source's hash beside the wasm (src_sha): a folder that carries this build isn't built again on the device.
src_sha > "$D/out/.module.sha"
fi
# The UI: static files as they are, widgets and pages (ui/widgets/*.tsx, ui/pages/*.tsx) bundled one ES module each
# with their bindings (pages were missed until 2026-10-23: a page change never shipped through here) -
# Preact and the SpacetimeDB SDK stay imports, which the shell's import map resolves to its own (one copy per page).
# Workers (ui/workers/*.ts) are bundled whole: a worker has no import map.
# __POWOS_SCHEMA__: the bindings' fingerprint, as `powos app build` defines it (lib/apps/powos-app tree_hash, 16 hex):
# a new schema makes the host reconnect with the new bindings.
# shell/ui/shared (friction f179): mounted read-only at /shared and aliased to @powos/shared, so an app's own UI
# can import the shell's framework-neutral building blocks (e.g. @powos/shared/pending) instead of forking them -
# the app's own folder is still the only thing mounted writable, so a bundled app can't reach into or modify shell/.
if [ -d "$D/ui" ]; then
  SCHEMA=$(python3 - "$D/ui/bindings" <<'PY'
import hashlib, os, sys
d, h = sys.argv[1], hashlib.sha256()
if not os.path.isdir(d): print("none"); sys.exit()
for root, dirs, files in os.walk(d):
    dirs[:] = sorted(dirs)
    for f in sorted(files):
        p = os.path.join(root, f); h.update(os.path.relpath(p, d).encode() + b"\0"); h.update(open(p, "rb").read())
print(h.hexdigest()[:16])
PY
)
  docker run --rm --platform linux/arm64 -v powos-apps-cargo:/cache -v "$D:/app" -v "$REPO/shell/ui/shared:/shared:ro" \
    -e HOST_UID="$(id -u)" -e SCHEMA="$SCHEMA" node:22 bash -c '
    set -euo pipefail
    E=/cache/esbuild-0.25; [ -x $E/node_modules/.bin/esbuild ] || (mkdir -p $E && cd $E && npm i -s esbuild@0.25 >/dev/null 2>&1)
    rm -rf /app/out/ui && mkdir -p /app/out/ui
    cd /app/ui && find . -type f ! -name "*.ts" ! -name "*.tsx" ! -name "tsconfig.json" ! -path "./bindings/*" -exec cp --parents {} /app/out/ui/ \;
    w=$(ls widgets/*.tsx pages/*.tsx 2>/dev/null || true)
    [ -z "$w" ] || $E/node_modules/.bin/esbuild $w --bundle --format=esm --target=es2022 --jsx=automatic --jsx-import-source=preact \
      --external:preact --external:preact/hooks --external:preact/jsx-runtime --external:@preact/signals --external:spacetimedb \
      --alias:@powos/shared=/shared \
      --define:__POWOS_SCHEMA__="\"$SCHEMA\"" --minify --outdir=/app/out/ui --outbase=/app/ui --log-level=warning
    k=$(ls workers/*.ts 2>/dev/null || true)
    [ -z "$k" ] || $E/node_modules/.bin/esbuild $k --bundle --format=esm --target=es2022 --minify --alias:@powos/shared=/shared --outdir=/app/out/ui/workers --log-level=warning
    chown -R $HOST_UID /app/out/ui; ls -la /app/out/ui/widgets /app/out/ui/pages 2>/dev/null || true'
fi
