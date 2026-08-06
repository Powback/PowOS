#!/usr/bin/env bash
# test-tmux-resume.sh — unit tests for the tmux resume path.
#
# ARCHITECTURE (changed): the picker used to live in the profile.d hook and
# sniff $KONSOLE_VERSION to decide whether it was in a terminal we own. It now
# lives in lib/powos-tmux-shell, which Konsole runs as its profile Command, so
# there is nothing to detect — if it runs, it is in a terminal. The profile.d
# hook survives only for SSH (no Konsole profile to point at) and merely
# delegates. So this file tests TWO things:
#
#   1. the WRAPPER  — guards, empty-state auto-start, menu ordering, attach
#   2. the SSH HOOK — guards + that it delegates to the wrapper
#
# The wrapper exec()s and requires a tty ([ -t 0 ]), so each case runs it under
# `script` to get a real pty. tmux/fzf are shadowed by stubs on PATH: the tmux
# stub records the terminal action to $ACTION_FILE; the fzf stub captures its
# stdin (the rendered menu) to $MENU_FILE and prints $FZF_PICK.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/../../lib/powos-tmux-shell"
HOOK="$HERE/../../config/etc/profile.d/50-powos-tmux-resume.sh"
[ -f "$WRAPPER" ] || { echo "FAIL: wrapper not found at $WRAPPER"; exit 1; }
[ -f "$HOOK" ]    || { echo "FAIL: hook not found at $HOOK"; exit 1; }

command -v script >/dev/null 2>&1 || { echo "SKIP: util-linux 'script' not available"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
ACTION_FILE="$WORK/action"; MENU_FILE="$WORK/menu"

# --- stub tmux -------------------------------------------------------------
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
cmd="$1"; shift
case "$cmd" in
  list-sessions) printf '%s\n' "${SESSIONS:-}" | grep -v '^$' ;;
  display-message|capture-pane|list-windows) echo "x" ;;
  start-server) exit 0 ;;
  has-session) exit 0 ;;
  attach-session) shift; echo "attach:$1" >> "$ACTION_FILE"; exit 0 ;;  # -t <name>
  new-session)    echo "new:$*"           >> "$ACTION_FILE"; exit 0 ;;
  *) : ;;
esac
STUB
chmod +x "$BIN/tmux"

# --- stub fzf: capture the menu, print the chosen row ----------------------
cat > "$BIN/fzf" <<'STUB'
#!/usr/bin/env bash
cat > "${MENU_FILE:-/dev/null}"
[ -n "${FZF_PICK:-}" ] && printf '%s\n' "$FZF_PICK"
exit 0
STUB
chmod +x "$BIN/fzf"

# --- stub the fallback shell so a fallback is observable, not a hang --------
cat > "$BIN/fallback-shell" <<'STUB'
#!/usr/bin/env bash
echo "shell:$*" >> "$ACTION_FILE"
exit 0
STUB
chmod +x "$BIN/fallback-shell"

# Run the WRAPPER under a pty with a clean, explicit environment.
# Usage: run_wrapper VAR=VAL ...
run_wrapper() {
  : > "$ACTION_FILE"; : > "$MENU_FILE"
  local assigns=""
  for kv in "$@"; do assigns="$assigns $(printf '%q' "$kv")"; done
  script -qec "env -i PATH='$BIN:/usr/bin:/bin' HOME='$WORK' TERM=dumb \
      SHELL='$BIN/fallback-shell' \
      ACTION_FILE='$ACTION_FILE' MENU_FILE='$MENU_FILE' \
      $assigns bash '$WRAPPER'" /dev/null >/dev/null 2>&1
}

# Run the SSH HOOK in an interactive child (it is sourced, and self-executes).
run_hook() {
  : > "$ACTION_FILE"
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$WORK" TERM=dumb \
      ACTION_FILE="$ACTION_FILE" \
      POWOS_TMUX_SHELL_BIN="$BIN/fake-wrapper" \
      "$@" \
      bash --norc -i -c "source '$HOOK'" 2>/dev/null
}
cat > "$BIN/fake-wrapper" <<'STUB'
#!/usr/bin/env bash
echo "delegated" >> "$ACTION_FILE"
exit 0
STUB
chmod +x "$BIN/fake-wrapper"

echo "== powos-tmux-shell (wrapper) =="

# 1. Already inside tmux → never nest; fall back to a shell.
run_wrapper TMUX="/tmp/tmux-x,1,0" SESSIONS="0 lost"
grep -q '^shell:' "$ACTION_FILE" && ok "refuses to nest inside tmux" \
  || bad "nested inside tmux: $(cat "$ACTION_FILE")"

# 2. Opt-out env → straight to a shell.
run_wrapper POWOS_NO_TMUX=1 SESSIONS="0 lost"
grep -q '^shell:' "$ACTION_FILE" && ok "respects POWOS_NO_TMUX" \
  || bad "ignored POWOS_NO_TMUX: $(cat "$ACTION_FILE")"

# 3. No sessions → auto-start a fresh one, and show no menu.
run_wrapper SESSIONS=""
grep -q '^new:' "$ACTION_FILE" && ok "empty state auto-starts tmux" \
  || bad "empty state did not auto-start: $(cat "$ACTION_FILE")"
[ -s "$MENU_FILE" ] && bad "showed a menu with no sessions" || ok "no menu when nothing to resume"

# 4. Sessions exist → DETACHED before ATTACHED, attached tagged, no divider row.
run_wrapper SESSIONS=$'0 lost-work\n2 live-tab\n0 scratch'
plain=$(tr -d '\r' < "$MENU_FILE" | perl -pe 's/\e\[[0-9;]*m//g' 2>/dev/null \
        || tr -d '\r' < "$MENU_FILE")
d_line=$(printf '%s\n' "$plain" | grep -n 'lost-work' | head -1 | cut -d: -f1)
a_line=$(printf '%s\n' "$plain" | grep -n 'live-tab'  | head -1 | cut -d: -f1)
if [ -n "$d_line" ] && [ -n "$a_line" ] && [ "$d_line" -lt "$a_line" ]; then
  ok "detached listed before attached"
else
  bad "ordering wrong (detached=$d_line attached=$a_line)"
fi
if printf '%s\n' "$plain" | grep -q '── already attached'; then
  bad "still emits a selectable divider row"
else
  ok "no divider row (was a bogus selectable entry)"
fi
printf '%s\n' "$plain" | grep 'live-tab' | grep -q '(attached)' \
  && ok "attached session tagged '(attached)'" || bad "attached session not tagged"

# 5. Picking a detached session → attach to it by name.
run_wrapper SESSIONS=$'0 lost-work\n2 live-tab' FZF_PICK=$'lost-work\t  ○  lost-work'
grep -q '^attach:lost-work$' "$ACTION_FILE" && ok "attaches the picked session" \
  || bad "did not attach picked session: $(cat "$ACTION_FILE")"

# 6. Choosing "plain shell" → fall back, never leave a dead terminal.
run_wrapper SESSIONS=$'0 lost-work' FZF_PICK=$'  ·  plain shell (no tmux)\t  ·  plain shell (no tmux)'
grep -q '^shell:' "$ACTION_FILE" && ok "'plain shell' falls back to a shell" \
  || bad "plain shell did not fall back: $(cat "$ACTION_FILE")"

echo
echo "== profile.d SSH hook (delegation only) =="

# 7. Not SSH → hook must do nothing (Konsole now goes via the profile Command).
run_hook SESSIONS="0 lost"
[ -s "$ACTION_FILE" ] && bad "fired without SSH" || ok "skips when not SSH"

# 8. Inside tmux → never nest.
run_hook SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22" TMUX="/tmp/tmux-x,1,0"
[ -s "$ACTION_FILE" ] && bad "nests inside tmux" || ok "skips inside tmux"

# 9. Opt-out env → skip.
run_hook SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22" POWOS_NO_TMUX=1
[ -s "$ACTION_FILE" ] && bad "ignores POWOS_NO_TMUX" || ok "respects POWOS_NO_TMUX"

# 10. Already handled once (wrapper sets this before exec'ing a fallback shell)
#     → must not re-enter, or picking "plain shell" over SSH would loop.
run_hook SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22" POWOS_TMUX_RESUME_DONE=1
[ -s "$ACTION_FILE" ] && bad "re-entered after RESUME_DONE" || ok "does not re-enter once done"

# 11. Real SSH login → delegates to the wrapper (one implementation, not two).
run_hook SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22"
grep -q '^delegated$' "$ACTION_FILE" && ok "SSH login delegates to the wrapper" \
  || bad "did not delegate: $(cat "$ACTION_FILE")"

echo
echo "tmux-resume: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
