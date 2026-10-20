#include "services.h"

#include <KApplicationTrader>
#include <KIO/ApplicationLauncherJob>
#include <KService>
#include <KSycoca>
#include <QCollator>
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
