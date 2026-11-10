#!/bin/bash
# Cold home has no WorkFeed: verification must open AI before waiting for its live subscription.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
from pathlib import Path
s = Path('tools/phone/verify/ai-area-drilldown.sh').read_text()
j = Path('shell/dev/ai-area-device.js').read_text()
assert 'for step in open setup mixed area rest task all collapse' in s
assert 'guard ||' in s and 'r=$(shell_check home ai-area-device.js aiAreaDevice "$step")' in s
op = j.split('async function aiAreaOpen(', 1)[1]
assert 'S.page.value = -1' in op and 'S.aiScreen.value = "chat"' in op
setup = j.split('async function aiAreaSetup(', 1)[1].split('/** WorkFeed', 1)[0]
assert setup.index('await G.until(') < setup.index('const areas = A.areaStats()')
assert '12000' in setup and 'SKIP: live board subscription not ready' in setup
assert 'window.__aiAreaDevice.touched' in setup
assert 'P.board.value =' not in j and 'P.boardSeen.value =' not in j
print('PASS: cold-home open precedes bounded live readiness; touch guard and honest SKIP remain')
PY
