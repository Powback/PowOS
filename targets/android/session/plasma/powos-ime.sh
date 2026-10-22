# The Android keyboard for X11 apps' text fields (unit x11-ime-bridge; /usr/bin/powos-ime-bridge): X11 apps reach
# IBus - GTK on X11 picks its IM module by itself, XIM apps through this XMODIFIERS - and IBus tells KWin.
# Installed as /etc/xdg/plasma-workspace/env/ibus.sh (the desktop's apps; it replaces the image's, whose
# "XMODIFIERS= @ im = ibus" was a shell error) and /etc/profile.d/60-powos-ime.sh (the launcher's, via bash -l).
# No GTK_IM_MODULE / QT_IM_MODULE: those would take Wayland apps off text-input, which already shows the keyboard.
export XMODIFIERS=@im=ibus
# One address file for every IBus client: by default IBus names it after WAYLAND_DISPLAY or DISPLAY, which differ
# between the desktop's apps and the launcher's.
export IBUS_ADDRESS_FILE="${XDG_RUNTIME_DIR:-/run/powos-app}/ibus-address"
