#!/usr/bin/env bash
# fake-composed.sh DIR [stale] - what `apps/build.sh composed` leaves, for tests that stage powos-core without docker
# (POWOS_CORE_COMPOSED=DIR): apps/composed's module source + out/module.wasm (a stand-in), out/.module.sha (the
# source's real tree hash, lib/apps/powos-app tree_hash; "stale": a wrong one) and out/bindings/index.ts.
set -eu
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
D=$1
mkdir -p "$D/out/bindings"; cp -R "$ROOT/apps/composed/module" "$D/module"; rm -rf "$D/module/target"
printf '\0asm-composed' > "$D/out/module.wasm"; echo 'export const DbConnection = null;' > "$D/out/bindings/index.ts"
if [ "${2:-}" = stale ]; then echo 0000 > "$D/out/.module.sha"; exit 0; fi
python3 -I - "$ROOT/lib/apps/powos-app" "$D/module" > "$D/out/.module.sha" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
l = SourceFileLoader("pa", sys.argv[1]); m = module_from_spec(spec_from_loader("pa", l)); l.exec_module(m)
print(m.tree_hash(sys.argv[2], skip={"target", "Cargo.lock"}))
PY
