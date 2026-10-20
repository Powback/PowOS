#include "bridge.h"
#include "services.h"

#include <QFile>
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

Bridge::Bridge(const Services &services, std::function<void(int)> resize, QObject *parent)
    : QObject(parent)
    , m_services(services)
    , m_resize(std::move(resize))
{
    connect(services.windows, &Windows::changed, this, [this](const QJsonArray &list) { emitEvent(QStringLiteral("windows.changed"), list); });
    connect(services.apps, &Apps::changed, this, [this] { emitEvent(QStringLiteral("apps.changed"), QJsonValue::Null); });
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
        m_resize(a.at(0).toInt());
        return QJsonValue::Null;
    }
    // What every page asks at start (app.tsx): no system bars or keyboard inside a layer surface.
    if (method == QLatin1String("system.insets"))
        return QJsonObject{{QStringLiteral("top"), 0}, {QStringLiteral("bottom"), 0}, {QStringLiteral("left"), 0},
                           {QStringLiteral("right"), 0}, {QStringLiteral("keyboard"), 0}};
    if (method == QLatin1String("usage.recent"))
        return QJsonArray{};
    if (method == QLatin1String("store.get"))
        return QJsonValue::Null;
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
  });
})();
)JS");
}
