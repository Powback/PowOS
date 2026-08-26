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
TMPD="$(mktemp -d)"
TM() { tmux -L "$SOCK" "$@"; }
cleanup() { TM kill-server 2>/dev/null; rm -rf "$TMPD"; }
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

# ══════════════════════════════════════════════════════════════════
echo "== console_build phases (the extracted seams, contract level) =="
# ══════════════════════════════════════════════════════════════════
# console_build is an orchestrator over named phases. The checks above pin the
# whole-file invariants; these pin each phase's own contract — what it
# publishes, which tmux verb it reaches for, and what it refuses to do — so a
# phase cannot quietly change while console_build still looks right.
#
# Asserted on the CONTRACT (published global, recorded tmux call, exit code),
# never on the prose: rewording a message must not fail a test about a guard.
# tmux is a RECORDER here, not the real server: these phases are about which
# command is issued, and the real-server checks above already cover the rest.

# `cleanup` already ran once above (it clears any leftovers from a previous
# run), and it removes TMPD — so recreate it here rather than at declaration.
mkdir -p "$TMPD"
PRE="$TMPD/phase-preamble.sh"
cat > "$PRE" <<PREEOF
source "$LIB" 2>/dev/null
REC="$TMPD/tmux-calls"; : > "\$REC"
tmux() {
    printf 'tmux %s\n' "\$*" >> "\$REC"
    case "\$1" in
        display-message) echo '%1' ;;
        list-sessions)   [ -n "\${SESSIONS:-}" ] && printf '%s\n' \${SESSIONS} ;;
    esac
    return 0
}
tput() { case "\$1" in lines) echo "\${TLINES:-24}" ;; cols) echo "\${TCOLS:-80}" ;; esac; return 0; }
calls() { cat "\$REC"; }
PREEOF

# Run a snippet with the lib sourced and tmux/tput recording.
phase() { POWOS_LIB="$REPO/lib" bash -c "source '$PRE'; $1" 2>&1; }

# ── console_self_cmd: which binary a snapshot pane re-invokes ─────
# Its last statement is `[ -n "$POWOS_LIB" ] && CONSOLE_ENV_PFX=...`, FALSE
# whenever POWOS_LIB is unset. Without the explicit `return 0` that status
# becomes the return value and a sourced caller under `set -e` dies here.
OUT=$(env -u POWOS_LIB bash -c "source '$LIB' 2>/dev/null; console_self_cmd; echo rc=\$?")
printf '%s' "$OUT" | grep -q 'rc=0' \
  && ok "console_self_cmd returns 0 when POWOS_LIB is unset" \
  || bad "console_self_cmd leaks a false test as its return value (set -e would abort)"

OUT=$(phase 'POWOS_BIN=/opt/powos console_self_cmd; echo "$CONSOLE_SELF_BIN"')
[ "$OUT" = /opt/powos ] && ok "console_self_cmd honours POWOS_BIN" \
  || bad "console_self_cmd ignored POWOS_BIN (got '$OUT')"

OUT=$(phase 'POWOS_LIB=/tmp/l console_self_cmd; printf "%s" "$CONSOLE_ENV_PFX"')
case "$OUT" in
  POWOS_LIB=*) ok "console_self_cmd pins POWOS_LIB for the re-invoked pane" ;;
  *) bad "pane re-invocation would not pin POWOS_LIB (got '$OUT')" ;;
esac

# ── console_page_size: how many stacked rows stay readable ────────
OUT=$(phase 'TLINES=4 console_page_size')
[ "$OUT" = 1 ] && ok "console_page_size floors at 1 (never 0 panes per page)" \
  || bad "console_page_size returned '$OUT' on a 4-row terminal"
OUT=$(phase 'TLINES=61 POWOS_CONSOLE_MIN_ROWS=5 console_page_size')
[ "$OUT" = 12 ] && ok "console_page_size divides the rows by MIN_ROWS" \
  || bad "console_page_size returned '$OUT', expected 12"

# ── console_pane_cmd: what one grid cell runs ─────────────────────
OUT=$(phase 'console_self_cmd; console_pane_cmd 0 sess; echo "$CONSOLE_PANE_CMD"')
printf '%s' "$OUT" | grep -q -- '--pane' \
  && ok "snapshot mode re-invokes powos with --pane" \
  || bad "snapshot pane does not re-invoke --pane (got '$OUT')"
OUT=$(phase 'console_self_cmd; console_pane_cmd 1 sess; echo "$CONSOLE_PANE_CMD"; calls')
printf '%s' "$OUT" | grep -q 'attach-session -r -t =sess' \
  && ok "--live attaches READ-ONLY, to the exact session name" \
  || bad "--live pane is not a read-only exact-match attach"
printf '%s' "$OUT" | grep -q 'window-size largest' \
  && ok "--live sets window-size=largest first (mirrors must not shrink originals)" \
  || bad "--live mirror could resize the user's real session"
OUT=$(phase 'console_self_cmd; console_pane_cmd 0 sess; calls')
[ -z "$OUT" ] && ok "snapshot mode touches NO tmux options (the whole point)" \
  || bad "snapshot mode issued tmux commands: $OUT"

# ── console_place_pane: session/window/split ──────────────────────
OUT=$(phase 'console_place_pane grid 1 0 0 s "cmd"; calls')
printf '%s' "$OUT" | grep -q 'new-session .* -x 80 -y 24' \
  && ok "first pane pins the size to THIS terminal (-x/-y explicit)" \
  || bad "first pane built without explicit geometry: $OUT"
OUT=$(phase 'console_place_pane tabs 0 1 0 s "cmd"; calls')
printf '%s' "$OUT" | grep -q 'new-window' \
  && ok "tabs layout opens a window per session" || bad "tabs did not open a window"
OUT=$(phase 'console_place_pane stack 0 4 2 s "cmd"; calls')
printf '%s' "$OUT" | grep -q 'new-window' \
  && ok "stack paginates onto a new window at the page boundary" \
  || bad "stack did not paginate at placed%%per_page==0"
OUT=$(phase 'console_place_pane stack 0 3 2 s "cmd"; calls')
printf '%s' "$OUT" | grep -q 'split-window' \
  && ok "stack splits within a page" || bad "stack did not split mid-page"
OUT=$(phase 'console_place_pane stack 0 4 0 s "cmd"; calls')
printf '%s' "$OUT" | grep -q 'split-window' \
  && ok "per_page=0 cannot divide by zero — it splits instead" \
  || bad "per_page=0 did not fall through to split-window"

# ── console_relayout: the layout pass must honour the layout ──────
# An unconditional `tiled` here silently undid the even-vertical stack, so a
# phone got the 2-column grid the stack layout exists to avoid.
OUT=$(phase 'console_relayout stack; calls')
printf '%s' "$OUT" | grep -q 'even-vertical' \
  && ok "stack lays out even-vertical" || bad "stack was not laid out vertically"
OUT=$(phase 'console_relayout grid; calls')
printf '%s' "$OUT" | grep -q 'tiled' && ok "grid lays out tiled" || bad "grid was not tiled"
OUT=$(phase 'console_relayout tabs; calls')
[ -z "$OUT" ] && ok "tabs lays out nothing (each session owns its window)" \
  || bad "tabs issued a layout command: $OUT"

# ── console_status_bar: borders are labelled in EVERY layout ──────
for L in grid stack tabs; do
  OUT=$(phase "console_status_bar $L; calls")
  printf '%s' "$OUT" | grep -q 'pane-border-format' \
    && ok "$L: panes are labelled with the session they show" \
    || bad "$L: pane borders unlabelled — you cannot tell the panes apart"
done
OUT=$(phase 'console_status_bar grid; calls')
printf '%s' "$OUT" | grep -q 'status-position top' \
  && bad "grid got the touch status bar (that bar is for phones)" \
  || ok "grid gets no touch status bar"
OUT=$(phase 'console_status_bar stack; calls')
printf '%s' "$OUT" | grep -q 'status-position top' \
  && ok "stack puts the bar at the TOP (thumbs occlude the bottom)" \
  || bad "stack bar is not at the top"

# ── console_bind_keys: paging keys only where paging exists ───────
OUT=$(phase 'console_bind_keys grid; calls')
printf '%s' "$OUT" | grep -qE 'bind-key -n [np] ' \
  && bad "grid bound n/p — it has no pages to move between" \
  || ok "grid does not bind the paging keys"
for L in stack tabs; do
  OUT=$(phase "console_bind_keys $L; calls")
  printf '%s' "$OUT" | grep -q 'bind-key -n n ' \
    && ok "$L binds n/p (it paginates across windows)" \
    || bad "$L cannot be paged with n/p"
done
OUT=$(phase 'console_bind_keys stack; calls')
if printf '%s\n' "$OUT" | grep 'bind-key -n' | grep -qv 'if-shell -F'; then
  bad "a binding escaped the session guard (would steal keys everywhere)"
else
  ok "every key console_bind_keys binds is session-guarded"
fi
OUT=$(phase 'console_bind_keys grid; declare -F _ckey || echo gone')
[ "$OUT" = gone ] && ok "the _ckey helper is unset again afterwards" \
  || bad "_ckey leaked into the caller's namespace"

# ── console_build: nothing to mirror is a refusal, not an empty grid ──
OUT=$(phase 'SESSIONS= console_build 0 grid; echo "rc=$?"; calls')
printf '%s' "$OUT" | grep -q 'rc=1' \
  && ok "console_build refuses when there are no other sessions" \
  || bad "console_build built an empty console"
printf '%s' "$OUT" | grep -q 'kill-session' \
  && bad "console_build killed the console session before knowing it had work" \
  || ok "the refusal happens before anything is destroyed"


echo
echo "console: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
