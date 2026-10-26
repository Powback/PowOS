#include "view.h"
#include "bridge.h"

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
    // index.html's boot guard writes "powos-shell-error {...}" here when there's no native PowosBoot: the log has it.
    static const char *levels[] = {"info", "warn", "error"};
    qInfo().noquote() << QStringLiteral("[page %1] %2 (%3:%4)").arg(QLatin1String(levels[level]), message, source).arg(line);
}

ShellView::ShellView(QScreen *screen, QWebEngineProfile *profile, const Services &services, const QString &mode)
    : m_screen(screen)
    , m_bridge(new Bridge(services, this))
    , m_channel(new QWebChannel(this))
    , m_mode(mode)
{
    auto *page = new ShellPage(profile, this);
    setPage(page);
    m_channel->registerObject(QStringLiteral("host"), m_bridge);
    page->setWebChannel(m_channel);
    // The page draws its surfaces; anything it leaves clear shows what's under it (the wallpaper, under home).
    page->setBackgroundColor(Qt::transparent);
    setAttribute(Qt::WA_TranslucentBackground);
    setContextMenuPolicy(Qt::NoContextMenu);

    // A renderer that died (OOM, GPU fault) is a reload, not a dead surface: the services keep their state.
    connect(page, &QWebEnginePage::renderProcessTerminated, this, [this](QWebEnginePage::RenderProcessTerminationStatus status, int code) {
        qWarning() << "powos-shell:" << m_mode << "renderer ended" << status << code << "- reloading";
        QTimer::singleShot(1000, this, [this] { reload(); });
    });
}

void ShellView::start()
{
    // The layer surface: set up before the window is first shown (LayerShellQt takes the role then).
    winId();
    windowHandle()->setScreen(m_screen); // LayerShellQt puts the surface on its window's screen
    applyLayer();
    QUrl url(QStringLiteral("powos://shell/index.html"));
    url.setQuery(QUrlQuery{{QStringLiteral("mode"), m_mode}, {QStringLiteral("screen"), m_screen->name()}});
    load(url);
}

bool ShellView::event(QEvent *e)
{
    // A new native window (the re-create at first show): the role again, on the window that's there now.
    if (e->type() == QEvent::WinIdChange)
        applyLayer();
    return QWebEngineView::event(e);
}
