package dev.omalauncher.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Issue #1: the voice servers come from the owner config only; a device without one dictates on-device. */
class OwnerConfigTest {
    @Test fun parsesTheOwnerConfigDeviceWrites() {
        val m =
            OwnerConfig.parse(
                "# The owner's settings\nPOWOS_STT_URL=http://stt.pow\nPOWOS_VOICE_URL='ws://voiceagent.pow/ws'\n" +
                    "POWOS_BOARD_REMOTE=docker exec x sh -c \"a '{cmd}'\"\n\nbroken line\n",
            )
        assertEquals("http://stt.pow", m["POWOS_STT_URL"])
        assertEquals("ws://voiceagent.pow/ws", m["POWOS_VOICE_URL"])
        assertEquals("docker exec x sh -c \"a '{cmd}'\"", m["POWOS_BOARD_REMOTE"])
        assertEquals(3, m.size)
    }

    @Test fun noOwnerConfigMeansOnDevice() {
        assertTrue(OwnerConfig.parse("").isEmpty())
        assertEquals(SpeechEngines.ON_DEVICE, SpeechEngines.engineFor(SpeechEngines.GPU, stt = false, voice = false))
        assertEquals(SpeechEngines.ON_DEVICE, SpeechEngines.engineFor(SpeechEngines.GPU_HTTP, stt = false, voice = true))
    }

    @Test fun theOwnersDevicesKeepTheirEngine() {
        assertEquals(SpeechEngines.GPU, SpeechEngines.engineFor(SpeechEngines.GPU, stt = true, voice = true))
        assertEquals(SpeechEngines.GPU, SpeechEngines.engineFor("anything", stt = true, voice = true))
        assertEquals(SpeechEngines.GPU_HTTP, SpeechEngines.engineFor(SpeechEngines.GPU_HTTP, stt = true, voice = true))
        assertEquals(SpeechEngines.ON_DEVICE, SpeechEngines.engineFor(SpeechEngines.ON_DEVICE, stt = true, voice = true))
    }

    @Test fun aTerminalEndingReasksOnlyWhenNotSignedIn() {
        val chat = dev.omalauncher.PowosAiChat
        assertTrue(chat.recheckAfterTerminal("signin"))
        assertTrue(chat.recheckAfterTerminal("relogin"))
        assertTrue(chat.recheckAfterTerminal(""))
        assertFalse(chat.recheckAfterTerminal("endpoint"))
        assertFalse(chat.recheckAfterTerminal("login"))
    }
}
