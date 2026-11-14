package andro.marchy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * razr fold 11-14 "steam doesnt launch": the no-root launcher started Steam with WAYLAND_DISPLAY only, so its X11
 * windows had no display ("XOpenDisplay failed"). The guest env takes DISPLAY/XAUTHORITY from KWin, as rooted mode does.
 */
class XwaylandDisplayTest {
    private fun cmdline(vararg a: String) = a.joinToString("\u0000", postfix = "\u0000").toByteArray()

    // KWin as the engine runs it (razr's /proc/13226/cmdline): through the loader, the program as the next argument.
    private val kwin = cmdline(
        "/opt/lotfix/arch-glibc/ld-linux-aarch64.so.1", "/usr/bin/kwin_wayland",
        "--wayland-fd", "7", "--socket", "wayland-0", "--xwayland-fd", "8", "--xwayland-display", ":0",
        "--xwayland-xauthority", "/data/user/0/com.powos.app/files/run/xauth_doiOVQ", "--xwayland",
    )

    @Test
    fun kwinsXwaylandArgumentsGiveDisplayAndAuth() {
        assertEquals(
            mapOf("DISPLAY" to ":0", "XAUTHORITY" to "/data/user/0/com.powos.app/files/run/xauth_doiOVQ"),
            XwaylandDisplay.fromKwinCmdline(kwin),
        )
    }

    @Test
    fun otherProcessesGiveNothing() {
        // the wrapper has --xwayland but starts no X server itself; a script merely naming the flags isn't KWin
        assertTrue(XwaylandDisplay.fromKwinCmdline(cmdline("ld-linux-aarch64.so.1", "/usr/bin/kwin_wayland_wrapper", "--xwayland")).isEmpty())
        assertTrue(XwaylandDisplay.fromKwinCmdline(cmdline("/usr/bin/bash", "-c", "echo --xwayland-display :0")).isEmpty())
        assertTrue(XwaylandDisplay.fromKwinCmdline(cmdline("/usr/bin/kwin_wayland", "--socket", "wayland-0")).isEmpty())
        assertTrue(XwaylandDisplay.fromKwinCmdline(ByteArray(0)).isEmpty())
    }

    @Test
    fun findScansProcForTheRunningKwin() {
        val proc = Files.createTempDirectory("proc").toFile()
        try {
            File(proc, "self").mkdirs()
            File(proc, "12").apply { mkdirs() }.resolve("cmdline").writeBytes(cmdline("/usr/bin/bash", "-l"))
            File(proc, "13").mkdirs() // no cmdline readable: skipped
            File(proc, "14").apply { mkdirs() }.resolve("cmdline").writeBytes(kwin)
            assertEquals(":0", XwaylandDisplay.find(proc)["DISPLAY"])
            // a new session: the old KWin is gone, the new one has a new auth file
            File(proc, "14").deleteRecursively()
            File(proc, "99").apply { mkdirs() }.resolve("cmdline").writeBytes(
                cmdline("ld-linux-aarch64.so.1", "/usr/bin/kwin_wayland", "--xwayland-display", ":1", "--xwayland-xauthority", "/run/xauth_new"),
            )
            assertEquals(mapOf("DISPLAY" to ":1", "XAUTHORITY" to "/run/xauth_new"), XwaylandDisplay.find(proc))
            File(proc, "99").deleteRecursively()
            assertTrue(XwaylandDisplay.find(proc).isEmpty()) // no session: nothing, not a stale display
        } finally {
            proc.deleteRecursively()
        }
    }
}
