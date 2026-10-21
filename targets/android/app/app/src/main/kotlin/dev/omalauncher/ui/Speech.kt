package dev.omalauncher.ui

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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

    private var session: SpeechSession? = null

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
        mine = NativeSpeech.start(context, hold, callbacks)
        session = mine
    }

    /** Ends recognition now; the text so far goes to onDone. */
    fun stop() {
        session?.stop()
    }

    /** Keeps listening, but ends at the next pause instead of at [stop]. */
    fun letGo() {
        session?.letGo()
    }

    /** Ends recognition without calling onDone. */
    fun cancel() {
        val s = session
        session = null
        s?.cancel()
        listening = false
        level = 0f
    }
}

/** One recognition, from start to its end (onEnd, exactly once, unless cancelled). */
interface SpeechSession {
    /** Ends now: what's been heard goes to onEnd. */
    fun stop()

    /** Ends at the next pause instead of at [stop]. */
    fun letGo()

    /** Ends without onEnd. */
    fun cancel()
}

class SpeechCallbacks(
    val onText: (String) -> Unit,
    val onLevel: (Float) -> Unit,
    /** The whole text (maybe empty) and why it failed, if it did. */
    val onEnd: (String, String?) -> Unit,
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

    private fun onDeviceAvailable(c: Context) = Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(c)

    fun available(c: Context) = onDeviceAvailable(c) || regularService(c) != null

    /**
     * The phone's default recognition service (Settings.Secure voice_recognition_service), unless that's PowOS's own
     * forwarding service or missing: then the first other one installed, Google's speech services first.
     */
    fun regularService(c: Context): ComponentName? {
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
    ): SpeechSession {
        active?.cancel()
        val s = Session(c.applicationContext, hold, callbacks)
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
                        .also { onDevice = it }
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

    /** A recognizer that misbehaved (disconnected, client error): the next use gets a new one. */
    private fun drop(kind: Kind) {
        when (kind) {
            Kind.ON_DEVICE -> onDevice?.destroy().also { onDevice = null }
            Kind.REGULAR -> regular?.destroy().also { regular = null }
        }
    }

    private fun intent(p: Plan?) =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            .apply {
                if (p?.offline == true) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                p?.language?.let { putExtra(RecognizerIntent.EXTRA_LANGUAGE, it) }
            }

    private fun withPlan(
        c: Context,
        then: (Plan) -> Unit,
    ) {
        plan?.takeIf { System.currentTimeMillis() - planAt < PLAN_TTL_MS }?.let { return then(it) }
        if (Build.VERSION.SDK_INT < 33) return then(remember(Plan(Kind.REGULAR, null, false)))
        support(c, Kind.ON_DEVICE) { onDev ->
            support(c, Kind.REGULAR) { reg -> then(remember(decide(c, onDev, reg))) }
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
        onDev?.let { closest(listOf(it.installedOnDeviceLanguages)) }?.let { return Plan(Kind.ON_DEVICE, it, true) }
        reg?.let { closest(listOf(it.installedOnDeviceLanguages)) }?.let { return Plan(Kind.REGULAR, it, true) }
        // No offline model: ask for one once (it downloads in the background), and recognize online meanwhile.
        val downloadable = reg?.let { closest(listOf(it.pendingOnDeviceLanguages, it.supportedOnDeviceLanguages)) }
        if (downloadable != null && !downloadAsked) {
            downloadAsked = true
            Log.i(TAG, "asking for the offline speech model $downloadable")
            runCatching { recognizer(c, Kind.REGULAR).triggerModelDownload(intent(Plan(Kind.REGULAR, downloadable, true))) }
                .onFailure { Log.w(TAG, "model download", it) }
        }
        val online = reg?.let { closest(listOf(it.onlineLanguages)) }
        return Plan(Kind.REGULAR, online ?: downloadable ?: fallbackLanguage(), false)
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
        val c: Context,
        hold: Boolean,
        val cb: SpeechCallbacks,
    ) : SpeechSession {
        var held = hold
        var finished = ""
        var text = ""
        var current: SpeechRecognizer? = null
        var attempt = 0
        var retries = 0
        var ended = false

        override fun stop() {
            held = false
            current?.stopListening() ?: end(null)
        }

        override fun letGo() {
            held = false
        }

        override fun cancel() {
            if (ended) return
            ended = true
            current?.cancel()
            current = null
            if (active === this) active = null
        }

        fun end(why: String?) {
            if (ended) return
            ended = true
            current = null
            if (active === this) active = null
            if (why != null) Log.w(TAG, why)
            cb.onEnd(text.trim(), why)
        }

        fun listen(p: Plan) {
            if (ended) return
            val r = runCatching { recognizer(c, p.kind) }.getOrElse { return end("no speech recognizer (${it.message})") }
            val a = ++attempt
            current = r
            r.setRecognitionListener(Listener(a, p))
            runCatching { r.startListening(intent(p)) }.onFailure {
                drop(p.kind)
                retry(p) { "speech recognition failed (${it.message})" }
            }
        }

        /** Tries [p] again (after a moment), at most [MAX_RETRIES] times a session; then ends with [why]. */
        fun retry(
            p: Plan,
            delayMs: Long = 250,
            why: () -> String,
        ) {
            if (retries++ >= MAX_RETRIES) return end(why())
            current?.cancel()
            main.postDelayed({ listen(p) }, delayMs)
        }

        private fun join(
            a: String,
            b: String,
        ) = listOf(a, b).filter { it.isNotBlank() }.joinToString(" ") { it.trim() }

        private fun Bundle.best() = getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()

        /** Listens to one attempt; callbacks from an earlier one (or after the end) are ignored. */
        inner class Listener(
            private val a: Int,
            private val p: Plan,
        ) : RecognitionListener {
            private val current get() = !ended && a == attempt

            override fun onPartialResults(partial: Bundle) {
                if (!current) return
                text = join(finished, partial.best())
                cb.onText(text)
            }

            override fun onResults(results: Bundle) {
                if (!current) return
                finished = join(finished, results.best())
                text = finished
                cb.onText(text)
                retries = 0
                if (held) listen(p) else end(null)
            }

            override fun onError(code: Int) {
                if (!current) return
                Log.i(TAG, "error $code ($p)")
                when (code) {
                    // Silence or nothing understood: fine while the button is held.
                    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> if (held) listen(p) else end(null)
                    SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> {
                        // The model went away or never came: online with the system default recognizer, then without
                        // naming a language, before giving up.
                        val next =
                            when {
                                p.kind == Kind.ON_DEVICE || p.offline -> Plan(Kind.REGULAR, p.language, false)
                                p.language != null -> Plan(Kind.REGULAR, null, false)
                                else -> null
                            }
                        if (next == null) {
                            plan = null
                            end("no speech model for ${Locale.getDefault().toLanguageTag()} on this phone (check Settings > speech recognition)")
                        } else {
                            remember(next)
                            retry(next, 0) { "speech isn't available in ${p.language ?: "this language"}" }
                        }
                    }
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> retry(p, 400) { "the speech recognizer is busy" }
                    SpeechRecognizer.ERROR_SERVER_DISCONNECTED, SpeechRecognizer.ERROR_CLIENT -> {
                        drop(p.kind)
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

            override fun onReadyForSpeech(params: Bundle?) {}

            override fun onBeginningOfSpeech() {}

            override fun onBufferReceived(buffer: ByteArray?) {}

            override fun onEndOfSpeech() {}

            override fun onEvent(
                eventType: Int,
                params: Bundle?,
            ) {}
        }
    }
}
