// A transparent desktop: draws nothing and clears the desktop window's own fill. plasmashell's DesktopView paints its
// window black under the wallpaper; with this wallpaper the window is transparent instead, so what is behind the
// desktop shows - on a phone, Android's wallpaper (the PowOS app's surface is translucent). plasmashell creates its
// windows with an alpha channel (QQuickWindow::setDefaultAlphaBuffer), so only the color needs changing.
//
// It must stay transparent: never draw a picture of the wallpaper here. cb40fa50 (2026-10-23) drew PowOS home's
// picture to keep Android's task snapshots from showing black; live, that was a second copy of the wallpaper at its
// own scale and offset (with KWin at scale 2.25, black over the top) instead of the real wallpaper and frost behind
// the app - the user wants the seamless desktop. Check: tools/phone/verify/plasma-transparent.sh.
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
