#include "panel.h"
#include "bridge.h"

#include <LayerShellQt/Window>
#include <QScreen>
#include <QWindow>

Panel::Panel(QScreen *screen, QWebEngineProfile *profile, const Services &services)
    : ShellView(screen, profile, services, QStringLiteral("panel"))
{
    connect(m_bridge, &Bridge::surfaceHeight, this, &Panel::setSurfaceHeight);
    resize(screen->geometry().width(), Height);
    start();
    // The screen's size changes the bar's width (anchored left|right: KWin stretches it; the widget follows).
    connect(screen, &QScreen::geometryChanged, this, [this](const QRect &g) { resize(g.width(), height()); });
}

void Panel::applyLayer()
{
    QWindow *window = windowHandle();
    if (!window)
        return;
    auto *layer = LayerShellQt::Window::get(window);
    layer->setLayer(LayerShellQt::Window::LayerTop);
    layer->setAnchors(LayerShellQt::Window::Anchors(LayerShellQt::Window::AnchorBottom | LayerShellQt::Window::AnchorLeft
                                                    | LayerShellQt::Window::AnchorRight));
    layer->setExclusiveZone(Height);
    // Open (taller than the bar): it takes the keyboard when clicked, for the launcher's search. The bar alone never.
    layer->setKeyboardInteractivity(m_open ? LayerShellQt::Window::KeyboardInteractivityOnDemand
                                           : LayerShellQt::Window::KeyboardInteractivityNone);
    layer->setScope(QStringLiteral("powos-panel"));
}

void Panel::setSurfaceHeight(int px)
{
    const int h = px <= Height ? Height : qMin(px, m_screen->geometry().height() - 32);
    m_open = h > Height;
    applyLayer();
    resize(m_screen->geometry().width(), h);
}
