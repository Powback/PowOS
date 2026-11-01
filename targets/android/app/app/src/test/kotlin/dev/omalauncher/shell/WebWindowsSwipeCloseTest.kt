package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Board swiping-a-game-or-linux-app-away-in-the-switcher (X1/X2): a Linux window's card swiped away closes the app,
 * not just its card. X1: the swipe (Tasks.remove of the card's id) closes that one web window by its bar's close path,
 * which tells KWin "quit" for that KWin window. X2: KWin closes it and ~3 s later, if that window's own pid still runs,
 * runs powos-app-quit on that pid only (its tree / its Steam game's launch chain; never Steam or another app).
 */
class WebWindowsSwipeCloseTest {
    private val src = File("src/main/kotlin/dev/omalauncher/shell/WebWindows.kt").readText()
    private val kwin = File("../../pkgs/kwin/0042-backends-anland-a-task-the-user-closes-quits-its-app.patch").readText()
    private val quit = File("../../session/powos-app-quit").readText()
    private val source = File("../engine/src/main/java/andro/marchy/WebWindowSource.java").readText()
    private val closeAfterQuit = File("../../pkgs/kwin/0050-backends-anland-a-quit-task-s-window-says-close-when-it-goes.patch").readText()

    private fun body(start: String) = src.substringAfter(start).substringBefore("\n        }\n\n")

    @Test
    fun cardIdsMapToTheirOwnWindowOnly() {
        assertEquals(7, WebWindows.linuxCardWindow(WebWindows.LINUX_CARD + 7))
        assertEquals(0, WebWindows.linuxCardWindow(WebWindows.LINUX_CARD))
        // An Android task's card: not a Linux window's (its swipe stays Android's removeTask).
        assertNull(WebWindows.linuxCardWindow(1234))
        assertNull(WebWindows.linuxCardWindow(WebWindows.LINUX_CARD - 1))
    }

    @Test
    fun aUserCloseQuitsAHandBackOrKwinsOwnCloseDoesNot() {
        assertEquals(WebWindows.LinuxGoes.QUIT, WebWindows.linuxGoes(kwinClosed = false, handBack = false))
        assertEquals(WebWindows.LinuxGoes.HAND_BACK, WebWindows.linuxGoes(kwinClosed = false, handBack = true))
        assertEquals(WebWindows.LinuxGoes.GONE, WebWindows.linuxGoes(kwinClosed = true, handBack = false))
        assertEquals(WebWindows.LinuxGoes.GONE, WebWindows.linuxGoes(kwinClosed = true, handBack = true))
    }

    @Test
    fun theSwipeClosesThatWindowThroughTheQuitPath() {
        val forTask = body("fun closeForTask(")
        assertTrue("a Linux card's removal closes its own window", forTask.contains("linuxCardWindow(taskId)?.let { id ->"))
        assertTrue("by the bar's close (drop without handBack)", forTask.contains("ww.close(id)"))
        val close = src.substringAfter("fun close(id: Int): Boolean {").substringBefore("\n    }\n")
        assertTrue(close.contains("drop(w)") && !close.contains("handBack = true"))
        val dropLinux = src.substringAfter("private fun dropLinux(").substringBefore("\n    }\n")
        assertTrue(dropLinux.contains("LinuxGoes.QUIT -> andro.marchy.WebWindowSource.quit(context, src.kwin)"))
    }

    @Test
    fun kwinEscalatesAfter3sOnThatWindowsPidOnly() {
        assertTrue("X1: the window's own close first", kwin.contains("window->closeWindow();"))
        assertTrue("its pid, taken before the close", kwin.contains("window->pid()"))
        assertTrue("X2: ~3 s later", kwin.contains("QTimer::singleShot(3000"))
        assertTrue("only if that pid still runs", kwin.contains("::kill(pid, 0) != 0 && errno == ESRCH"))
        assertTrue("left running with other windows of its own", kwin.contains("has other windows"))
        assertTrue("that pid alone handed on", kwin.contains("QStringLiteral(\"powos-app-quit\"), {QString::number(pid)}"))
        assertTrue("never KWin itself", kwin.contains("pid == ::getpid()"))
    }

    @Test
    fun powosAppQuitEndsOnlyThatTreeNeverSteamOrTheSession() {
        // The tree is the pid's own descendants (a Steam game's: from its own launch's SteamLaunch AppId root).
        assertTrue(quit.contains("tree=\$(ps -e -o pid=,ppid="))
        assertTrue(quit.contains("SteamLaunch\\ AppId=([0-9]+)"))
        for (name in listOf(" steam ", " steamwebhelper ", " kwin_wayland ", " Xwayland ", " plasmashell ", " FEXServer ")) {
            assertTrue("$name protected", quit.contains(name) || quit.contains(name.trimEnd() + "\n"))
        }
        assertTrue("never another user's", quit.contains("stat -c %u"))
        assertTrue("never by name globally", !quit.contains("pkill") && !quit.contains("killall"))
    }

    /**
     * The ship gate's hidden Linux check (11-01 16:43-16:55, 3 FAILs "KWin window 19 wasn't closed after the quit"):
     * after a quit, KWin's "close" never reached the selftest - KWin removed the task before closing (no close hook
     * left) and the app forgot the id at the quit (a later close went nowhere). Now KWin says "close" once the window
     * goes (0050) and a quit id stays routed to the host until it does.
     */
    @Test
    fun aQuitWindowsCloseStillReachesTheHost() {
        val q = source.substringAfter("public static void quit(").substringBefore("\n    }\n")
        assertTrue("the quit id is kept for its close", q.contains("quitting.add(id);"))
        assertTrue(source.contains("return ids.contains(id) || quitting.contains(id);"))
        val closed = source.substringAfter("static void closed(int id) {").substringBefore("\n    }\n")
        assertTrue(closed.contains("quitting.remove(id);") && closed.contains("h.closed(id)"))
        assertTrue("KWin: close once the quit window goes", closeAfterQuit.contains("+    connect(window, &Window::closed, this, [this, id]() {"))
        assertTrue(closeAfterQuit.contains("+        send({QStringLiteral(\"close\"), QString::number(id)});"))
        assertTrue(File("../../pkgs/kwin/PKGBUILD").readText().contains("0050-backends-anland-a-quit-task-s-window-says-close-when-it-goes.patch"))
    }

    @Test
    fun theSelftestsWindowOfferedAgainStaysOffThePage() {
        assertTrue(WebWindows.selftestOwns(selftestKwin = 19, kwin = 19))
        assertTrue(!WebWindows.selftestOwns(selftestKwin = 19, kwin = 20))
        assertTrue("none taken yet", !WebWindows.selftestOwns(selftestKwin = -1, kwin = -1))
        val opened = src.substringAfter("fun linuxOpened(").substringBefore("\n    }\n")
        assertTrue(opened.indexOf("selftestOwns(t.kwin, kwin)") in 0 until opened.indexOf("pendingLinux[kwin] = offer"))
    }
}
