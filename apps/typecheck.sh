#!/bin/bash
# Typechecks a PowOS app's UI (preact/tsx) with the shell's tsc + node_modules (friction f109: there was no recipe
# for this at all - app-api/pet/sketch each had a ui/tsconfig.json nobody ever ran, and none of them resolve
# "preact" without a node_modules of their own; apps/build.sh only compiles the module, not the UI's types).
#   apps/typecheck.sh <app|dir>   e.g. apps/typecheck.sh counter, apps/typecheck.sh ~/Projects/hue-rooms
# Needs shell/node_modules (npm ci in shell/ first if missing - same requirement as shell/dev/gate.sh's own tsc
# step). An app whose UI imports its generated bindings (apps/<app>/ui/bindings, gitignored) needs a build first
# (apps/build.sh <app>) or tsc reports a real-looking "cannot find module" that is actually just "not built yet".
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
APP=${1:?usage: apps/typecheck.sh <app>}
case $APP in */*) D=$(cd "$APP" && pwd) ;; *) D=$HERE/$APP ;; esac
[ -d "$D/ui" ] || { echo "typecheck.sh: $D has no ui/ (module-only app, nothing to typecheck)" >&2; exit 1; }
TSC=$HERE/../shell/node_modules/.bin/tsc
[ -x "$TSC" ] || { echo "typecheck.sh: no shell/node_modules/.bin/tsc - run 'npm ci' in shell/ first" >&2; exit 1; }

# tsc resolves node_modules by walking UP from the files it compiles; apps/<app>/ui has none of its own (preact etc.
# are shell devDependencies, shared), so point it at shell's with a throwaway symlink - same pattern worktree.sh
# uses for shell/node_modules itself. Never committed: apps/.gitignore excludes it.
ln -sfn "$(cd "$HERE/../shell/node_modules" && pwd)" "$D/ui/node_modules"
# The app's own ui/tsconfig.json if it has one (app-api, pet, sketch do); the shared default otherwise, copied in
# (not symlinked) so tsc's "include" resolves relative to ui/ and only picks up this app's files.
tmpcfg=""
if [ -f "$D/ui/tsconfig.json" ]; then cfg=tsconfig.json
else tmpcfg=$D/ui/.typecheck-tsconfig.json; cp "$HERE/tsconfig.app.json" "$tmpcfg"; cfg=$(basename "$tmpcfg"); fi
trap 'rm -f "$D/ui/node_modules" "$tmpcfg"' EXIT
(cd "$D/ui" && "$TSC" --noEmit -p "$cfg")
