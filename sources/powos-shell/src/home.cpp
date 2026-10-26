#include "home.h"
#include "bridge.h"

#include <KWindowEffects>
#include <LayerShellQt/Window>
#include <QGuiApplication>
#include <QPainterPath>
#include <QRegion>
#include <QScreen>
#include <QWindow>

Home::Home(QScreen *screen, QWebEngineProfile *profile, const Services &services)
    : ShellView(screen, profile, services, QStringLiteral("desktop"))
{
    connect(m_bridge, &Bridge::glass, this, &Home::setGlass);
    resize(screen->geometry().size());
    start();
}

void Home::resizeEvent(QResizeEvent *e)
{
    ShellView::resizeEvent(e);
    // What `powos-desktop-shell status` shows: where KWin put the surface (anchored to every edge, inside the panels).
    qInfo().noquote() << QStringLiteral("powos-shell surface: home %1x%2 on %3, layer %4, scope %5")
                             .arg(width()).arg(height()).arg(m_screen->name(),
                                  qEnvironmentVariable("POWOS_HOME_LAYER") == QLatin1String("background") ? QStringLiteral("background") : QStringLiteral("bottom"),
                                  qEnvironmentVariable("POWOS_HOME_SCOPE", QStringLiteral("dock")));
}

void Home::applyLayer()
{
    QWindow *window = windowHandle();
    // Off screen (dev/phone.sh render: QT_QPA_PLATFORM=offscreen at a desktop's size): no compositor, no layer.
    if (!window || QGuiApplication::platformName() != QLatin1String("wayland"))
        return;
    auto *layer = LayerShellQt::Window::get(window);
    // The bottom layer: over the desktop's wallpaper (plasmashell's desktop window, on KWin's desktop layer) and under
    // every window. The background layer would share that desktop layer with plasmashell's window and its wallpaper.
    // POWOS_HOME_LAYER=background tries it there.
    layer->setLayer(qEnvironmentVariable("POWOS_HOME_LAYER") == QLatin1String("background") ? LayerShellQt::Window::LayerBackground
                                                                                            : LayerShellQt::Window::LayerBottom);
    layer->setAnchors(LayerShellQt::Window::Anchors(LayerShellQt::Window::AnchorTop | LayerShellQt::Window::AnchorBottom
                                                    | LayerShellQt::Window::AnchorLeft | LayerShellQt::Window::AnchorRight));
    // 0: inside what panels reserve (Plasma's own panel stays visible and usable).
    layer->setExclusiveZone(0);
    // The keyboard when clicked (the pill, a widget's field); never taken from a window on its own.
    layer->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityOnDemand);
    // KWin types a layer surface by its scope: "dock" is a special window - never in the task list (nor an Android
    // task on the phone: powos-android-tasks skips docks), and blurred behind like Plasma's panels.
    layer->setScope(qEnvironmentVariable("POWOS_HOME_SCOPE", QStringLiteral("dock")));
    if (!m_glass.isEmpty())
        KWindowEffects::enableBlurBehind(window, true, m_glass);
}

void Home::setGlass(const QString &regions)
{
    QWindow *window = windowHandle();
    if (!window || QGuiApplication::platformName() != QLatin1String("wayland"))
        return;
    const QStringList f = regions.split(QLatin1Char(' '), Qt::SkipEmptyParts);
    const int n = f.size() > 1 ? f[1].toInt() : 0;
    QRegion region;
    for (int i = 0; i < n && 2 + i * 10 + 9 < f.size(); ++i) {
        const auto v = [&](int k) { return f[2 + i * 10 + k].toDouble(); };
        // A surface fading out (alpha under half) leaves the blur: KWin's region is on or off, never see-through.
        if (v(8) < 0.5)
            continue;
        const QRectF r(v(0), v(1), v(2), v(3));
        QPainterPath path;
        // One radius per surface (KWin's region is a mask): the largest corner, as the page rounds it.
        const double radius = qMax(qMax(v(4), v(5)), qMax(v(6), v(7)));
        path.addRoundedRect(r, radius, radius);
        region += QRegion(path.toFillPolygon().toPolygon());
    }
    m_glass = region;
    // An empty region with blur on would blur the whole window: off instead.
    KWindowEffects::enableBlurBehind(window, !region.isEmpty(), region);
}
