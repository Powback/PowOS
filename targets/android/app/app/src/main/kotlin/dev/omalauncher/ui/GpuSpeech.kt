package dev.omalauncher.ui

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingDeque
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * Which engine dictates (Settings > voice > transcription, the shell's store "speech": {"engine": "gpu"|"gpu-http"|"ondevice"}).
 * GPU (the default): PowOS's own recording streamed to the voice agent's transcription (voiceagent.pow/ws, the swipe
 * keyboard's protocol, [StreamSession]); "gpu-http": the same recording re-POSTed to stt.pow ([GpuSession]), only when
 * chosen explicitly; on-device: Android's recognizer ([NativeSpeech]). Every dictation (the mic, hold to talk, the side button) starts here: one
 * session at a time across both engines, the latest start wins.
 */
internal object SpeechEngines {
    private const val TAG = "speech"
    const val GPU = "gpu"
    const val GPU_HTTP = "gpu-http"
    const val ON_DEVICE = "ondevice"

    /** The one dictation, whichever window started it ([SessionSlot]): a new start ends it first, its owner told. */
    private class Owned(
        val session: SpeechSession,
        val callbacks: SpeechCallbacks,
        val who: String,
    )

    private val slot =
        SessionSlot<Owned> {
            Log.i(TAG, "dictation of ${it.who}: superseded by a new start")
            it.session.cancel()
            it.callbacks.onSuperseded()
        }
    private var ids = 0

    /** The dictation under way (any window's), or null. */
    val current: SpeechSession? get() = slot.current?.session

    fun choice(c: Context): String =
        runCatching {
            JSONObject(File(c.filesDir, "shell-data/speech.json").readText()).optString("engine", GPU)
        }.getOrDefault(GPU).takeIf { it == ON_DEVICE || it == GPU_HTTP } ?: GPU

    fun start(
        c: Context,
        hold: Boolean,
        callbacks: SpeechCallbacks,
        /** Which window asks (logged: who started, who was superseded). */
        who: String = "?",
    ): SpeechSession = slot.start { Owned(make(c, hold, callbacks, who), callbacks, who) }.session

    private fun make(
        c: Context,
        hold: Boolean,
        callbacks: SpeechCallbacks,
        who: String,
    ): SpeechSession {
        Log.i(TAG, "dictation start by $who (${if (hold) "hold" else "tap"})")
        val app = c.applicationContext
        val engine = choice(app)
        val s =
            // GPU: always the server - never a silent switch to the on-device model (2026-10-30: one slow request
            // over the VPN moved the user's dictation onto Android's recognizer, unseen; and a "known down" kept the
            // next 30 s there too). Unreachable, the session ends at once with a message (GpuSession.fail).
            // On-device is the explicit choice in Settings > voice only.
            // The streaming engine is the default; stt.pow's POSTs only as the explicit "gpu-http" setting.
            if (engine == GPU) {
                callbacks.onEngine(GPU)
                StreamSession(++ids, hold, callbacks, MicSource()).also { it.begin() }
            } else if (engine == GPU_HTTP) {
                callbacks.onEngine(GPU)
                GpuSession(++ids, app, hold, callbacks, MicSource()).also { it.begin() }
            } else {
                callbacks.onEngine(ON_DEVICE)
                NativeSpeech.start(app, hold, callbacks)
            }
        return s
    }

    fun warm(c: Context) {
        if (choice(c) == GPU_HTTP) SttServer.checkIfStale()
        NativeSpeech.warm(c)
    }

    /**
     * A test with recorded audio instead of the mic (16 kHz mono 16-bit WAV under the app's files/speech-test/): the
     * whole dictation as a tap's, logged as "test: ..." - nothing reaches a page. [mode]: "gpu" (as a dictation would:
     * streamed to voiceagent.pow), "gpu-http" (stt.pow's POSTs, the explicit setting), "fallback" (stt.pow made to fail after its first answer: partials are tolerated, the finals' failure ends the
     * session with a message and what was heard kept - no on-device fallback), "down" (the on-device recognizer from
     * the file, as the explicit on-device setting).
     */
    fun test(
        c: Context,
        name: String,
        mode: String,
    ): String {
        require(name.matches(Regex("[A-Za-z0-9_.-]+\\.wav"))) { "bad test file" }
        val f = File(c.filesDir, "speech-test/$name")
        if (!f.isFile) return "no file"
        val cb =
            SpeechCallbacks(
                onText = {},
                onLevel = {},
                onEnd = { heard, why -> Log.i(TAG, "test ($mode): \"$heard\"${if (why != null) " ($why)" else ""}") },
                onEngine = { Log.i(TAG, "test ($mode): engine $it") },
            )
        val app = c.applicationContext
        when (mode) {
            "down" -> {
                cb.onEngine(ON_DEVICE)
                val feed = AudioFeed(ByteArray(0))
                val src = FileSource(f)
                src.start { b, n -> feed.write(b.copyOf(n)) }
                // The file's end: the recognizer's audio ends with it.
                Handler(Looper.getMainLooper()).postDelayed({
                    src.stop()
                    feed.finish()
                }, src.durationMs + 300)
                NativeSpeech.start(app, false, cb, feed)
            }
            "gpu" -> {
                cb.onEngine(GPU)
                val src = FileSource(f)
                val s = StreamSession(++ids, false, cb, src).also { it.begin() }
                Handler(Looper.getMainLooper()).postDelayed({ s.stop() }, src.durationMs + 1500)
            }
            else -> {
                cb.onEngine(GPU)
                val src = FileSource(f)
                val s = GpuSession(++ids, app, false, cb, src, failAfterFirst = mode == "fallback").also { it.begin() }
                // Pauses don't end a dictation any more: the test's tap on the mic comes 1.5 s after the file's end.
                Handler(Looper.getMainLooper()).postDelayed({ s.stop() }, src.durationMs + 1500)
            }
        }
        return "started"
    }
}

/**
 * stt.pow (stt-batch: whisper-fast large-v3-turbo on gpu-195's GPU1, OpenAI-compatible; docs/GPU-SERVERS-PLAN.md).
 * Whether it's up is checked cheaply (GET /health, 400 ms to connect) and remembered 30 s, so a dictation on a phone
 * away from the LAN starts on-device at once instead of after a timeout.
 */
internal object SttServer {
    private const val TAG = "speech"
    const val URL_BASE = "http://stt.pow"
    private const val HEALTH_TTL_MS = 30_000L
    const val CONNECT_MS = 400

    @Volatile private var healthy: Boolean? = null

    @Volatile private var checkedAt = 0L

    @Volatile private var checking = false
    private val io = Executors.newSingleThreadExecutor { Thread(it, "stt-health").apply { isDaemon = true } }

    fun checkedAgoMs() = SystemClock.elapsedRealtime() - checkedAt

    private fun fresh() = healthy != null && checkedAgoMs() < HEALTH_TTL_MS

    fun knownUp() = healthy == true && fresh()

    fun checkIfStale() {
        if (!fresh()) check()
    }

    fun check(then: ((Boolean) -> Unit)? = null) {
        if (checking && then == null) return
        checking = true
        io.execute {
            val ok =
                runCatching {
                    val h = URL("$URL_BASE/health").openConnection() as HttpURLConnection
                    h.connectTimeout = CONNECT_MS
                    h.readTimeout = 800
                    try {
                        h.responseCode == 200
                    } finally {
                        h.disconnect()
                    }
                }.getOrDefault(false)
            if (ok != healthy) Log.i(TAG, "stt.pow ${if (ok) "up" else "down"}")
            healthy = ok
            checkedAt = SystemClock.elapsedRealtime()
            checking = false
            then?.let { Handler(Looper.getMainLooper()).post { it(ok) } }
        }
    }

    fun markDown(why: String) {
        Log.w(TAG, "stt.pow: $why")
        healthy = false
        checkedAt = SystemClock.elapsedRealtime()
    }

    fun markUp() {
        healthy = true
        checkedAt = SystemClock.elapsedRealtime()
    }

    /** stt.pow answered, but not 200 (no speech is 200 with empty text since 2df111b). */
    class HttpError(
        val code: Int,
    ) : IOException("HTTP $code")

    class Heard(
        val text: String,
        val language: String?,
    )

    /** [pcm] (16 kHz mono 16-bit) as text; throws on any failure. Blocking: call it off the main thread. */
    fun transcribe(
        pcm: ByteArray,
        language: String?,
        prompt: String?,
        readMs: Int,
    ): Heard {
        val boundary = "powos${System.nanoTime()}"
        val body = ByteArrayOutputStream(pcm.size + 1024)
        fun field(
            name: String,
            value: String,
        ) = body.write("--$boundary\r\nContent-Disposition: form-data; name=\"$name\"\r\n\r\n$value\r\n".toByteArray())
        field("model", "whisper-1")
        field("response_format", "verbose_json")
        language?.let { field("language", it) }
        prompt?.takeIf { it.isNotBlank() }?.let { field("prompt", it.takeLast(200)) }
        body.write("--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".toByteArray())
        body.write(wavHeader(pcm.size))
        body.write(pcm)
        body.write("\r\n--$boundary--\r\n".toByteArray())
        val h = URL("$URL_BASE/v1/audio/transcriptions").openConnection() as HttpURLConnection
        h.connectTimeout = CONNECT_MS
        h.readTimeout = readMs
        h.requestMethod = "POST"
        h.doOutput = true
        h.setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
        h.setFixedLengthStreamingMode(body.size())
        try {
            h.outputStream.use { body.writeTo(it) }
            val code = h.responseCode
            if (code != 200) throw HttpError(code)
            val j = JSONObject(h.inputStream.bufferedReader().readText())
            return Heard(j.optString("text").trim(), j.optString("language").takeIf { it.isNotBlank() })
        } finally {
            h.disconnect()
        }
    }

    private fun wavHeader(n: Int): ByteArray {
        val b = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(36 + n).put("WAVE".toByteArray())
        b.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(RATE).putInt(RATE * 2).putShort(2).putShort(16)
        b.put("data".toByteArray()).putInt(n)
        return b.array()
    }

    const val RATE = 16_000
}

/** 16 kHz mono 16-bit audio, 20 ms at a time, on its own thread. */
internal interface PcmSource {
    fun start(onPcm: (ByteArray, Int) -> Unit)

    fun stop()
}

/** The mic (the voice-recognition source: Android's own tuning for speech). */
internal class MicSource : PcmSource {
    @Volatile private var running = false
    private var thread: Thread? = null

    @SuppressLint("MissingPermission")
    override fun start(onPcm: (ByteArray, Int) -> Unit) {
        running = true
        thread =
            Thread({
                // The previous recording's recorder stopped and released first: one AudioRecord at a time (MicGate).
                val turn = MicGate.shared.enter()
                try {
                    if (running) record(turn, onPcm)
                } finally {
                    MicGate.shared.leave(turn)
                }
            }, "speech-mic").apply { start() }
    }

    @SuppressLint("MissingPermission")
    private fun record(
        turn: MicGate.Turn,
        onPcm: (ByteArray, Int) -> Unit,
    ) {
        val min = AudioRecord.getMinBufferSize(SttServer.RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec =
            runCatching {
                AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, SttServer.RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, 640 * 8))
            }.getOrNull()
        if (rec == null || rec.state != AudioRecord.STATE_INITIALIZED) {
            Log.w("speech", "the mic didn't open")
            rec?.release()
            return
        }
        val buf = ByteArray(640)
        try {
            rec.startRecording()
            while (running && turn.mine) {
                val n = rec.read(buf, 0, buf.size)
                if (n > 0) onPcm(buf, n) else if (n < 0) break
            }
        } finally {
            runCatching { rec.stop() }
            rec.release()
        }
    }

    override fun stop() {
        running = false
    }
}

/** A recorded WAV (16 kHz mono 16-bit), at the speed it was spoken, then silence: the tests' mic. */
internal class FileSource(
    f: File,
) : PcmSource {
    // After the "data" chunk's header, wherever it is (afconvert's WAVs put a 4 KB FLLR chunk first; a plain one is 44).
    private val pcm =
        f.readBytes().let { b ->
            val at = (12 until minOf(b.size - 8, 1 shl 16)).firstOrNull { b[it] == 'd'.code.toByte() && b[it + 1] == 'a'.code.toByte() && b[it + 2] == 't'.code.toByte() && b[it + 3] == 'a'.code.toByte() }
            b.copyOfRange(if (at != null) at + 8 else minOf(44, b.size), b.size)
        }
    val durationMs = pcm.size / 32L

    @Volatile private var running = false

    override fun start(onPcm: (ByteArray, Int) -> Unit) {
        running = true
        Thread({
            var off = 0
            val silence = ByteArray(640)
            val t0 = SystemClock.elapsedRealtime()
            var frames = 0L
            while (running) {
                if (off < pcm.size) {
                    val n = minOf(640, pcm.size - off)
                    onPcm(pcm.copyOfRange(off, off + n), n)
                    off += n
                } else {
                    onPcm(silence, silence.size)
                }
                frames++
                val wait = t0 + frames * 20 - SystemClock.elapsedRealtime()
                if (wait > 0) Thread.sleep(wait)
            }
        }, "speech-file").apply { start() }
    }

    override fun stop() {
        running = false
    }
}

/**
 * Audio for Android's recognizer from PowOS's own recording (RecognizerIntent.EXTRA_AUDIO_SOURCE, API 33+): what was
 * recorded before the fallback first ([backlog]), then live. A pipe per listen ([open]); the recognizer reads it at its
 * pace.
 *
 * Only the "speech-feed" thread ever writes a pipe. A pipe holds 64 KB (2 s of 16 kHz PCM) and its reader - the
 * recognizer - starts only after [open] returned (the read end goes in its intent), so any write on [open]'s caller
 * (main) with more than that queued blocks forever: the whole app froze (ANRs 2026-10-23/24, main in
 * FileOutputStream.write under AudioFeed.open, from the side-button assist's dictation fallback with its backlog).
 */
internal class AudioFeed(
    backlog: ByteArray,
) {
    private val q = LinkedBlockingDeque<ByteArray>()
    private val eof = ByteArray(0)

    /** The current listen's pipe; null between two listens. Guarded by this. */
    private var out: OutputStream? = null

    /** Audio that came while no listen was reading, oldest first: the next [open]'s pipe gets it first. Guarded by this. */
    private val pendingWhileClosed = ArrayList<ByteArray>()

    @Volatile var done = false
        private set

    init {
        if (backlog.isNotEmpty()) q.add(backlog)
        Thread({
            while (true) {
                val b = q.take()
                if (b === eof) {
                    synchronized(this) { runCatching { out?.close() } }
                    done = true
                    return@Thread
                }
                // The check and the park in one lock: an open() between them would otherwise leave b behind newer audio.
                val o =
                    synchronized(this) {
                        out ?: run {
                            pendingWhileClosed.add(b)
                            null
                        }
                    } ?: continue
                try {
                    o.write(b) // blocks while the recognizer is behind: only ever this thread
                } catch (e: IOException) {
                    synchronized(this) {
                        if (out === o) {
                            out = null // the recognizer closed it: b waits for the next listen
                        }
                    }
                    // A newer listen replaced this pipe mid-write: b goes to it (or is parked), in order.
                    q.putFirst(b)
                }
            }
        }, "speech-feed").apply {
            isDaemon = true
            start()
        }
    }

    /** A new pipe for one listen: its read end goes in the intent. Never blocks (no write here). */
    fun open(): ParcelFileDescriptor {
        val (r, w) = ParcelFileDescriptor.createPipe()
        synchronized(this) {
            runCatching { out?.close() }
            out = ParcelFileDescriptor.AutoCloseOutputStream(w)
            // What came while no listen was reading goes ahead of everything queued, for the feed thread to write.
            for (i in pendingWhileClosed.indices.reversed()) q.putFirst(pendingWhileClosed[i])
            pendingWhileClosed.clear()
        }
        return r
    }

    fun write(b: ByteArray) {
        if (!done) q.add(b)
    }

    /** The audio ends: the recognizer gets end-of-file after what's queued. */
    fun finish() {
        q.add(eof)
    }

    fun close() {
        finish()
        synchronized(this) { runCatching { out?.close() } }
    }
}

/**
 * One dictation on the GPU: PowOS records (16 kHz PCM, kept whole), cuts it into segments at pauses, and has stt.pow
 * transcribe each segment as it grows (partials, back to back: ~60-150 ms a request) and once more when it ends (its
 * final, with the text before it as the prompt). Release-to-send (the page's) takes the text shown at that moment.
 *
 * Like the swipe keyboard's dictation (android-app-dev swipe-keyboard VoiceClient): pauses never end or reset it - a
 * tap's goes on until the mic is tapped again, sent, or [MAX_SESSION_MS]; the text accumulates segment by segment. Only
 * a tap with no voice at all ends on its own (after the tap's silence), or a quiet() asked for explicitly (side button).
 *
 * No fallback to Android's recognizer: a failed or slow partial is skipped (the next one covers its audio); a final
 * that fails is retried; stt.pow unreachable (the health check, a connect failure) or not answering at all ends the
 * session at once with a message ([fail]), keeping what was heard.
 */
internal class GpuSession(
    val id: Int,
    private val c: Context,
    hold: Boolean,
    private val cb: SpeechCallbacks,
    private val source: PcmSource,
    /** Tests: stt.pow "fails" after its first answer. */
    private val failAfterFirst: Boolean = false,
) : SpeechSession {
    companion object {
        private const val TAG = "speech"
        /** No answer at all this long after the first voice: the server isn't answering - the session ends with that. */
        private const val FIRST_ANSWER_MS = 6000L
        private const val PARTIAL_READ_MS = 2500
        private const val FINAL_READ_MS = 8000
        private const val FINAL_TRIES = 3
        const val UNREACHABLE = "speech server unreachable (stt.pow) - offline? Settings > Voice > on-device"
        private const val BYTES_PER_MS = 32
        private const val PAUSE_MS = 700L
        private const val MIN_SEGMENT_MS = 1200L
        private const val MAX_SEGMENT_MS = 25_000L
        private const val MIN_NEW_AUDIO_MS = 250L
        private const val MAX_SESSION_MS = 5 * 60_000L
        private const val STOP_GRACE_MS = 2L * FINAL_READ_MS
        private val net = Executors.newSingleThreadExecutor { Thread(it, "stt-net").apply { isDaemon = true } }
    }

    private val main = Handler(Looper.getMainLooper())
    private val d = Dictation(hold, NativeSpeech.TAP_SILENCE_MS) { SystemClock.elapsedRealtime() }
    private val startedAt = SystemClock.elapsedRealtime()

    /** All that was recorded (written by the recorder thread, read on main and the network thread). */
    private val pcm = ByteArrayOutputStream(32 * 60_000)

    private fun recorded(): Int = synchronized(pcm) { pcm.size() }

    private fun slice(
        from: Int,
        to: Int,
    ): ByteArray = synchronized(pcm) { pcm.toByteArray().copyOfRange(from, minOf(to, pcm.size())) }

    private class Seg(
        val start: Int,
    ) {
        var end = -1
        var text = ""
        var final = false
        var voiced = false
    }

    private val segs = mutableListOf(Seg(0))
    private val live get() = segs.last()
    private var lastVoiceAt = -1
    private var firstVoiceAt = 0L
    private var answers = 0

    /** stt.pow's 500s in a row ([SttServer.HttpError]); touched on the network thread only. */
    @Volatile private var errorRuns = 0
    private var inFlight = false
    private var partialUpTo = 0
    private var language: String? = null
    private var ended = false
    private var stopAt = 0L

    /** Failed tries of each final, by segment start. */
    private val finalFails = HashMap<Int, Int>()

    /** An explicit quiet() (the side button's quick ask): a tap then ends after that silence even after speech. */
    private var quietAsked = false

    // Voice from loudness: above the room's own floor (tracked slowly upward, at once downward).
    private var floorDb = -60.0

    val text get() = segs.joinToString(" ") { it.text.trim() }.trim()

    fun begin() {
        Log.i(TAG, "session #$id (gpu): start (${if (d.hold) "hold" else "tap"})")
        if (!SttServer.knownUp()) {
            SttServer.check { ok -> if (!ok && !ended) fail(UNREACHABLE) }
        }
        source.start { b, n ->
            val db = db(b, n)
            synchronized(pcm) { pcm.write(b, 0, n) }
            main.post { frame(db) }
        }
        main.postDelayed(watch, 250)
    }

    private fun db(
        b: ByteArray,
        n: Int,
    ): Double {
        var sum = 0.0
        var i = 0
        while (i + 1 < n) {
            val s = ((b[i + 1].toInt() shl 8) or (b[i].toInt() and 0xff)).toShort().toDouble()
            sum += s * s
            i += 2
        }
        val rms = sqrt(sum / maxOf(1, n / 2))
        return 20 * log10(maxOf(rms, 1.0) / 32768.0)
    }

    private fun frame(db: Double) {
        if (ended) return
        floorDb = if (db < floorDb) db else floorDb + 0.02
        cb.onLevel(((db + 60) / 50).toFloat().coerceIn(0f, 1f))
        if (d.stopping) return
        val now = recorded()
        val voice = db > floorDb + 12 && db > -55
        if (voice) {
            if (firstVoiceAt == 0L) firstVoiceAt = SystemClock.elapsedRealtime()
            lastVoiceAt = now
            live.voiced = true
            d.voice()
        }
        val segMs = (now - live.start) / BYTES_PER_MS
        val pausedMs = if (lastVoiceAt < 0) 0 else (now - lastVoiceAt) / BYTES_PER_MS
        if (live.voiced && ((pausedMs >= PAUSE_MS && segMs >= MIN_SEGMENT_MS) || segMs >= MAX_SEGMENT_MS)) cut(now)
        pump()
    }

    /** The live segment ends at [at]; a new one starts. */
    private fun cut(at: Int) {
        live.end = at
        segs.add(Seg(at))
        partialUpTo = at
    }

    /** One request at a time: the oldest unfinished final first, else the live segment's partial. */
    private fun pump() {
        if (inFlight || ended) return
        val f = segs.firstOrNull { it.end >= 0 && !it.final }
        if (f != null) return send(f, final = true)
        val now = recorded()
        if (live.voiced && (now - partialUpTo) / BYTES_PER_MS >= MIN_NEW_AUDIO_MS) send(live, final = false)
    }

    private fun send(
        s: Seg,
        final: Boolean,
    ) {
        val to = if (final) s.end else recorded()
        val audio = slice(s.start, to)
        val prompt = segs.takeWhile { it !== s }.joinToString(" ") { it.text }
        val lang = language
        inFlight = true
        if (!final) partialUpTo = to
        net.execute {
            val r =
                runCatching {
                    if (failAfterFirst && answers > 0) throw IOException("test: made to fail")
                    try {
                        SttServer.transcribe(audio, lang, prompt, if (final) FINAL_READ_MS else PARTIAL_READ_MS).also { errorRuns = 0 }
                    } catch (e: SttServer.HttpError) {
                        // A server error: one is tolerated (no words from this request, the next one tries again);
                        // three in a row fail over to on-device.
                        if (e.code != 500 || ++errorRuns >= 3) throw e
                        SttServer.Heard("", null)
                    }
                }
            main.post {
                inFlight = false
                if (ended) return@post
                r.onSuccess { h ->
                    answers++
                    SttServer.markUp()
                    if (language == null && audio.size >= 1500 * BYTES_PER_MS) language = h.language
                    if (s.final) return@onSuccess
                    // Whisper's words for silence or noise (subtitle credits, "Thank you."): dropped, see WhisperJunk.
                    s.text = WhisperJunk.clean(h.text)
                    if (s.text != h.text) Log.i(TAG, "session #$id (gpu): dropped Whisper junk \"${h.text}\"")
                    if (final) s.final = true
                    if (answers == 1) Log.i(TAG, "session #$id (gpu): first words ${SystemClock.elapsedRealtime() - startedAt} ms after the start")
                    cb.onText(text)
                    if (d.stopping && segs.all { it.final || (it === live && it.end < 0 && !it.voiced) }) end(null) else pump()
                }.onFailure {
                    Log.w(TAG, "session #$id (gpu): ${if (final) "final" else "partial"} failed: ${it.javaClass.simpleName}: ${it.message}")
                    when {
                        unreachable(it) -> {
                            SttServer.markDown("${it.javaClass.simpleName}: ${it.message}")
                            return@post fail(UNREACHABLE)
                        }
                        // A partial is a preview: the next one (or the final) covers its audio.
                        !final -> {}
                        (finalFails.merge(s.start, 1, Int::plus) ?: 0) >= FINAL_TRIES -> {
                            // What its partials heard stays in the text.
                            s.final = true
                            return@post fail("the speech server failed (${it.message})")
                        }
                    }
                    if (d.stopping && segs.all { it.final || (it === live && it.end < 0 && !it.voiced) }) end(null) else pump()
                }
            }
        }
    }

    private val watch =
        object : Runnable {
            override fun run() {
                if (ended) return
                val now = SystemClock.elapsedRealtime()
                when {
                    // Pauses don't end it: only a tap that never heard a voice, or an explicit quiet().
                    d.silent() && (quietAsked || firstVoiceAt == 0L) -> {
                        Log.i(TAG, "session #$id (gpu): silence, ending the dictation")
                        stop()
                    }
                    now - startedAt > MAX_SESSION_MS -> {
                        Log.w(TAG, "session #$id (gpu): listened ${MAX_SESSION_MS / 60_000} min, ending the dictation")
                        stop()
                    }
                    answers == 0 && firstVoiceAt > 0 && now - firstVoiceAt > FIRST_ANSWER_MS -> {
                        SttServer.markDown("no answer ${now - firstVoiceAt} ms after the first voice")
                        return fail("the speech server isn't answering")
                    }
                    // What the partials heard is the text: the dictation ends with it.
                    d.stopping && now - stopAt > STOP_GRACE_MS -> return end(null)
                }
                if (!ended) main.postDelayed(this, 100)
            }
        }

    /** Ends now with [why] shown (the bar's placeholder when nothing was heard); what was heard is kept. */
    private fun fail(why: String) {
        if (ended) return
        Log.w(TAG, "session #$id (gpu): $why")
        end(why)
    }

    private fun unreachable(e: Throwable) =
        e is java.net.ConnectException || e is java.net.UnknownHostException || e is java.net.NoRouteToHostException ||
            (e is java.net.SocketTimeoutException && e.message.orEmpty().contains("connect", ignoreCase = true))

    override fun stop() {
        if (ended || d.stopping) return
        Log.i(TAG, "session #$id (gpu): stop")
        d.stopping = true
        stopAt = SystemClock.elapsedRealtime()
        source.stop()
        val now = recorded()
        if (live.voiced) cut(now) else live.end = now.also { live.final = true }
        if (segs.all { it.final || !it.voiced }) return end(null)
        pump()
    }

    override fun letGo() {
        d.hold = false
    }

    override fun hold() {
        d.hold = true
    }

    override fun quiet(ms: Long) {
        d.silenceMs = ms.coerceIn(800, 10_000)
        quietAsked = true
    }

    override fun cancel() {
        if (ended) return
        ended = true
        Log.i(TAG, "session #$id (gpu): cancel")
        main.removeCallbacks(watch)
        source.stop()
    }

    private fun end(why: String?) {
        if (ended) return
        ended = true
        main.removeCallbacks(watch)
        source.stop()
        val t = text
        Log.i(TAG, "session #$id (gpu): end (${t.length} chars, ${segs.size} segments${if (why != null) ", $why" else ""})")
        cb.onEnd(t, why)
    }
}

/**
 * The voice agent's transcription protocol, as the swipe keyboard speaks it (android-app-dev swipe-keyboard
 * VoiceClient): `{"type":"start","mode":"transcription_only"}`, then raw 16 kHz mono Int16 PCM in binary frames of
 * [CHUNK_BYTES] (512 samples, 32 ms: Silero VAD's frame), and back `{"type":"transcript","text":...,"final":bool}` -
 * the server's VAD cuts segments; a partial is the current segment so far, a final is that segment's text (not the
 * whole). `{"type":"stop"}` ends it (the server drops what it hasn't transcribed: [StreamSession] flushes with silence
 * first). Also `{"type":"state","phase":"listening"|"processing"|"idle"}` and `{"type":"error",...}`.
 */
internal object VoiceAgentProtocol {
    const val URL = "ws://voiceagent.pow/ws"
    const val CHUNK_BYTES = 1024
    const val START = """{"type":"start","mode":"transcription_only"}"""
    const val STOP = """{"type":"stop"}"""

    sealed class Msg {
        data class Transcript(
            val text: String,
            val final: Boolean,
        ) : Msg()

        data class Phase(
            val phase: String,
        ) : Msg()

        data class Error(
            val message: String,
        ) : Msg()

        object Other : Msg()
    }

    fun parse(json: String): Msg =
        runCatching {
            val j = JSONObject(json)
            when (j.optString("type")) {
                "transcript" -> Msg.Transcript(j.optString("text").trim(), j.optBoolean("final", false))
                "state" -> Msg.Phase(j.optString("phase"))
                "error" -> Msg.Error(j.optString("message").ifBlank { j.optString("code", "error") })
                else -> Msg.Other
            }
        }.getOrDefault(Msg.Other)

    /** Any-size PCM in, exact [CHUNK_BYTES] frames out (the server's VAD takes a frame as given). */
    class Rechunker(
        private val emit: (ByteArray) -> Unit,
    ) {
        private val buf = ByteArray(CHUNK_BYTES)
        private var n = 0

        fun write(
            b: ByteArray,
            len: Int,
        ) {
            var off = 0
            while (off < len) {
                val k = minOf(CHUNK_BYTES - n, len - off)
                System.arraycopy(b, off, buf, n, k)
                n += k
                off += k
                if (n == CHUNK_BYTES) {
                    emit(buf.copyOf())
                    n = 0
                }
            }
        }

        /** The last partial frame, padded with silence. */
        fun flush() {
            if (n == 0) return
            java.util.Arrays.fill(buf, n, CHUNK_BYTES, 0)
            emit(buf.copyOf())
            n = 0
        }
    }
}

/**
 * One dictation streamed to the voice agent (voiceagent.pow/ws, GPU0's realtime voice path, transcription only), the
 * swipe keyboard's way: the server's VAD cuts segments, each final is appended at once, a partial shows the segment
 * still being spoken. Pauses never end it; a tap's ends at [stop] (or with no voice at all, after the tap's silence;
 * or a quiet() asked for). No read timeout. A connection that fails or drops ends it at once with "voice: <why>",
 * keeping what was heard - no fallback.
 *
 * [stop]: the audio ends with [FLUSH_MS] of silence (the server's VAD then ends the segment and transcribes it), the
 * last final is awaited - quiet for [QUIET_MS] with nothing processing, at most [STOP_MAX_MS] (under dictation.ts's
 * FINISH_MS) - then the server gets its stop; a partial never finalized stays in the text (the keyboard commits it too).
 */
internal class StreamSession(
    val id: Int,
    hold: Boolean,
    private val cb: SpeechCallbacks,
    private val source: PcmSource,
) : SpeechSession {
    companion object {
        private const val TAG = "speech"
        private const val FLUSH_MS = 800
        private const val QUIET_MS = 500L
        private const val STOP_MAX_MS = 2500L
        // HACK: a forgotten tap's mic would stream forever; the keyboard has no cap. Real fix: the shell's own
        // mic-on indicator/timeout policy - until then 15 min.
        private const val MAX_SESSION_MS = 15 * 60_000L
    }

    private val main = Handler(Looper.getMainLooper())
    private val d = Dictation(hold, NativeSpeech.TAP_SILENCE_MS) { SystemClock.elapsedRealtime() }
    private val startedAt = SystemClock.elapsedRealtime()

    /** Connect, then every frame in order, then the stop: one thread, so nothing overtakes the handshake. */
    private val io = Executors.newSingleThreadExecutor { Thread(it, "voice-ws").apply { isDaemon = true } }
    private val ws = VoiceSocket(VoiceAgentProtocol.URL, { t -> main.post { message(t) } }, { why -> main.post { dropped(why) } })

    @Volatile private var up = false
    private val chunks = VoiceAgentProtocol.Rechunker { f -> send { ws.send(f) } }

    private val finals = mutableListOf<String>()
    private var partial = ""
    private var phase = ""
    private var firstVoiceAt = 0L
    private var lastEventAt = 0L
    private var answers = 0
    private var ended = false
    private var stopAt = 0L
    private var flushedAt = 0L
    private var quietAsked = false
    private var floorDb = -60.0

    val text get() = (finals + partial).filter { it.isNotBlank() }.joinToString(" ").trim()

    fun begin() {
        Log.i(TAG, "session #$id (gpu stream): start (${if (d.hold) "hold" else "tap"})")
        io.execute {
            try {
                ws.connect()
                ws.sendText(VoiceAgentProtocol.START)
                up = true
            } catch (e: Exception) {
                main.post { fail("voice: speech server unreachable (voiceagent.pow: ${e.message ?: e.javaClass.simpleName})") }
            }
        }
        source.start { b, n ->
            val db = db(b, n)
            // Before the handshake ends the frames queue behind it (io is one thread): the first words aren't lost.
            synchronized(chunks) { chunks.write(b, n) }
            main.post { frame(db) }
        }
        main.postDelayed(watch, 100)
    }

    private fun send(what: () -> Unit) {
        if (io.isShutdown) return
        runCatching {
            io.execute {
                if (!up) return@execute
                try {
                    what()
                } catch (e: IOException) {
                    up = false
                    main.post { dropped(e.message ?: e.javaClass.simpleName) }
                }
            }
        }
    }

    private fun db(
        b: ByteArray,
        n: Int,
    ): Double {
        var sum = 0.0
        var i = 0
        while (i + 1 < n) {
            val s = ((b[i + 1].toInt() shl 8) or (b[i].toInt() and 0xff)).toShort().toDouble()
            sum += s * s
            i += 2
        }
        return 20 * log10(maxOf(sqrt(sum / maxOf(1, n / 2)), 1.0) / 32768.0)
    }

    private fun frame(db: Double) {
        if (ended) return
        floorDb = if (db < floorDb) db else floorDb + 0.02
        cb.onLevel(((db + 60) / 50).toFloat().coerceIn(0f, 1f))
        if (d.stopping) return
        if (db > floorDb + 12 && db > -55) {
            if (firstVoiceAt == 0L) firstVoiceAt = SystemClock.elapsedRealtime()
            d.voice()
        }
    }

    private fun message(json: String) {
        if (ended) return
        lastEventAt = SystemClock.elapsedRealtime()
        when (val m = VoiceAgentProtocol.parse(json)) {
            is VoiceAgentProtocol.Msg.Transcript -> transcript(m)
            is VoiceAgentProtocol.Msg.Phase -> phase = m.phase
            // The keyboard ignores these too: one segment's failure, the stream goes on.
            is VoiceAgentProtocol.Msg.Error -> Log.w(TAG, "session #$id (gpu stream): server error: ${m.message}")
            VoiceAgentProtocol.Msg.Other -> {}
        }
    }

    /** A final is its segment's text, appended at once; a partial, the segment still being spoken. */
    private fun transcript(m: VoiceAgentProtocol.Msg.Transcript) {
        // Whisper's words for silence or noise (subtitle credits, "Thank you."): dropped, see WhisperJunk.
        val t = WhisperJunk.clean(m.text)
        if (t != m.text) Log.i(TAG, "session #$id (gpu stream): dropped Whisper junk \"${m.text}\"")
        if (m.final) {
            if (t.isNotBlank()) finals.add(t)
            partial = ""
        } else {
            partial = t
        }
        if (t.isNotBlank()) {
            d.voice()
            if (++answers == 1) Log.i(TAG, "session #$id (gpu stream): first words ${SystemClock.elapsedRealtime() - startedAt} ms after the start")
        }
        cb.onText(text)
    }

    private fun dropped(why: String?) {
        if (ended) return
        // During the stop the last final may still be missing: what was heard stands, with the reason.
        fail("voice: ${why ?: "connection closed"}")
    }

    private val watch =
        object : Runnable {
            override fun run() {
                if (ended) return
                val now = SystemClock.elapsedRealtime()
                when {
                    d.silent() && (quietAsked || firstVoiceAt == 0L) -> {
                        Log.i(TAG, "session #$id (gpu stream): silence, ending the dictation")
                        stop()
                    }
                    !d.stopping && now - startedAt > MAX_SESSION_MS -> {
                        Log.w(TAG, "session #$id (gpu stream): listened ${MAX_SESSION_MS / 60_000} min, ending the dictation")
                        stop()
                    }
                    d.stopping && now - stopAt > STOP_MAX_MS -> return end(null)
                    d.stopping && flushedAt > 0 && phase != "processing" && now - flushedAt >= QUIET_MS && now - lastEventAt >= QUIET_MS ->
                        return end(null)
                }
                if (!ended) main.postDelayed(this, 50)
            }
        }

    private fun fail(why: String) {
        if (ended) return
        Log.w(TAG, "session #$id (gpu stream): $why")
        end(why)
    }

    override fun stop() {
        if (ended || d.stopping) return
        Log.i(TAG, "session #$id (gpu stream): stop")
        d.stopping = true
        stopAt = SystemClock.elapsedRealtime()
        source.stop()
        // Nothing heard and nothing pending: no need to wait for the server.
        if (firstVoiceAt == 0L && text.isEmpty() && partial.isEmpty()) return end(null)
        // The last partial frame, then silence: the server's VAD ends the segment and transcribes it.
        synchronized(chunks) { chunks.flush() }
        send {
            val silence = ByteArray(VoiceAgentProtocol.CHUNK_BYTES)
            repeat(FLUSH_MS / 32) { ws.send(silence) }
            main.post { flushedAt = SystemClock.elapsedRealtime() }
        }
    }

    override fun letGo() {
        d.hold = false
    }

    override fun hold() {
        d.hold = true
    }

    override fun quiet(ms: Long) {
        d.silenceMs = ms.coerceIn(800, 10_000)
        quietAsked = true
    }

    override fun cancel() {
        if (ended) return
        Log.i(TAG, "session #$id (gpu stream): cancel")
        ended = true
        close()
    }

    private fun close() {
        main.removeCallbacks(watch)
        source.stop()
        send { ws.sendText(VoiceAgentProtocol.STOP) }
        runCatching { io.execute { ws.close() } }
        io.shutdown()
    }

    private fun end(why: String?) {
        if (ended) return
        ended = true
        close()
        val t = text
        Log.i(TAG, "session #$id (gpu stream): end (${t.length} chars, ${finals.size} finals${if (partial.isNotBlank()) " + a partial" else ""}${if (why != null) ", $why" else ""})")
        cb.onEnd(t, why)
    }
}
