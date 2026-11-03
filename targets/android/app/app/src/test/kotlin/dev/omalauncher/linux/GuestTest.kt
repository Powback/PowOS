package dev.omalauncher.linux

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** PowOS's one choice of Linux (Guest): rooted unchanged, the image without root, a clear "needs" otherwise. */
class GuestTest {
    @After fun reset() {
        Guest.override = null
    }

    @Test fun rootWinsThenImageThenNone() {
        assertEquals(Guest.Kind.ROOTED, Guest.pick(rooted = true, engine = false))
        assertEquals(Guest.Kind.ROOTED, Guest.pick(rooted = true, engine = true))
        assertEquals(Guest.Kind.ENGINE, Guest.pick(rooted = false, engine = true))
        assertEquals(Guest.Kind.NONE, Guest.pick(rooted = false, engine = false))
    }

    @Test fun noLinuxSaysWhatsNeeded() {
        Guest.override = Guest.Kind.NONE
        assertEquals(Guest.NEEDS_IMAGE, Guest.unavailable())
        Guest.override = Guest.Kind.ENGINE
        assertNull(Guest.unavailable())
    }

    @Test fun rootedTerminalIsTheOldSuLine() {
        Guest.override = Guest.Kind.ROOTED
        assertEquals(RootedGuest.TERMINAL_SHELL, Guest.terminalShell)
        val t = Guest.terminal(null, mapOf("TERM" to "xterm-256color"))
        assertEquals("/system/bin/sh", t.executable)
        // Byte for byte what PtyTerminal and ShellTerminals ran before Guest.
        assertEquals(listOf("sh", "-c", "exec su -c " + shellQuote(RootedGuest.rootCommand(RootedGuest.TERMINAL_SHELL))), t.argv)
        assertEquals("xterm-256color", t.env["TERM"])
    }

    @Test fun imageTerminalFallsBackToALoginShell() {
        Guest.override = Guest.Kind.ENGINE
        assertEquals(Guest.ENGINE_TERMINAL_SHELL, Guest.terminalShell)
        assertTrue(Guest.terminalShell.contains("exec ${RootedGuest.TERMINAL_SHELL}"))
        assertTrue(Guest.terminalShell.endsWith("else exec bash -l; fi"))
    }

    @Test fun openTaskCommandUnchanged() {
        val exec = "steam steam://rungameid/1"
        val expected =
            "if command -v powos-open-task >/dev/null; then exec powos-open-task --app-id 'steam_app_1' -- ${shellQuote(exec)}; " +
                "else echo '${RootedGuest.OPEN_DESKTOP}'; ${RootedGuest.launchCommand("steam_app_1", exec)}; fi"
        assertEquals(expected, RootedGuest.openTaskCommand("steam_app_1", null, exec))
    }

    /**
     * Every PowOS Linux call site goes through Guest, so it works without root too; only the root-by-nature ones
     * (the rooted session's own bootstrap, the Android system theme, the verify queue, the desktop-shell hook) keep
     * calling RootedGuest directly.
     */
    @Test fun callSitesGoThroughGuest() {
        val root = File("src/main/kotlin/dev/omalauncher")
        val allowed =
            mapOf(
                "linux/RootedGuest.kt" to Int.MAX_VALUE,
                "linux/Guest.kt" to Int.MAX_VALUE,
                "linux/EngineGuest.kt" to Int.MAX_VALUE,
                "App.kt" to 1, // powos-desktop-shell: Plasma desktop mode, rooted only
                "Runtime.kt" to 1, // onRootedReady's keymap
                "shell/VerifyRun.kt" to 1, // the verify queue (rooted test phones)
                "theme/SystemTheme.kt" to 1, // Android's system colours: root by nature
            )
        val direct = Regex("""RootedGuest\.(run|runOwn|process|launch|openAsTask|TERMINAL_SHELL|rootCommand)\b""")
        val bad =
            root.walkTopDown().filter { it.extension == "kt" }.mapNotNull { f ->
                val rel = f.relativeTo(root).path
                val n = f.readLines().count { direct.containsMatchIn(it) && !it.trimStart().startsWith("*") && !it.trimStart().startsWith("//") }
                if (n > (allowed[rel] ?: 0)) "$rel: $n" else null
            }.toList()
        assertTrue("PowOS Linux calls past Guest (no root breaks them): $bad", bad.isEmpty())
        for (f in listOf("PowosAiChat.kt", "AgentMail.kt", "AgentsSpool.kt", "shell/ShellErrors.kt", "shell/ShellBridge.kt", "ui/PtyTerminal.kt", "shell/ShellTerminals.kt", "ui/TerminalTiles.kt", "PowosTerminalActivity.kt", "OpenPowosApp.kt")) {
            assertTrue("$f doesn't use Guest", Regex("""\bGuest\.""").containsMatchIn(File(root, f).readText()))
        }
    }
}
