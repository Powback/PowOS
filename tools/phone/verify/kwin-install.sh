#!/bin/bash
# lanes: phone
# kwin-install.sh MIN [OUT]: installs the newest built kwin package (kwin-up.sh's lookup: here, a sibling
# worktree, or the shared build-inputs cache) if it's newer than the one running, restarts the session if the
# running KWin is stale, and FAILs if the installed KWin ends up older than MIN.
#
# Its own queued step (friction f121): a check that needs a new KWin paid for the install + the session restart
# inside its OWN budget (one check's 300 s covering both the install and the feature it's there to prove - a
# window title-bar check timed out mostly waiting on an install it never should have had to pay for). Queue THIS
# first against the same board task, then queue the feature check after it with a normal budget - queue.sh runs
# a window's jobs in queue order, so the feature check finds KWin already there instead of paying for it again:
#   queue.sh add <task> tools/phone/verify/kwin-install.sh 6.7.5-3.29
#   queue.sh add <task> tools/phone/verify/one-title-bar.sh
# Exit: 0 passed; 1 FAIL; 3 a real touch / no free window / not now (re-queued); 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
OUT=${2:-$HOME/.cache/powos-verify/kwin-install-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
[ $# -ge 1 ] || { echo "usage: kwin-install.sh MIN [OUT]"; exit 2; }
restore() { "$T/adb.sh" shell "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null" >/dev/null 2>&1; echo "restored"; }
. "$here/window-lock.sh"
. "$here/kwin-up.sh"
window_lock kwin-install.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$HOME/.cache/powos-verify.lock"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
log() { echo "$*"; }
kwin_up "$1"
echo "PASS: kwin $(kwin_installed) installed and running"
