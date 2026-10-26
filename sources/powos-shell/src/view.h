// One shell/ page in one layer surface (docs/DESKTOP-WEB-SHELL.md §3.4): a QWebEngineView that LayerShellQt makes a
// layer surface, with its own Bridge over QWebChannel. Panel (the bar) and Home (the desktop's home) are its roles.
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

class ShellView : public QWebEngineView {
    Q_OBJECT
public:
    /** [mode]: index.html?mode=<mode> on [screen]. The subclass sets its layer up in applyLayer(). */
    ShellView(QScreen *screen, QWebEngineProfile *profile, const Services &services, const QString &mode);
    Bridge *bridge() const { return m_bridge; }

protected:
    /** Called once the subclass is built (the layer role needs its virtual applyLayer), then loads the page. */
    void start();
    /**
     * The layer surface's role, set on the window's LayerShellQt::Window - looked up each time, never kept: QWidget
     * re-creates the top-level window at the first show (see main.cpp's HACK) and the old one's Window goes with it.
     */
    virtual void applyLayer() = 0;
    bool event(QEvent *e) override;
    QScreen *m_screen;
    Bridge *m_bridge;

private:
    QWebChannel *m_channel;
    QString m_mode;
};
