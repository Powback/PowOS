# Left twice on an empty prompt, in a PowOS tmux session: the session picker (powos-tmux-shell --switch, as Ctrl+b s
# opens it), over the session - pick another, or Esc back. Left anywhere else moves the cursor as ever.
# Login shells read this (tmux starts its shells as login shells); interactive bash inside tmux only.
case $- in *i*) ;; *) return 0 ;; esac
[ -n "$BASH_VERSION" ] && [ -n "$TMUX" ] || return 0

# The two presses count as one gesture within this long (microseconds).
_POWOS_LEFT_TWICE_US=600000

_powos_left() {
    if [ -n "$READLINE_LINE" ]; then
        unset _powos_left_at
        ((READLINE_POINT > 0)) && READLINE_POINT=$((READLINE_POINT - 1))
        return
    fi
    local now=${EPOCHREALTIME/[.,]/}
    if [ -n "$_powos_left_at" ] && ((now - _powos_left_at < _POWOS_LEFT_TWICE_US)); then
        unset _powos_left_at
        tmux display-popup -E -w 90% -h 80% '/usr/lib/powos/powos-tmux-shell --switch'
    else
        _powos_left_at=$now
    fi
}
# Both encodings of Left: normal and application cursor mode.
bind -x '"\e[D": _powos_left'
bind -x '"\eOD": _powos_left'
