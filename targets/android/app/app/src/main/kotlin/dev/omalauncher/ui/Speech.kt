package dev.omalauncher.ui

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.Locale

/**
 * Speech to text for the prompt bar (one per bridge window). The guest has no microphone, so speech becomes text
 * here and only text reaches Linux. The recognizing is [NativeSpeech]'s, shared by every window of the app: one
 * session at a time, the latest start wins. Main thread only, like SpeechRecognizer.
 */
class Speech(
    private val context: Context,
    /** Which window it is (home, pull, assist, ...): in the log of every start, stop and cancel. */
    private val who: () -> String = { "?" },
) {
    var listening by mutableStateOf(false)
        private set

    /** What's been recognized so far: finished segments plus the current partial result. */
    var text by mutableStateOf("")
        private set

    /** Input loudness, 0..1. */
    var level by mutableFloatStateOf(0f)
        private set

    /** Why recognition failed; the UI clears it once shown. */
    var error by mutableStateOf<String?>(null)

    /** Bumped when another window's start ended this one's dictation (the page drops it: speech.cancelled). */
    var superseded by mutableIntStateOf(0)
        private set

    private var session: SpeechSession? = null
        set(v) {
            field = v
            if (v != null) owner = this else if (owner === this) owner = null
        }

    /** Another window's dictation is under way (its mic is the one on): a tap on this one's mic ends it. */
    val elsewhere get() = owner.let { it != null && it !== this }

    val available get() = NativeSpeech.available(context)

    /**
     * Starts listening; [onDone] gets the full text (maybe empty) once recognition ends.
     * With [hold], it keeps listening across pauses until [stop] or [letGo].
     */
    fun start(
        hold: Boolean,
        onDone: (String) -> Unit,
    ) {
        cancel()
        error = null
        if (!available) {
            error = "no speech recognizer on this phone"
            return
        }
        text = ""
        listening = true
        var mine: SpeechSession? = null
        val callbacks =
            SpeechCallbacks(
                onText = { if (session === mine) text = it },
                onLevel = { if (session === mine) level = it },
                onSuperseded = {
                    if (session === mine) {
                        session = null
                        listening = false
                        level = 0f
                        superseded++
                    }
                },
                onEnd = { heard, why ->
                    if (session === mine) {
                        session = null
                        listening = false
                        level = 0f
                        text = heard
                        // Keep what was already recognized; the error is only worth showing when there's nothing.
                        if (why != null && heard.isBlank()) error = why
                        onDone(heard)
                    }
                },
            )
        // Which engine (Settings > voice > transcription): stt.pow on the GPU box, or Android's own (GpuSpeech.kt).
        mine = SpeechEngines.start(context, hold, callbacks, who())
        session = mine
    }

    /**
     * Ends recognition now; the text so far goes to onDone. Not listening here, it ends the one another window started
     * (the launcher overlay over home's dictation: its mic shows the dictation and a tap there ends it, AO3).
     */
    fun stop() {
        Log.i("speech", "stop by ${who()}${if (session == null) " (another window's)" else ""}")
        (session ?: SpeechEngines.current)?.stop()
    }

    /** Keeps listening, but ends after a tap's silence instead of at [stop]. */
    fun letGo() {
        session?.letGo()
    }

    /** A tap's dictation becomes a hold's (the press that started it is still down): it ends only at [stop]. */
    fun hold() {
        session?.hold()
    }

    /** A tap's dictation ends after [ms] with nothing heard instead of the usual ~4 s (the side button's quick ask). */
    fun quiet(ms: Long) {
        session?.quiet(ms)
    }

    /** Binds the recognizer and works out its plan, without listening, so a press starts at once. */
    fun warm() = SpeechEngines.warm(context)

    /** Ends recognition without calling onDone. */
    fun cancel() {
        val s = session
        if (s != null) Log.i("speech", "cancel by ${who()}")
        session = null
        s?.cancel()
        listening = false
        level = 0f
    }
}

/** The window whose dictation is under way (at most one: SpeechEngines), or null. */
private var owner by mutableStateOf<Speech?>(null)

/** One recognition, from start to its end (onEnd, exactly once, unless cancelled). */
interface SpeechSession {
    /** Ends now: what's been heard goes to onEnd. */
    fun stop()

    /** Ends after a tap's silence instead of at [stop]. */
    fun letGo()

    /** Ends only at [stop] (a press still held). */
    fun hold()

    /** Ends after [ms] with nothing heard (a tap's). */
    fun quiet(ms: Long)

    /** Ends without onEnd. */
    fun cancel()
}

class SpeechCallbacks(
    val onText: (String) -> Unit,
    val onLevel: (Float) -> Unit,
    /** The whole text (maybe empty) and why it failed, if it did. */
    val onEnd: (String, String?) -> Unit,
    /** Which engine it runs on now (SpeechEngines.GPU / ON_DEVICE): at its start, and again on a fallback. */
    val onEngine: (String) -> Unit = {},
    /** A newer start (any window's) ended it: no onEnd comes. */
    val onSuperseded: () -> Unit = {},
)

/**
 * Android's speech recognizers, for the whole app process (every bridge window, and PowosRecognitionService's choice
 * of the real recognizer). One recognizer per kind, created once and reused across segments and sessions, instead of
 * one created and destroyed per listen: two live recognizers of one app are two sessions of one caller in
 * system_server ("#startListening called while listening is in progress for this caller"), and a recognizer
 * destroyed right after its support check drops its connection ("Connection to speech recognition service lost").
 *
 * Which recognizer and language ([Plan]): checked once (cached a few minutes) against what each recognizer has
 * a model for. On-device (Android System Intelligence) when it has the phone's language installed; else the system's
 * default recognizer (explicitly its component, never PowOS's own forwarding service), offline only when its offline
 * model is installed, online otherwise. Asking it for offline without a downloaded pack failed every time as
 * LANGUAGE_PACK_ERROR (13, "speech isn't available in this language", even in English): the pack download is
 * requested once, and online recognition is used until it's there.
 */
internal object NativeSpeech {
    private const val TAG = "speech"
    private const val PLAN_TTL_MS = 5 * 60_000L
    private const val MAX_RETRIES = 2

    /** A tap's dictation ends after this long with nothing new heard (a hold's only when let go). */
    const val TAP_SILENCE_MS = 4000L

    /** No dictation listens longer than this (a hold whose release never came: the mic mustn't stay open). */
    private const val MAX_SESSION_MS = 5 * 60_000L

    /** After stopListening, the final result's wait at most. */
    private const val STOP_GRACE_MS = 2000L

    /** The silence after which a recognizer may consider an utterance complete (most ignore it; Google's may not). */
    private const val UTTERANCE_SILENCE_MS = 3000L

    /** A segmented session's minimum length: the session lasts until stopped, its pauses only end segments. */
    private const val SESSION_MIN_MS = 30 * 60_000L

    /**
     * Listening with no callback at all (no RMS, no ready, no results) for this long: the recognizer is wedged (its
     * session stuck in system_server or the service), so it's destroyed and a new one listens. A live mic reports RMS
     * many times a second, so this never fires on a working session, silent room or not.
     */
    private const val STALL_MS = 6000L

    /** How a recognizer that can't do what the intent asks refuses it (before hearing anything). */
    private val REFUSALS = setOf(SpeechRecognizer.ERROR_CLIENT, SpeechRecognizer.ERROR_SERVER, SpeechRecognizer.ERROR_SERVER_DISCONNECTED)

    /** The recognizer refused segmented sessions: plain sessions, restarted at each pause, from then on. */
    private var segmentedOff = false
    private var segmentedRefusals = 0
    private var segmentsSeen = false

    private enum class Kind { ON_DEVICE, REGULAR }

    private data class Plan(
        val kind: Kind,
        val language: String?,
        val offline: Boolean,
    )

    private val main = Handler(Looper.getMainLooper())
    private var plan: Plan? = null
    private var planAt = 0L
    private var onDevice: SpeechRecognizer? = null
    private var regular: SpeechRecognizer? = null
    private var regularComponent: ComponentName? = null
    private var active: Session? = null
    private var downloadAsked = false
    private var sessionIds = 0

    private fun onDeviceAvailable(c: Context) = lookup(c).onDevice

    /** The recognizers' package manager / settings lookups ([onDeviceAvailable], [regularService]) at one time. */
    private class Lookup(
        val onDevice: Boolean,
        val service: ComponentName?,
        val at: Long,
    )

    @Volatile private var lookedUp: Lookup? = null

    /**
     * [Lookup], kept [LOOKUP_TTL_MS]: binder calls into the package manager - [warm] makes them off the main thread so
     * the main thread's support check and press find them done (a recognizer installed or switched is seen within it).
     */
    private fun lookup(c: Context): Lookup =
        lookedUp?.takeIf { System.currentTimeMillis() - it.at < LOOKUP_TTL_MS }
            ?: Lookup(
                Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(c),
                findRegularService(c),
                System.currentTimeMillis(),
            ).also { lookedUp = it }

    private const val LOOKUP_TTL_MS = 60_000L

    fun available(c: Context) = onDeviceAvailable(c) || regularService(c) != null

    /**
     * The phone's default recognition service (Settings.Secure voice_recognition_service), unless that's PowOS's own
     * forwarding service or missing: then the first other one installed, Google's speech services first.
     */
    fun regularService(c: Context): ComponentName? = lookup(c).service

    private fun findRegularService(c: Context): ComponentName? {
        val installed =
            c.packageManager
                .queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0)
                .map { ComponentName(it.serviceInfo.packageName, it.serviceInfo.name) }
                .filter { it.packageName != c.packageName }
        val default =
            runCatching { Settings.Secure.getString(c.contentResolver, "voice_recognition_service") }
                .getOrNull()
                ?.let(ComponentName::unflattenFromString)
        return default?.takeIf { it in installed }
            ?: installed.firstOrNull { it.packageName == "com.google.android.tts" }
            ?: installed.firstOrNull()
    }

    fun start(
        c: Context,
        hold: Boolean,
        callbacks: SpeechCallbacks,
        /** Audio from PowOS's own recording (a GPU dictation's fallback, replayed): the recognizer reads it, not the mic. */
        feed: AudioFeed? = null,
    ): SpeechSession {
        active?.let {
            Log.i(TAG, "session #${it.id}: superseded by a new start")
            it.cancel()
        }
        val s = Session(++sessionIds, c.applicationContext, hold, callbacks, feed)
        Log.i(TAG, "session #${s.id}: start (${if (hold) "hold" else "tap"})")
        active = s
        // Never synchronously: the caller holds the session before any of its callbacks.
        main.post { if (active === s) withPlan(s.c) { p -> if (active === s) s.listen(p) } }
        return s
    }

    private fun recognizer(
        c: Context,
        kind: Kind,
    ): SpeechRecognizer =
        when (kind) {
            Kind.ON_DEVICE ->
                onDevice
                    ?: (if (Build.VERSION.SDK_INT >= 31) SpeechRecognizer.createOnDeviceSpeechRecognizer(c) else error("no on-device recognizer"))
                        .also {
                            Log.i(TAG, "recognizer: created ON_DEVICE")
                            onDevice = it
                        }
            Kind.REGULAR -> {
                val component = regularService(c)
                regular?.takeIf { component == regularComponent }
                    ?: run {
                        regular?.destroy()
                        Log.i(TAG, "recognizer: ${component?.flattenToShortString() ?: "the system default"}")
                        (if (component != null) SpeechRecognizer.createSpeechRecognizer(c, component) else SpeechRecognizer.createSpeechRecognizer(c))
                            .also {
                                regular = it
                                regularComponent = component
                            }
                    }
            }
        }

    /** A recognizer that misbehaved (busy, disconnected, client error, stalled): destroyed; the next use gets a new one. */
    private fun drop(
        kind: Kind,
        why: String,
    ) {
        val r =
            when (kind) {
                Kind.ON_DEVICE -> onDevice.also { onDevice = null }
                Kind.REGULAR -> regular.also { regular = null }
            } ?: return
        Log.i(TAG, "recognizer: destroyed $kind ($why)")
        runCatching { r.destroy() }.onFailure { Log.w(TAG, "destroy $kind", it) }
    }

    private fun intent(
        p: Plan?,
        feed: AudioFeed? = null,
    ) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            .apply {
                if (p?.offline == true) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                p?.language?.let { putExtra(RecognizerIntent.EXTRA_LANGUAGE, it) }
                if (p == null) return@apply
                // From PowOS's own recording (16 kHz mono PCM, a pipe per listen) instead of the mic (API 33+).
                if (feed != null && Build.VERSION.SDK_INT >= 33) {
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, feed.open())
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, android.media.AudioFormat.ENCODING_PCM_16BIT)
                    putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, SttServer.RATE)
                }
                // Longer pauses before a segment ends (where the recognizer honours it).
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, UTTERANCE_SILENCE_MS)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, UTTERANCE_SILENCE_MS)
                // One session for the whole dictation, pauses ending only segments (onSegmentResults), until stopped.
                if (Build.VERSION.SDK_INT >= 33 && !segmentedOff) {
                    putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS)
                    putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, SESSION_MIN_MS)
                }
            }

    /**
     * The plan, at once when there is one (a stale one too: it's checked again in the background for next time, so a
     * press never waits for the support checks); else after them.
     */
    private fun withPlan(
        c: Context,
        then: (Plan) -> Unit,
    ) {
        val known = plan
        if (known != null) {
            then(known)
            if (System.currentTimeMillis() - planAt >= PLAN_TTL_MS) main.post { refresh(c) {} }
            return
        }
        refresh(c, then)
    }

    private var refreshing = false

    private fun refresh(
        c: Context,
        then: (Plan) -> Unit,
    ) {
        if (Build.VERSION.SDK_INT < 33) return then(remember(Plan(Kind.REGULAR, null, false)))
        if (refreshing && plan != null) return then(plan!!)
        refreshing = true
        support(c, Kind.ON_DEVICE) { onDev ->
            support(c, Kind.REGULAR) { reg ->
                refreshing = false
                then(remember(decide(c, onDev, reg)))
            }
        }
    }

    /**
     * Ready for a press: the recognizer created and bound (its support check binds it) and the plan worked out -
     * nothing listens, the mic stays closed. Cheap when it's been done: the plan is cached.
     */
    fun warm(c: Context) {
        if (active != null) return
        // Called off the main thread (ShellBridge's lookups): the package manager lookups here; the recognizer's
        // creation and binding (main thread only, SpeechRecognizer) when the main thread is idle, not mid-frame.
        lookup(c.applicationContext)
        Looper.getMainLooper().queue.addIdleHandler {
            if (active == null && (plan == null || System.currentTimeMillis() - planAt >= PLAN_TTL_MS)) refresh(c.applicationContext) {}
            false
        }
    }

    private fun remember(p: Plan): Plan {
        plan = p
        planAt = System.currentTimeMillis()
        Log.i(TAG, "plan: $p")
        return p
    }

    /** What [kind]'s recognizer has models for (null: it can't say, or there's none). */
    private fun support(
        c: Context,
        kind: Kind,
        then: (RecognitionSupport?) -> Unit,
    ) {
        if (Build.VERSION.SDK_INT < 33 || (kind == Kind.ON_DEVICE && !onDeviceAvailable(c))) return then(null)
        var answered = false
        val once = { s: RecognitionSupport? ->
            if (!answered) {
                answered = true
                then(s)
            }
        }
        // A recognizer that never answers mustn't keep the mic button waiting.
        main.postDelayed({ once(null) }, 1500)
        runCatching {
            recognizer(c, kind).checkRecognitionSupport(
                intent(null),
                c.mainExecutor,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) = once(support)

                    override fun onError(error: Int) {
                        Log.i(TAG, "$kind support check failed ($error)")
                        once(null)
                    }
                },
            )
        }.onFailure {
            Log.w(TAG, "$kind support check", it)
            once(null)
        }
    }

    @androidx.annotation.RequiresApi(33)
    private fun decide(
        c: Context,
        onDev: RecognitionSupport?,
        reg: RecognitionSupport?,
    ): Plan {
        Log.i(TAG, "on-device installed ${onDev?.installedOnDeviceLanguages}; regular installed ${reg?.installedOnDeviceLanguages}, online ${reg?.onlineLanguages?.size}")
        if (System.currentTimeMillis() > onDeviceBusyUntil) {
            onDev?.let { closest(listOf(it.installedOnDeviceLanguages)) }?.let { return Plan(Kind.ON_DEVICE, it, true) }
        }
        reg?.let { closest(listOf(it.installedOnDeviceLanguages)) }?.let { return Plan(Kind.REGULAR, it, true) }
        // No offline model (or a recognizer that can't say - Speech Services by Google answers the support check with
        // ERROR_CANNOT_CHECK_SUPPORT): ask both recognizers once for the language's model; it downloads in the
        // background. Offline is faster to start and works without a network.
        val language = reg?.let { closest(listOf(it.pendingOnDeviceLanguages, it.supportedOnDeviceLanguages, it.onlineLanguages)) } ?: fallbackLanguage()
        if (!downloadAsked) {
            downloadAsked = true
            download(c, Kind.REGULAR, language)
            onDev?.let { closest(listOf(it.pendingOnDeviceLanguages, it.supportedOnDeviceLanguages)) }?.let { download(c, Kind.ON_DEVICE, it) }
        }
        // A recognizer that can't say what it has: try its offline model (a missing one fails at once, ~50 ms, and
        // online takes over - LANGUAGE_UNAVAILABLE below), unless that failed lately.
        val guessOffline = reg == null && System.currentTimeMillis() > offlineMissingUntil
        val online = reg?.let { closest(listOf(it.onlineLanguages)) }
        return Plan(Kind.REGULAR, online ?: language, guessOffline)
    }

    /**
     * Until when the on-device recognizer is known to be full: Android System Intelligence takes one session at a time
     * ("#startListening received when the service's capacity is full"), and a session that never ended there (one of
     * ours before 2026-10-21's fix, or its own) refuses every start as BUSY, whatever recognizer object asks. Meanwhile
     * the regular recognizer listens.
     */
    private var onDeviceBusyUntil = 0L

    /** Until when the regular recognizer's offline model is known to be missing (a failed offline try). */
    private var offlineMissingUntil = 0L

    /** Asks [kind]'s recognizer to download its model for [language]; when it's there, the plan is worked out again. */
    private fun download(
        c: Context,
        kind: Kind,
        language: String,
    ) {
        Log.i(TAG, "asking $kind for the offline speech model $language")
        val i = intent(Plan(kind, language, true))
        runCatching {
            val r = recognizer(c, kind)
            if (Build.VERSION.SDK_INT >= 34) {
                r.triggerModelDownload(
                    i,
                    c.mainExecutor,
                    object : android.speech.ModelDownloadListener {
                        override fun onProgress(completedPercent: Int) {
                            if (completedPercent % 25 == 0) Log.i(TAG, "$kind model $language: $completedPercent%")
                        }

                        override fun onSuccess() {
                            Log.i(TAG, "$kind model $language downloaded")
                            offlineMissingUntil = 0
                            plan = null
                        }

                        override fun onScheduled() {
                            Log.i(TAG, "$kind model $language: download scheduled")
                        }

                        override fun onError(error: Int) {
                            Log.i(TAG, "$kind model $language: download failed ($error)")
                        }
                    },
                )
            } else {
                r.triggerModelDownload(i)
            }
        }.onFailure { Log.w(TAG, "model download ($kind)", it) }
    }

    /**
     * The phone's language-region if a pool has it, else the same language in another region: the language's home
     * region (de-DE) first, then -US, then any. Recognizers know common pairs only, so a phone set to English
     * (Switzerland) needs en-US or en-GB. Null when no pool has the language.
     */
    private fun closest(pools: List<List<String>>): String? {
        val locale = Locale.getDefault()
        val wanted = Locale(locale.language, locale.country).toLanguageTag()
        pools.flatten().firstOrNull { it.equals(wanted, ignoreCase = true) }?.let { return it }
        val home = "${locale.language}-${locale.language}"
        for (pool in pools) {
            pool
                .filter { it.substringBefore('-').equals(locale.language, ignoreCase = true) }
                .minByOrNull {
                    when {
                        it.equals(home, ignoreCase = true) -> 0
                        it.endsWith("-US", ignoreCase = true) -> 1
                        it.endsWith("-GB", ignoreCase = true) -> 2
                        else -> 3
                    }
                }?.let { return it }
        }
        return null
    }

    /** No recognizer told its languages: a language-region pair recognizers commonly have. */
    private fun fallbackLanguage(): String {
        val l = Locale.getDefault().language
        return when (l) {
            "en" -> "en-US"
            "de" -> "de-DE"
            "fr" -> "fr-FR"
            "it" -> "it-IT"
            "es" -> "es-ES"
            "pt" -> "pt-BR"
            else -> Locale.getDefault().toLanguageTag()
        }
    }

    private class Session(
        val id: Int,
        val c: Context,
        hold: Boolean,
        val cb: SpeechCallbacks,
        val feed: AudioFeed? = null,
    ) : SpeechSession {
        val d = Dictation(hold, TAP_SILENCE_MS) { SystemClock.elapsedRealtime() }
        val startedAt = SystemClock.elapsedRealtime()
        var ready = false
        var partialSeen = false
        var current: SpeechRecognizer? = null
        var attempt = 0
        var attemptAt = 0L
        var retries = 0
        var ended = false

        /** The last callback of any kind from the recognizer (or the last listen): the stall watchdog's clock. */
        var lastSign = SystemClock.elapsedRealtime()

        /** The plan of the latest listen (the stall watchdog's retry). */
        var lastPlan: Plan? = null

        /** BUSY/CLIENT already answered with a fresh recognizer once in this session (the free retry). */
        var renewed = false

        /** Heard anything in this attempt (an error before that, with segmenting asked for, blames the segmenting). */
        var heard = false

        /** A tap's dictation: ends after [TAP_SILENCE_MS] of nothing new heard, whatever the recognizer does. */
        private val watch =
            object : Runnable {
                override fun run() {
                    if (ended) return
                    val now = SystemClock.elapsedRealtime()
                    if (d.silent()) {
                        Log.i(TAG, "session #$id: silence, ending the dictation")
                        stop()
                    } else if (now - startedAt > MAX_SESSION_MS) {
                        Log.w(TAG, "session #$id: listened ${MAX_SESSION_MS / 60_000} min, ending the dictation")
                        stop()
                    } else if (current != null && !d.stopping && now - lastSign > STALL_MS) {
                        // Wedged: "listening" with no sign of the mic. A new recognizer, once; else the end.
                        Log.w(TAG, "session #$id: no recognizer activity for ${now - lastSign} ms, resetting it")
                        val p = lastPlan
                        lastSign = now
                        current?.let { r -> runCatching { r.cancel() } }
                        current = null
                        if (p == null) return end("the speech recognizer stopped responding")
                        drop(p.kind, "stalled")
                        retry(p, 0) { "the speech recognizer stopped responding" }
                        main.postDelayed(this, 250)
                    } else {
                        main.postDelayed(this, 250)
                    }
                }
            }

        init {
            main.postDelayed(watch, 250)
        }

        override fun stop() {
            if (ended) return
            Log.i(TAG, "session #$id: stop")
            d.stopping = true
            val r = current ?: return end(null)
            r.stopListening()
            // The final result comes within moments; a recognizer that never sends it mustn't keep the session open.
            main.postDelayed({ end(null) }, STOP_GRACE_MS)
        }

        override fun letGo() {
            d.hold = false
        }

        override fun hold() {
            d.hold = true
        }

        override fun quiet(ms: Long) {
            d.silenceMs = ms.coerceIn(800, 10_000)
        }

        override fun cancel() {
            if (ended) return
            ended = true
            main.removeCallbacks(watch)
            Log.i(TAG, "session #$id: cancel (recognizer ${if (current != null) "cancelled" else "idle"})")
            current?.let { runCatching { it.cancel() } }
            current = null
            if (active === this) active = null
        }

        fun end(why: String?) {
            if (ended) return
            ended = true
            main.removeCallbacks(watch)
            // Always release the recognizer's session: a stop whose final result never came (the grace ran out) left it
            // listening in system_server, and the next start on it was refused as busy. Harmless when already idle.
            current?.let { runCatching { it.cancel() } }
            current = null
            if (active === this) active = null
            Log.i(TAG, "session #$id: end (${d.text.length} chars${if (why != null) ", $why" else ""})")
            cb.onEnd(d.text, why)
        }

        fun listen(p: Plan) {
            if (ended) return
            val r = runCatching { recognizer(c, p.kind) }.getOrElse { return end("no speech recognizer (${it.message})") }
            val a = ++attempt
            attemptAt = SystemClock.elapsedRealtime()
            lastSign = attemptAt
            lastPlan = p
            current = r
            heard = false
            r.setRecognitionListener(Listener(a, p))
            Log.i(TAG, "session #$id: listen, attempt $a (${p.kind}${if (p.offline) ", offline" else ""})")
            runCatching { r.startListening(intent(p, feed)) }.onFailure {
                current = null
                drop(p.kind, "startListening threw")
                retry(p) { "speech recognition failed (${it.message})" }
            }
        }

        /**
         * A segment ended (results, a pause with nothing understood): listen again at once, on the same recognizer, while
         * the session goes on ([Dictation.goOn]) - the field keeps "listening" throughout, nothing is lost but the
         * restart's few hundred ms of audio.
         */
        fun next(p: Plan) {
            if (!d.goOn(feedDone = feed?.done == true)) return end(null)
            // A recognizer that ends a segment the moment it starts (no mic, nothing to hear) mustn't spin.
            if (SystemClock.elapsedRealtime() - attemptAt < 500) main.postDelayed({ listen(p) }, 300) else listen(p)
        }

        /** Tries [p] again (after a moment), at most [MAX_RETRIES] times a session; then ends with [why]. */
        fun retry(
            p: Plan,
            delayMs: Long = 250,
            why: () -> String,
        ) {
            if (retries++ >= MAX_RETRIES) return end(why())
            current?.let { runCatching { it.cancel() } }
            current = null
            main.postDelayed({ listen(p) }, delayMs)
        }

        private fun Bundle.best() = getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()

        /** Listens to one attempt; callbacks from an earlier one (or after the end) are ignored. */
        inner class Listener(
            private val a: Int,
            private val p: Plan,
        ) : RecognitionListener {
            private val current get() = (!ended && a == attempt).also { if (it) lastSign = SystemClock.elapsedRealtime() }

            override fun onPartialResults(partial: Bundle) {
                if (!current) return
                val t = partial.best()
                if (t.isNotBlank()) {
                    heard = true
                    segmentedRefusals = 0
                }
                if (t.isNotBlank() && !partialSeen) {
                    partialSeen = true
                    Log.i(TAG, "first words ${SystemClock.elapsedRealtime() - startedAt} ms after the start")
                }
                d.partial(t)
                cb.onText(d.text)
            }

            override fun onResults(results: Bundle) {
                if (!current) return
                Log.i(TAG, "session #$id: results, attempt $a (${results.best().length} chars)")
                d.segment(results.best())
                cb.onText(d.text)
                retries = 0
                next(p)
            }

            // Segmented sessions (API 33+, a recognizer that supports them): each pause's text as it ends, one session
            // to the end - no restarts at all.
            override fun onSegmentResults(segmentResults: Bundle) {
                if (!current) return
                Log.i(TAG, "session #$id: segment, attempt $a (${segmentResults.best().length} chars)")
                if (!segmentsSeen) {
                    segmentsSeen = true
                    Log.i(TAG, "segmented session: the recognizer sends segments (no restarts)")
                }
                segmentedRefusals = 0
                heard = true
                d.segment(segmentResults.best())
                cb.onText(d.text)
            }

            override fun onEndOfSegmentedSession() {
                if (!current) return
                Log.i(TAG, "session #$id: end of the segmented session, attempt $a")
                next(p)
            }

            override fun onError(code: Int) {
                if (!current) return
                Log.i(TAG, "session #$id: error $code, attempt $a ($p)")
                // Words already heard in this attempt are kept whatever comes next: the restart below starts a new
                // partial, and the audio they came from is gone (from PowOS's recording, too, a pipe read once).
                if (heard) {
                    d.segment("")
                    cb.onText(d.text)
                }
                if (code == SpeechRecognizer.ERROR_CLIENT && heard && !d.stopping) {
                    // After words: the end of an utterance the recognizer reported as a client error (Android System
                    // Intelligence does, reading PowOS's recording) - a segment's end, no retry spent. The same
                    // recognizer, a moment later: a new one right after destroying the old raced system_server's
                    // unbinding (SERVER_DISCONNECTED, 11, on every listen after it).
                    Log.i(TAG, "session #$id: error $code after words: a segment's end")
                    main.postDelayed({ if (!ended) next(p) }, 250)
                    return
                }
                if (code == SpeechRecognizer.ERROR_RECOGNIZER_BUSY || code == SpeechRecognizer.ERROR_CLIENT) {
                    // The shared recognizer stuck in a bad state (a session of ours that never ended in system_server,
                    // or a client error): destroy it and listen on a new one - once for free, then within the retries.
                    if (d.stopping) return end(null)
                    if (code == SpeechRecognizer.ERROR_CLIENT && Build.VERSION.SDK_INT >= 33 && !segmentedOff && !heard &&
                        ++segmentedRefusals >= 2
                    ) {
                        Log.i(TAG, "no segmented sessions with this recognizer ($code): restarting segments instead")
                        segmentedOff = true
                    }
                    this@Session.current = null
                    drop(p.kind, "error $code")
                    if (renewed && p.kind == Kind.ON_DEVICE && code == SpeechRecognizer.ERROR_RECOGNIZER_BUSY) {
                        // Still busy on a new recognizer: the service itself is full. The regular recognizer, now and
                        // for the next 10 minutes.
                        onDeviceBusyUntil = System.currentTimeMillis() + 10 * 60_000L
                        val other = remember(Plan(Kind.REGULAR, p.language, false))
                        Log.w(TAG, "session #$id: the on-device recognizer is full, using the regular one")
                        main.post { listen(other) }
                        return
                    }
                    if (!renewed) {
                        renewed = true
                        Log.i(TAG, "session #$id: retrying on a new recognizer")
                        main.post { listen(p) }
                        return
                    }
                    return retry(p, 300) {
                        if (code == SpeechRecognizer.ERROR_RECOGNIZER_BUSY) "the speech recognizer is busy" else "the speech recognizer stopped ($code)"
                    }
                }
                if (Build.VERSION.SDK_INT >= 33 && !segmentedOff && !heard && (code in REFUSALS || code > 15)) {
                    // A recognizer that won't take a segmented session as asked: plain sessions (restarted) from now on.
                    // Twice in a row, not once: a start right after a cancel gets a CLIENT error once too (a page
                    // reloaded mid-summoning, 2026-10-21), and that turned segmenting off for good.
                    if (++segmentedRefusals >= 2) {
                        Log.i(TAG, "no segmented sessions with this recognizer ($code): restarting segments instead")
                        segmentedOff = true
                    }
                    return retry(p, 0) { "speech recognition failed ($code)" }
                }
                when (code) {
                    // Silence or nothing understood: a pause, not the end - unless the session is over.
                    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> next(p)
                    SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> {
                        // The model went away or never came: online with the system default recognizer, then without
                        // naming a language, before giving up.
                        val next =
                            when {
                                p.kind == Kind.ON_DEVICE || p.offline -> Plan(Kind.REGULAR, p.language, false)
                                p.language != null -> Plan(Kind.REGULAR, null, false)
                                else -> null
                            }
                        if (p.kind == Kind.REGULAR && p.offline) offlineMissingUntil = System.currentTimeMillis() + 30 * 60_000L
                        if (next == null) {
                            plan = null
                            end("no speech model for ${Locale.getDefault().toLanguageTag()} on this phone (check Settings > speech recognition)")
                        } else {
                            remember(next)
                            retry(next, 0) { "speech isn't available in ${p.language ?: "this language"}" }
                        }
                    }
                    SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> {
                        if (d.stopping) return end(null)
                        this@Session.current = null
                        drop(p.kind, "error $code")
                        retry(p) { "the speech recognizer stopped ($code)" }
                    }
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> end("microphone permission needed")
                    SpeechRecognizer.ERROR_AUDIO -> end("the microphone is busy")
                    SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT, SpeechRecognizer.ERROR_SERVER ->
                        end("speech recognition needs a network connection")
                    SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> end("speech recognition: too many requests, try again shortly")
                    else -> end("speech recognition failed ($code)")
                }
            }

            override fun onRmsChanged(rmsdB: Float) {
                if (current) cb.onLevel(((rmsdB + 2f) / 12f).coerceIn(0f, 1f))
            }

            override fun onBeginningOfSpeech() {
                if (current) d.voice()
            }

            override fun onReadyForSpeech(params: Bundle?) {
                if (!current || ready) return
                ready = true
                Log.i(TAG, "listening ${SystemClock.elapsedRealtime() - startedAt} ms after the start")
            }

            override fun onBufferReceived(buffer: ByteArray?) {}

            override fun onEndOfSpeech() {}

            override fun onEvent(
                eventType: Int,
                params: Bundle?,
            ) {}
        }
    }

}

/**
 * What a dictation has heard and whether it goes on - Android's recognizers end at every short pause, a dictation
 * doesn't: held (the mic held down) it goes on until let go; a tap's goes on until [silenceMs] pass with nothing new
 * heard (or the mic is tapped again). Pure (a clock passed in), so the rules are unit-tested (SpeechDictationTest).
 */
internal class Dictation(
    var hold: Boolean,
    var silenceMs: Long,
    private val clock: () -> Long,
) {
    /** Asked to stop: the next end of a segment is the end. */
    var stopping = false
    private var lastVoice = clock()
    private var finished = ""
    private var partial = ""

    /** Everything heard: the finished segments, then the current one so far. */
    val text get() = join(finished, partial)

    /** Speech began (the recognizer said so). */
    fun voice() {
        lastVoice = clock()
    }

    /** The current segment so far; new words count as voice. */
    fun partial(t: String) {
        if (t.isNotBlank() && t != partial) voice()
        partial = t
    }

    /** A segment ended with [t]; empty (some recognizers' final for a short tail) keeps what the partial had. */
    fun segment(t: String) {
        val words = t.ifBlank { partial }
        finished = join(finished, words)
        partial = ""
        if (t.isNotBlank()) voice()
    }

    /**
     * At the end of a segment: listen on? Never when its audio is PowOS's recording and that has ended ([feedDone]: a
     * GPU dictation's fallback after the release) - a new listen would read an ended pipe, error, and restart, over and over.
     */
    fun goOn(feedDone: Boolean = false) = !feedDone && !stopping && (hold || clock() - lastVoice < silenceMs)

    /** A tap's dictation has been quiet long enough to end (checked while listening). */
    fun silent() = !hold && !stopping && clock() - lastVoice >= silenceMs

    private fun join(
        a: String,
        b: String,
    ) = listOf(a, b).filter { it.isNotBlank() }.joinToString(" ") { it.trim() }
}
