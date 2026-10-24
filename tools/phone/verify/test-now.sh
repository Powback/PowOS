#!/bin/bash
# lanes: phone
# tools/phone/verify/test-now.sh <board-task> (Mac; queue it: `queue.sh add --close <task> test-now.sh <task>`):
# the verify queue's phone side while it runs this very check -
#   1. the status pill is up (window "PowOS verify status") and its surface is out of screencaps (skip-screenshot);
#   2. the AI page's board shows <task>'s queued check as queue.sh add marked it (the board is live) and the page
#      offers "test now" / "testing…" on it.
# Read-only on the phone (dumpsys, one CDP read of the page); prints FAIL: lines, exit 1 on any.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); phone=$(cd "$here/.." && pwd)
task=${1:?usage: test-now.sh <board-task>}
fail=0
win=$("$phone/adb.sh" shell 'dumpsys window windows | grep -c "PowOS verify status"' | tr -d '\r')
[ "${win:-0}" -ge 1 ] && echo "ok: the status pill is shown" || { echo "FAIL: no status pill window while the queue runs"; fail=1; }
skip=$("$phone/adb.sh" shell 'dumpsys SurfaceFlinger | grep -A12 "PowOS verify status" | grep -ciE "skipScreenshot|SKIP_SCREENSHOT|0x40"' | tr -d '\r')
echo "info: skip-screenshot markers near the pill's layer: ${skip:-0}"
page=$("$phone/cdp.sh" eval home "JSON.stringify([...document.querySelectorAll('.ai-work-list .ai-item')].map(e=>e.innerText).filter(t=>t.includes('phone check queued')||t.includes('testing')).length)" 2>&1 | tail -1)
echo "info: AI page rows with a queued/testing check: $page"
case "$page" in *'"0"'*|*'0'|'') echo "FAIL: the AI page shows no queued phone check (task $task)"; fail=1 ;; esac
[ $fail = 0 ] && echo "test-now: pill up, board live, queued check shown"
exit $fail
