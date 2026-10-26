// One screen's panel (docs/DESKTOP-WEB-SHELL.md §3.4): shell/'s index.html?mode=panel in a layer surface - top layer,
// along the bottom edge, its height reserved (exclusive zone). Phase 0; not started by default (Plasma's panel stays).
#pragma once

#include "view.h"

class Panel : public ShellView {
    Q_OBJECT
public:
    /** The bar's height, and the space KWin keeps free of maximized windows. */
    static constexpr int Height = 48;

    Panel(QScreen *screen, QWebEngineProfile *profile, const Services &services);

private:
    /** panel.height: taller while the launcher is open above the bar (exclusive zone unchanged); [px] <= 0: the bar. */
    void setSurfaceHeight(int px);
    void applyLayer() override;
    bool m_open = false;
};
