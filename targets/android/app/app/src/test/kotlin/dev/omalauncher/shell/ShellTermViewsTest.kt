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

    @Test fun theWholeSignInLinkOverItsRows() {
        // Claude Code's sign-in link, query string and all, laid over 3 rows of a 40-column terminal that only fill
        // the width (no wrap flag: tmux redraws with cursor moves) - the user 11-09: "it ends after the question mark".
        val url = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c&redirect_uri=https%3A%2F%2Fx&state=ab#c"
        val cols = 40
        val line = "  $url"
        val rows = listOf("Browser didn't open? Use the url below:") + line.chunked(cols) + listOf("", "Paste code here if prompted >")
        val wraps = rows.map { false }
        // A tap on its first row, on its last, and on the '?'.
        assertEquals(url, ShellTermViews.linkAt(rows, wraps, 1, 5, cols))
        assertEquals(url, ShellTermViews.linkAt(rows, wraps, 3, 2, cols))
        val q = line.indexOf('?')
        assertEquals(url, ShellTermViews.linkAt(rows, wraps, 1 + q / cols, q % cols, cols))
        // Not on it: the text before, the blank margin, the prompt.
        assertNull(ShellTermViews.linkAt(rows, wraps, 0, 3, cols))
        assertNull(ShellTermViews.linkAt(rows, wraps, 1, 0, cols))
        assertNull(ShellTermViews.linkAt(rows, wraps, 5, 3, cols))
    }

    @Test fun aFullRowContinuesAndPunctuationStaysOut() {
        val rows = listOf("see https://example.com/a?b=1", "&c=2).", "next")
        val flat = listOf(false, false, false)
        // 29 columns: the first row is full, so the link goes on; 40: it ends there.
        assertEquals("https://example.com/a?b=1&c=2", ShellTermViews.linkAt(rows, flat, 1, 1, 29))
        assertEquals("https://example.com/a?b=1", ShellTermViews.linkAt(rows, flat, 0, 6, 40))
        assertNull(ShellTermViews.linkAt(rows, flat, 1, 1, 40))
        assertEquals("https://en.wikipedia.org/wiki/A_(b)", ShellTermViews.trimLink("https://en.wikipedia.org/wiki/A_(b)."))
    }

    @Test fun pageColorsToArgb() {
        assertEquals(0x80112233.toInt(), ShellTermViews.parseColor("#11223380"))
        assertEquals(0x00000000, ShellTermViews.parseColor("#00000000"))
        assertNull(ShellTermViews.parseColor("rgb(1, 2, 3)"))
        assertNull(ShellTermViews.parseColor(null))
    }
}
