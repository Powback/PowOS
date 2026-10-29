// The KDE models the bridge puts a web UI on (docs/DESKTOP-WEB-SHELL.md §2): one of each per process, shared by
// every page's Bridge.
#pragma once

#include <QFileSystemWatcher>
#include <QHash>
#include <QSet>
#include <QIcon>
#include <QJsonArray>
#include <QModelIndex>
#include <QJsonObject>
#include <QObject>
#include <QProcess>
#include <QTimer>

class Desktops;

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
    /** Asks the window to close (the app may ask to save first). */
    bool close(const QString &id);
    /** A window's icon when its theme has no name for it (served on powos://icon/_task/<id>). */
    QIcon icon(const QString &id) const;
    /** KWin virtual desktop ids that hold a window (on-all-desktops windows hold none): desktops.ensure keeps these. */
    QSet<QString> desktopsInUse() const;
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

/**
 * store.*: the shell's own data files (layout, dock, settings), one JSON file per name in
 * ~/.local/share/powos/shell-data/<name>.json - the phone's files/shell-data, same names and contents.
 */
class Store : public QObject {
    Q_OBJECT
public:
    explicit Store(QObject *parent = nullptr);
    QJsonValue get(const QString &name) const;
    void set(const QString &name, const QJsonValue &value);
    /** A name that is a plain file name, nothing else (no "/", no ".."). */
    static bool valid(const QString &name);

private:
    QString m_dir;
};

/**
 * theme.*: PowOS's theme on Linux, Omarchy's current one: ~/.local/state/omarchy/current/theme/colors.toml, mapped
 * to the page's tokens as the phone's ThemePalette does. Watched: a picked theme recolors the page ("theme.changed").
 */
class Theme : public QObject {
    Q_OBJECT
public:
    explicit Theme(QObject *parent = nullptr);
    /** ThemeColors (types.ts), or null when there is no theme (the page keeps theme.css's defaults). */
    QJsonValue get() const;
Q_SIGNALS:
    void changed(const QJsonValue &theme);

private:
    void watch();
    QString m_file;
    QFileSystemWatcher m_watcher;
};

/**
 * ai.*: PowOS AI's chat - the manager's one conversation (docs/DESIGN-LANGUAGE.md 7): each ask is one turn of
 * `powos manager --once-stdin --json-events` in ~, streamed into the chat's items as the phone's PowosAiChat does.
 * The items are kept in the store (desktop-chat) across restarts.
 */
class Ai : public QObject {
    Q_OBJECT
public:
    Ai(Store *store, QObject *parent = nullptr);
    /** Chat (types.ts): busy, items. */
    QJsonObject chat() const;
    /** False: a turn is under way (as the phone's: what's sent meanwhile is dropped; the page queues it). */
    bool send(const QString &text);
Q_SIGNALS:
    void changed(const QJsonObject &chat);

private:
    void add(const QJsonObject &item);
    void finishTool(bool ok, const QString &out);
    void line(const QByteArray &line);
    void done(int exit);
    Store *m_store;
    QJsonArray m_items;
    QProcess *m_turn = nullptr;
    QByteArray m_buffer;
    QString m_lastError;
    bool m_answered = false;
};

/** Every service, handed to each page's Bridge. */
struct Services {
    Apps *apps;
    Windows *windows;
    Store *store;
    Theme *theme;
    Ai *ai;
    /** desktops.*: KWin's virtual desktops, one per home page (desktops.h). */
    Desktops *desktops;
};

/** powos://icon/<name>: a theme icon by name (QIcon::fromTheme), percent-encoded. */
QString iconUrl(const QString &name);
