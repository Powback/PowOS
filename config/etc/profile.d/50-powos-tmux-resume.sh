# 50-powos-tmux-resume.sh — open a terminal → fzf menu to resume a tmux session.
#
# On an interactive Konsole tab (or an SSH login) this puts you into tmux so no
# work is ever lost when a tab closes:
#   • no sessions yet        → silently start & attach a fresh session
#   • sessions already exist  → fzf picker to resume one
# The picker leads with DETACHED sessions — no client attached, i.e. the tabs you
# lost — since those are the real resume targets. Sessions already attached to a
# client (still visible in another tab) are listed dimmed on the underside for
# reference. Enter attaches; Del kills the highlighted session; Esc = plain shell.
#
# Guards: interactive + (Konsole tab OR SSH) only, never nests inside tmux, bash
# only, once per terminal. Opt out for a login/tab with:  POWOS_NO_TMUX=1
#   ssh box            → POWOS_NO_TMUX=1 ssh box
#   Konsole            → set POWOS_NO_TMUX=1 in the environment / profile

[ -n "$BASH_VERSION" ] || return 0

# Row generator for the picker. Exported so fzf's reload() can re-run it after a
# kill. Reads tmux fresh each call, so the list always reflects reality. Emits
# tab-delimited "<session-name-or-token>\t<pretty label>" rows: detached first
# (the real resume targets), then the new/shell actions, then the already-
# attached sessions, each dimmed and tagged "attached" (still selectable — you
# can jump to one — but visibly distinct). No divider row, because fzf can't
# make a row non-selectable and a fake entry is confusing.
_powos_tmux_rows() {
    local NEW="${POWOS_TMUX_NEW}" SHELL_ONLY="${POWOS_TMUX_SHELL}"
    local s wins cwd cmd
    local ttl winlbl
    _row() {  # _row <name> <glyph> <dim?> <tag?>
        local pre="" post="" tag=""
        [ -n "$3" ] && { pre=$'\033[2m'; post=$'\033[0m'; }
        [ -n "$4" ] && tag="  ($4)"
        wins=$(tmux display-message -p -t "$1" '#{session_windows}' 2>/dev/null)
        # Only surface the window count when a session actually has more than one
        # — every fresh session has 1, so printing "1 win" on every row is noise.
        winlbl=""; [ "${wins:-1}" -gt 1 ] 2>/dev/null && winlbl="${wins}w"
        cwd=$(tmux  display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null)
        cmd=$(tmux  display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)
        # The title a program set for the pane (OSC 0/2 — what a terminal shows
        # in its titlebar). Much more identifying than the bare command. Fall
        # back to the command when nothing set a distinct title.
        ttl=$(tmux display-message -p -t "$1" '#{pane_title}' 2>/dev/null)
        cwd=${cwd/#\/var\/home\//\/home\/}   # ostree physical → logical
        cwd=${cwd/#$HOME/\~}
        case "$ttl" in ""|"$cmd"|"$(hostname -s 2>/dev/null)") ttl="$cmd" ;; esac
        printf '%s\t%s%s  %-14s %-4s %-26.26s  %s%s%s\n' \
               "$1" "$pre" "$2" "$1" "$winlbl" "$ttl" "$cwd" "$tag" "$post"
    }
    # tmux -F does NOT expand \t, so put the number first and split on space.
    tmux list-sessions -F '#{session_attached} #{session_name}' 2>/dev/null \
      | awk '$1==0{$1="";sub(/^ /,"");print}' | while IFS= read -r s; do
          [ -n "$s" ] && _row "$s" '○' ''
      done
    printf '%s\t%s\n' "$NEW" "$NEW"
    printf '%s\t%s\n' "$SHELL_ONLY" "$SHELL_ONLY"
    tmux list-sessions -F '#{session_attached} #{session_name}' 2>/dev/null \
      | awk '$1!=0{$1="";sub(/^ /,"");print}' | while IFS= read -r s; do
          [ -n "$s" ] && _row "$s" '●' 'dim' 'attached'
      done
    unset -f _row
}
export -f _powos_tmux_rows 2>/dev/null

_powos_tmux_resume() {
    case $- in *i*) : ;; *) return ;; esac           # interactive only
    [ -z "$TMUX" ] || return                          # never nest inside tmux
    [ -z "$POWOS_NO_TMUX" ] || return                 # escape hatch
    [ -z "$POWOS_TMUX_RESUME_DONE" ] || return        # once per terminal
    # Scope to real terminals we own: a Konsole tab (exports KONSOLE_VERSION) or
    # an SSH login. Skips random `bash -i`, editor terminals, distrobox shells.
    [ -n "$KONSOLE_VERSION" ] || [ -n "$SSH_CONNECTION" ] || return
    command -v tmux >/dev/null 2>&1 || return
    # Mark before we prompt: if the user picks "plain shell", a nested bash in
    # the same tab must not re-open this menu.
    export POWOS_TMUX_RESUME_DONE=1

    # Action-row tokens, exported so _powos_tmux_rows (incl. fzf reload) agrees
    # with the case below on the exact strings.
    export POWOS_TMUX_NEW='  +  new session'
    export POWOS_TMUX_SHELL='  ·  plain shell (no tmux)'
    local choice name sname have_any

    have_any=$(tmux list-sessions -F x 2>/dev/null | head -n1)
    # Nothing to resume → just make this tab persistent by starting a fresh
    # session. This is the "auto-start tmux" case; no menu when there is no
    # prior work to choose from.
    if [ -z "$have_any" ]; then
        exec tmux new-session
    fi

    # Multi-line preview: window list + active dir/cmd + last screenful (colour).
    local preview='
        s={1}
        case "$s" in *"new session"*|*"plain shell"*)
            echo "  (starts a fresh session/shell)"; exit 0;; esac
        tmux list-windows -t "$s" -F \
          "  #{window_index}: #{window_name}  [#{window_panes}p]#{?window_active,   ← active,}" 2>/dev/null
        echo
        tmux display-message -p -t "$s" "  title: #{pane_title}"
        tmux display-message -p -t "$s" "  dir  : #{pane_current_path}"
        tmux display-message -p -t "$s" "  cmd  : #{pane_current_command}"
        tmux display-message -p -t "$s" "  seen : #{t:session_activity}"
        echo "  ────────────────────────────────────────────"
        tmux capture-pane -ep -t "$s" 2>/dev/null | tail -n 40
    '

    if command -v fzf >/dev/null 2>&1; then
        choice=$(
            _powos_tmux_rows | fzf --ansi --reverse --height='80%' \
                    --delimiter=$'\t' --with-nth=2 \
                    --prompt='resume ▶ ' \
                    --header="tmux on $(hostname -s)   ·   Enter = attach   ·   Del = kill   ·   Esc = shell" \
                    --bind='del:execute-silent(tmux kill-session -t {1} 2>/dev/null)+reload(bash -c _powos_tmux_rows)' \
                    --preview="$preview" \
                    --preview-window='right,58%,border-left,wrap'
        )
        name=${choice%%$'\t'*}
    else
        # No fzf (shouldn't happen on PowOS) → most-recent DETACHED session, else
        # leave the terminal as a plain shell.
        name=$(tmux list-sessions -F '#{session_attached} #{session_name}' 2>/dev/null \
                 | awk '$1==0{$1="";sub(/^ /,"");print}' | head -n1)
    fi

    case "$name" in
        "" | "$POWOS_TMUX_SHELL")
            return ;;
        "$POWOS_TMUX_NEW")
            printf 'name for new session (blank = auto): ' >&2
            read -r sname
            [ -n "$sname" ] && exec tmux new-session -s "$sname"
            exec tmux new-session ;;
        *)
            # The picked session may have just been killed (Del) leaving nothing;
            # attach only if it still exists, else fall through to a shell.
            tmux has-session -t "$name" 2>/dev/null && exec tmux attach-session -t "$name" ;;
    esac
}
_powos_tmux_resume
unset -f _powos_tmux_resume _powos_tmux_rows 2>/dev/null
