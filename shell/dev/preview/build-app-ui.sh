#!/bin/bash
# Bundles a PowOS app's UI for the widget preview, on the Mac (no bun here): ui/widgets/*.tsx and ui/pages/*.tsx, one
# ES module each into <appdir>/out/ui/, the static files copied as they are - as `powos app build --ui` lays it out.
# Only the UI: the module isn't built (apps/build.sh does both, for the repo's apps/*; this takes any app folder, e.g.
# one pulled from the phone with tools/phone/app-src.sh pull).
#   shell/dev/preview/build-app-ui.sh <appdir>      then: shell/dev/preview.sh --no-defaults --app <appdir> ...
# Preact and the SpacetimeDB SDK stay imports (the shell's import map resolves them). esbuild is cached in the
# powos-apps-cargo volume (apps/build.sh's), node:22 arm64.
set -euo pipefail
D=$(cd "${1:?usage: build-app-ui.sh <appdir>}" && pwd)
[ -d "$D/ui" ] || { echo "build-app-ui: no ui/ in $D" >&2; exit 1; }
docker run --rm --platform linux/arm64 -v powos-apps-cargo:/cache -v "$D:/app" -e HOST_UID="$(id -u)" node:22 bash -c '
  set -euo pipefail
  E=/cache/esbuild-0.25; [ -x $E/node_modules/.bin/esbuild ] || (mkdir -p $E && cd $E && npm i -s esbuild@0.25 >/dev/null 2>&1)
  rm -rf /app/out/ui && mkdir -p /app/out/ui
  cd /app/ui && find . -type f ! -name "*.ts" ! -name "*.tsx" ! -name "tsconfig.json" ! -path "./bindings/*" -exec cp --parents {} /app/out/ui/ \;
  src=$(ls widgets/*.tsx pages/*.tsx 2>/dev/null || true)
  [ -z "$src" ] || $E/node_modules/.bin/esbuild $src --bundle --format=esm --target=es2022 --jsx=automatic \
    --jsx-import-source=preact --external:preact --external:preact/hooks --external:preact/jsx-runtime \
    --external:@preact/signals --external:spacetimedb --minify --outdir=/app/out/ui --outbase=/app/ui --log-level=warning
  chown -R $HOST_UID /app/out
  echo "built $(ls /app/out/ui/widgets /app/out/ui/pages 2>/dev/null | grep -c "\.js$") module(s) in out/ui"'
