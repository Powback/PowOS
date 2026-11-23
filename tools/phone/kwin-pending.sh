#!/bin/bash
# tools/phone/kwin-pending.sh: run by ship.sh after a successful rooted deploy (coordinator decision 2026-11-23,
# docs/AGENT-HANDBOOK.md "KWin activation"). The rooted deploy installs a new kwin package, but the session's kwin_wayland
# keeps running the old one (its libkwin mapped "(deleted)") until the Linux session restarts - the fix is installed,
# not live. When the installed package isn't the running one, this records it for `ship.sh status` ("kwin X installed,
# active after next idle window") and queues tools/phone/verify/kwin-activate.sh on board task kwin-activation: the
# verify queue's idle window restarts the session then - never over a game or a Linux app the user has open.
# Running KWin already the installed one: recorded "active" when a pending record was there. Phone unreadable: nothing.
#   KWACT_TASK (kwin-activation) the board task; KWACT_STATUS the record (default $SHIP_DIR/kwin-activation)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/verify/kwin-activate-lib.sh"
ST=${KWACT_STATUS:-${SHIP_DIR:-$HOME/.cache/powos-ship-queue}/kwin-activation}
f=$(mktemp "${TMPDIR:-/tmp}/kwin-pending.XXXXXX"); trap 'rm -f "$f"' EXIT
printf '%s\n' 'v=$(pacman -Q kwin 2>/dev/null | cut -d" " -f2); k=$(pgrep -x kwin_wayland | head -1); n=0; [ -n "$k" ] && ! grep -q "libkwin.*(deleted)" /proc/$k/maps && n=1; echo "kwin_pkg=${v:--} kwin=${k:--} kwin_new=$n"' > "$f"
o=$("$here/root.sh" "$f" 2>/dev/null | tr -d '\r' | grep '^kwin_pkg=' | tail -1)
v=$(sed -n 's/^kwin_pkg=\([^ ]*\).*/\1/p' <<<"$o"); n=$(sed -n 's/.*kwin_new=\([01]\).*/\1/p' <<<"$o")
case "$v:$n" in
  -:*|:*|*:) echo "kwin-pending: the phone didn't say ($o) - nothing recorded"; exit 0 ;;
  *:1) [ ! -s "$ST" ] || grep -q "^active $v " "$ST" || kwact_status "$ST" active "$v"
       echo "kwin-pending: kwin $v is the running KWin" ;;
  *:0) grep -qE "^(pending|waiting) $v " "$ST" 2>/dev/null || kwact_status "$ST" pending "$v"
       echo "kwin-pending: kwin $v installed, the session runs the old one ($o) - active after next idle window"
       "$here/verify/queue.sh" add --name "kwin activation" "${KWACT_TASK:-kwin-activation}" "$here/verify/kwin-activate.sh" ;;
esac
