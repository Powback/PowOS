#!/bin/bash
# The shell's copy of an app's bindings (shell/vendor/<database>.js, the apps listed "generated" in shell/vendor/VERSIONS):
# the module built (apps/build.sh), its TS bindings bundled into one ES module, spacetimedb left an import (the shell's
# import map resolves it to its own copy).
#   apps/vendor.sh <app> [--out FILE]     default: shell/vendor/<database>.js (commit it, push vendor/<database>.js)
# A module change ships with this AND a publish (apps/install.sh <app> publish): the shell can't decode rows of another
# shape (tools/phone/bindings-check.sh, run by shell/push.sh and ship-apk, compares them with the phone's).
#   apps/vendor.sh --check <app>...       the committed shell/vendor/<database>.js IS what apps/<app>/module builds
#                                         (regenerated into a temp file, byte for byte) - else exit 1 with the fix
#   apps/vendor.sh --changed A B          "<app> <database>" of each vendored app whose module/ changed in A..B
# A schema change ships atomically (2026-10-30: powos-agents' work.try_line was published before shell/vendor/
# powos-agents.js was regenerated - home's board subscription stopped decoding): the module and its regenerated
# bindings in the SAME commit. tools/agents/land.sh and the ship service's apps step (tools/phone/ship.sh) run --check
# and refuse a module whose committed bindings differ. VENDOR_GEN (tests) replaces the generator: VENDOR_GEN <app> OUT.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
vendored() { sed -n 's|^\([a-z0-9-]*\)\.js  *generated  *apps/\([a-z0-9-]*\):.*|\2 \1|p' "$HERE/../shell/vendor/VERSIONS"; }
case "${1:-}" in
--changed)
  A=${2:?--changed A B} B=${3:?--changed A B}
  vendored | while read -r app db; do
    if [ -n "$(git -C "$HERE/.." diff --name-only "$A" "$B" -- "apps/$app/module" 2>/dev/null | grep -v '/Cargo.lock$')" ]; then echo "$app $db"; fi
  done; exit 0 ;;
--check)
  shift; rc=0; mkdir -p "$HOME/.cache"; tmp=$(mktemp -d "$HOME/.cache/powos-vendor-check.XXXXXX")   # under ~: Colima mounts it, not /tmp or $TMPDIR; trap 'rm -rf "$tmp"' EXIT
  for app in "$@"; do
    db=$(vendored | awk -v a="$app" '$1 == a {print $2}')
    [ -n "$db" ] || { echo "vendor: apps/$app has no vendored binding - nothing to check"; continue; }
    if ! ${VENDOR_GEN:-"$HERE/vendor.sh"} "$app" --out "$tmp/$db.js" > "$tmp/gen.log" 2>&1; then
      tail -5 "$tmp/gen.log" >&2
      echo "vendor: REFUSED - apps/$app/module doesn't build its bindings (above)" >&2; rc=1; continue; fi
    if cmp -s "$tmp/$db.js" "$HERE/../shell/vendor/$db.js"; then echo "vendor: shell/vendor/$db.js is what apps/$app/module builds"
    else
      echo "vendor: REFUSED - shell/vendor/$db.js isn't what apps/$app/module builds (a schema change without its bindings):" \
        "run apps/vendor.sh $app and commit shell/vendor/$db.js in the SAME commit as the module" >&2; rc=1
    fi
  done; exit $rc ;;
esac
APP=${1:?usage: apps/vendor.sh <app> [--out FILE] | --check <app>... | --changed A B}
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
# An --out outside what the Docker VM mounts (Colima: ~, not /tmp or $TMPDIR) came back EMPTY with exit 0 - and every
# compare against it said "differs" (2026-10-30). Never hand back an empty bundle.
[ -s "$OUT" ] || { echo "vendor.sh: $OUT came back empty - is its folder mounted in the Docker VM (use one under ~)?" >&2; exit 1; }
echo "$OUT"
