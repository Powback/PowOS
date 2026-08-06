# 50-powos-tmux-resume.sh — SSH login → tmux resume picker.
#
# Local terminals do NOT come through here any more. Konsole's PowOS.profile
# sets Command=/usr/lib/powos/powos-tmux-shell, so every Konsole-KPart surface
# (Konsole tabs, Dolphin's F4 panel, Yakuake) runs the wrapper directly and
# needs no shell-rc hook at all.
#
# SSH is the one case with no Konsole profile to point at, so it keeps a hook —
# but the hook only *delegates*. All the picker logic lives in the wrapper, so
# there is exactly one implementation to maintain.
#
# Opt out for one login with:  POWOS_NO_TMUX=1 ssh box

[ -n "$BASH_VERSION" ] || return 0

_powos_tmux_ssh_hook() {
    case $- in *i*) : ;; *) return ;; esac        # interactive only
    [ -n "$SSH_CONNECTION" ] || return            # SSH logins only
    [ -z "$TMUX" ] || return                      # never nest inside tmux
    [ -z "$POWOS_NO_TMUX" ] || return             # escape hatch
    [ -z "$POWOS_TMUX_RESUME_DONE" ] || return    # once per login; the wrapper
                                                  # sets this before exec'ing a
                                                  # fallback shell, which would
                                                  # otherwise re-enter here.
    [ -x /usr/lib/powos/powos-tmux-shell ] || return
    exec /usr/lib/powos/powos-tmux-shell
}
_powos_tmux_ssh_hook
unset -f _powos_tmux_ssh_hook 2>/dev/null
