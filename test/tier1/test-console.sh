#!/usr/bin/env bash
# test-console.sh — unit tests for `powos console` (lib/console.sh).
#
# The grid is built against a REAL tmux server, but on a private socket
# (-L powos-console-test) so it can never see, resize or kill the developer's
# actual sessions. Sessions are deliberately named "0"/"1" because numeric names
# are the interesting case: inside a tmux client `-t 0` resolves as WINDOW index
# 0, not the session named 0, so a pane ends up mirroring itself. That bug is
# what the exact-target (`=name`) assertions below pin down.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LIB="$REPO/lib/console.sh"
[ -f "$LIB" ] || { echo "FAIL: lib/console.sh not found"; exit 1; }

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

SOCK=powos-console-test
TM() { tmux -L "$SOCK" "$@"; }
cleanup() { TM kill-server 2>/dev/null; }
trap cleanup EXIT
cleanup

echo "== powos console =="

# --- static checks ---------------------------------------------------------
bash -n "$LIB" && ok "console.sh parses" || bad "console.sh has a syntax error"

grep -q 'console)' "$REPO/bin/powos" && ok "dispatched from bin/powos" \
  || bad "no dispatch in bin/powos"
grep -q '^  console  ' "$REPO/bin/powos" && ok "documented in powos help" \
  || bad "missing from help (an undocumented command does not exist)"

# Every session target must use tmux's exact-match form, or numeric session
# names silently resolve to window indices.
if grep -nE 'tmux (has-session|capture-pane|attach-session|set-option)[^|]*-t "\$s"' "$LIB" \
     | grep -v '=' | grep -q .; then
  bad "found a non-exact -t \"\$s\" target (numeric names will mis-resolve)"
else
  ok "all session targets use exact-match (=name)"
fi

# --- behavioural checks against a private tmux server ----------------------
TM new-session -d -s 0 'sleep 300' 2>/dev/null
TM new-session -d -s 1 'sleep 300' 2>/dev/null
sleep 0.5

if [ "$(TM list-sessions 2>/dev/null | wc -l)" -eq 2 ]; then
  ok "fixture: two numeric sessions created"
else
  bad "fixture failed to create sessions"
fi

# console_targets must exclude the console session itself, or it mirrors itself.
OUT=$(POWOS_LIB="$REPO/lib" bash -c "
  source '$LIB' 2>/dev/null
  tmux() { command tmux -L '$SOCK' \"\$@\"; }
  CONSOLE_SESSION=console
  console_targets" 2>/dev/null)
if printf '%s\n' "$OUT" | grep -qx '0' && printf '%s\n' "$OUT" | grep -qx '1'; then
  ok "console_targets lists the real sessions"
else
  bad "console_targets missed sessions: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

TM new-session -d -s console 'sleep 300' 2>/dev/null
OUT=$(POWOS_LIB="$REPO/lib" bash -c "
  source '$LIB' 2>/dev/null
  tmux() { command tmux -L '$SOCK' \"\$@\"; }
  CONSOLE_SESSION=console
  console_targets" 2>/dev/null)
printf '%s\n' "$OUT" | grep -qx 'console' \
  && bad "console_targets includes itself (would mirror itself)" \
  || ok "console_targets excludes the console session"

# --- the resize guarantee: the whole reason this is snapshot-based ---------
BEFORE=$(TM display-message -p -t "=0:" '#{window_width}x#{window_height}' 2>/dev/null)
TM capture-pane -p -t "=0:" >/dev/null 2>&1
AFTER=$(TM display-message -p -t "=0:" '#{window_width}x#{window_height}' 2>/dev/null)
if [ -n "$BEFORE" ] && [ "$BEFORE" = "$AFTER" ]; then
  ok "capture-pane does not resize the source session ($BEFORE)"
else
  bad "source session resized by capture: $BEFORE -> $AFTER"
fi

echo
echo "console: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
