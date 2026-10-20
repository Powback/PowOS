// One screen's panel (docs/DESKTOP-WEB-SHELL.md §3.4): shell/'s index.html?mode=panel in a QWebEngineView that
// LayerShellQt makes a layer surface - top layer, along the bottom edge, its height reserved (exclusive zone).
#pragma once

#include <QWebEnginePage>
#include <QWebEngineView>

class Bridge;
class QScreen;
class QWebChannel;
class QWebEngineProfile;
struct Services;

/** Stays on powos:; anything else opens outside (the bridge is powerful). Console lines to stderr. */
class ShellPage : public QWebEnginePage {
    Q_OBJECT
public:
    using QWebEnginePage::QWebEnginePage;

protected:
    bool acceptNavigationRequest(const QUrl &url, NavigationType type, bool isMainFrame) override;
    void javaScriptConsoleMessage(JavaScriptConsoleMessageLevel level, const QString &message, int line, const QString &source) override;
};

class Panel : public QWebEngineView {
    Q_OBJECT
public:
    /** The bar's height, and the space KWin keeps free of maximized windows. */
    static constexpr int Height = 48;

    Panel(QScreen *screen, QWebEngineProfile *profile, const Services &services);
    Bridge *bridge() const { return m_bridge; }

private:
    /** panel.height: taller while the launcher is open above the bar (exclusive zone unchanged); [px] <= 0: the bar. */
    void setSurfaceHeight(int px);
    /**
     * The layer surface's role, set on the window's LayerShellQt::Window - looked up each time, never kept: QWidget
     * re-creates the top-level window at the first show (see main.cpp's HACK) and the old one's Window goes with it.
     */
    void applyLayer();
    bool event(QEvent *e) override;
    QScreen *m_screen;
    Bridge *m_bridge;
    QWebChannel *m_channel;
    bool m_open = false;
};
