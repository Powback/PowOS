#!/bin/bash
# test-home-stacks.sh - widget stacks on home (shell/ui/stackmodel.ts): create/add/remove/reorder/unstack, persistence
# and migration (no store = an old layout loads unchanged), the grid's one-tile-per-stack view, and the swipe hand-off
# to home's pages at a stack's first/last widget. Runs shell/test/stackmodel.test.ts (node's own TS type stripping,
# node 23+); SKIP (exit 0) without such a node.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v node >/dev/null || { echo "  skip node not installed"; exit 0; }
major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
[ "${major:-0}" -ge 23 ] || { echo "  skip node $major has no default TS type stripping"; exit 0; }
exec node --test "$ROOT/shell/test/stackmodel.test.ts"
