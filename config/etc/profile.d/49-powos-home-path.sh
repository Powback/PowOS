# 49-powos-home-path.sh — show /home/<user> paths, not ostree's physical
# /var/home/<user>, in the shell prompt.
#
# On ostree/bootc systems /home is a symlink to /var/home, and $HOME is
# /home/<user>. But a terminal's getcwd() reports the *physical* path, so a tab
# opened (or cloned) anywhere under home shows /var/home/<user>/… instead of
# ~/… . New Konsole tabs clone the current tab's directory (by design), so this
# ugly prefix follows you around.
#
# Fix: if $PWD is under /var/home, re-cd to the equivalent /home path (same
# directory, since /home → /var/home). PWD then reads /home/<user>/… and, when
# that IS $HOME, collapses to ~. Only rewrites when the /home path resolves to
# the exact same directory, so a non-ostree box (real /home) is left untouched.
#
# Runs before 50-powos-tmux-resume.sh so a tmux session it starts inherits the
# clean path too.

[ -n "$BASH_VERSION" ] || return 0

_powos_home_path() {
    case $- in *i*) : ;; *) return ;; esac        # interactive only
    case "$PWD" in /var/home/?*) : ;; *) return ;; esac
    local logical="/home/${PWD#/var/home/}"
    # Same physical directory? (symlink intact) Then adopt the logical path.
    [ "$(cd -P "$logical" 2>/dev/null && pwd)" = "$PWD" ] && cd "$logical" 2>/dev/null
    return 0
}
_powos_home_path
unset -f _powos_home_path 2>/dev/null
