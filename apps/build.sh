#!/bin/bash
# Builds a PowOS app's module (Rust -> wasm, in an arm64 Rust container: no Rust toolchain on the Mac or the phone)
# and its TypeScript client bindings, with the SpacetimeDB CLI pinned in targets/android/pkgs/spacetimedb-bin.
#   apps/build.sh <app>        e.g. apps/build.sh counter
# Output: apps/<app>/out/module.wasm, and apps/<app>/ui/bindings/ (generated; the UI imports it).
# An app without a module (UI only: "module": null, e.g. stickman) skips that half. An app with an assets.sh runs it
# first: it fetches what the UI ships but git doesn't keep (stickman: MuJoCo's wasm, a trained brain).
# Installing on the phone: apps/install.sh <app> (the module published, the UI and manifest in place, the registry).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
APP=${1:?usage: apps/build.sh <app>}
D=$HERE/$APP
[ -f "$D/module/Cargo.toml" ] || [ -d "$D/ui" ] || { echo "build.sh: $D has neither module/Cargo.toml nor ui/" >&2; exit 1; }
[ -x "$D/assets.sh" ] && "$D/assets.sh"
mkdir -p "$D/out"
if [ -f "$D/module/Cargo.toml" ]; then
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
  if [ -d /app/ui ]; then
    rm -rf /app/ui/bindings && $S/spacetimedb-cli generate --lang typescript --out-dir /app/ui/bindings --bin-path /app/out/module.wasm -y >/dev/null
  fi
  chown -R $HOST_UID /app/out /app/ui/bindings 2>/dev/null || true
  ls -la /app/out/module.wasm'
fi
# The UI: static files as they are, widgets (ui/widgets/*.tsx) bundled one ES module each with their bindings -
# Preact and the SpacetimeDB SDK stay imports, which the shell's import map resolves to its own (one copy per page).
# Workers (ui/workers/*.ts) are bundled whole: a worker has no import map.
if [ -d "$D/ui" ]; then
  docker run --rm --platform linux/arm64 -v powos-apps-cargo:/cache -v "$D:/app" -e HOST_UID="$(id -u)" node:22 bash -c '
    set -euo pipefail
    E=/cache/esbuild-0.25; [ -x $E/node_modules/.bin/esbuild ] || (mkdir -p $E && cd $E && npm i -s esbuild@0.25 >/dev/null 2>&1)
    rm -rf /app/out/ui && mkdir -p /app/out/ui
    cd /app/ui && find . -type f ! -name "*.ts" ! -name "*.tsx" ! -path "./bindings/*" -exec cp --parents {} /app/out/ui/ \;
    w=$(ls widgets/*.tsx 2>/dev/null || true)
    [ -z "$w" ] || $E/node_modules/.bin/esbuild $w --bundle --format=esm --target=es2022 --jsx=automatic --jsx-import-source=preact \
      --external:preact --external:preact/hooks --external:preact/jsx-runtime --external:@preact/signals --external:spacetimedb \
      --minify --outdir=/app/out/ui/widgets --log-level=warning
    k=$(ls workers/*.ts 2>/dev/null || true)
    [ -z "$k" ] || $E/node_modules/.bin/esbuild $k --bundle --format=esm --target=es2022 --minify --outdir=/app/out/ui/workers --log-level=warning
    chown -R $HOST_UID /app/out/ui; ls -la /app/out/ui/widgets 2>/dev/null || true'
fi
