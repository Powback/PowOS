package dev.omalauncher.ui

/**
 * What Whisper writes for silence or noise: the subtitle credits and sign-offs from its training video
 * ("Субтитры создавал DimaTorzok", "Thanks for watching", "Продолжение следует...", "Amara.org").
 *
 * stt.pow (whisper-fast) gives no per-segment `no_speech_prob` / `avg_logprob`, so the app can't drop segments
 * the model itself doubts; this list is the backstop. It removes a whole SENTENCE only when the sentence is one of
 * these and nothing else (a credit line, at most [MAX_WORDS] words), so real speech that only mentions them stays.
 * Add a phrase here only after seeing it on silence in the logs (`session #n (gpu)` lines).
 */
internal object WhisperJunk {
    /** Junk only as the WHOLE answer: people do say these at the end of real speech. */
    private val alone = setOf("thank you", "you", "bye", "спасибо")

    /** A sentence that is only this, in full (lowercase, without its end punctuation). */
    private val whole =
        setOf(
            "thanks for watching", "thank you for watching", "продолжение следует", "спасибо за просмотр", "подписывайтесь на канал", "ставьте лайки",
            "danke fürs zuschauen", "untertitel im auftrag des zdf", "sous-titrage st' 501",
        )

    /** A sentence that starts like a credit line (anything after it is the name). */
    private val credit =
        Regex(
            "^(" +
                "субтитры (сделал|сделала|сделаны|создавал|создавала|создал|создала|подготовил|подготовила|делал|делала|делали|подогнал|выполнил)" +
                "|субтитры by|субтитры:|редактор субтитров|корректор субтитров|автор субтитров" +
                "|subtitles by|subtitled by|transcribed by|captions by|transcription by" +
                "|untertitel (von|der|im auftrag)|sous-titres (réalisés|par)" +
                ")",
        )

    /** Credit names Whisper prints on their own. */
    private val names = Regex("(dimatorzok|amara\\.org|a\\.semkin|a\\.egorova|а\\.семкин|а\\.егорова|elena kurbanova)")

    private const val MAX_WORDS = 8
    private val SENTENCE_END = Regex("(?<=[.!?…])\\s+")

    fun junk(sentence: String): Boolean {
        val s = sentence.trim().lowercase().trimEnd('.', '!', '?', '…', ' ')
        if (s.isEmpty()) return true
        if (s in whole) return true
        if (s.split(Regex("\\s+")).size > MAX_WORDS) return false
        return credit.containsMatchIn(s) || names.containsMatchIn(s)
    }

    /** [text] without its junk sentences ("" when it was all junk). */
    fun clean(text: String): String {
        val t = text.trim()
        if (t.isEmpty() || t.lowercase().trimEnd('.', '!', '?', '…', ' ') in alone) return ""
        // Sentences end at punctuation followed by a space: "Amara.org" and "A.Semkin" stay whole.
        return t.split(SENTENCE_END).filterNot { junk(it) }.joinToString(" ").trim()
    }
}
