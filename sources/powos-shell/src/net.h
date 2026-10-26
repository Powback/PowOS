// host.net on the desktop (shell/apps/net.ts over the native port; the phone's is ShellNet.kt, the same contract):
// PowOS apps' islands and pages reach the devices and services their powos-app.json declares in "net" - exact hosts,
// or "lan" for any private address - from the host, with no CORS and no browser refusing a LAN device's self-signed
// certificate (pinned on first use, per app and host:port). Secrets (a bridge's key) stay here: `capture` takes one
// out of a response, `${secret:name}` in a header puts it in. Kept in ~/.local/share/powos/net/ (0600).
//
//   n.req {"id","op","app",...}: fetch {url, method?, headers?, body?, capture?} -> n.res {id, status, body}
//                                events {sub, url, headers?} -> n.ev {app, sub, event, data} / n.st {app, sub, state}
//                                close {sub} | mdns {type, ms?} -> {services} | secret {name} -> {has} | forget {host?, secret?}
#pragma once

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QTimer>

class QNetworkAccessManager;
class QNetworkReply;
class QNetworkRequest;
class QSslError;

class Net : public QObject {
    Q_OBJECT
public:
    explicit Net(QObject *parent = nullptr);
    ~Net() override;
    /** One "n.req" body. Every request is answered ("n.res"), streams report through "n.ev" / "n.st". */
    void command(const QString &json);
    /** The page reloaded: its streams go. */
    void reset();
Q_SIGNALS:
    /** A text message for the page's native port ("n.res {...}"). */
    void reply(const QString &message);

private:
    struct Stream;
    void answer(const QString &id, QJsonObject out);
    QStringList declared(const QString &app) const;
    /** The URL if [app] may reach it; else empty, [why] says what to declare. */
    QUrl allowed(const QString &app, const QString &url, QString *why) const;
    static bool isPrivate(const QString &host);
    /** The request with the app's headers (secrets put in) and its pin check; false + [why]: a missing secret. */
    bool prepare(QNetworkRequest &req, const QString &app, const QJsonObject &headers, QString *why) const;
    void pinCheck(QNetworkReply *reply, const QString &app);
    void fetch(const QString &id, const QString &app, const QJsonObject &r);
    void mdns(const QString &id, const QString &app, const QJsonObject &r);
    void openStream(Stream *s);
    QString capture(const QString &app, const QJsonObject &cap, const QString &body);
    void save(const QString &file, const QJsonObject &obj) const;
    QJsonObject load(const QString &file) const;

    QNetworkAccessManager *m_nam;
    QHash<QString, Stream *> m_streams;
    QString m_dir;
};
