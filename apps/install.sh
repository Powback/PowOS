#!/bin/bash
# Installs a built PowOS app (apps/build.sh) on the phone: the app's manifest and build output pushed into PowOS, then
# `powos app install` there as the user powos (module published to the device's SpacetimeDB, UI in place, registry).
#   apps/install.sh <app|dir> [install|publish|ui] --note "what changed, for the user" [--direct]
#                                    publish = only the module (hot swap); ui = only the UI (hot reload). The note is
#                                    the phone's quiet "update applied" notification (`powos app ... --note`).
# Runs adb from wherever adb reaches the phone: ADB="docker exec powos-vadb adb" (the VPN), or plain adb.
# The UI goes through the shell's gate first (shell/dev/gate.sh --app): each page/widget entry of out/ui imported in a
# headless Chromium as the shell imports it - one that doesn't load refuses the install. --force installs anyway.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NOTE="" ARGS=() FORCE="" DIRECT=""
while [ $# -gt 0 ]; do
  case "$1" in --force) FORCE=1; shift ;; --direct) DIRECT=1; shift ;; --note) NOTE=${2:-}; shift 2 || shift ;; --note=*) NOTE=${1#--note=}; shift ;; *) ARGS+=("$1"); shift ;; esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
APP=${1:?usage: apps/install.sh <app> [install|publish|ui] --note "what changed, for the user"}
VERB=${2:-install}
[ -n "${NOTE// }" ] || { echo "install.sh: --note \"what changed, for the user\" is required (the phone's update notification)" >&2; exit 2; }
NOTE64=$(printf '%s' "$NOTE" | base64 | tr -d '\n')
case $APP in */*) D=$(cd "$APP" && pwd) ;; *) D=$HERE/$APP ;; esac
ADB=${ADB:-adb}
# A module publish (install / publish) goes through the ship service (tools/phone/ship.sh's apps step: the module with
# its regenerated bindings, after the shell has them). 2026-10-30 19:31: an agent published powos-agents' new column
# work.try_line from its own worktree before shell/vendor/powos-agents.js shipped - home's board subscription stopped
# decoding. So, outside the service (POWOS_SHIP_SERVICE unset): an app whose database the shell has bindings for
# (shell/vendor/VERSIONS "generated") is REFUSED; any other app's module is published with a loud warning.
# --direct: an emergency, logged to <ship queue>/direct.log. `ui` (no module) is never guarded.
APPNAME=$(basename "$D")
if [ "$VERB" != ui ] && [ -f "$D/module/Cargo.toml" ] && [ -z "${POWOS_SHIP_SERVICE:-}" ]; then
  VDB=$(sed -n "s|^\([a-z0-9-]*\)\.js  *generated  *apps/$APPNAME:.*|\1|p" "$HERE/../shell/vendor/VERSIONS" 2>/dev/null)
  if [ -n "$DIRECT" ]; then
    SQ=${SHIP_DIR:-$HOME/.cache/powos-ship-queue}; mkdir -p "$SQ"
    echo "$(date '+%F %T') apps/install.sh --direct $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null) $(basename "$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)") pid $$: $APPNAME $VERB --note $NOTE" >> "$SQ/direct.log"
  elif [ -n "$VDB" ]; then
    echo "install.sh: REFUSED - apps/$APPNAME's module is the shell's $VDB database (shell/vendor/$VDB.js): it ships only with" >&2
    echo "  its regenerated bindings, through the ship service. Run apps/vendor.sh $APPNAME, commit the module + shell/vendor/$VDB.js" >&2
    echo "  together, push, then tools/phone/ship.sh request --note \"...\" (--direct only for an emergency, logged)." >&2
    exit 3
  else
    echo "install.sh: WARNING - publishing apps/$APPNAME's module from $(basename "$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || echo "$HERE")"), outside the ship service." >&2
    echo "  A schema change here can break anything reading this database; the ship service publishes origin's tip (tools/phone/ship.sh request)." >&2
  fi
fi
# Built: the module (an app that has one) and the UI.
[ -f "$D/powos-app.json" ] && { [ -f "$D/out/module.wasm" ] || [ ! -f "$D/module/Cargo.toml" ]; } && [ -d "$D/out" ] ||
  { echo "install.sh: build it first (apps/build.sh $APP)" >&2; exit 1; }
# The gate: the UI's modules, loaded as the shell loads them (not for publish: the module alone, no UI).
if [ "$VERB" != publish ] && [ -d "$D/out/ui" ]; then
  # Only THIS app's runs (GATE_ONLY on the run names: "app <id>" and its widget/page entries) - not the shell's scenes, so an
  # unrelated failing scene (shade-overpull, 2026-10-28) can't block an app deploy. The lints and the app's widget sweep
  # still run; ship.sh's post-deploy full gate reports the rest.
  GID=$(sed -n 's/^ *"id": *"\([^"]*\)".*/\1/p' "$D/powos-app.json" | head -1)
  if ! GATE_ONLY="^app ${GID//./\\.}( |\$)" GATE_SHELL_PAGES=0 "$HERE/../shell/dev/gate.sh" --app "$D"; then
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
$ADB shell "su -c 'R=/data/powos/root; rm -rf \$R/tmp/powos-app-$ID && mkdir -p \$R/tmp/powos-app-$ID && tar -xzf $T.tgz -C \$R/tmp/powos-app-$ID --strip-components=1 && rm -f $T.tgz && chown -R \$(stat -c %u /data/data/com.powos.app) \$R/tmp/powos-app-$ID && sh /data/powos/powos-run.sh \"POWOS_SHIPPED=${POWOS_SHIP_SERVICE:+1}${DIRECT:+direct} powos app $VERB /tmp/powos-app-$ID --note-b64 $NOTE64\"'"
