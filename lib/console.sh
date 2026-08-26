#!/bin/bash
# console.sh — `powos console`: every tmux session at once, in one grid.
#
# WHY SNAPSHOTS AND NOT NESTED ATTACHES
# -------------------------------------
# The obvious build is a grid of panes each running `tmux attach -rt <session>`.
# It looks right and is quietly destructive: a tmux session sizes its window to
# fit its attached clients, so a 40x12 grid pane joining your full-screen session
# reflows that session TO 40x12 — for every other client too. You would open the
# overview and watch your real terminals collapse. That is the single reason
# people try this once and conclude tmux can't do it.
#
# So the default renders read-only SNAPSHOTS (`capture-pane`), which attach no
# client and therefore cannot resize anything. `--live` opts into real read-only
# attaches for people who want true interactivity and accept the reflow; it sets
# window-size=largest first so the mirrors at least cannot shrink the originals.
#
# Alt+Enter PROMOTES the focused pane: the snapshot is replaced by a real attach
# to that session, so overview -> working is one keystroke.
set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh"
POWOS_TAG=console

CONSOLE_SESSION="${POWOS_CONSOLE_SESSION:-console}"
# Every key the console binds globally (guarded). ONE list, used both to
# bind and to unbind, so the two can never drift apart — they already did:
# DoubleClick1Pane was bound but not cleaned up, and outlived --kill.
CONSOLE_KEYS="Enter M-Enter DoubleClick1Pane n p"

# Sessions worth showing: everything except the console itself (which would
# recurse) and any leftover console-* scratch sessions.
console_targets() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | awk -v me="$CONSOLE_SESSION" '$0 != me'
}

# One grid cell: a live-refreshing snapshot of a session. No client is attached,
# so the source session's geometry is untouched.
console_pane() {
    local s="${1:-}" rows cols
    [ -n "$s" ] || return 1
    while :; do
        # In tabs layout only one window is on screen; the rest are invisible.
        # Redrawing them anyway burns CPU and — over a phone's connection —
        # real bandwidth, for output nobody can see. Idle until shown.
        if [ "$(tmux display-message -p '#{window_active}' 2>/dev/null)" = "0" ]; then
            sleep "${POWOS_CONSOLE_IDLE_REFRESH:-5}"
            continue
        fi
        tmux has-session -t "=$s" 2>/dev/null || {
            printf '\033[2J\033[H\033[2m%s — session ended\033[0m\n' "$s"; sleep 2; continue
        }
        rows=$(tput lines 2>/dev/null || echo 24)
        cols=$(tput cols 2>/dev/null || echo 80)
        # \033[H homes the cursor instead of clearing, so the pane does not
        # flicker white on every refresh.
        printf '\033[H\033[2K\033[1;36m%s\033[0m  \033[2m(Alt+Enter to take over)\033[0m\n' "$s"
        # A plain `tail` shows the BOTTOM of the source pane, which for a shell
        # idling near the top of a 60-row window is pure trailing whitespace —
        # the grid renders blank and looks broken. Find the last line with real
        # content and show the window ending there instead.
        # Captured WITHOUT -e (no colour) on purpose: a source line wider than
        # this cell must be truncated, and cutting a coloured capture mid-escape
        # corrupts the sequence and bleeds styling across the whole grid. Plain
        # text truncates safely. Without truncation the long lines wrap, push
        # everything down, and scroll the header off — which is what a naive
        # version looks like: unreadable.
        tmux capture-pane -p -t "=$s:" 2>/dev/null \
            | awk -v rows="$((rows > 3 ? rows - 2 : 10))" -v cols="$cols" '
                { l[NR] = substr($0, 1, cols); if ($0 ~ /[^[:space:]]/) last = NR }
                END {
                    if (last == 0) exit
                    start = last - rows + 1; if (start < 1) start = 1
                    for (i = start; i <= last; i++) print l[i]
                }' \
            | while IFS= read -r line; do printf '\033[2K%s\n' "$line"; done
        printf '\033[J'
        sleep "${POWOS_CONSOLE_REFRESH:-1}"
    done
}

# Replace a snapshot pane with a REAL attach to the session it was showing.
# TMUX must be unset or tmux refuses to nest.
console_promote() {
    local pane="${1:-}" s
    s=$(tmux show-options -p -t "$pane" -v @console-session 2>/dev/null)
    [ -n "$s" ] || { tmux display-message "no session bound to this pane"; return 0; }
    tmux has-session -t "=$s" 2>/dev/null || { tmux display-message "$s is gone"; return 0; }
    tmux respawn-pane -k -t "$pane" \
        "TMUX= tmux attach-session -t $(printf '%q' "=$s")" 2>/dev/null
}

# Which layout? A tiled grid halves the WIDTH, and width is the scarce dimension
# on a phone — terminal output is wide, so ~20-column cells are unreadable no
# matter how many rows they get. So narrow screens get a STACK: full-width rows,
# one per session, so each keeps its horizontal output intact and you scroll
# vertically (which is the natural phone gesture anyway).
#
#   grid   tiled 2D      — roomy terminals
#   stack  full-width rows, stacked vertically — phones (default when narrow)
#   tabs   one per window, full screen each    — very small screens
console_layout() {
    local c l
    [ -n "${POWOS_CONSOLE_LAYOUT:-}" ] && { echo "$POWOS_CONSOLE_LAYOUT"; return; }
    c=$(tput cols 2>/dev/null || echo 80)
    l=$(tput lines 2>/dev/null || echo 24)
    if [ "$c" -lt "${POWOS_CONSOLE_MIN_COLS:-100}" ] || [ "$l" -lt "${POWOS_CONSOLE_MIN_LINES:-28}" ]; then
        echo stack
    else
        echo grid
    fi
}

# ── console_build's phases ────────────────────────────────────────
# console_build is an orchestrator over these, in the order it calls them.
# Phases that produce a value publish it in a CONSOLE_* global rather than
# echoing it: several of them call tmux, and a command substitution would
# capture that output instead of letting it through.
CONSOLE_SELF_BIN=""   # binary a snapshot pane re-invokes (console_self_cmd)
CONSOLE_ENV_PFX=""    # env prefix that pins POWOS_LIB for that re-invocation
CONSOLE_PANE_CMD=""   # the command one grid cell runs (console_pane_cmd)

# Panes re-invoke us, so resolve OUR binary and lib rather than trusting
# whatever `powos` happens to be on PATH inside the pane — running from a
# checkout, that would otherwise dispatch into the installed copy.
console_self_cmd() {
    CONSOLE_SELF_BIN="${POWOS_BIN:-}"
    [ -n "$CONSOLE_SELF_BIN" ] || CONSOLE_SELF_BIN="$(command -v powos 2>/dev/null)"
    [ -n "$CONSOLE_SELF_BIN" ] || CONSOLE_SELF_BIN="/usr/bin/powos"
    CONSOLE_ENV_PFX=""
    [ -n "${POWOS_LIB:-}" ] && CONSOLE_ENV_PFX="POWOS_LIB=$(printf '%q' "$POWOS_LIB") "
    # The line above is FALSE whenever POWOS_LIB is unset, and as the last
    # statement of a function that status becomes the return value — which
    # would abort a sourced caller running under `set -e`.
    return 0
}

# How many stacked rows fit before each becomes unreadable? Each pane costs
# its content plus a border line; below ~4 content rows a snapshot shows
# nothing useful, so that is the floor.
console_page_size() {
    local avail per_page
    avail=$(( $(tput lines 2>/dev/null || echo 24) - 1 ))
    per_page=$(( avail / ${POWOS_CONSOLE_MIN_ROWS:-5} ))
    [ "$per_page" -lt 1 ] && per_page=1
    echo "$per_page"
}

# What one grid cell runs: a read-only snapshot re-invocation of ourselves, or
# — under --live — a real read-only attach.
console_pane_cmd() {
    local live="$1" s="$2"
    if [ "$live" = 1 ]; then
        # Mirrors must not dictate geometry. 'largest' means the real client
        # still sets the size; the small mirror just sees part of it.
        tmux set-option -t "=$s" window-size largest 2>/dev/null || true
        tmux set-option -t "=$s" aggressive-resize on 2>/dev/null || true
        CONSOLE_PANE_CMD="TMUX= tmux attach-session -r -t $(printf '%q' "=$s")"
    else
        CONSOLE_PANE_CMD="${CONSOLE_ENV_PFX}$(printf '%q' "$CONSOLE_SELF_BIN") console --pane $(printf '%q' "$s")"
    fi
}

# Put one session on screen: first pane creates the session, the rest either
# open a window (tabs, and each new stack page) or split the current one.
console_place_pane() {
    local layout="$1" first="$2" placed="$3" per_page="$4" s="$5" cmd="$6"
    if [ "$first" = 1 ]; then
        # Pin the size to THIS terminal. Built detached, tmux would pick an
        # arbitrary default and later pages came out a different width from
        # the first — so the pagination maths and the geometry disagreed
        # until a client attached.
        tmux new-session -d -s "$CONSOLE_SESSION" -n "$s" \
             -x "$(tput cols 2>/dev/null || echo 80)" \
             -y "$(tput lines 2>/dev/null || echo 24)" "$cmd"
    elif [ "$layout" = tabs ]; then
        # One window per session: full screen each, switch via the status bar.
        tmux new-window -t "$CONSOLE_SESSION" -n "$s" "$cmd"
    elif [ "$layout" = stack ] && [ "$per_page" -gt 0 ] \
         && [ "$((placed % per_page))" -eq 0 ]; then
        # PAGINATE. tmux panes are not a scrollable viewport — you cannot drag
        # the stack past the window edge. Cramming 12 sessions into 24 rows
        # gives 1 line each, which is useless. So fill a page with readable
        # rows and put the rest on the next window, which the status bar (and
        # n/p) pages through — swipe-equivalent rather than scroll.
        tmux new-window -t "$CONSOLE_SESSION" -n "$s" "$cmd"
    else
        tmux split-window -t "$CONSOLE_SESSION" "$cmd"
    fi
}

# The layout pass, run after every placement and once at the end. It MUST
# honour the chosen layout — an unconditional `tiled` here silently undid the
# even-vertical stack, so a phone got a 2-column grid: exactly the
# narrow-column problem the stack layout exists to avoid.
console_relayout() {
    case "${1:-grid}" in
        tabs)  : ;;   # each session is its own window; nothing to lay out
        stack) tmux select-layout -t "$CONSOLE_SESSION" even-vertical >/dev/null 2>&1 || true ;;
        *)     tmux select-layout -t "$CONSOLE_SESSION" tiled >/dev/null 2>&1 || true ;;
    esac
}

# Bar at the TOP on touch layouts: thumbs sit at the bottom of a phone, so a
# bottom bar is exactly where they occlude the screen, and it reads as chrome
# rather than navigation. tmux makes window names clickable when mouse is on,
# so this doubles as the switcher. The pane borders are labelled either way.
console_status_bar() {
    local layout="$1"
    if [ "$layout" = tabs ] || [ "$layout" = stack ]; then
        tmux set-option -t "$CONSOLE_SESSION" status on 2>/dev/null || true
        tmux set-option -t "$CONSOLE_SESSION" status-position top 2>/dev/null || true
        tmux set-option -t "$CONSOLE_SESSION" status-left '#[bold] ‹ console #[default]' 2>/dev/null || true
        if [ "$layout" = stack ]; then
            tmux set-option -t "$CONSOLE_SESSION" status-right \
                '#[dim] double-tap = open · scroll to pan ' 2>/dev/null || true
        else
            tmux set-option -t "$CONSOLE_SESSION" status-right \
                '#[dim] double-tap = open · n/p = switch ' 2>/dev/null || true
        fi
        tmux set-option -t "$CONSOLE_SESSION" window-status-format ' #W ' 2>/dev/null || true
        tmux set-option -t "$CONSOLE_SESSION" window-status-current-format '#[reverse] #W #[noreverse]' 2>/dev/null || true
    fi
    tmux set-option -t "$CONSOLE_SESSION" pane-border-status top 2>/dev/null || true
    tmux set-option -t "$CONSOLE_SESSION" pane-border-format \
        ' #{?#{@console-session},#{@console-session},#{pane_index}} ' 2>/dev/null || true
}

# Bind single keys WITHOUT stealing them everywhere else. `bind-key -n` adds
# to the root table, which is server-global — an unguarded binding here would
# fire inside the user's real sessions too (Enter would stop working). The
# `-F` guard is evaluated as a format, so it costs no shell per keystroke,
# and anything outside the console session is passed straight through.
console_bind_keys() {
    local layout="$1"
    _ckey() {
        tmux bind-key -n "$1" if-shell -F "#{==:#{session_name},$CONSOLE_SESSION}" \
             "$2" "send-keys $1" 2>/dev/null || true
    }
    local promote="run-shell \"${POWOS_BIN:-powos} console --promote '#{pane_id}'\""
    _ckey Enter   "$promote"
    _ckey M-Enter "$promote"
    # Touch to enter. A SINGLE tap must stay "focus this pane" — tmux uses it to
    # move between panes, and hijacking it would make the overview impossible to
    # navigate without opening something. Double-tap is the deliberate gesture.
    _ckey DoubleClick1Pane "$promote"
    # stack paginates across windows too, so it needs the same paging keys.
    if [ "$layout" = tabs ] || [ "$layout" = stack ]; then
        _ckey n 'next-window'
        _ckey p 'previous-window'
    fi
    unset -f _ckey
}

console_build() {
    local live="${1:-0}" layout="${2:-grid}" first=1 s pane
    local -a targets
    console_self_cmd
    mapfile -t targets < <(console_targets)
    if [ "${#targets[@]}" -eq 0 ]; then
        perr "No other tmux sessions to show."
        plog "Open a terminal or two first — every PowOS terminal is a session."
        return 1
    fi

    tmux kill-session -t "$CONSOLE_SESSION" 2>/dev/null || true

    local placed=0 per_page=0
    [ "$layout" = stack ] && per_page="$(console_page_size)"

    for s in "${targets[@]}"; do
        console_pane_cmd "$live" "$s"
        console_place_pane "$layout" "$first" "$placed" "$per_page" "$s" "$CONSOLE_PANE_CMD"
        first=0
        placed=$((placed + 1))
        # Remember which session this pane shows, so Enter can promote it.
        pane=$(tmux display-message -p -t "$CONSOLE_SESSION" '#{pane_id}')
        tmux set-option -p -t "$pane" @console-session "$s" 2>/dev/null || true
        console_relayout "$layout"
    done

    tmux set-option -t "$CONSOLE_SESSION" mouse on 2>/dev/null || true
    console_status_bar "$layout"
    console_bind_keys "$layout"
    console_relayout "$layout"
    tmux select-window -t "$CONSOLE_SESSION:^" 2>/dev/null || true
    return 0
}

console_usage() {
    cat <<EOF
powos console — every tmux session at once, in one grid

  powos console            Adapts to the screen: tiled GRID on a big terminal,
                           one-session-per-TAB on a small one (phone/SSH).
  powos console --grid     Force the tiled 2D grid (roomy terminals).
  powos console --stack    Force full-width rows stacked vertically. This is
                           what a narrow screen gets automatically: width is the
                           scarce dimension on a phone, so each session keeps its
                           full horizontal output and you scroll vertically.
  powos console --tabs     Force one session per window, full screen each.
  powos console --live     Real read-only attaches instead of snapshots. More
                           interactive, but mirrors participate in tmux's size
                           negotiation (mitigated with window-size=largest).
  powos console --kill     Close the console session.

Keys (only inside the console — passed through everywhere else):
  double-tap / Enter       TAKE OVER the focused session in place
  single tap               focus a pane (kept as focus, not open, so the
                           overview stays navigable by touch)
  scroll / two-finger      pan within a pane (tmux copy-mode); q leaves it
  n / p                    next / previous session        (tabs layout)
  prefix + z               zoom a pane fullscreen         (grid layout)

Layout is chosen from terminal size; override with POWOS_CONSOLE_LAYOUT,
POWOS_CONSOLE_MIN_COLS (default 100) or POWOS_CONSOLE_MIN_LINES (default 28).
EOF
}

cmd_console() {
    command -v tmux >/dev/null 2>&1 || { perr "tmux is not installed."; return 1; }
    case "${1:-}" in
        --pane)    shift; console_pane "${1:-}"; return $? ;;
        --promote) shift; console_promote "${1:-}"; return $? ;;
        --kill)
            # Bindings live in tmux's server-global root table (guarded, but
            # still global), so closing the console must take them with it —
            # otherwise they outlive the thing they belong to.
            # Keep in sync with the _ckey calls in console_build — a key bound
            # there and missing here outlives the console it belongs to.
            for k in $CONSOLE_KEYS; do
                tmux unbind-key -n "$k" 2>/dev/null || true
            done
            tmux kill-session -t "$CONSOLE_SESSION" 2>/dev/null \
                && pok "console closed." || plog "no console session was open."
            return 0 ;;
        -h|--help|help) console_usage; return 0 ;;
    esac

    local live=0 layout=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --live)  live=1 ;;
            --grid)  layout=grid ;;
            --tabs)  layout=tabs ;;
            --stack) layout=stack ;;
        esac
        shift
    done
    [ -n "$layout" ] || layout="$(console_layout)"

    console_build "$live" "$layout" || return 1

    # Never nest the console inside a tmux client — switch instead of attaching.
    if [ -n "${TMUX:-}" ]; then
        tmux switch-client -t "$CONSOLE_SESSION"
    else
        tmux attach-session -t "$CONSOLE_SESSION"
    fi
}
