// The page's one native entry, the same contract as the phone's ShellBridge.kt (docs/DESKTOP-WEB-SHELL.md §3.2):
// PowosHost.call(id, method, argsJson) answered through window.__powosHost.resolve / reject, events through
// window.__powosHost.emit. Over QWebChannel here: bridgeScript() makes window.PowosHost of the channel's object.
#pragma once

#include <QJsonArray>
#include <QJsonValue>
#include <QObject>

struct Services;

class Bridge : public QObject {
    Q_OBJECT
public:
    /** One Bridge per page. */
    Bridge(const Services &services, QObject *parent = nullptr);

    /** [args]: a JSON array (the page's JSON.stringify(args)). Every call is answered: resolved or rejected. */
    Q_INVOKABLE void call(int id, const QString &method, const QString &args);

    /**
     * The page's native port (apps/native.ts: PowosNative + a MessagePort, as the phone's ShellNative.kt): one text
     * message. "b.hello" / "b.r ..." are the glass (ui/nativeglass.ts), "open <url>" a link.
     */
    Q_INVOKABLE void native(const QString &message);

    /** An event to the page: "windows.changed", "apps.changed", "files.changed", ... */
    void emitEvent(const QString &name, const QJsonValue &data);

Q_SIGNALS:
    // JSON text both ways: the page parses it (bridgeScript), so any JSON value - null and bare strings included -
    // gets there as it was sent.
    void resolved(int id, const QString &json);
    void rejected(int id, const QString &message);
    void event(const QString &name, const QString &json);
    /** A text message back over the native port ("b.state 1"). */
    void nativeMessage(const QString &message);
    /** panel.height: the page asks for its surface to be this tall. */
    void surfaceHeight(int px);
    /** The page's glass surfaces moved ("b.r" without its prefix): the view's blur behind them. */
    void glass(const QString &regions);

private:
    QJsonValue dispatch(const QString &method, const QJsonArray &a);
    const Services &m_services;
};

/** The script every page gets at DocumentCreation: qwebchannel.js, then window.PowosHost over the channel. */
QString bridgeScript();
