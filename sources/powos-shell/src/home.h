// One screen's home (docs/DESKTOP-SHELL.md): shell/'s index.html?mode=desktop - the grid of widgets and apps, PowOS
// AI's pill and the pet - in a full-screen layer surface under every window, the wallpaper behind it. Its glass is
// KWin's blur behind the page's surfaces: the page reports where they are (ui/nativeglass.ts "b.r"), as on the phone.
#pragma once

#include "view.h"

#include <QRegion>

class Home : public ShellView {
    Q_OBJECT
public:
    Home(QScreen *screen, QWebEngineProfile *profile, const Services &services);

private:
    void applyLayer() override;
    void resizeEvent(QResizeEvent *e) override;
    /** "b.r <dpr> <n> [x y w h tl tr br bl alpha blur]..." (CSS px = this view's px): KWin blurs behind those. */
    void setGlass(const QString &regions);
    /** The last regions: set again on a re-created window (the first show's, see view.h). */
    QRegion m_glass;
};
