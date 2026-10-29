// desktops.*: KWin's virtual desktops as home's pages (docs/DESKTOP-KWIN-NATIVE.md): a window belongs to the desktop
// it opened on, and switching home's page switches KWin's current desktop - KWin hides, shows and slides the windows
// itself. Over KWin's D-Bus org.kde.KWin /VirtualDesktopManager (org.kde.KWin.VirtualDesktopManager).
#pragma once

#include <QJsonArray>
#include <QList>
#include <QObject>
#include <QString>

class Windows;

class Desktops : public QObject {
    Q_OBJECT
public:
    /** [windows]: which desktops hold a window (ensure never removes those). */
    Desktops(Windows *windows, QObject *parent = nullptr);
    /** [{id, name, index, current}] in KWin's order: index = the home page's index. */
    QJsonArray list() const;
    /** KWin's current desktop becomes [index]; false: there is no such desktop. */
    bool setCurrent(int index);
    /** Creates or removes desktops at the end until KWin has [count]; one holding a window stays. The list after. */
    QJsonArray ensure(int count);

Q_SIGNALS:
    /** KWin's current desktop changed (by anyone): its index. */
    void currentChanged(int index);

private Q_SLOTS:
    void kwinCurrentChanged(const QString &id);

private:
    struct Desktop {
        uint position = 0;
        QString id;
        QString name;
    };
    /** KWin's desktops by position (one blocking property read: KWin answers at once). */
    QList<Desktop> fetch() const;
    QString current() const;
    Windows *m_windows;
};
