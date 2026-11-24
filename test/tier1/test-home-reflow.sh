#!/bin/bash
# test-home-reflow.sh - one home layout on the folded and unfolded screens (shell/hosts/reflow.ts, flowsync.ts): an
# edit on either screen laid out on the other (same pages, same order, sizes in cells, overflow to the next page, pins
# kept), and the migration of the old separate layouts. Runs shell/test/reflow.test.ts and flowsync.test.ts (node's own
# TS type stripping, node 23+); SKIP (exit 0) without such a node.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v node >/dev/null || { echo "  skip node not installed"; exit 0; }
major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
[ "${major:-0}" -ge 23 ] || { echo "  skip node $major has no default TS type stripping"; exit 0; }
exec node --test "$ROOT/shell/test/reflow.test.ts" "$ROOT/shell/test/flowsync.test.ts"
