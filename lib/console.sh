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

# Sessions worth showing: everything except the console itself (which would
# recurse) and any leftover console-* scratch sessions.
console_targets() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | awk -v me="$CONSOLE_SESSION" '$0 != me'
}

# One grid cell: a live-refreshing snapshot of a session. No client is attached,
# so the source session's geometry is untouched.
console_pane() {
    local s="${1:-}" rows
    [ -n "$s" ] || return 1
    while :; do
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

console_build() {
    local live="${1:-0}" first=1 s pane cmd
    local -a targets
    # Panes re-invoke us, so resolve OUR binary and lib rather than trusting
    # whatever `powos` happens to be on PATH inside the pane — running from a
    # checkout, that would otherwise dispatch into the installed copy.
    local self_bin="${POWOS_BIN:-}" env_pfx=""
    [ -n "$self_bin" ] || self_bin="$(command -v powos 2>/dev/null)"
    [ -n "$self_bin" ] || self_bin="/usr/bin/powos"
    [ -n "${POWOS_LIB:-}" ] && env_pfx="POWOS_LIB=$(printf '%q' "$POWOS_LIB") "
    mapfile -t targets < <(console_targets)
    if [ "${#targets[@]}" -eq 0 ]; then
        perr "No other tmux sessions to show."
        plog "Open a terminal or two first — every PowOS terminal is a session."
        return 1
    fi

    tmux kill-session -t "$CONSOLE_SESSION" 2>/dev/null || true

    for s in "${targets[@]}"; do
        if [ "$live" = 1 ]; then
            # Mirrors must not dictate geometry. 'largest' means the real client
            # still sets the size; the small mirror just sees part of it.
            tmux set-option -t "=$s" window-size largest 2>/dev/null || true
            tmux set-option -t "=$s" aggressive-resize on 2>/dev/null || true
            cmd="TMUX= tmux attach-session -r -t $(printf '%q' "=$s")"
        else
            cmd="${env_pfx}$(printf '%q' "$self_bin") console --pane $(printf '%q' "$s")"
        fi

        if [ "$first" = 1 ]; then
            tmux new-session -d -s "$CONSOLE_SESSION" -n grid "$cmd"
            first=0
        else
            tmux split-window -t "$CONSOLE_SESSION":grid "$cmd"
        fi
        # Remember which session this pane shows, so Alt+Enter can promote it.
        pane=$(tmux display-message -p -t "$CONSOLE_SESSION":grid '#{pane_id}')
        tmux set-option -p -t "$pane" @console-session "$s" 2>/dev/null || true
        tmux select-layout -t "$CONSOLE_SESSION":grid tiled >/dev/null 2>&1 || true
    done

    tmux set-option -t "$CONSOLE_SESSION" mouse on 2>/dev/null || true
    tmux set-option -t "$CONSOLE_SESSION" pane-border-status top 2>/dev/null || true
    tmux set-option -t "$CONSOLE_SESSION" pane-border-format \
        ' #{?#{@console-session},#{@console-session},#{pane_index}} ' 2>/dev/null || true
    # No prefix needed: this is a viewer, so the useful verbs are single keys.
    tmux bind-key -n M-Enter run-shell \
        "${POWOS_BIN:-powos} console --promote '#{pane_id}'" 2>/dev/null || true
    tmux select-layout -t "$CONSOLE_SESSION":grid tiled >/dev/null 2>&1 || true
    return 0
}

console_usage() {
    cat <<EOF
powos console — every tmux session at once, in one grid

  powos console            Snapshot grid (default). Read-only, cannot resize
                           your real sessions.
  powos console --live     Real read-only attaches instead of snapshots. More
                           interactive, but mirrors participate in tmux's size
                           negotiation (mitigated with window-size=largest).
  powos console --kill     Close the console session.

In the grid:
  click / arrow keys       focus a pane (mouse is on)
  prefix + z               zoom the focused pane fullscreen, again to restore
  Alt + Enter              TAKE OVER the focused session in place
EOF
}

cmd_console() {
    command -v tmux >/dev/null 2>&1 || { perr "tmux is not installed."; return 1; }
    case "${1:-}" in
        --pane)    shift; console_pane "${1:-}"; return $? ;;
        --promote) shift; console_promote "${1:-}"; return $? ;;
        --kill)
            tmux kill-session -t "$CONSOLE_SESSION" 2>/dev/null \
                && pok "console closed." || plog "no console session was open."
            return 0 ;;
        -h|--help|help) console_usage; return 0 ;;
    esac

    local live=0
    [ "${1:-}" = "--live" ] && live=1

    console_build "$live" || return 1

    # Never nest the console inside a tmux client — switch instead of attaching.
    if [ -n "${TMUX:-}" ]; then
        tmux switch-client -t "$CONSOLE_SESSION"
    else
        tmux attach-session -t "$CONSOLE_SESSION"
    fi
}
