package dev.omalauncher.ai

import dev.omalauncher.ClaudeSignIn
import dev.omalauncher.PowosAiChat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The native Claude sign-in's protocol with `powos manager --fleet-login login` (fleet_login.py) and its words. */
class ClaudeSignInTest {
    @Test
    fun theLinkThenDone() {
        // authority: /oauth/start's answer; direct: claude-login's URL - both the same line shape.
        val link = ClaudeSignIn.event("""{"ok": true, "tenant": "powback", "authorizeUrl": "https://claude.com/cai/oauth/authorize?x=1"}""")
        assertEquals("https://claude.com/cai/oauth/authorize?x=1", link?.url)
        assertTrue(ClaudeSignIn.event("""{"ok": true, "tenant": "powback", "done": true}""")!!.done)
    }

    @Test
    fun errorsComeBackInTheirWords() {
        assertEquals("invalid code", ClaudeSignIn.event("""{"ok": false, "error": "invalid code"}""")?.error)
        assertEquals("sign-in failed", ClaudeSignIn.event("""{"ok": false}""")?.error)
    }

    @Test
    fun aLoginThatEndsSaysWhyFromItsStderr() {
        // The non-root razr's old image (11-09): `powos manager` had no --fleet-login and ended with this on stderr.
        assertEquals(
            "the sign-in stopped: not signed in to Claude (powos manager --signin)",
            ClaudeSignIn.stoppedMessage("manager: not signed in to Claude (powos manager --signin)"),
        )
        assertEquals("the sign-in stopped - try again", ClaudeSignIn.stoppedMessage("  "))
    }

    @Test
    fun anythingElseIsIgnored() {
        assertNull(ClaudeSignIn.event(""))
        assertNull(ClaudeSignIn.event("manager: installing Claude Code (first use)"))
        // Only an https link is ever opened.
        assertNull(ClaudeSignIn.event("""{"ok": true, "authorizeUrl": "intent://evil"}"""))
    }

    @Test
    fun titleNamesTheTenant() {
        assertEquals("Claude sign-in needed - powback", ClaudeSignIn.title("powback"))
        assertEquals("Claude sign-in needed", ClaudeSignIn.title(""))
        assertEquals("Claude sign-in needed", ClaudeSignIn.title("null"))
        assertTrue(ClaudeSignIn.notificationText("refresh").contains("expired"))
        assertTrue(ClaudeSignIn.notificationText("missing").contains("aren't signed in"))
    }

    @Test
    fun reloginIsAnAuthWord() {
        assertEquals("relogin", PowosAiChat.authWord("relogin\n"))
    }
}
