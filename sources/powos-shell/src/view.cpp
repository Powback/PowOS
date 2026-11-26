#include "view.h"
#include "bridge.h"

#include <QDesktopServices>
#include <QScreen>
#include <QTimer>
#include <QUrlQuery>
#include <QWebChannel>
#include <QWebEngineProfile>
#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
#include <QWebEnginePermission>
#endif
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

    // HDMI in (shell/ui/hdmiin.tsx, docs/HDMI-IN.md): the page's own getUserMedia on a capture dongle (a V4L2 camera +
    // ALSA input). Only the shell's powos: origin, only camera / mic; every other ask is left unanswered, as before.
#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
    connect(page, &QWebEnginePage::permissionRequested, this, [](QWebEnginePermission p) {
        using T = QWebEnginePermission::PermissionType;
        const auto t = p.permissionType();
        if (t != T::MediaAudioCapture && t != T::MediaVideoCapture && t != T::MediaAudioVideoCapture)
            return;
        if (p.origin().scheme() == QLatin1String("powos"))
            p.grant();
        else
            p.deny();
    });
#else
    connect(page, &QWebEnginePage::featurePermissionRequested, this, [page](const QUrl &origin, QWebEnginePage::Feature f) {
        if (f != QWebEnginePage::MediaAudioCapture && f != QWebEnginePage::MediaVideoCapture && f != QWebEnginePage::MediaAudioVideoCapture)
            return;
        page->setFeaturePermission(origin, f, origin.scheme() == QLatin1String("powos") ? QWebEnginePage::PermissionGrantedByUser
                                                                                         : QWebEnginePage::PermissionDeniedByUser);
    });
#endif

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
