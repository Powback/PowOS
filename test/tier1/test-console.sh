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

# --- layout adapts to screen size (the mobile case) ------------------------
L=$(POWOS_CONSOLE_LAYOUT=tabs bash -c "source '$LIB' 2>/dev/null; console_layout")
[ "$L" = tabs ] && ok "POWOS_CONSOLE_LAYOUT overrides detection" \
  || bad "layout override ignored (got '$L')"

# A phone-sized terminal must NOT get a tiled grid: halving the WIDTH is the
# problem on a phone, so the answer is full-width rows stacked vertically.
L=$(POWOS_CONSOLE_MIN_COLS=9999 bash -c "source '$LIB' 2>/dev/null; console_layout")
[ "$L" = stack ] && ok "narrow terminal selects stack (full-width rows), not grid" \
  || bad "narrow terminal chose '$L', expected stack"
L=$(POWOS_CONSOLE_MIN_COLS=1 POWOS_CONSOLE_MIN_LINES=1 \
      bash -c "source '$LIB' 2>/dev/null; console_layout")
[ "$L" = grid ] && ok "roomy terminal selects grid" || bad "roomy terminal chose '$L'"

# --- key bindings must never be unguarded -----------------------------------
# `bind-key -n` writes to tmux's SERVER-GLOBAL root table. An unguarded binding
# would steal Enter inside the user's real sessions, which is unacceptable.
# Anchor on "tmux bind-key" so that "tmux UNbind-key -n" (cleanup, legitimate)
# does not match, and skip comments — the file explains this hazard in prose,
# and the prose necessarily contains the string being searched for.
if grep -nE 'tmux bind-key -n' "$LIB" | grep -vE '^[0-9]+: *#' | grep -v 'if-shell -F' | grep -q .; then
  bad "found an UNGUARDED bind-key -n (would steal keys in real sessions)"
else
  ok "every global binding is guarded by a session check"
fi
grep -q 'send-keys \$1' "$LIB" \
  && ok "guarded bindings pass the key through outside the console" \
  || bad "no pass-through: keys would be swallowed elsewhere"
grep -q 'unbind-key -n' "$LIB" \
  && ok "--kill removes the global bindings" \
  || bad "bindings would outlive the console session"

# Every key bound with _ckey must appear in CONSOLE_KEYS, or --kill leaves it
# behind. This already happened once: DoubleClick1Pane was bound and not cleaned.
KEYS=$(grep -E '^CONSOLE_KEYS=' "$LIB" | cut -d'"' -f2)
MISSING=""
for k in $(grep -oE '^\s*_ckey [A-Za-z0-9-]+' "$LIB" | awk '{print $2}' | sort -u); do
  printf '%s\n' $KEYS | grep -qx "$k" || MISSING="$MISSING $k"
done
[ -z "$MISSING" ] && ok "every bound key is in CONSOLE_KEYS (cleanup can't drift)" \
  || bad "bound but never unbound:$MISSING"

echo
echo "console: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
