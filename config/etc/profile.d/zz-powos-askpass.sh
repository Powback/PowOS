# shellcheck shell=sh
# Sourced, never executed, and by /bin/sh as well as bash — /etc/profile is
# POSIX sh and startplasma does not promise bash. No bashisms below.
# zz-powos-askpass.sh - point every askpass consumer at powos-askpass.
#
# WHY THE FILENAME STARTS WITH "zz" AND NOT A NUMBER
#
# Every other PowOS profile.d drop-in is numbered (05-, 49-, 50-). This one
# cannot be, and the reason is the whole point of the file.
#
# /etc/profile and /etc/bashrc both iterate `/etc/profile.d/*.sh`, i.e. in
# glob order, and digits sort BEFORE letters. The two files this must win
# against are lettered:
#
#     /etc/profile.d/askpass.sh              (ublue/bazzite, unowned by rpm)
#         -> SUDO_ASKPASS=/usr/bin/ksshaskpass
#     /etc/profile.d/kde-openssh-askpass.sh  (kde-settings rpm)
#         -> SSH_ASKPASS=/usr/bin/ksshaskpass
#
# A "50-powos-askpass.sh" would run FIRST and be silently overwritten by both,
# and the only symptom would be the original bug still happening. Verified
# ordering on the shipped base:
#     6: askpass.sh   20: gnome-ssh-askpass.sh   22: kde-openssh-askpass.sh
# "zz-" sorts after every one of them (vte.sh and which2.sh included).
#
# THE BUG BEING FIXED
#
# ksshaskpass is an SSH passphrase dialog. Handing it a sudo prompt produces
#     ksshaskpass[1259757]: Unable to parse phrase "[sudo] password for powos: "
# and a box titled "Enter SSH Credentials" reading "Please enter passphrase" —
# no command, no requesting process, no reason. See /usr/bin/powos-askpass.
#
# WHY THE -x GUARD
#
# So a half-applied image degrades to the old, ugly-but-working helper instead
# of to nothing. Note this only ever affects `sudo -A`; plain `sudo` prompts on
# the terminal regardless of SUDO_ASKPASS, so no value here — or absence of one
# — can lock anyone out of root.
#
# The matching .csh files are deliberately NOT shadowed: nothing on this image
# runs a csh login shell, and a broken csh syntax error in profile.d would be
# far more damaging than the dialog it fixed.

if [ -x /usr/bin/powos-askpass ]; then
    SUDO_ASKPASS=/usr/bin/powos-askpass
    SSH_ASKPASS=/usr/bin/powos-askpass
    export SUDO_ASKPASS SSH_ASKPASS
fi
