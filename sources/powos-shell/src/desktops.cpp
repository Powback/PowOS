#include "desktops.h"
#include "services.h"

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusVariant>
#include <QJsonObject>
#include <algorithm>

namespace {
const QString kService = QStringLiteral("org.kde.KWin");
const QString kPath = QStringLiteral("/VirtualDesktopManager");
const QString kInterface = QStringLiteral("org.kde.KWin.VirtualDesktopManager");

QDBusMessage call(const QString &interface, const QString &method, const QVariantList &args)
{
    QDBusMessage m = QDBusMessage::createMethodCall(kService, kPath, interface, method);
    m.setArguments(args);
    return QDBusConnection::sessionBus().call(m);
}

QVariant property(const QString &name)
{
    const QDBusMessage reply = call(QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("Get"), {kInterface, name});
    if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty())
        return {};
    return reply.arguments().first().value<QDBusVariant>().variant();
}
}

Desktops::Desktops(Windows *windows, QObject *parent)
    : QObject(parent)
    , m_windows(windows)
{
    QDBusConnection::sessionBus().connect(kService, kPath, kInterface, QStringLiteral("currentChanged"), this,
                                          SLOT(kwinCurrentChanged(QString)));
}

QList<Desktops::Desktop> Desktops::fetch() const
{
    QList<Desktop> out;
    // desktops: a(uss) - KWin's DBusDesktopDataStruct {position, id, name}, read off the wire (no registered type).
    const QVariant v = property(QStringLiteral("desktops"));
    if (!v.canConvert<QDBusArgument>())
        return out;
    const QDBusArgument arg = v.value<QDBusArgument>();
    arg.beginArray();
    while (!arg.atEnd()) {
        Desktop d;
        arg.beginStructure();
        arg >> d.position >> d.id >> d.name;
        arg.endStructure();
        out << d;
    }
    arg.endArray();
    std::sort(out.begin(), out.end(), [](const Desktop &a, const Desktop &b) { return a.position < b.position; });
    return out;
}

QString Desktops::current() const
{
    return property(QStringLiteral("current")).toString();
}

QJsonArray Desktops::list() const
{
    const QString now = current();
    const QList<Desktop> desktops = fetch();
    QJsonArray out;
    for (int i = 0; i < desktops.size(); ++i)
        out.append(QJsonObject{{QStringLiteral("id"), desktops[i].id},
                               {QStringLiteral("name"), desktops[i].name},
                               {QStringLiteral("index"), i},
                               {QStringLiteral("current"), desktops[i].id == now}});
    return out;
}

bool Desktops::setCurrent(int index)
{
    const QList<Desktop> desktops = fetch();
    if (index < 0 || index >= desktops.size())
        return false;
    if (desktops[index].id == current())
        return true;
    const QDBusMessage reply = call(QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("Set"),
                                    {kInterface, QStringLiteral("current"), QVariant::fromValue(QDBusVariant(desktops[index].id))});
    return reply.type() == QDBusMessage::ReplyMessage;
}

QJsonArray Desktops::ensure(int count)
{
    count = std::max(count, 1);
    QList<Desktop> desktops = fetch();
    for (int i = desktops.size(); i < count; ++i)
        call(kInterface, QStringLiteral("createDesktop"), {uint(i), QStringLiteral("Page %1").arg(i + 1)});
    if (desktops.size() > count) {
        // From the end only (indices are pages), and stop at the first that holds a window: its page keeps it.
        const QSet<QString> used = m_windows->desktopsInUse();
        for (int i = desktops.size() - 1; i >= count && !used.contains(desktops[i].id); --i)
            call(kInterface, QStringLiteral("removeDesktop"), {desktops[i].id});
    }
    return list();
}

void Desktops::kwinCurrentChanged(const QString &id)
{
    const QList<Desktop> desktops = fetch();
    for (int i = 0; i < desktops.size(); ++i)
        if (desktops[i].id == id)
            return Q_EMIT currentChanged(i);
}
