#include "services.h"

#include <KApplicationTrader>
#include <KIO/ApplicationLauncherJob>
#include <KService>
#include <KSycoca>
#include <QCollator>
#include <QColor>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>
#include <QJsonObject>
#include <QUrl>
#include <algorithm>

#include <taskmanager/abstracttasksmodel.h>
#include <taskmanager/tasksmodel.h>

using TaskManager::AbstractTasksModel;

QString iconUrl(const QString &name)
{
    return QStringLiteral("powos://icon/") + QString::fromLatin1(QUrl::toPercentEncoding(name));
}

// ---- apps ----

Apps::Apps(QObject *parent)
    : QObject(parent)
{
    connect(KSycoca::self(), &KSycoca::databaseChanged, this, &Apps::changed);
}

QJsonArray Apps::list() const
{
    KService::List services = KApplicationTrader::query([](const KService::Ptr &s) {
        return !s->noDisplay() && s->showInCurrentDesktop();
    });
    QCollator collator;
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    std::sort(services.begin(), services.end(), [&](const KService::Ptr &a, const KService::Ptr &b) {
        return collator.compare(a->name(), b->name()) < 0;
    });
    QJsonArray out;
    for (const auto &s : services) {
        out.append(QJsonObject{
            {QStringLiteral("key"), QStringLiteral("l:") + s->desktopEntryName()},
            {QStringLiteral("label"), s->name()},
            {QStringLiteral("icon"), iconUrl(s->icon().isEmpty() ? QStringLiteral("application-x-executable") : s->icon())},
            {QStringLiteral("kind"), QStringLiteral("linux")},
        });
    }
    return out;
}

bool Apps::launch(const QString &key)
{
    if (!key.startsWith(QLatin1String("l:")))
        return false;
    const KService::Ptr service = KService::serviceByDesktopName(key.mid(2));
    if (!service)
        return false;
    auto *job = new KIO::ApplicationLauncherJob(service);
    connect(job, &KJob::result, this, [key](KJob *job) {
        if (job->error())
            qWarning().noquote() << "powos-shell: launching" << key << "failed:" << job->errorString();
    });
    job->start();
    return true;
}

// ---- windows ----

Windows::Windows(QObject *parent)
    : QObject(parent)
    , m_model(new TaskManager::TasksModel(this))
{
    // One row per window (no grouping), every screen and desktop: phase 0's taskbar is the plain list.
    m_model->setGroupMode(TaskManager::TasksModel::GroupDisabled);
    m_model->setSortMode(TaskManager::TasksModel::SortManual);
    m_model->setFilterByScreen(false);
    m_model->setFilterByVirtualDesktop(false);
    m_model->setFilterByActivity(false);

    m_coalesce.setSingleShot(true);
    m_coalesce.setInterval(50);
    connect(&m_coalesce, &QTimer::timeout, this, [this] { Q_EMIT changed(list()); });
    auto later = [this] { m_coalesce.start(); };
    connect(m_model, &QAbstractItemModel::dataChanged, this, later);
    connect(m_model, &QAbstractItemModel::rowsInserted, this, later);
    connect(m_model, &QAbstractItemModel::rowsRemoved, this, later);
    connect(m_model, &QAbstractItemModel::rowsMoved, this, later);
    connect(m_model, &QAbstractItemModel::modelReset, this, later);
    connect(m_model, &QAbstractItemModel::layoutChanged, this, later);
}

QString Windows::idOf(const QModelIndex &index)
{
    // Wayland: the plasma window's uuid (a string); X11: the window id. The first of the row's (one, ungrouped).
    const QVariantList ids = index.data(AbstractTasksModel::WinIdList).toList();
    return ids.isEmpty() ? QString() : ids.first().toString();
}

QModelIndex Windows::find(const QString &id) const
{
    for (int row = 0; row < m_model->rowCount(); ++row) {
        const QModelIndex index = m_model->index(row, 0);
        if (idOf(index) == id)
            return index;
    }
    return {};
}

QJsonArray Windows::list() const
{
    QJsonArray out;
    m_icons.clear();
    for (int row = 0; row < m_model->rowCount(); ++row) {
        const QModelIndex index = m_model->index(row, 0);
        if (!index.data(AbstractTasksModel::IsWindow).toBool() || index.data(AbstractTasksModel::IsStartup).toBool())
            continue;
        const QString id = idOf(index);
        if (id.isEmpty())
            continue;
        const QIcon icon = index.data(Qt::DecorationRole).value<QIcon>();
        m_icons.insert(id, icon);
        // A theme name when the icon has one (cacheable, any size); else the window's own pixmap, by id.
        const QString url = !icon.name().isEmpty()
            ? iconUrl(icon.name())
            : QStringLiteral("powos://icon/_task/") + QString::fromLatin1(QUrl::toPercentEncoding(id));
        out.append(QJsonObject{
            {QStringLiteral("id"), id},
            {QStringLiteral("title"), index.data(Qt::DisplayRole).toString()},
            {QStringLiteral("app"), index.data(AbstractTasksModel::AppId).toString()},
            {QStringLiteral("appName"), index.data(AbstractTasksModel::AppName).toString()},
            {QStringLiteral("icon"), url},
            {QStringLiteral("active"), index.data(AbstractTasksModel::IsActive).toBool()},
            {QStringLiteral("minimized"), index.data(AbstractTasksModel::IsMinimized).toBool()},
        });
    }
    return out;
}

bool Windows::activate(const QString &id)
{
    const QModelIndex index = find(id);
    if (!index.isValid())
        return false;
    m_model->requestActivate(index);
    return true;
}

bool Windows::minimize(const QString &id)
{
    const QModelIndex index = find(id);
    if (!index.isValid())
        return false;
    m_model->requestToggleMinimized(index);
    return true;
}

QIcon Windows::icon(const QString &id) const
{
    return m_icons.value(id);
}

// ---- store ----

Store::Store(QObject *parent)
    : QObject(parent)
    , m_dir(QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/powos/shell-data"))
{
    QDir().mkpath(m_dir);
}

bool Store::valid(const QString &name)
{
    static const QRegularExpression plain(QStringLiteral("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"));
    return plain.match(name).hasMatch() && !name.contains(QLatin1String(".."));
}

QJsonValue Store::get(const QString &name) const
{
    QFile file(m_dir + QLatin1Char('/') + name + QStringLiteral(".json"));
    if (!valid(name) || !file.open(QIODevice::ReadOnly))
        return QJsonValue::Null;
    // Any JSON value (a bare string too, as the phone stores it): through a one-element array.
    const QJsonDocument doc = QJsonDocument::fromJson("[" + file.readAll() + "]");
    return doc.isArray() ? doc.array().at(0) : QJsonValue::Null;
}

void Store::set(const QString &name, const QJsonValue &value)
{
    if (!valid(name))
        return;
    const QByteArray wrapped = QJsonDocument(QJsonArray{value}).toJson(QJsonDocument::Compact);
    QSaveFile file(m_dir + QLatin1Char('/') + name + QStringLiteral(".json"));
    if (file.open(QIODevice::WriteOnly)) {
        file.write(wrapped.mid(1, wrapped.size() - 2));
        file.commit();
    }
}

// ---- theme ----

Theme::Theme(QObject *parent)
    : QObject(parent)
    , m_file(QStandardPaths::writableLocation(QStandardPaths::GenericStateLocation) + QStringLiteral("/omarchy/current/theme/colors.toml"))
{
    // omarchy-theme-set swaps the current/theme link: the file, and the folders above it as they come and go.
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, [this] { watch(); Q_EMIT changed(get()); });
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] { watch(); Q_EMIT changed(get()); });
    watch();
}

void Theme::watch()
{
    for (QString dir = QFileInfo(m_file).absolutePath(); dir.size() > 1; dir = QFileInfo(dir).absolutePath()) {
        if (QFileInfo::exists(dir)) {
            m_watcher.addPath(dir);
            break;
        }
    }
    if (QFileInfo::exists(m_file))
        m_watcher.addPath(m_file);
}

QJsonValue Theme::get() const
{
    QFile file(m_file);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return QJsonValue::Null;
    // colors.toml: key = "value" lines (Omarchy's format; nothing nested).
    static const QRegularExpression entry(QStringLiteral(R"(^\s*([A-Za-z0-9_]+)\s*=\s*"([^"]*)\")"));
    QJsonObject colors;
    QString mode;
    for (const QString &l : QString::fromUtf8(file.readAll()).split(QLatin1Char('\n'))) {
        const auto m = entry.match(l);
        if (!m.hasMatch())
            continue;
        if (m.captured(1) == QLatin1String("mode"))
            mode = m.captured(2);
        else if (QColor::isValidColorName(m.captured(2)))
            colors.insert(m.captured(1), QColor(m.captured(2)).name());
    }
    // As the phone's ThemePalette (ui/Theme.kt): which of the theme's colors each token is, and its defaults.
    const auto c = [&](const char *key, const char *fallback) { return colors.value(QLatin1String(key)).toString(QLatin1String(fallback)); };
    const QColor background(c("background", "#1a1b26"));
    const QJsonObject css{
        {QStringLiteral("background"), background.name()},
        {QStringLiteral("surface"), c("lighter_background", "#24283b")},
        {QStringLiteral("overlay"), QStringLiteral("rgba(%1, %2, %3, 0.9)").arg(background.red()).arg(background.green()).arg(background.blue())},
        {QStringLiteral("foreground"), c("foreground", "#c0caf5")},
        {QStringLiteral("muted"), c("dark_foreground", "#565f89")},
        {QStringLiteral("accent"), c("accent", "#7aa2f7")},
        {QStringLiteral("border"), c("muted", "#414868")},
        {QStringLiteral("red"), c("red", "#f7768e")},
        {QStringLiteral("green"), c("green", "#9ece6a")},
    };
    QFile name(QFileInfo(m_file).absolutePath() + QStringLiteral("/../theme.name"));
    const QString picked = name.open(QIODevice::ReadOnly) ? QString::fromUtf8(name.readAll()).trimmed() : QString();
    return QJsonObject{{QStringLiteral("name"), picked}, {QStringLiteral("light"), mode == QLatin1String("light")},
                       {QStringLiteral("css"), css}, {QStringLiteral("colors"), colors}};
}

// ---- ai ----

Ai::Ai(Store *store, QObject *parent)
    : QObject(parent)
    , m_store(store)
    , m_items(store->get(QStringLiteral("desktop-chat")).toArray())
{
}

QJsonObject Ai::chat() const
{
    return QJsonObject{{QStringLiteral("busy"), m_turn != nullptr}, {QStringLiteral("items"), m_items},
                       {QStringLiteral("thread"), QJsonValue::Null}};
}

void Ai::add(const QJsonObject &item)
{
    m_items.append(item);
    // The chat's history, as long as the phone keeps one (older items go).
    while (m_items.size() > 200)
        m_items.removeFirst();
    Q_EMIT changed(chat());
}

void Ai::finishTool(bool ok, const QString &out)
{
    for (qsizetype i = m_items.size() - 1; i >= 0; --i) {
        QJsonObject item = m_items.at(i).toObject();
        if (item.value(QStringLiteral("kind")).toString() != QLatin1String("tool") || !item.value(QStringLiteral("ok")).isNull())
            continue;
        item.insert(QStringLiteral("ok"), ok);
        if (!out.isEmpty())
            item.insert(QStringLiteral("out"), out.left(2000));
        m_items.replace(i, item);
        Q_EMIT changed(chat());
        return;
    }
}

bool Ai::send(const QString &text)
{
    const QString shown = text.trimmed();
    if (shown.isEmpty() || m_turn)
        return false;
    add(QJsonObject{{QStringLiteral("kind"), QStringLiteral("user")}, {QStringLiteral("text"), shown}});
    m_turn = new QProcess(this);
    m_buffer.clear();
    m_lastError.clear();
    m_answered = false;
    m_turn->setWorkingDirectory(QDir::homePath());
    connect(m_turn, &QProcess::readyReadStandardOutput, this, [this] {
        m_buffer += m_turn->readAllStandardOutput();
        for (qsizetype nl; (nl = m_buffer.indexOf('\n')) >= 0;) {
            const QByteArray l = m_buffer.left(nl);
            m_buffer.remove(0, nl + 1);
            line(l);
        }
    });
    connect(m_turn, &QProcess::readyReadStandardError, this, [this] {
        for (const QByteArray &l : m_turn->readAllStandardError().split('\n'))
            if (!l.trimmed().isEmpty())
                m_lastError = QString::fromUtf8(l.trimmed());
    });
    connect(m_turn, &QProcess::finished, this, [this](int exit, QProcess::ExitStatus status) { done(status == QProcess::NormalExit ? exit : -1); });
    connect(m_turn, &QProcess::errorOccurred, this, [this](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart)
            done(-1);
    });
    m_turn->start(QStringLiteral("powos"), {QStringLiteral("manager"), QStringLiteral("--once-stdin"), QStringLiteral("--json-events")});
    if (!m_turn)
        return true; // it didn't start (no powos): done() said so in the chat
    m_turn->write(text.toUtf8());
    m_turn->closeWriteChannel();
    Q_EMIT changed(chat());
    return true;
}

void Ai::line(const QByteArray &l)
{
    const QJsonObject ev = QJsonDocument::fromJson(l).object();
    const QString kind = ev.value(QStringLiteral("kind")).toString();
    if (kind == QLatin1String("assistant")) {
        m_answered = true;
        add(QJsonObject{{QStringLiteral("kind"), kind}, {QStringLiteral("text"), ev.value(QStringLiteral("text")).toString()}});
    } else if (kind == QLatin1String("tool_use")) {
        add(QJsonObject{{QStringLiteral("kind"), QStringLiteral("tool")}, {QStringLiteral("name"), ev.value(QStringLiteral("name")).toString()},
                        {QStringLiteral("hint"), ev.value(QStringLiteral("hint")).toString()}, {QStringLiteral("ok"), QJsonValue::Null}});
    } else if (kind == QLatin1String("tool_result")) {
        finishTool(ev.value(QStringLiteral("ok")).toBool(true), ev.value(QStringLiteral("out")).toString());
    } else if (kind == QLatin1String("inbox")) {
        add(QJsonObject{{QStringLiteral("kind"), QStringLiteral("note")}, {QStringLiteral("text"), ev.value(QStringLiteral("text")).toString()},
                        {QStringLiteral("error"), false}});
    }
}

void Ai::done(int exit)
{
    if (!m_turn)
        return;
    m_turn->deleteLater();
    m_turn = nullptr;
    if (exit != 0 || !m_answered)
        add(QJsonObject{{QStringLiteral("kind"), QStringLiteral("note")},
                        {QStringLiteral("text"), QStringLiteral("PowOS AI didn't answer") + (m_lastError.isEmpty() ? QStringLiteral(" (exit %1)").arg(exit) : QStringLiteral(": ") + m_lastError)},
                        {QStringLiteral("error"), true}});
    m_store->set(QStringLiteral("desktop-chat"), m_items);
    Q_EMIT changed(chat());
}
