package dev.omalauncher.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** Whisper's silence/noise junk goes; real speech, even speech mentioning subtitles or thanks, stays. */
class WhisperJunkTest {
    @Test fun creditsOnSilenceAreDropped() {
        for (t in listOf(
            "Субтитры создавал DimaTorzok",
            "Субтитры создавал DimaTorzok.",
            "Субтитры сделал DimaTorzok",
            "Редактор субтитров А.Семкин Корректор А.Егорова",
            "Продолжение следует...",
            "Thanks for watching!",
            "Subtitles by the Amara.org community",
            "Amara.org",
            "Thank you.",
            "you",
            "",
            "  ",
        )) assertEquals(t, "", WhisperJunk.clean(t))
    }

    @Test fun creditAfterRealSpeechIsCut() {
        assertEquals("Привет, как дела?", WhisperJunk.clean("Привет, как дела? Субтитры создавал DimaTorzok"))
        assertEquals("Call Mats tomorrow.", WhisperJunk.clean("Call Mats tomorrow. Thanks for watching!"))
    }

    @Test fun realSpeechPasses() {
        for (t in listOf(
            "Remind me to call Mats about the GPU server.",
            "Send it to Mats. Thank you.",
            "Bye for now, see you tomorrow.",
            "Как включить субтитры на телевизоре?",
            "Я читал, что субтитры создавал один человек, и это заняло у него целый год работы.",
            "Open amara dot org please.",
        )) assertEquals(t, t, WhisperJunk.clean(t))
    }
}
