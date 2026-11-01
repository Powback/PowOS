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
}
