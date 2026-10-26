package dev.omalauncher.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The dictation rules: pauses don't end it, a held mic only ends when let go, a tap's after 4 s of nothing heard. */
class SpeechDictationTest {
    private var now = 0L

    private fun dictation(hold: Boolean) = Dictation(hold, 4000) { now }

    /** A 30+ s utterance with pauses, the way Android's recognizer cuts it: one segment per pause. */
    private val talk =
        listOf(
            // (ms after the last event, partials, final)
            Triple(300L, listOf("remind me", "remind me to call"), "remind me to call Mats"),
            Triple(2500L, listOf("about the", "about the GPU server"), "about the GPU server"),
            Triple(3500L, listOf("and tell him"), "and tell him the transcription works"),
            Triple(1200L, listOf("on the phone"), "on the phone and the desktop"),
            Triple(3900L, listOf("also"), ""), // a final that came back empty: the partial stays
            Triple(2000L, listOf("buy milk"), "buy milk tomorrow"),
        )

    private fun speak(d: Dictation): List<Boolean> =
        talk.map { (gap, partials, final) ->
            now += gap
            d.voice()
            for (p in partials) {
                now += 400
                d.partial(p)
            }
            now += 600
            d.segment(final)
            d.goOn()
        }

    @Test
    fun tapGoesOnThroughPausesUnderFourSeconds() {
        val d = dictation(hold = false)
        assertEquals(List(talk.size) { true }, speak(d))
        assertEquals(
            "remind me to call Mats about the GPU server and tell him the transcription works on the phone and the desktop also buy milk tomorrow",
            d.text,
        )
        assertTrue(now > 20_000)
    }

    @Test
    fun tapEndsAfterFourSecondsOfSilence() {
        val d = dictation(hold = false)
        speak(d)
        now += 3900
        assertFalse(d.silent())
        assertTrue(d.goOn())
        now += 200
        assertTrue(d.silent())
        assertFalse(d.goOn())
    }

    @Test
    fun holdNeverEndsOnSilenceOnlyWhenStopped() {
        val d = dictation(hold = true)
        speak(d)
        now += 60_000
        assertFalse(d.silent())
        assertTrue(d.goOn())
        d.stopping = true
        assertFalse(d.goOn())
    }

    @Test
    fun letGoTurnsAHoldIntoATap() {
        val d = dictation(hold = true)
        speak(d)
        d.hold = false
        now += 4100
        assertTrue(d.silent())
    }

    @Test
    fun tappedAgainEndsAtOnce() {
        val d = dictation(hold = false)
        d.partial("hello")
        d.stopping = true
        assertFalse(d.goOn())
        assertFalse(d.silent())
        d.segment("hello there")
        assertEquals("hello there", d.text)
    }

    @Test
    fun repeatedPartialsDoNotCountAsVoice() {
        val d = dictation(hold = false)
        d.partial("same")
        now += 2000
        d.partial("same")
        now += 2100
        assertTrue(d.silent())
    }

    @Test
    fun partialsShowAfterFinishedSegments() {
        val d = dictation(hold = false)
        d.segment("first part")
        d.partial("second")
        assertEquals("first part second", d.text)
    }

    /** A GPU dictation's fallback after the release: its recording ended, so the recognizer doesn't listen again. */
    @Test
    fun anEndedRecordingEndsTheDictationEvenHeld() {
        val d = dictation(hold = true)
        assertTrue(d.goOn(feedDone = false))
        assertFalse(d.goOn(feedDone = true))
        d.stopping = true
        assertFalse(d.goOn(feedDone = false))
    }
}
