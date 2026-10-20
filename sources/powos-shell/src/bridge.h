// The page's one native entry, the same contract as the phone's ShellBridge.kt (docs/DESKTOP-WEB-SHELL.md §3.2):
// PowosHost.call(id, method, argsJson) answered through window.__powosHost.resolve / reject, events through
// window.__powosHost.emit. Over QWebChannel here: bridgeScript() makes window.PowosHost of the channel's object.
#pragma once

#include <QJsonArray>
#include <QJsonValue>
#include <QObject>
#include <functional>

struct Services;

class Bridge : public QObject {
    Q_OBJECT
public:
    /** [resize]: the page asks for its surface to be this tall (panel.height). One Bridge per page. */
    Bridge(const Services &services, std::function<void(int)> resize, QObject *parent = nullptr);

    /** [args]: a JSON array (the page's JSON.stringify(args)). Every call is answered: resolved or rejected. */
    Q_INVOKABLE void call(int id, const QString &method, const QString &args);

    /** An event to the page: "windows.changed", "apps.changed", "files.changed", ... */
    void emitEvent(const QString &name, const QJsonValue &data);

Q_SIGNALS:
    // JSON text both ways: the page parses it (bridgeScript), so any JSON value - null and bare strings included -
    // gets there as it was sent.
    void resolved(int id, const QString &json);
    void rejected(int id, const QString &message);
    void event(const QString &name, const QString &json);

private:
    QJsonValue dispatch(const QString &method, const QJsonArray &a);
    const Services &m_services;
    std::function<void(int)> m_resize;
};

/** The script every page gets at DocumentCreation: qwebchannel.js, then window.PowosHost over the channel. */
QString bridgeScript();
