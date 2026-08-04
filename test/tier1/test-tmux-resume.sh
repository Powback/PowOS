#!/usr/bin/env bash
# test-tmux-resume.sh — unit tests for the Konsole/SSH tmux-resume profile hook
# (config/etc/profile.d/50-powos-tmux-resume.sh).
#
# The script self-executes on source, guards on an interactive shell, and exec()s
# tmux. So each case runs the hook in a child `bash --norc -i -c 'source …'`
# (interactive $- , no rc pollution) with a clean env and `tmux`/`fzf` shadowed
# by stubs on PATH. The tmux stub records the terminal action (attach/new) to
# $ACTION_FILE; the fzf stub captures its stdin (the rendered menu) to $MENU_FILE
# and prints whatever selection the case wants via $FZF_PICK.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../config/etc/profile.d/50-powos-tmux-resume.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT"; exit 1; }

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
  list-sessions) printf '%s\n' "${SESSIONS:-}" | sed '/^$/d' ;;
  display-message|capture-pane|list-windows) echo "x" ;;
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

# Run the hook in an interactive child with a clean, explicit environment.
# Usage: run_hook VAR=VAL ...   (KONSOLE_VERSION, SSH_CONNECTION, TMUX,
#                                POWOS_NO_TMUX, SESSIONS, FZF_PICK)
run_hook() {
  : > "$ACTION_FILE"; : > "$MENU_FILE"
  env -i PATH="$BIN:/usr/bin:/bin" HOME="$WORK" TERM=dumb \
      ACTION_FILE="$ACTION_FILE" MENU_FILE="$MENU_FILE" \
      "$@" \
      bash --norc -i -c "source '$SCRIPT'" 2>/dev/null
}

echo "== tmux-resume hook =="

# 1. Guard: neither Konsole nor SSH → hook must not touch tmux at all.
run_hook SESSIONS="0 lost"
[ -s "$ACTION_FILE" ] && bad "fires with no Konsole/SSH" || ok "skips when not Konsole/SSH"

# 2. Inside tmux already → never nest.
run_hook KONSOLE_VERSION=22.12 TMUX="/tmp/tmux-x,1,0" SESSIONS="0 lost"
[ -s "$ACTION_FILE" ] && bad "nests inside tmux" || ok "skips inside tmux"

# 3. Opt-out env → skip.
run_hook KONSOLE_VERSION=22.12 POWOS_NO_TMUX=1 SESSIONS="0 lost"
[ -s "$ACTION_FILE" ] && bad "ignores POWOS_NO_TMUX" || ok "respects POWOS_NO_TMUX"

# 4. Konsole tab, NO sessions → auto-start a fresh session (no menu shown).
run_hook KONSOLE_VERSION=22.12 SESSIONS=""
grep -q '^new:' "$ACTION_FILE" && ok "empty state auto-starts tmux" || bad "empty state did not auto-start"
[ -s "$MENU_FILE" ] && bad "showed a menu with no sessions" || ok "no menu when nothing to resume"

# 5. Sessions exist → DETACHED listed before ATTACHED, attached tagged, and NO
#    selectable divider row is emitted.
run_hook KONSOLE_VERSION=22.12 SESSIONS=$'0 lost-work\n2 live-tab\n0 scratch'
plain=$(sed 's/\x1b\[[0-9;]*m//g' "$MENU_FILE")
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

# 6. Picking a detached session → attach to it by name.
run_hook KONSOLE_VERSION=22.12 SESSIONS=$'0 lost-work\n2 live-tab' \
         FZF_PICK=$'lost-work\t  ○  lost-work'
grep -q '^attach:lost-work$' "$ACTION_FILE" && ok "attaches the picked session" \
  || bad "did not attach picked session: $(cat "$ACTION_FILE")"

echo
echo "tmux-resume: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
