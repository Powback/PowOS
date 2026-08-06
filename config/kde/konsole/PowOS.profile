[Appearance]
ColorScheme=Breeze

[General]
Name=PowOS Default
Parent=FALLBACK/
# Note: no Directory / StartInCurrentSessionDir here on purpose. Konsole's
# default (StartInCurrentSessionDir=true) clones the current tab's directory
# into new tabs, which is the wanted behavior. The physical /var/home/<user>
# path that results is collapsed to /home/<user> (and ~) by
# /etc/profile.d/49-powos-home-path.sh.

# Run every terminal through the tmux resume wrapper instead of a bare shell, so
# closing a tab never loses work. /etc/xdg/konsolerc points DefaultProfile here,
# so every Konsole-KPart surface — Dolphin's F4 panel, Yakuake — inherits it too.
# Opt out with POWOS_NO_TMUX=1; the wrapper always falls back to a login shell.
Command=/usr/lib/powos/powos-tmux-shell
