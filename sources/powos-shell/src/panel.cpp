#include "panel.h"
#include "bridge.h"
#include "services.h"

#include <LayerShellQt/Window>
#include <QDesktopServices>
#include <QScreen>
#include <QTimer>
#include <QUrlQuery>
#include <QWebChannel>
#include <QWebEngineProfile>
#include <QWindow>

bool ShellPage::acceptNavigationRequest(const QUrl &url, NavigationType, bool isMainFrame)
{
    if (url.scheme() == QLatin1String("powos") || url.scheme() == QLatin1String("about") || !isMainFrame)
        return true;
    QDesktopServices::openUrl(url);
    return false;
}

void ShellPage::javaScriptConsoleMessage(JavaScriptConsoleMessageLevel level, const QString &message, int line, const QString &source)
{
    // index.html's boot guard writes "powos-shell-error {...}" here when there's no native PowosBoot: the journal has it.
    static const char *levels[] = {"info", "warn", "error"};
    qInfo().noquote() << QStringLiteral("[page %1] %2 (%3:%4)").arg(QLatin1String(levels[level]), message, source).arg(line);
}

Panel::Panel(QScreen *screen, QWebEngineProfile *profile, const Services &services)
    : m_screen(screen)
    , m_bridge(new Bridge(services, [this](int px) { setSurfaceHeight(px); }, this))
    , m_channel(new QWebChannel(this))
{
    auto *page = new ShellPage(profile, this);
    setPage(page);
    m_channel->registerObject(QStringLiteral("host"), m_bridge);
    page->setWebChannel(m_channel);
    // The page draws the bar; anything it leaves clear (the launcher's room above it) shows what's under it.
    page->setBackgroundColor(Qt::transparent);
    setAttribute(Qt::WA_TranslucentBackground);
    setContextMenuPolicy(Qt::NoContextMenu);

    // A renderer that died (OOM, GPU fault) is a reload, not a dead panel: the services keep their state.
    connect(page, &QWebEnginePage::renderProcessTerminated, this, [this](QWebEnginePage::RenderProcessTerminationStatus status, int code) {
        qWarning() << "powos-shell: panel renderer ended" << status << code << "- reloading";
        QTimer::singleShot(1000, this, [this] { reload(); });
    });

    // The layer surface: set up before the window is first shown (LayerShellQt takes the role then).
    winId();
    windowHandle()->setScreen(screen); // LayerShellQt puts the surface on its window's screen
    applyLayer();
    resize(screen->geometry().width(), Height);

    QUrl url(QStringLiteral("powos://shell/index.html"));
    url.setQuery(QUrlQuery{{QStringLiteral("mode"), QStringLiteral("panel")}, {QStringLiteral("screen"), screen->name()}});
    load(url);

    // The screen's size changes the bar's width (anchored left|right: KWin stretches it; the widget follows).
    connect(screen, &QScreen::geometryChanged, this, [this](const QRect &g) { resize(g.width(), height()); });
}

void Panel::applyLayer()
{
    QWindow *window = windowHandle();
    if (!window)
        return;
    auto *layer = LayerShellQt::Window::get(window);
    layer->setLayer(LayerShellQt::Window::LayerTop);
    layer->setAnchors(LayerShellQt::Window::Anchors(LayerShellQt::Window::AnchorBottom | LayerShellQt::Window::AnchorLeft
                                                    | LayerShellQt::Window::AnchorRight));
    layer->setExclusiveZone(Height);
    // Open (taller than the bar): it takes the keyboard when clicked, for the launcher's search. The bar alone never.
    layer->setKeyboardInteractivity(m_open ? LayerShellQt::Window::KeyboardInteractivityOnDemand
                                           : LayerShellQt::Window::KeyboardInteractivityNone);
    layer->setScope(QStringLiteral("powos-panel"));
}

bool Panel::event(QEvent *e)
{
    // A new native window (the re-create at first show): the role again, on the window that's there now.
    if (e->type() == QEvent::WinIdChange)
        applyLayer();
    return QWebEngineView::event(e);
}

void Panel::setSurfaceHeight(int px)
{
    const int h = px <= Height ? Height : qMin(px, m_screen->geometry().height() - 32);
    m_open = h > Height;
    applyLayer();
    resize(m_screen->geometry().width(), h);
}
