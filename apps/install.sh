#!/bin/bash
# Installs a built PowOS app (apps/build.sh) on the phone: the app's manifest and build output pushed into PowOS, then
# `powos app install` there as the user powos (module published to the device's SpacetimeDB, UI in place, registry).
#   apps/install.sh <app> [install|publish|ui] --note "what changed, for the user"
#                                    publish = only the module (hot swap); ui = only the UI (hot reload). The note is
#                                    the phone's quiet "update applied" notification (`powos app ... --note`).
# Runs adb from wherever adb reaches the phone: ADB="docker exec powos-vadb adb" (the VPN), or plain adb.
# The UI goes through the shell's gate first (shell/dev/gate.sh --app): each page/widget entry of out/ui imported in a
# headless Chromium as the shell imports it - one that doesn't load refuses the install. --force installs anyway.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NOTE="" ARGS=() FORCE=""
while [ $# -gt 0 ]; do
  case "$1" in --force) FORCE=1; shift ;; --note) NOTE=${2:-}; shift 2 || shift ;; --note=*) NOTE=${1#--note=}; shift ;; *) ARGS+=("$1"); shift ;; esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
APP=${1:?usage: apps/install.sh <app> [install|publish|ui] --note "what changed, for the user"}
VERB=${2:-install}
[ -n "${NOTE// }" ] || { echo "install.sh: --note \"what changed, for the user\" is required (the phone's update notification)" >&2; exit 2; }
NOTE64=$(printf '%s' "$NOTE" | base64 | tr -d '\n')
D=$HERE/$APP
ADB=${ADB:-adb}
# Built: the module (an app that has one) and the UI.
[ -f "$D/powos-app.json" ] && { [ -f "$D/out/module.wasm" ] || [ ! -f "$D/module/Cargo.toml" ]; } && [ -d "$D/out" ] ||
  { echo "install.sh: build it first (apps/build.sh $APP)" >&2; exit 1; }
# The gate: the UI's modules, loaded as the shell loads them (not for publish: the module alone, no UI).
if [ "$VERB" != publish ] && [ -d "$D/out/ui" ]; then
  if ! GATE_SHELL_PAGES=0 "$HERE/../shell/dev/gate.sh" --app "$D"; then
    [ -n "$FORCE" ] || { echo "install.sh: refused - the gate failed (above). Fix it, or --force to install anyway." >&2; exit 1; }
    echo "install.sh: the gate failed - installing anyway (--force)" >&2
  fi
fi
ID=$(sed -n 's/^ *"id": *"\([^"]*\)".*/\1/p' "$D/powos-app.json" | head -1)
T=/data/local/tmp/powos-app-$ID
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/app" && cp "$D/powos-app.json" "$STAGE/app/" && cp -R "$D/out" "$STAGE/app/out"
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$STAGE/app.tgz" app
# Through a file the adb side can read (powos-vadb has the Mac's tmp mounted only at /t: copy in there if so).
if [[ $ADB == docker\ exec* ]]; then
  c=$(echo "$ADB" | awk '{print $3}'); docker cp "$STAGE/app.tgz" "$c:/tmp/powos-app.tgz"; src=/tmp/powos-app.tgz
else src=$STAGE/app.tgz; fi
$ADB push -q "$src" "$T.tgz"
$ADB shell "su -c 'R=/data/powos/root; rm -rf \$R/tmp/powos-app-$ID && mkdir -p \$R/tmp/powos-app-$ID && tar -xzf $T.tgz -C \$R/tmp/powos-app-$ID --strip-components=1 && rm -f $T.tgz && chown -R \$(stat -c %u /data/data/com.powos.app) \$R/tmp/powos-app-$ID && sh /data/powos/powos-run.sh \"powos app $VERB /tmp/powos-app-$ID --note-b64 $NOTE64\"'"
