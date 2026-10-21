#!/bin/bash
# The shell's vendored bindings (shell/vendor/<db>.js, "generated" in shell/vendor/VERSIONS) against the LIVE modules on
# the phone's SpacetimeDB: a table of another shape can't be decoded on home (local-pet's columns, twice on 2026-10-21).
#   tools/phone/bindings-check.sh [--schemas FILE] [--vendor DIR]... [--no-publish]
#   tools/phone/bindings-check.sh --remote-cmd      the phone-side command that prints the schemas (one adb shell call)
# --schemas: the phone's schemas already read (shell/push.sh reads them in its one call); else one adb call reads them.
# --vendor: where the phone's copy of each binding is, first match wins (push.sh: the pushed files, the phone's
# overrides, the installed APK's shell); default shell/vendor.
# A module the bindings are AHEAD of (they add tables or columns at the end) is published when this commit's
# apps/<app>/module builds exactly these bindings (apps/vendor.sh, byte for byte): apps/install.sh <app> publish.
# Anything else fails (exit 1) with the command that fixes it. --no-publish: fail instead of publishing.
# Tests: BINDINGS_ADB, BINDINGS_VENDOR, BINDINGS_PUBLISH replace the adb call, apps/vendor.sh and apps/install.sh.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
pairs=$(sed -n 's|^\([a-z0-9-]*\)\.js  *generated  *apps/\([a-z0-9-]*\):.*|\1 \2|p' "$ROOT/shell/vendor/VERSIONS")
dbs=$(echo "$pairs" | awk '{print $1}' | tr '\n' ' ')
remote="su -c 'for d in $dbs; do echo @@\$d; chroot /data/powos/root /usr/bin/curl -s -m 5 http://127.0.0.1:3410/v1/database/\$d/schema?version=9; echo; done'"
[ "${1:-}" = --remote-cmd ] && { echo "$remote"; exit 0; }
schemas="" dirs=() publish=1
while [ $# -gt 0 ]; do
  case "$1" in
    --schemas) schemas=$2; shift 2 ;;
    --vendor) dirs+=("$2"); shift 2 ;;
    --no-publish) publish=""; shift ;;
    *) echo "bindings-check: unknown $1" >&2; exit 2 ;;
  esac
done
[ ${#dirs[@]} -gt 0 ] || dirs=("$ROOT/shell/vendor")
tmp=$(mktemp -d "${TMPDIR:-/tmp}/bindings-check.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
if [ -z "$schemas" ]; then
  schemas=$tmp/schemas
  ${BINDINGS_ADB:-"$ROOT/tools/phone/adb.sh"} shell "$remote" | tr -d '\r' > "$schemas"
fi
args=()
while read -r db app; do
  for d in "${dirs[@]}"; do [ -f "$d/$db.js" ] && { args+=("$db=$d/$db.js"); break; }; done
done <<< "$pairs"
if command -v node >/dev/null; then
  out=$(node "$ROOT/tools/phone/bindings-check.mjs" "$ROOT/shell/vendor/spacetimedb.js" "$schemas" ${args[@]+"${args[@]}"})
else
  out=$(docker run --rm -v "$ROOT:$ROOT:ro" -v "$tmp:$tmp" node:22 node "$ROOT/tools/phone/bindings-check.mjs" \
    "$ROOT/shell/vendor/spacetimedb.js" "$schemas" ${args[@]+"${args[@]}"})
fi
rc=0
while read -r db state what; do
  [ -n "$db" ] || continue
  app=$(echo "$pairs" | awk -v d="$db" '$1 == d {print $2}')
  file=""; for a in ${args[@]+"${args[@]}"}; do [ "${a%%=*}" = "$db" ] && file=${a#*=}; done
  case "$state" in
    ok) echo "bindings: $db matches the phone" ;;
    absent) echo "bindings: $db isn't on the phone - not checked" ;;
    ahead)
      if [ -f "$ROOT/apps/$app/powos-app.json" ] && [ -d "$ROOT/apps/$app/module" ] &&
         ${BINDINGS_VENDOR:-"$ROOT/apps/vendor.sh"} "$app" --out "$tmp/$db.js" >/dev/null && cmp -s "$tmp/$db.js" "$file"; then
        if [ -n "$publish" ]; then
          echo "bindings: $db on the phone lacks $what - publishing apps/$app/module (this commit builds these bindings)"
          name=$(sed -n 's/^ *"name": *"\([^"]*\)".*/\1/p' "$ROOT/apps/$app/powos-app.json" | head -1)
          ADB=${ADB:-"docker exec powos-vadb adb"} ${BINDINGS_PUBLISH:-"$ROOT/apps/install.sh"} "$app" publish --note "${name:-$app} updated" ||
            { echo "bindings: publishing $db failed (above)" >&2; rc=1; }
        else
          echo "bindings: $db on the phone lacks $what - fix: apps/install.sh $app publish --note \"...\"" >&2; rc=1
        fi
      else
        echo "bindings: $db on the phone lacks $what, and $file isn't what apps/$app/module builds - fix: apps/vendor.sh $app, commit shell/vendor/$db.js, apps/install.sh $app publish --note \"...\", then push vendor/$db.js" >&2
        rc=1
      fi ;;
    *) echo "bindings: $db on the phone isn't the module $file was made from ($what) - fix: apps/vendor.sh $app from the published module's source, commit shell/vendor/$db.js and push vendor/$db.js (or, if apps/$app/module is the newer one, apps/install.sh $app publish)" >&2
       rc=1 ;;
  esac
done <<< "$out"
exit $rc
