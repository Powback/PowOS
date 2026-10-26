#include "net.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSslCertificate>
#include <QSslConfiguration>
#include <QStandardPaths>
#include <QUrl>

namespace {
const QRegularExpression appId(QStringLiteral("^[a-z0-9][a-z0-9.-]{0,63}$"));
const QRegularExpression secretRef(QStringLiteral(R"(\$\{secret:([a-zA-Z0-9_.-]{1,64})\})"));
QString compact(const QJsonObject &o) { return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact)); }
QString pinKey(const QString &app, const QUrl &u) { return app + QLatin1Char('/') + u.host().toLower() + QLatin1Char(':') + QString::number(u.port(443)); }
QString sha256(const QSslCertificate &c) { return QString::fromLatin1(QCryptographicHash::hash(c.toDer(), QCryptographicHash::Sha256).toHex()); }
}

/** One server-sent-events subscription: reconnected with backoff until it's closed. */
struct Net::Stream {
    QString app, sub;
    QUrl url;
    QJsonObject headers;
    QPointer<QNetworkReply> reply;
    QByteArray buffer;
    QString event, data;
    int backoff = 1000;
    bool stopped = false, open = false;
    QTimer retry;
};

Net::Net(QObject *parent)
    : QObject(parent)
    , m_nam(new QNetworkAccessManager(this))
    , m_dir(QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/powos/net"))
{
    QDir().mkpath(m_dir);
    QFile::setPermissions(m_dir, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
}

Net::~Net() { reset(); }

void Net::reset()
{
    for (Stream *s : std::as_const(m_streams)) {
        s->stopped = true;
        if (s->reply)
            s->reply->abort();
        delete s;
    }
    m_streams.clear();
}

void Net::answer(const QString &id, QJsonObject out)
{
    out.insert(QStringLiteral("id"), id);
    Q_EMIT reply(QStringLiteral("n.res ") + compact(out));
}

QJsonObject Net::load(const QString &file) const
{
    QFile f(m_dir + QLatin1Char('/') + file);
    return f.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(f.readAll()).object() : QJsonObject();
}

void Net::save(const QString &file, const QJsonObject &obj) const
{
    QSaveFile f(m_dir + QLatin1Char('/') + file);
    if (!f.open(QIODevice::WriteOnly))
        return;
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    f.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
    f.commit();
}

// ---- scope ----

QStringList Net::declared(const QString &app) const
{
    const QString apps = qEnvironmentVariable("POWOS_APPS_DIR", QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/powos/apps"));
    QFile f(apps + QLatin1Char('/') + app + QStringLiteral("/current/powos-app.json"));
    if (!f.open(QIODevice::ReadOnly))
        return {};
    QStringList out;
    for (const QJsonValue &v : QJsonDocument::fromJson(f.readAll()).object().value(QStringLiteral("net")).toArray())
        out << v.toString().toLower();
    return out;
}

bool Net::isPrivate(const QString &host)
{
    if (host.endsWith(QLatin1String(".local")))
        return true;
    QHostAddress a;
    if (!a.setAddress(host))
        return false;
    if (a.protocol() == QAbstractSocket::IPv4Protocol)
        return a.isPrivateUse() || a.isLinkLocal();
    return a.isLinkLocal() || (a.toIPv6Address()[0] & 0xfe) == 0xfc;
}

QUrl Net::allowed(const QString &app, const QString &url, QString *why) const
{
    const QUrl u(url);
    if (u.scheme() != QLatin1String("https") && u.scheme() != QLatin1String("http")) {
        *why = QStringLiteral("only http(s)");
        return {};
    }
    const QString host = u.host().toLower();
    const QStringList net = declared(app);
    if (net.contains(host) || (net.contains(QStringLiteral("lan")) && isPrivate(host)))
        return u;
    *why = QStringLiteral("%1 may not reach %2: add it (or \"lan\") to \"net\" in its powos-app.json").arg(app, host);
    return {};
}

// ---- requests ----

bool Net::prepare(QNetworkRequest &req, const QString &app, const QJsonObject &headers, QString *why) const
{
    const QJsonObject secrets = load(QStringLiteral("secrets.json"));
    for (auto it = headers.begin(); it != headers.end(); ++it) {
        QString v = it.value().toString();
        for (auto m = secretRef.globalMatch(v); m.hasNext();) {
            const auto hit = m.next();
            const QJsonValue s = secrets.value(app + QLatin1Char('/') + hit.captured(1));
            if (!s.isString()) {
                *why = QStringLiteral("no secret ") + hit.captured(1);
                return false;
            }
            v.replace(hit.captured(0), s.toString());
        }
        req.setRawHeader(it.key().toUtf8(), v.toUtf8());
    }
    return true;
}

void Net::pinCheck(QNetworkReply *reply, const QString &app)
{
    const QUrl u = reply->url();
    if (u.scheme() != QLatin1String("https") || !isPrivate(u.host().toLower()))
        return; // public hosts: the system's CAs, as always
    // A LAN device's certificate is its identity, pinned on first use (its name is a serial number, not the address).
    const auto check = [this, reply, app, u] {
        const QSslCertificate leaf = reply->sslConfiguration().peerCertificate();
        if (leaf.isNull())
            return false;
        QJsonObject pins = load(QStringLiteral("pins.json"));
        const QString key = pinKey(app, u), sha = sha256(leaf);
        if (!pins.contains(key)) {
            pins.insert(key, sha);
            save(QStringLiteral("pins.json"), pins);
            qInfo().noquote() << "powos-shell net: pinned" << key;
        }
        return pins.value(key).toString() == sha;
    };
    connect(reply, &QNetworkReply::sslErrors, reply, [reply, check](const QList<QSslError> &) {
        if (check())
            reply->ignoreSslErrors();
    });
    connect(reply, &QNetworkReply::encrypted, reply, [reply, check] {
        if (!check())
            reply->abort();
    });
}

void Net::command(const QString &json)
{
    const QJsonObject r = QJsonDocument::fromJson(json.toUtf8()).object();
    const QString id = r.value(QStringLiteral("id")).toString();
    const QString app = r.value(QStringLiteral("app")).toString();
    const QString op = r.value(QStringLiteral("op")).toString();
    const auto fail = [&](const QString &why) { answer(id, QJsonObject{{QStringLiteral("error"), why}}); };
    // HACK: the app id is the island's word for itself (as the phone's ShellNet.kt): islands are modules in the shell's
    // one page, so one could name another app's id and use its grants and secrets. Real fix: per-app origins (islands
    // in <id>.app.powos frames, docs/POWOS-APPS-FEASIBILITY.md 6.1) and the id taken from the calling frame's origin.
    if (!appId.match(app).hasMatch())
        return fail(QStringLiteral("bad app id"));
    if (op == QLatin1String("fetch"))
        return fetch(id, app, r);
    if (op == QLatin1String("mdns"))
        return mdns(id, app, r);
    if (op == QLatin1String("secret"))
        return answer(id, QJsonObject{{QStringLiteral("has"), load(QStringLiteral("secrets.json")).contains(app + QLatin1Char('/') + r.value(QStringLiteral("name")).toString())}});
    if (op == QLatin1String("forget")) {
        const QString host = r.value(QStringLiteral("host")).toString().toLower();
        if (!host.isEmpty()) {
            QJsonObject pins = load(QStringLiteral("pins.json"));
            for (const QString &k : pins.keys())
                if (k.startsWith(app + QLatin1Char('/') + host + QLatin1Char(':')))
                    pins.remove(k);
            save(QStringLiteral("pins.json"), pins);
        }
        const QString secret = r.value(QStringLiteral("secret")).toString();
        if (!secret.isEmpty()) {
            QJsonObject secrets = load(QStringLiteral("secrets.json"));
            secrets.remove(app + QLatin1Char('/') + secret);
            save(QStringLiteral("secrets.json"), secrets);
        }
        return answer(id, {});
    }
    const QString key = app + QLatin1Char('/') + r.value(QStringLiteral("sub")).toString();
    if (op == QLatin1String("close")) {
        if (Stream *s = m_streams.take(key)) {
            s->stopped = true;
            if (s->reply)
                s->reply->abort();
            Q_EMIT reply(QStringLiteral("n.st ") + compact({{QStringLiteral("app"), app}, {QStringLiteral("sub"), s->sub}, {QStringLiteral("state"), QStringLiteral("closed")}, {QStringLiteral("error"), QString()}}));
            delete s;
        }
        return answer(id, {});
    }
    if (op == QLatin1String("events")) {
        QString why;
        const QUrl u = allowed(app, r.value(QStringLiteral("url")).toString(), &why);
        if (u.isEmpty())
            return fail(why);
        if (Stream *old = m_streams.take(key)) {
            old->stopped = true;
            if (old->reply)
                old->reply->abort();
            delete old;
        }
        auto *s = new Stream{app, r.value(QStringLiteral("sub")).toString(), u, r.value(QStringLiteral("headers")).toObject()};
        s->retry.setSingleShot(true);
        connect(&s->retry, &QTimer::timeout, this, [this, s] { openStream(s); });
        m_streams.insert(key, s);
        openStream(s);
        return answer(id, {});
    }
    fail(QStringLiteral("no such op: ") + op);
}

void Net::fetch(const QString &id, const QString &app, const QJsonObject &r)
{
    QString why;
    const QUrl u = allowed(app, r.value(QStringLiteral("url")).toString(), &why);
    QNetworkRequest req(u);
    if (u.isEmpty() || !prepare(req, app, r.value(QStringLiteral("headers")).toObject(), &why))
        return answer(id, QJsonObject{{QStringLiteral("error"), why}});
    req.setTransferTimeout(20000);
    const QByteArray method = r.value(QStringLiteral("method")).toString(QStringLiteral("GET")).toUpper().toUtf8();
    const bool hasBody = r.contains(QStringLiteral("body"));
    if (hasBody && !req.hasRawHeader("Content-Type"))
        req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    QNetworkReply *reply = m_nam->sendCustomRequest(req, method, hasBody ? r.value(QStringLiteral("body")).toString().toUtf8() : QByteArray());
    pinCheck(reply, app);
    const QJsonObject cap = r.value(QStringLiteral("capture")).toObject();
    connect(reply, &QNetworkReply::finished, this, [this, reply, id, app, cap] {
        reply->deleteLater();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status == 0)
            return answer(id, QJsonObject{{QStringLiteral("error"), reply->errorString()}});
        QString body = QString::fromUtf8(reply->readAll());
        if (!cap.isEmpty())
            body = capture(app, cap, body);
        answer(id, QJsonObject{{QStringLiteral("status"), status}, {QStringLiteral("body"), body}});
    });
}

/** The value at path[i...] of [v] replaced by "(kept)"; [found] the string that was there. */
static QJsonValue keep(const QJsonValue &v, const QStringList &path, int i, QString *found)
{
    const QString p = path.at(i);
    const bool last = i == path.size() - 1;
    if (v.isArray()) {
        QJsonArray a = v.toArray();
        bool ok = false;
        const int n = p.toInt(&ok);
        if (!ok || n < 0 || n >= a.size())
            return v;
        if (last) {
            if (!a.at(n).isString())
                return v;
            *found = a.at(n).toString();
            a.replace(n, QStringLiteral("(kept)"));
        } else {
            a.replace(n, keep(a.at(n), path, i + 1, found));
        }
        return a;
    }
    if (v.isObject()) {
        QJsonObject o = v.toObject();
        if (!o.contains(p))
            return v;
        if (last) {
            if (!o.value(p).isString())
                return v;
            *found = o.value(p).toString();
            o.insert(p, QStringLiteral("(kept)"));
        } else {
            o.insert(p, keep(o.value(p), path, i + 1, found));
        }
        return o;
    }
    return v;
}

QString Net::capture(const QString &app, const QJsonObject &cap, const QString &body)
{
    // The secret at cap.path ("0.success.username") goes into this app's secrets, and out of what the page gets.
    const QJsonDocument doc = QJsonDocument::fromJson(body.toUtf8());
    if (doc.isNull())
        return body;
    QString found;
    const QJsonValue root = keep(doc.isArray() ? QJsonValue(doc.array()) : QJsonValue(doc.object()), cap.value(QStringLiteral("path")).toString().split(QLatin1Char('.')), 0, &found);
    if (found.isEmpty())
        return body;
    QJsonObject secrets = load(QStringLiteral("secrets.json"));
    secrets.insert(app + QLatin1Char('/') + cap.value(QStringLiteral("secret")).toString(), found);
    save(QStringLiteral("secrets.json"), secrets);
    return QString::fromUtf8(root.isArray() ? QJsonDocument(root.toArray()).toJson(QJsonDocument::Compact) : QJsonDocument(root.toObject()).toJson(QJsonDocument::Compact));
}

// ---- server-sent events ----

void Net::openStream(Stream *s)
{
    const auto state = [this, s](const QString &st, const QString &error) {
        Q_EMIT reply(QStringLiteral("n.st ") + compact({{QStringLiteral("app"), s->app}, {QStringLiteral("sub"), s->sub}, {QStringLiteral("state"), st}, {QStringLiteral("error"), error}}));
    };
    QString why;
    QNetworkRequest req(s->url);
    if (!prepare(req, s->app, s->headers, &why)) {
        state(QStringLiteral("retry"), why);
        s->retry.start(60000);
        return;
    }
    req.setRawHeader("Accept", "text/event-stream");
    // Quiet streams stay open; a dead network shows as this (inactivity) timeout and a reconnect.
    req.setTransferTimeout(300000);
    s->buffer.clear();
    s->open = false;
    s->reply = m_nam->get(req);
    pinCheck(s->reply, s->app);
    QNetworkReply *reply = s->reply;
    connect(reply, &QNetworkReply::readyRead, this, [this, s, reply, state] {
        if (!s->open) {
            if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() != 200)
                return;
            s->open = true;
            s->backoff = 1000;
            state(QStringLiteral("open"), QString());
        }
        s->buffer += reply->readAll();
        for (qsizetype nl; (nl = s->buffer.indexOf('\n')) >= 0;) {
            QString line = QString::fromUtf8(s->buffer.left(nl));
            s->buffer.remove(0, nl + 1);
            if (line.endsWith(QLatin1Char('\r')))
                line.chop(1);
            if (line.isEmpty()) {
                if (!s->data.isEmpty())
                    Q_EMIT this->reply(QStringLiteral("n.ev ") + compact({{QStringLiteral("app"), s->app}, {QStringLiteral("sub"), s->sub}, {QStringLiteral("event"), s->event}, {QStringLiteral("data"), s->data}}));
                s->event.clear();
                s->data.clear();
            } else if (line.startsWith(QLatin1String("data:"))) {
                if (!s->data.isEmpty())
                    s->data += QLatin1Char('\n');
                s->data += line.mid(line.startsWith(QLatin1String("data: ")) ? 6 : 5);
            } else if (line.startsWith(QLatin1String("event:"))) {
                s->event = line.mid(6).trimmed();
            }
        }
    });
    connect(reply, &QNetworkReply::finished, this, [s, reply, state] {
        reply->deleteLater();
        if (s->stopped)
            return;
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        state(QStringLiteral("retry"), status && status != 200 ? QStringLiteral("HTTP %1").arg(status) : reply->errorString());
        s->retry.start(s->backoff);
        s->backoff = qMin(s->backoff * 2, 30000);
    });
}

// ---- mDNS ----

void Net::mdns(const QString &id, const QString &app, const QJsonObject &r)
{
    if (!declared(app).contains(QStringLiteral("lan")))
        return answer(id, QJsonObject{{QStringLiteral("error"), app + QStringLiteral(" doesn't declare \"lan\" in its manifest's net")}});
    const QString type = r.value(QStringLiteral("type")).toString();
    static const QRegularExpression typeOk(QStringLiteral("^_[a-z0-9-]+\\._(tcp|udp)$"));
    if (!typeOk.match(type).hasMatch())
        return answer(id, QJsonObject{{QStringLiteral("error"), QStringLiteral("bad service type")}});
    // Avahi's browser (the system's mDNS): resolved, parsable, terminating once its cache is dumped - or at ms.
    auto *p = new QProcess(this);
    const int ms = qBound(500, r.value(QStringLiteral("ms")).toInt(3000), 10000);
    QTimer::singleShot(ms, p, [p] { p->terminate(); });
    connect(p, &QProcess::finished, this, [this, p, id] {
        p->deleteLater();
        // =;iface;proto;name;type;domain;host;address;port;"txt" "txt"   (names \DDD-escaped)
        static const QRegularExpression esc(QStringLiteral(R"(\\(\d{3}))"));
        const auto unescape = [](QString s) {
            for (auto m = esc.match(s); m.hasMatch(); m = esc.match(s))
                s.replace(m.capturedStart(), 4, QChar(m.captured(1).toInt()));
            return s;
        };
        QJsonArray services;
        QStringList seen;
        for (const QString &l : QString::fromUtf8(p->readAllStandardOutput()).split(QLatin1Char('\n'))) {
            const QStringList f = l.split(QLatin1Char(';'));
            if (f.size() < 10 || f[0] != QLatin1String("=") || f[2] != QLatin1String("IPv4") || seen.contains(f[3]))
                continue;
            seen << f[3];
            QJsonObject txt;
            static const QRegularExpression item(QStringLiteral(R"re("([^"=]+)=([^"]*)")re"));
            for (auto m = item.globalMatch(f.mid(9).join(QLatin1Char(';'))); m.hasNext();) {
                const auto hit = m.next();
                txt.insert(hit.captured(1), hit.captured(2));
            }
            services.append(QJsonObject{{QStringLiteral("name"), unescape(f[3])}, {QStringLiteral("host"), f[7]},
                                        {QStringLiteral("port"), f[8].toInt()}, {QStringLiteral("txt"), txt}});
        }
        answer(id, QJsonObject{{QStringLiteral("services"), services}});
    });
    connect(p, &QProcess::errorOccurred, this, [this, p, id](QProcess::ProcessError e) {
        if (e != QProcess::FailedToStart)
            return;
        p->deleteLater();
        answer(id, QJsonObject{{QStringLiteral("error"), QStringLiteral("mdns: no avahi-browse on this system")}});
    });
    p->start(QStringLiteral("avahi-browse"), {QStringLiteral("-rpt"), type});
}
