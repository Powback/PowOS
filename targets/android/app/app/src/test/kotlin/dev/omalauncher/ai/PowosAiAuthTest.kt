package dev.omalauncher.ai

import dev.omalauncher.PowosAiChat
import org.junit.Assert.assertEquals
import org.junit.Test

/** `powos manager --auth`'s word, as the AI page's sign-in state reads it (PowosAiChat.authWord). */
class PowosAiAuthTest {
    @Test
    fun theThreeWords() {
        assertEquals("endpoint", PowosAiChat.authWord("endpoint\n"))
        assertEquals("login", PowosAiChat.authWord("login"))
        assertEquals("signin", PowosAiChat.authWord("manager: installing Claude Code (first use)\nsignin\n\n"))
    }

    @Test
    fun anythingElseIsUnknown() {
        // An older image without --auth runs the manager's chat path or prints its usage: never a sign-in guess.
        assertEquals("", PowosAiChat.authWord(""))
        assertEquals("", PowosAiChat.authWord("usage: powos ai manager [-h]"))
        assertEquals("", PowosAiChat.authWord("{\"kind\": \"assistant\"}"))
    }
}
