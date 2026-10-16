// HACK(PowOS phone): the desktop window at opacity 0.999 (no visible difference). On the phone the desktop is
// transparent over Android's wallpaper (org.powos.transparent), but plasmashell's surface still declares itself
// opaque, so KWin never cleared the output under it and translucent pixels piled up frame after frame (selection
// rectangles left trails). KWin doesn't treat a window below full opacity as opaque, so it clears under it again.
// Real fix: plasmashell/QtWayland shouldn't set an opaque region on a window whose color is transparent.
function translucent(w) {
    if (w && w.desktopWindow && w.opacity > 0.999)
        w.opacity = 0.999;
}
workspace.windowAdded.connect(translucent);
workspace.windowList().forEach(translucent);
