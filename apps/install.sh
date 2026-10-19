#!/bin/bash
# Installs a built PowOS app (apps/build.sh) on the phone: the app's manifest and build output pushed into PowOS, then
# `powos app install` there as the user powos (module published to the device's SpacetimeDB, UI in place, registry).
#   apps/install.sh <app> [install|publish|ui]   publish = only the module (hot swap); ui = only the UI (hot reload)
# Runs adb from wherever adb reaches the phone: ADB="docker exec powos-vadb adb" (the VPN), or plain adb.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
APP=${1:?usage: apps/install.sh <app> [install|publish|ui]}
VERB=${2:-install}
D=$HERE/$APP
ADB=${ADB:-adb}
[ -f "$D/powos-app.json" ] && [ -f "$D/out/module.wasm" ] || { echo "install.sh: build it first (apps/build.sh $APP)" >&2; exit 1; }
ID=$(sed -n 's/^ *"id": *"\([^"]*\)".*/\1/p' "$D/powos-app.json" | head -1)
T=/data/local/tmp/powos-app-$ID
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/app" && cp "$D/powos-app.json" "$STAGE/app/" && cp -R "$D/out" "$STAGE/app/out"
tar -C "$STAGE" -czf "$STAGE/app.tgz" app
# Through a file the adb side can read (powos-vadb has the Mac's tmp mounted only at /t: copy in there if so).
if [[ $ADB == docker\ exec* ]]; then
  c=$(echo "$ADB" | awk '{print $3}'); docker cp "$STAGE/app.tgz" "$c:/tmp/powos-app.tgz"; src=/tmp/powos-app.tgz
else src=$STAGE/app.tgz; fi
$ADB push -q "$src" "$T.tgz"
$ADB shell "su -c 'R=/data/powos/root; rm -rf \$R/tmp/powos-app-$ID && mkdir -p \$R/tmp/powos-app-$ID && tar -xzf $T.tgz -C \$R/tmp/powos-app-$ID --strip-components=1 && rm -f $T.tgz && chown -R \$(stat -c %u /data/data/com.powos.app) \$R/tmp/powos-app-$ID && sh /data/powos/powos-run.sh \"powos app $VERB /tmp/powos-app-$ID\"'"
