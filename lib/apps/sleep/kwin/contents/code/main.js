// PowOS sleep (lib/apps/powos-sleep-gui loads this): every app window's focus and minimized state, as it changes, to
// the session's watcher over D-Bus. Event-driven - no timers here.
const SVC = "dev.powos.Sleep", PATH = "/Gui", IFACE = "dev.powos.Sleep.Gui";

function app(w) {
    return w && w.normalWindow && !w.specialWindow && w.pid > 0;
}

function send(w) {
    if (app(w))
        callDBus(SVC, PATH, IFACE, "Window", String(w.internalId), w.pid, String(w.resourceClass || ""), !!w.active, !!w.minimized);
}

function hook(w) {
    if (!app(w))
        return;
    w.activeChanged.connect(function () { send(w); });
    w.minimizedChanged.connect(function () { send(w); });
    send(w);
}

workspace.windowList().forEach(hook);
workspace.windowAdded.connect(hook);
workspace.windowRemoved.connect(function (w) {
    if (app(w))
        callDBus(SVC, PATH, IFACE, "Closed", String(w.internalId), w.pid);
});
// Every activation (any window, or none) for powos-sleep-gui's resume trace: who has KWin's focus after a game's thaw.
workspace.windowActivated.connect(function (w) {
    callDBus(SVC, PATH, IFACE, "Activated", w ? String(w.resourceClass || "") + " " + String(w.caption || "").slice(0, 40)
        + (w.normalWindow ? "" : " (not normal)") + (w.desktopWindow ? " (desktop)" : "") : "");
});
