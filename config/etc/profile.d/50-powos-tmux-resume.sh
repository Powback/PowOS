# 50-powos-tmux-resume.sh — SSH login → rich fzf menu to resume a tmux session.
#
# On an interactive SSH login (and only then) this presents an fzf picker of
# your running tmux sessions — each row shows attach state, name, window count,
# the running command and working dir — with a live preview of the session's
# windows and last screenful. Enter attaches; Esc drops to a plain shell.
#
# Guards: interactive + SSH only, never nests inside tmux, bash only.
# Opt out for one login with:  POWOS_NO_TMUX=1 ssh box

[ -n "$BASH_VERSION" ] || return 0

_powos_tmux_resume() {
    case $- in *i*) : ;; *) return ;; esac          # interactive only
    [ -n "$SSH_CONNECTION" ] || return               # SSH logins only
    [ -z "$TMUX" ] || return                         # never nest inside tmux
    [ -z "$POWOS_NO_TMUX" ] || return                # per-login escape hatch
    command -v tmux >/dev/null 2>&1 || return

    local NEW='  +  new session' SHELL_ONLY='  ·  plain shell (no tmux)'
    local sessions choice name sname

    sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)

    # Build tab-delimited rows: <name>\t<pretty label with attach/wins/cmd/dir>
    _rows() {
        local s wins attach cwd cmd
        while IFS= read -r s; do
            [ -n "$s" ] || continue
            wins=$(tmux   display-message -p -t "$s" '#{session_windows}')
            attach=$(tmux display-message -p -t "$s" '#{?session_attached,●,○}')
            cwd=$(tmux    display-message -p -t "$s" '#{pane_current_path}')
            cmd=$(tmux    display-message -p -t "$s" '#{pane_current_command}')
            cwd=${cwd/#$HOME/\~}
            printf '%s\t%s  %-16s %2s win  %-9s  %s\n' \
                   "$s" "$attach" "$s" "$wins" "$cmd" "$cwd"
        done <<< "$sessions"
    }

    # Multi-line preview: window list + active dir/cmd + last screenful (colour).
    local preview='
        s={1}
        case "$s" in *"new session"*|*"plain shell"*)
            echo "  (starts a fresh session/shell)"; exit 0;; esac
        tmux list-windows -t "$s" -F \
          "  #{window_index}: #{window_name}  [#{window_panes}p]#{?window_active,   ← active,}" 2>/dev/null
        echo
        tmux display-message -p -t "$s" "  dir : #{pane_current_path}"
        tmux display-message -p -t "$s" "  cmd : #{pane_current_command}"
        tmux display-message -p -t "$s" "  seen: #{t:session_activity}"
        echo "  ────────────────────────────────────────────"
        tmux capture-pane -ep -t "$s" 2>/dev/null | tail -n 40
    '

    if command -v fzf >/dev/null 2>&1; then
        choice=$(
            { _rows
              printf '%s\t%s\n' "$NEW" "$NEW"
              printf '%s\t%s\n' "$SHELL_ONLY" "$SHELL_ONLY"
            } | fzf --ansi --reverse --height='80%' \
                    --delimiter=$'\t' --with-nth=2 \
                    --prompt='resume ▶ ' \
                    --header="tmux on $(hostname -s)   ·   Enter = attach   ·   Esc = shell" \
                    --preview="$preview" \
                    --preview-window='right,58%,border-left,wrap'
        )
        name=${choice%%$'\t'*}
    else
        # No fzf (shouldn't happen on PowOS) → most-recent session, else shell.
        name=$(printf '%s\n' "$sessions" | head -n1)
    fi

    case "$name" in
        "" | "$SHELL_ONLY")
            return ;;
        "$NEW")
            printf 'name for new session (blank = auto): ' >&2
            read -r sname
            [ -n "$sname" ] && exec tmux new-session -s "$sname"
            exec tmux new-session ;;
        *)
            exec tmux attach-session -t "$name" ;;
    esac
}
_powos_tmux_resume
unset -f _powos_tmux_resume _rows 2>/dev/null
