// The PowOS phone's desktop wallpaper: PowOS home's own picture of the wallpaper, over a transparent window.
//
// The Android app writes the picture PowOS home shows (ShellWallpaper: a still wallpaper's picture, a live one's
// current frame) into the session's run dir as powos-wallpaper-<n>.jpg - a new name per picture. A folder watch
// (FolderListModel: inotify, no polling) shows the newest one, cropped to cover the screen as Android crops it.
//
// Why a picture and not only the transparent window (2026-10-16 design): the desktop was transparent over Android's
// wallpaper (the PowOS app's surface is translucent), but every snapshot Android takes of the desktop's task leaves
// the wallpaper out - the starting window shown when the desktop comes back, recents and PowOS's switcher cards, the
// assist screenshot - so the desktop showed on black there (2026-10-23). Without a picture yet (the app hasn't written
// one) it is transparent as before.
//
// Nothing persistent changes: the containment keeps wallpaperplugin=org.powos.transparent; the picture is runtime only.
//
// plasmashell's DesktopView paints its window black under the wallpaper; the window's color is cleared to transparent
// (plasmashell creates its windows with an alpha channel, QQuickWindow::setDefaultAlphaBuffer) and kept so.
import QtQuick
import QtQuick.Window
import QtCore
import Qt.labs.folderlistmodel
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

    FolderListModel {
        id: pictures
        folder: StandardPaths.writableLocation(StandardPaths.RuntimeLocation) // /run/powos-app
        nameFilters: ["powos-wallpaper-*.jpg"]
        showDirs: false
        showHidden: false
        sortField: FolderListModel.Name
        sortReversed: true // the newest (largest time in its name) first
    }

    Repeater {
        model: pictures
        // The newest on top; an older one stays under it until the new one has loaded (no transparent flash on a
        // change), and is gone as soon as the app deletes its file.
        delegate: Image {
            required property int index
            required property url fileUrl
            anchors.fill: parent
            z: -index
            visible: status === Image.Ready
            source: fileUrl
            fillMode: Image.PreserveAspectCrop
            horizontalAlignment: Image.AlignHCenter
            verticalAlignment: Image.AlignVCenter
            asynchronous: true
            cache: false
            smooth: true
        }
    }
}
