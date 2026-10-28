// org.powos.Shell /Launcher on the session bus (docs/DESKTOP-KWIN-NATIVE.md phase 1 item 5): Meta (kwinrc
// ModifierOnlyShortcuts, set by powos-desktop-shell) and KWin's swipe-up (kwin 0009) open PowOS's launcher, not
// Kickoff. Registered in desktop mode only (POWOS_DESKTOP_MODE=1); the page gets it as the "launcher.toggle" event.
#pragma once

#include <QObject>

class Launcher : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.powos.Shell")
public:
    using QObject::QObject;

public Q_SLOTS:
    /** Opens the launcher, or closes it when it's open (the panel's, else home's). */
    Q_SCRIPTABLE void toggle() { Q_EMIT toggled(); }

Q_SIGNALS:
    void toggled();
};
