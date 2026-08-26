# shellcheck shell=sh
# Sourced, never executed, and by /bin/sh as well as bash — /etc/profile is
# POSIX sh and startplasma does not promise bash. No bashisms below.
# zz-powos-askpass.sh - the same askpass override, for the Plasma session.
#
# /etc/profile.d only reaches processes descended from a login or interactive
# shell. An app started from the Plasma launcher, a .desktop file, KRunner or
# an autostart entry never sees it — and those are exactly the paths that have
# no terminal and therefore actually need an askpass helper.
#
# startplasma sources /etc/xdg/plasma-workspace/env/*.sh into the session
# environment. The file it has to beat is lettered, so this one is "zz-" for
# the same reason as its profile.d twin:
#     /etc/xdg/plasma-workspace/env/ksshaskpass.sh -> SSH_ASKPASS=ksshaskpass
#
# Same -x guard, same reason: degrade to the old helper, never to nothing.

if [ -x /usr/bin/powos-askpass ]; then
    SUDO_ASKPASS=/usr/bin/powos-askpass
    SSH_ASKPASS=/usr/bin/powos-askpass
    export SUDO_ASKPASS SSH_ASKPASS
fi
