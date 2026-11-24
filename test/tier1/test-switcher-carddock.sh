#!/bin/bash
# test-switcher-carddock.sh - the switcher's card gestures (shell/ui/carddock.ts): a plain push up still removes, a
# short one springs back, and only a clear up-and-to-a-side drag docks into Open Canvas (native split view) on that
# side, beside the newest other single Android app. Runs shell/test/carddock.test.ts (node's own TS type stripping,
# node 22.6+); SKIP (exit 0) without such a node.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v node >/dev/null || { echo "  skip node not installed"; exit 0; }
major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
[ "${major:-0}" -ge 23 ] || { echo "  skip node $major has no default TS type stripping"; exit 0; }
exec node --test "$ROOT/shell/test/carddock.test.ts"
