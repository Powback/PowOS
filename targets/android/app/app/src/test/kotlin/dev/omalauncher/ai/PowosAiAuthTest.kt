package dev.omalauncher.ai

import dev.omalauncher.ClaudeInstall
import dev.omalauncher.PowosAiChat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** `powos manager --auth`'s word, as the AI page's sign-in state reads it (PowosAiChat.authWord). */
class PowosAiAuthTest {
    @Test
    fun theThreeWords() {
        assertEquals("endpoint", PowosAiChat.authWord("endpoint\n"))
        assertEquals("login", PowosAiChat.authWord("login"))
        assertEquals("signin", PowosAiChat.authWord("manager: installing Claude Code (first use)\nsignin\n\n"))
    }

    /** Claude isn't installed (11-10, razr): the page's Install Claude, never Sign in to Claude. */
    @Test
    fun installIsItsOwnWord() {
        assertEquals("install", PowosAiChat.authWord("install\n"))
        assertEquals("install", PowosAiChat.authWord("manager: something on stderr\ninstall"))
    }

    /** The installer's output as the page's progress line: no colour codes, a redrawn bar's last frame, no blanks. */
    @Test
    fun installProgressLines() {
        assertEquals("[ai] Installing claude", ClaudeInstall.progressLine("\u001B[0;36m[ai]\u001B[0m Installing claude"))
        assertEquals("80%", ClaudeInstall.progressLine(" 10%\r 50%\r 80%\r"))
        assertNull(ClaudeInstall.progressLine("   "))
        assertNull(ClaudeInstall.progressLine("\u001B[0m"))
    }

    @Test
    fun anythingElseIsUnknown() {
        // An older image without --auth runs the manager's chat path or prints its usage: never a sign-in guess.
        assertEquals("", PowosAiChat.authWord(""))
        assertEquals("", PowosAiChat.authWord("usage: powos ai manager [-h]"))
        assertEquals("", PowosAiChat.authWord("{\"kind\": \"assistant\"}"))
    }
}
