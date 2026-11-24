#!/usr/bin/env bash
# The lock face's charging line (shell/ui/charge.ts): the stock wording per charger class, time until full only when
# Android gives one. The class itself (by watts) is the JVM test ChargingTest.kt. Node's own TS type stripping.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec node --test "$ROOT/shell/test/charge.test.ts"
