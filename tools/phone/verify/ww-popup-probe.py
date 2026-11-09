#!/usr/bin/env python3
"""ww-popup-probe.py GO_FILE: an X11 app with a menu, for ww-popup-x11.sh (run in PowOS with QT_QPA_PLATFORM=xcb).

A main window ("PowOS popup probe"), then - once GO_FILE exists (the check makes it when the window is live as a web
window) - a menu with no parent widget: an override-redirect X11 window with no WM_TRANSIENT_FOR, as Steam's menus are
(kwin 0062). It stays POPUP_S (4) s, closes, and the app quits 2 s later. Prints "menu <x11 id> up|gone".
"""
import os
import sys

from PySide6.QtCore import QPoint, QTimer
from PySide6.QtWidgets import QApplication, QLabel, QMenu

POPUP_S = 4


def main():
    go = sys.argv[1]
    app = QApplication(sys.argv[:1])
    win = QLabel("PowOS popup probe")
    win.setWindowTitle("PowOS popup probe")
    win.resize(640, 420)
    win.show()
    menu = QMenu()
    for name in ("Open", "Save", "Quit"):
        menu.addAction(name)

    def gone():
        print(f"menu {int(menu.winId())} gone", flush=True)
        menu.hide()
        QTimer.singleShot(2000, app.quit)

    def poll():
        if not os.path.exists(go):
            QTimer.singleShot(200, poll)
            return
        menu.popup(win.mapToGlobal(QPoint(40, 60)))
        print(f"menu {int(menu.winId())} up", flush=True)
        QTimer.singleShot(POPUP_S * 1000, gone)

    QTimer.singleShot(200, poll)
    QTimer.singleShot(120_000, app.quit)  # never outlives the check
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
