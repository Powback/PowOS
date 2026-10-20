// The KDE models the bridge puts a web UI on (docs/DESKTOP-WEB-SHELL.md §2): one of each per process, shared by
// every page's Bridge.
#pragma once

#include <QHash>
#include <QIcon>
#include <QJsonArray>
#include <QModelIndex>
#include <QObject>
#include <QTimer>

namespace TaskManager {
class TasksModel;
}

/** apps.*: the installed applications (KSycoca), launched the way Plasma launches them. */
class Apps : public QObject {
    Q_OBJECT
public:
    explicit Apps(QObject *parent = nullptr);
    /** App[] (types.ts): key "l:<desktop id>", label, icon (powos://icon/<name>), kind "linux". */
    QJsonArray list() const;
    /** KIO::ApplicationLauncherJob: systemd app scope, xdg-activation token, startup feedback. False: no such app. */
    bool launch(const QString &key);
Q_SIGNALS:
    void changed();
};

/** windows.*: the window list over TaskManager::TasksModel (org_kde_plasma_window_management on KWin). */
class Windows : public QObject {
    Q_OBJECT
public:
    explicit Windows(QObject *parent = nullptr);
    /** DesktopWindow[] (types.ts), in the model's order. */
    QJsonArray list() const;
    bool activate(const QString &id);
    /** Toggles: a minimized window comes back. */
    bool minimize(const QString &id);
    /** A window's icon when its theme has no name for it (served on powos://icon/_task/<id>). */
    QIcon icon(const QString &id) const;
Q_SIGNALS:
    /** The list again, at most every 50 ms however busy the model is. */
    void changed(const QJsonArray &list);

private:
    QModelIndex find(const QString &id) const;
    static QString idOf(const QModelIndex &index);
    TaskManager::TasksModel *m_model;
    QTimer m_coalesce;
    mutable QHash<QString, QIcon> m_icons;
};

/** Every service, handed to each page's Bridge. */
struct Services {
    Apps *apps;
    Windows *windows;
};

/** powos://icon/<name>: a theme icon by name (QIcon::fromTheme), percent-encoded. */
QString iconUrl(const QString &name);
