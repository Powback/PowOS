#include "server.h"
#include "services.h"

#include <QBuffer>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QIcon>
#include <QMimeDatabase>
#include <QProcess>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUrlQuery>
#include <QWebEngineUrlRequestJob>

QStringList shellRoots()
{
    const QString override = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + QStringLiteral("/powos/shell");
    const QString base = qEnvironmentVariableIsSet("POWOS_SHELL_DIR") ? qEnvironmentVariable("POWOS_SHELL_DIR")
                                                                     : QStringLiteral("/usr/share/powos/shell");
    return {override, base};
}

ShellServer::ShellServer(Windows *windows, QObject *parent)
    : QWebEngineUrlSchemeHandler(parent)
    , m_windows(windows)
{
}

static QByteArray mimeOf(const QString &path)
{
    // es-module-shims wants JavaScript for modules; .ts/.tsx are compiled in the page (index.html's fetch hook).
    const QString suffix = QFileInfo(path).suffix().toLower();
    if (suffix == QLatin1String("js") || suffix == QLatin1String("mjs") || suffix == QLatin1String("ts") || suffix == QLatin1String("tsx"))
        return "text/javascript";
    if (suffix == QLatin1String("css"))
        return "text/css";
    if (suffix == QLatin1String("html"))
        return "text/html";
    if (suffix == QLatin1String("json"))
        return "application/json";
    if (suffix == QLatin1String("svg"))
        return "image/svg+xml";
    return QMimeDatabase().mimeTypeForFile(path, QMimeDatabase::MatchExtension).name().toLatin1();
}

void ShellServer::requestStarted(QWebEngineUrlRequestJob *job)
{
    const QUrl url = job->requestUrl();
    if (url.host() == QLatin1String("icon"))
        return icon(job);
    if (url.host() != QLatin1String("shell"))
        return job->fail(QWebEngineUrlRequestJob::UrlNotFound);
    QString rel = QDir::cleanPath(url.path());
    if (rel.startsWith(QLatin1Char('/')))
        rel.remove(0, 1);
    if (rel.isEmpty())
        rel = QStringLiteral("index.html");
    if (rel.startsWith(QLatin1String("..")))
        return job->fail(QWebEngineUrlRequestJob::RequestDenied);
    if (rel.startsWith(QLatin1String("_app/")))
        return appFile(job, rel.mid(5));
    if (rel == QLatin1String("_font/symbols"))
        return symbols(job);
    for (const QString &root : shellRoots()) {
        QFile file(root + QLatin1Char('/') + rel);
        if (!file.open(QIODevice::ReadOnly))
            continue;
        auto *buffer = new QBuffer(job);
        buffer->setData(file.readAll());
        job->reply(mimeOf(rel), buffer);
        return;
    }
    job->fail(QWebEngineUrlRequestJob::UrlNotFound);
}

void ShellServer::appFile(QWebEngineUrlRequestJob *job, const QString &rest)
{
    // "<app id>/<path>": a file of an installed PowOS app's UI (powos app install: ~/.local/share/powos/apps/<id>/
    // current/ui), never outside it - as the phone's ShellHost.appFile.
    static const QRegularExpression appId(QStringLiteral("^[a-z0-9][a-z0-9._-]*$"));
    const QString id = rest.section(QLatin1Char('/'), 0, 0);
    const QString name = rest.section(QLatin1Char('/'), 1);
    if (!appId.match(id).hasMatch() || name.isEmpty())
        return job->fail(QWebEngineUrlRequestJob::UrlNotFound);
    const QString apps = qEnvironmentVariable("POWOS_APPS_DIR", QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/powos/apps"));
    const QString ui = QDir(apps + QLatin1Char('/') + id + QStringLiteral("/current/ui")).canonicalPath();
    const QString path = QFileInfo(ui + QLatin1Char('/') + name).canonicalFilePath();
    QFile file(path);
    if (ui.isEmpty() || !path.startsWith(ui + QLatin1Char('/')) || !file.open(QIODevice::ReadOnly))
        return job->fail(QWebEngineUrlRequestJob::UrlNotFound);
    auto *buffer = new QBuffer(job);
    buffer->setData(file.readAll());
    job->reply(mimeOf(name), buffer);
}

void ShellServer::symbols(QWebEngineUrlRequestJob *job)
{
    // The terminals' icon glyphs (ui/terminal.tsx loads "/_font/symbols": Nerd Font's symbols, the phone's
    // res/font/nerd_symbols.ttf): the system's, found once through fontconfig.
    static const QString path = [] {
        QProcess fc;
        fc.start(QStringLiteral("fc-match"), {QStringLiteral("-f"), QStringLiteral("%{file}"), QStringLiteral("Symbols Nerd Font")});
        fc.waitForFinished(3000);
        const QString file = QString::fromLocal8Bit(fc.readAllStandardOutput()).trimmed();
        return file.contains(QLatin1String("Nerd"), Qt::CaseInsensitive) ? file : QString();
    }();
    QFile file(path);
    if (path.isEmpty() || !file.open(QIODevice::ReadOnly))
        return job->fail(QWebEngineUrlRequestJob::UrlNotFound);
    auto *buffer = new QBuffer(job);
    buffer->setData(file.readAll());
    job->reply("font/ttf", buffer);
}

void ShellServer::icon(QWebEngineUrlRequestJob *job)
{
    const QUrl url = job->requestUrl();
    const QString path = url.path(QUrl::FullyDecoded).mid(1);
    const int size = qBound(16, QUrlQuery(url).queryItemValue(QStringLiteral("s")).toInt() ?: 64, 512);
    QIcon icon;
    if (path.startsWith(QLatin1String("_task/")))
        icon = m_windows->icon(path.mid(6));
    else if (QDir::isAbsolutePath(path))
        icon = QIcon(path);
    else
        icon = QIcon::fromTheme(path);
    if (icon.isNull())
        icon = QIcon::fromTheme(QStringLiteral("application-x-executable"));
    auto *buffer = new QBuffer(job);
    buffer->open(QIODevice::WriteOnly);
    icon.pixmap(size, size).save(buffer, "PNG");
    buffer->close();
    job->reply("image/png", buffer);
}

// ---- watcher ----

Watcher::Watcher(const QStringList &roots, QObject *parent)
    : QObject(parent)
{
    for (const QString &root : roots) {
        QDir().mkpath(root);
        m_roots << QDir(root).canonicalPath();
    }
    for (const QString &root : std::as_const(m_roots))
        scan(root, false);
    connect(&m_fs, &QFileSystemWatcher::directoryChanged, this, [this](const QString &dir) { scan(dir, true); });
    connect(&m_fs, &QFileSystemWatcher::fileChanged, this, &Watcher::touched);
}

QString Watcher::relative(const QString &path) const
{
    for (const QString &root : m_roots)
        if (path.startsWith(root + QLatin1Char('/')))
            return path.mid(root.size() + 1);
    return path;
}

void Watcher::scan(const QString &dir, bool report)
{
    // Watches the folder and each file in it (an in-place write is a file event, a save-by-rename a folder event);
    // new folders are walked as they appear.
    if (!QFileInfo::exists(dir))
        return;
    m_fs.addPath(dir);
    const auto entries = QDir(dir).entryInfoList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot | QDir::Hidden);
    for (const QFileInfo &entry : entries) {
        const QString path = entry.absoluteFilePath();
        if (entry.isDir()) {
            if (entry.fileName() == QLatin1String("node_modules") || entry.fileName() == QLatin1String(".git"))
                continue;
            if (!m_fs.directories().contains(path))
                scan(path, report);
            continue;
        }
        const QDateTime mtime = entry.lastModified();
        const auto known = m_mtimes.constFind(path);
        const bool fresh = known == m_mtimes.constEnd() || *known != mtime;
        m_mtimes.insert(path, mtime);
        if (!m_fs.files().contains(path))
            m_fs.addPath(path);
        if (report && fresh)
            Q_EMIT changed(relative(path));
    }
}

void Watcher::touched(const QString &file)
{
    if (!QFileInfo::exists(file))
        return; // removed or renamed over: its folder's event rescans it
    m_mtimes.insert(file, QFileInfo(file).lastModified());
    if (!m_fs.files().contains(file))
        m_fs.addPath(file);
    Q_EMIT changed(relative(file));
}
