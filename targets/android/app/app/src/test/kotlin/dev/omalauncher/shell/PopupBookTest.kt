package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * N3a (docs/WEB_WINDOWS.md "Native-glued windows", kwin 0063): KWin's "popup <id> <popup-id> x y w h" / "popup-gone"
 * for a Linux web window's popups (Steam's menus) and each popup buffer's arrival are recorded by [PopupBook], the
 * log-only consumer's record (PopupLog) that tools/phone/verify/ww-popups.sh reads from logcat.
 */
class PopupBookTest {
    private val screen = 2268 to 2440

    @Test
    fun aSteamMenuIsRecordedFromPopupToGone() {
        val b = PopupBook()
        // Steam's "Steam" menu, 312x445 at its button, as 0063 says it.
        assertEquals("popup 7 40 at 151,148 312x445 (#1)", b.popup(7, 40, PopupGeo(151, 148, 312, 445), 1_000))
        assertNull(b.insane(40, screen))
        assertEquals("popup 40 buffer #1 312x445 +16 ms", b.buffer(40, 312, 445, 1_016))
        for (i in 2 until PopupBook.EVERY) assertNull(b.buffer(40, 312, 445, 1_016L + i))
        assertNotNull(b.buffer(40, 312, 445, 2_000))
        assertEquals("popup 7 40 at 151,150 312x460 (#2)", b.popup(7, 40, PopupGeo(151, 150, 312, 460), 2_100))
        val gone = b.gone(7, 40, 3_000)
        assertEquals("popup-gone 7 40: ${PopupBook.EVERY} buffers, 2 msgs, 2000 ms, first buffer +16 ms", gone)
        assertTrue(b.live().isEmpty())
        assertEquals(40, b.gone.last().id)
    }

    @Test
    fun aMenuOutOfItsWindowIsSaneButNotOneAScreenAway() {
        val b = PopupBook()
        b.popup(7, 41, PopupGeo(-120, 1900, 400, 900), 0) // reaches out left and below the window: why it is its own surface
        assertNull(b.insane(41, screen))
        b.popup(7, 42, PopupGeo(151, 148, 0, 445), 0)
        assertTrue(b.insane(42, screen)!!.startsWith("empty"))
        b.popup(7, 43, PopupGeo(151, 148, 5000, 445), 0)
        assertTrue(b.insane(43, screen)!!.contains("larger than the screen"))
        b.popup(7, 44, PopupGeo(9000, 148, 312, 445), 0)
        assertTrue(b.insane(44, screen)!!.contains("a screen away"))
    }

    @Test
    fun strayLinesAreSaidNotDropped() {
        val b = PopupBook()
        assertEquals("popup-gone 7 50: never announced", b.gone(7, 50, 0))
        assertTrue(b.buffer(50, 10, 10, 0)!!.contains("after its popup-gone"))
        b.popup(7, 51, PopupGeo(0, 0, 10, 10), 0)
        assertEquals("popup 8 51 at 0,0 10x10 (#2) (was of 7)", b.popup(8, 51, PopupGeo(0, 0, 10, 10), 0))
        assertEquals("popup-gone 7 51: 0 buffers, 2 msgs, 5 ms, no buffer", b.gone(7, 51, 5))
    }

    @Test
    fun theHostAsksForPopupsAndRoutesKWinsLines() {
        // Wiring: the Linux consumer's start says "web <id> 1"; WindowTasks routes "popup"/"popup-gone" before a web
        // window's close forgets it; the bridge's host hands them to PopupLog.
        val src = File("src/main/kotlin/dev/omalauncher/shell")
        assertTrue(File(src, "WebWindows.kt").readText().contains("WebWindowSource.webPopups(kwin, andro.marchy.WebWindowSource.popupMode())"))
        val bridge = File(src, "ShellBridge.kt").readText()
        assertTrue(bridge.contains("popupLog.popup(parent, popup, geo)") && bridge.contains("popupLog.popupGone(parent, popup)"))
        val tasks = File("../engine/src/main/java/andro/marchy/WindowTasks.java").readText()
        assertTrue(tasks.indexOf("f[0].equals(\"popup-gone\")") in 0 until tasks.indexOf("if (f[0].equals(\"close\"))"))
        val source = File("../engine/src/main/java/andro/marchy/WebWindowSource.java").readText()
        assertTrue(source.contains("WindowTasks.kwinCan(\"web\")"))
    }
}
