#!/bin/bash
# test-webwindows-kbfit.sh - KB1: the web window the keyboard types into ends at the keyboard's top, so its app (an
# Android app on its virtual display, which never gets IME insets there; a Linux window) lays out above it
# (shell/ui/kbfit.ts). Runs shell/test/kbfit.test.ts (node's own TS type stripping, node 23+); SKIP (exit 0) without
# such a node.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v node >/dev/null || { echo "  skip node not installed"; exit 0; }
major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
[ "${major:-0}" -ge 23 ] || { echo "  skip node $major has no default TS type stripping"; exit 0; }
exec node --test "$ROOT/shell/test/kbfit.test.ts"
