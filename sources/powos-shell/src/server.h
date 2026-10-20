// powos:// (docs/DESKTOP-WEB-SHELL.md §3.6): the shell's files and the icons it shows, and the watcher that tells
// the pages a file was saved (hot reload, "files.changed").
#pragma once

#include <QDateTime>
#include <QFileSystemWatcher>
#include <QHash>
#include <QStringList>
#include <QWebEngineUrlSchemeHandler>

class Windows;

/** Where shell/ is read from, first hit wins: the override folder, then the base. */
QStringList shellRoots();

/**
 * powos://shell/<path>: ~/.config/powos/shell/<path> if it's there, else the base ($POWOS_SHELL_DIR, or
 * /usr/share/powos/shell). powos://icon/<name>?s=<px>: a theme icon as PNG; powos://icon/_task/<id>: a window's.
 */
class ShellServer : public QWebEngineUrlSchemeHandler {
    Q_OBJECT
public:
    ShellServer(Windows *windows, QObject *parent = nullptr);
    void requestStarted(QWebEngineUrlRequestJob *job) override;

private:
    void icon(QWebEngineUrlRequestJob *job);
    Windows *m_windows;
};

/** Every file under the watched roots (node_modules aside): "changed" with its path relative to its root. */
class Watcher : public QObject {
    Q_OBJECT
public:
    Watcher(const QStringList &roots, QObject *parent = nullptr);
Q_SIGNALS:
    void changed(const QString &path);

private:
    void scan(const QString &dir, bool report);
    void touched(const QString &file);
    QString relative(const QString &path) const;
    QStringList m_roots;
    QFileSystemWatcher m_fs;
    QHash<QString, QDateTime> m_mtimes;
};
