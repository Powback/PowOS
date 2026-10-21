#!/bin/bash
# The shell's copy of an app's bindings (shell/vendor/<database>.js, the apps listed "generated" in shell/vendor/VERSIONS):
# the module built (apps/build.sh), its TS bindings bundled into one ES module, spacetimedb left an import (the shell's
# import map resolves it to its own copy).
#   apps/vendor.sh <app> [--out FILE]     default: shell/vendor/<database>.js (commit it, push vendor/<database>.js)
# A module change ships with this AND a publish (apps/install.sh <app> publish): the shell can't decode rows of another
# shape (tools/phone/bindings-check.sh, run by shell/push.sh and ship-apk, compares them with the phone's).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
APP=${1:?usage: apps/vendor.sh <app> [--out FILE]}
DB=$(sed -n "s|^\([a-z0-9-]*\)\.js  *generated  *apps/$APP:.*|\1|p" "$HERE/../shell/vendor/VERSIONS")
[ -n "$DB" ] || { echo "vendor.sh: apps/$APP isn't a vendored binding (shell/vendor/VERSIONS)" >&2; exit 1; }
OUT=$HERE/../shell/vendor/$DB.js
[ "${2:-}" = --out ] && OUT=${3:?--out FILE}
"$HERE/build.sh" "$APP" >/dev/null
B=ui/bindings; [ -d "$HERE/$APP/ui" ] || B=out/bindings
mkdir -p "$(dirname "$OUT")"; touch "$OUT"; OUT=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")
docker run --rm --platform linux/arm64 -v powos-apps-cargo:/cache -v "$HERE/$APP:/app:ro" -v "$(dirname "$OUT"):/out" \
  -e HOST_UID="$(id -u)" node:22 bash -c '
  set -euo pipefail
  E=/cache/esbuild-0.25; [ -x $E/node_modules/.bin/esbuild ] || (mkdir -p $E && cd $E && npm i -s esbuild@0.25 >/dev/null 2>&1)
  $E/node_modules/.bin/esbuild /app/'"$B"'/index.ts --bundle --format=esm --minify --external:spacetimedb \
    --outfile=/out/'"$(basename "$OUT")"' --log-level=warning
  chown $HOST_UID /out/'"$(basename "$OUT")"
echo "$OUT"
