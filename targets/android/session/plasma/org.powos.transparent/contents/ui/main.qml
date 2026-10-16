// A transparent desktop: draws nothing and clears the desktop window's own fill. plasmashell's DesktopView paints its
// window black under the wallpaper; with this wallpaper the window is transparent instead, so what is behind the
// desktop shows - on a phone, Android's wallpaper (the PowOS app's surface is translucent). plasmashell creates its
// windows with an alpha channel (QQuickWindow::setDefaultAlphaBuffer), so only the color needs changing.
import QtQuick
import QtQuick.Window
import org.kde.plasma.plasmoid

WallpaperItem {
    id: root

    function clear() {
        const w = root.Window.window;
        if (w && w.color.a !== 0)
            w.color = "transparent";
    }

    Component.onCompleted: clear()
    Window.onWindowChanged: clear()

    // plasmashell sets the window's color again after startup (and on screen changes): clear it each time.
    Connections {
        target: root.Window.window
        function onColorChanged() {
            root.clear();
        }
    }
}
