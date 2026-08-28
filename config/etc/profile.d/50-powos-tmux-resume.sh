# 50-powos-tmux-resume.sh — hand a terminal to the PowOS tmux wrapper.
#
# Konsole's PowOS.profile sets Command=/usr/lib/powos/powos-tmux-shell and
# /etc/xdg/konsolerc points DefaultProfile at it, so the Konsole *application*
# (its tabs, Yakuake) runs the wrapper directly and never needs this hook.
#
# Two surfaces that Command= cannot reach are why this hook exists:
#
#   1. SSH — there is no Konsole profile to point Command= at.
#
#   2. The Konsole *KPart* — Dolphin's F4 terminal panel. The KPart starts
#      $SHELL itself and ignores the default profile's Command=, so the panel
#      lands in a bare /bin/bash even though konsolerc names PowOS.profile.
#      (Verified on this box: `konsole` forks `tmux new-session`, while
#      `dolphin` forks a plain `/bin/bash`.) A profile.d drop-in DOES reach it,
#      because Fedora's /etc/bashrc sources /etc/profile.d/*.sh for non-login
#      interactive shells, not just login ones.
#
# The hook only *delegates* — all picker logic lives in the wrapper, so there is
# exactly one implementation to maintain.
#
# Opt out for one login/panel with:  POWOS_NO_TMUX=1

[ -n "$BASH_VERSION" ] || return 0

_powos_tmux_hook() {
    case $- in *i*) : ;; *) return ;; esac        # interactive only
    [ -z "$TMUX" ] || return                      # never nest inside tmux
    [ -z "$POWOS_NO_TMUX" ] || return             # escape hatch
    [ -z "$POWOS_TMUX_RESUME_DONE" ] || return    # the wrapper sets this before
                                                  # exec'ing a fallback shell,
                                                  # which would otherwise
                                                  # re-enter here and loop.

    # Restrict to the surfaces Command= could not reach. KONSOLE_VERSION is set
    # by the KPart *and* by the app, but in the app the wrapper has already run
    # and POWOS_TMUX_RESUME_DONE above has short-circuited us — so what actually
    # survives to this line is the embedded KPart case.
    [ -n "$SSH_CONNECTION" ] || [ -n "$KONSOLE_VERSION" ] || return

    # Overridable so the test suite can point at a stub; hardcoding the absolute
    # path made this hook untestable.
    _pts="${POWOS_TMUX_SHELL_BIN:-/usr/lib/powos/powos-tmux-shell}"
    [ -x "$_pts" ] || return
    exec "$_pts"
}
_powos_tmux_hook
unset -f _powos_tmux_hook 2>/dev/null
