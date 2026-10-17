// PowOS on Android: "Open as Android task" in every window's menu (the title bar's app icon, Alt+F3). KWin's Anland
// backend then shows the window as its own Android task - its own card in Recents, split screen, floating window -
// until that task is closed (targets/android/docs/powos-window-tasks.md).
registerUserActionsMenu(function (window) {
    if (!window.normalWindow) {
        return;
    }
    return {
        text: "Open as Android task",
        icon: "smartphone",
        triggered: function () {
            callDBus("org.kde.KWin", "/org/powos/WindowTasks", "org.powos.WindowTasks", "show",
                     window.internalId.toString());
        }
    };
});
