package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The shell's terminals drawn by PowTerm's own terminal (ShellTermViews): its glue compiled from PowTerm's repo. */
class ShellTermViewsTest {
    @Test fun powtermsBridgeIsCompiledFromItsRepo() {
        // app/build.gradle.kts powtermJava: android-app-dev/projects/powterm's RemoteSessionBridge, not a copy here.
        val c = Class.forName("com.termux.terminal.RemoteSessionBridge")
        val methods = c.methods.map { it.name }.toSet()
        for (m in listOf("install", "readInput", "append", "close")) assert(m in methods) { "RemoteSessionBridge.$m missing" }
    }

    @Test fun pageColorsToArgb() {
        assertEquals(0x80112233.toInt(), ShellTermViews.parseColor("#11223380"))
        assertEquals(0x00000000, ShellTermViews.parseColor("#00000000"))
        assertNull(ShellTermViews.parseColor("rgb(1, 2, 3)"))
        assertNull(ShellTermViews.parseColor(null))
    }
}
