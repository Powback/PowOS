#include "bridge.h"
#include "net.h"
#include "server.h"
#include "services.h"

#include <KWindowEffects>
#include <QDesktopServices>
#include <QFile>
#include <QFileInfo>
#include <QTimer>
#include <QUrl>
#include <QJsonDocument>
#include <QJsonObject>
#include <stdexcept>

namespace {
/** Any JSON value as text (QJsonDocument holds only objects and arrays: through a one-element array). */
QString toJson(const QJsonValue &v)
{
    const QByteArray wrapped = QJsonDocument(QJsonArray{v}).toJson(QJsonDocument::Compact);
    return QString::fromUtf8(wrapped.mid(1, wrapped.size() - 2));
}

struct Unsupported : std::runtime_error {
    using std::runtime_error::runtime_error;
};
}

Bridge::Bridge(const Services &services, QObject *parent)
    : QObject(parent)
    , m_services(services)
    , m_net(new Net(this))
{
    connect(m_net, &Net::reply, this, &Bridge::nativeMessage);
    connect(services.windows, &Windows::changed, this, [this](const QJsonArray &list) { emitEvent(QStringLiteral("windows.changed"), list); });
    connect(services.apps, &Apps::changed, this, [this] { emitEvent(QStringLiteral("apps.changed"), QJsonValue::Null); });
    connect(services.theme, &Theme::changed, this, [this](const QJsonValue &t) { emitEvent(QStringLiteral("theme.changed"), t); });
    connect(services.ai, &Ai::changed, this, [this](const QJsonObject &c) { emitEvent(QStringLiteral("ai.changed"), c); });
}

void Bridge::native(const QString &message)
{
    if (message == QLatin1String("b.hello")) {
        // The compositor blurs behind this page's surfaces when KWin's blur effect is on (the page tints only, then).
        const bool blur = KWindowEffects::isEffectAvailable(KWindowEffects::BlurBehind);
        Q_EMIT nativeMessage(blur ? QStringLiteral("b.state 1") : QStringLiteral("b.state 0"));
        // HACK: KWin 6.7 announces blur as ext_background_effect_v1's capabilities event, which reaches KWindowSystem
        // ~0.5 s after the first window (measured on the phone: off at the page's hello, on 500 ms later), and
        // KWindowEffects has no signal for it - so a "no" is asked again. Real fix: a change signal in KWindowSystem
        // (or binding ext_background_effect_manager_v1 here and following its capabilities event).
        if (!blur)
            for (int ms : {500, 3000})
                QTimer::singleShot(ms, this, [this] {
                    if (KWindowEffects::isEffectAvailable(KWindowEffects::BlurBehind))
                        Q_EMIT nativeMessage(QStringLiteral("b.state 1"));
                });
    } else if (message.startsWith(QLatin1String("b.r "))) {
        Q_EMIT glass(message.mid(4));
    } else if (message.startsWith(QLatin1String("n.req "))) {
        m_net->command(message.mid(6));
    } else if (message == QLatin1String("s.reset")) {
        // A new port (the page loaded again): what the last one had open goes.
        m_net->reset();
    } else if (message.startsWith(QLatin1String("open "))) {
        const QUrl url(message.mid(5));
        if (url.scheme() == QLatin1String("https") || url.scheme() == QLatin1String("http") || url.scheme() == QLatin1String("mailto"))
            QDesktopServices::openUrl(url);
    }
    // Anything else (surface tiles "s.*", liquid glass "b.liquid"): not on this host, the page falls back.
}

void Bridge::emitEvent(const QString &name, const QJsonValue &data)
{
    Q_EMIT event(name, toJson(data));
}

void Bridge::call(int id, const QString &method, const QString &args)
{
    const QJsonArray a = QJsonDocument::fromJson(args.toUtf8()).array();
    try {
        Q_EMIT resolved(id, toJson(dispatch(method, a)));
    } catch (const std::exception &e) {
        Q_EMIT rejected(id, QString::fromUtf8(e.what()));
    }
}

QJsonValue Bridge::dispatch(const QString &method, const QJsonArray &a)
{
    // Areas this host doesn't have yet reject with "unsupported", as the phone's does for desktop-only ones.
    if (method == QLatin1String("apps.list"))
        return m_services.apps->list();
    if (method == QLatin1String("apps.launch")) {
        if (!m_services.apps->launch(a.at(0).toString()))
            throw std::runtime_error("no such app: " + a.at(0).toString().toStdString());
        return QJsonValue::Null;
    }
    if (method == QLatin1String("windows.list"))
        return m_services.windows->list();
    if (method == QLatin1String("windows.activate"))
        return m_services.windows->activate(a.at(0).toString());
    if (method == QLatin1String("windows.minimize"))
        return m_services.windows->minimize(a.at(0).toString());
    if (method == QLatin1String("panel.height")) {
        Q_EMIT surfaceHeight(a.at(0).toInt());
        return QJsonValue::Null;
    }
    if (method == QLatin1String("store.get"))
        return m_services.store->get(a.at(0).toString());
    if (method == QLatin1String("store.set")) {
        m_services.store->set(a.at(0).toString(), a.at(1));
        return QJsonValue::Null;
    }
    if (method == QLatin1String("theme.get"))
        return m_services.theme->get();
    if (method == QLatin1String("ai.chat"))
        return m_services.ai->chat();
    if (method == QLatin1String("ai.send")) {
        m_services.ai->send(a.at(0).toString());
        return QJsonValue::Null;
    }
    if (method == QLatin1String("system.glass")) {
        const QString file = desktopWallpaper();
        if (file.isEmpty())
            return QJsonObject{{QStringLiteral("wallpaper"), QJsonValue::Null}, {QStringLiteral("blurBehind"), false}};
        const QString rev = QString::number(QFileInfo(file).lastModified().toMSecsSinceEpoch());
        return QJsonObject{{QStringLiteral("wallpaper"), QJsonObject{{QStringLiteral("url"), QStringLiteral("./_wallpaper?r=") + rev},
                                                                    {QStringLiteral("rev"), rev}, {QStringLiteral("source"), QStringLiteral("file")}}},
                           {QStringLiteral("blurBehind"), false}};
    }
    // Agents' mail comes as comms notifications on this host (Plasma's), not into the page yet.
    if (method == QLatin1String("ai.mail"))
        return QJsonArray{};
    // What every page asks at start (app.tsx): no system bars or keyboard inside a layer surface.
    if (method == QLatin1String("system.insets"))
        return QJsonObject{{QStringLiteral("top"), 0}, {QStringLiteral("bottom"), 0}, {QStringLiteral("left"), 0},
                           {QStringLiteral("right"), 0}, {QStringLiteral("keyboard"), 0}};
    if (method == QLatin1String("usage.recent"))
        return QJsonArray{};
    throw Unsupported("unsupported: " + method.toStdString());
}

QString bridgeScript()
{
    QFile channel(QStringLiteral(":/qtwebchannel/qwebchannel.js"));
    if (!channel.open(QIODevice::ReadOnly))
        qFatal("powos-shell: no qwebchannel.js in QtWebEngine's resources");
    // PowosHost exists from the first line of the page on (bridge.ts picks its host when it loads); calls made before
    // the channel is up wait in a queue. Answers go to window.__powosHost as on the phone.
    return QString::fromUtf8(channel.readAll()) + QStringLiteral(R"JS(
;(() => {
  const queue = [];
  let host = null;
  window.PowosHost = {
    name: "powos",
    call(id, method, args) { host ? host.call(id, method, args) : queue.push([id, method, args]); },
  };
  new QWebChannel(qt.webChannelTransport, (channel) => {
    host = channel.objects.host;
    host.resolved.connect((id, json) => window.__powosHost.resolve(id, JSON.parse(json)));
    host.rejected.connect((id, message) => window.__powosHost.reject(id, message));
    host.event.connect((name, json) => window.__powosHost.emit(name, JSON.parse(json)));
    for (const [id, method, args] of queue.splice(0)) host.call(id, method, args);
    // The native port (apps/native.ts), as the phone's ShellNative hands one over: text both ways.
    host.nativeMessage.connect((text) => port && port.postMessage(text));
    for (const text of early.splice(0)) host.native(text);
  });
  let port = null;
  const early = [];
  window.PowosNative = {
    postMessage(message) {
      if (message !== "connect") return;
      const channel = new MessageChannel();
      port = channel.port1;
      port.onmessage = (e) => typeof e.data === "string" && (host ? host.native(e.data) : early.push(e.data));
      window.postMessage("powos-native", "*", [channel.port2]);
    },
  };
})();
)JS");
}
