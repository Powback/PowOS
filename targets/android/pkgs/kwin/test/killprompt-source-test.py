#!/usr/bin/env python3
"""Structural regression only; does NOT execute Qt signals, processes, or KWin.
Run against src-tree.sh's canonical patched tree. The device hung-client gate
remains required for both XCB and Wayland, including exact helper retirement.
"""
from pathlib import Path
import sys

src = Path(sys.argv[1]) / "src"
cpp = (src / "killprompt.cpp").read_text()
hdr = (src / "killprompt.h").read_text()


def body(text, marker):
    start = text.index("{", text.index(marker))
    depth = 1
    end = start + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start + 1:end - 1]


# Logical close must retire even if a reference keeps the Window alive. Context
# is the owned QProcess, never Window (which can outlive KillPrompt).
close = body(cpp, "QObject::connect(window, &Window::closed, &m_process,")
assert close.index("m_ownerClosed = true;") < close.index("quit();")
assert '"KillPrompt: owner closed; helper"' in close
start = body(cpp, "void KillPrompt::start(")
assert "m_ownerClosed || m_process.state() != QProcess::NotRunning" in start
assert start.index("return;") < start.index("m_quitRequested = false;")
# Close/pong during Starting is latched; a later started signal honors it.
late = body(cpp, "QObject::connect(&m_process, &QProcess::started, &m_process,")
assert "if (m_quitRequested)" in late and "m_process.terminate();" in late
quit = body(cpp, "void KillPrompt::quit()")
assert quit.index("if (m_quitRequested)") < quit.index("m_quitRequested = true;")
assert "if (m_process.state() == QProcess::Running)" in quit
assert "m_retirementTimer.start();" in quit
assert "m_process.terminate();" in quit
# Diagnostics separate close delivery, a failed start, and a still-live helper.
assert "&QProcess::errorOccurred, &m_process," in cpp
assert "&QProcess::finished, &m_process," in cpp
assert "helper still active after quit; ownerClosed" in cpp
assert "&QTimer::timeout, &m_process," in cpp
assert hdr.index("bool m_quitRequested") < hdr.index("QTimer m_retirementTimer") < hdr.index("QProcess m_process;")
for forbidden in ("waitFor", "::kill(", "pkill", "QProcess::execute", "QThread::sleep"):
    assert forbidden not in cpp, forbidden
# Confirm both protocols deliver close before their final reference release;
# existing pong/destructor quit paths must stay present.
x11 = (src / "x11window.cpp").read_text()
xdg = (src / "xdgshellwindow.cpp").read_text()
for text, marker in ((x11, "void X11Window::releaseWindow("),
                     (x11, "void X11Window::destroyWindow("),
                     (xdg, "void XdgSurfaceWindow::destroyWindow(")):
    method = body(text, marker)
    assert method.index("Q_EMIT closed();") < method.index("unref();")
assert "m_killPrompt->quit();" in body(x11, "X11Window::~X11Window()")
assert "m_killPrompt->quit();" in body(xdg, "XdgToplevelWindow::~XdgToplevelWindow()")
print("PASS: KillPrompt structural close/start/lifetime guards (NOT runtime validation)")
