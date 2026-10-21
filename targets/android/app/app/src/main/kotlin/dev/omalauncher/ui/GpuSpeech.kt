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
import java.util.concurrent.LinkedBlockingQueue
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * Which engine dictates (Settings > voice > transcription, the shell's store "speech": {"engine": "gpu"|"ondevice"}).
 * GPU (the default): Whisper on the GPU box (stt.pow, [SttServer]) from PowOS's own recording ([GpuSession]); on-device:
 * Android's recognizer ([NativeSpeech]). Every dictation (the mic, hold to talk, the side button) starts here: one
 * session at a time across both engines, the latest start wins.
 */
internal object SpeechEngines {
    private const val TAG = "speech"
    const val GPU = "gpu"
    const val ON_DEVICE = "ondevice"

    private var current: SpeechSession? = null
    private var ids = 0

    fun choice(c: Context): String =
        runCatching {
            JSONObject(File(c.filesDir, "shell-data/speech.json").readText()).optString("engine", GPU)
        }.getOrDefault(GPU).takeIf { it == ON_DEVICE } ?: GPU

    fun start(
        c: Context,
        hold: Boolean,
        callbacks: SpeechCallbacks,
    ): SpeechSession {
        current?.cancel()
        val app = c.applicationContext
        val engine = choice(app)
        val s =
            if (engine == GPU && !SttServer.knownDown()) {
                callbacks.onEngine(GPU)
                GpuSession(++ids, app, hold, callbacks, MicSource()).also { it.begin() }
            } else {
                if (engine == GPU) Log.i(TAG, "stt.pow is down (checked ${SttServer.checkedAgoMs() / 1000} s ago): on-device")
                callbacks.onEngine(ON_DEVICE)
                NativeSpeech.start(app, hold, callbacks)
            }
        current = s
        return s
    }

    fun warm(c: Context) {
        if (choice(c) == GPU) SttServer.checkIfStale()
        NativeSpeech.warm(c)
    }

    /**
     * A test with recorded audio instead of the mic (16 kHz mono 16-bit WAV under the app's files/speech-test/): the
     * whole dictation as a tap's, logged as "test: ..." - nothing reaches a page. [mode]: "gpu" (as a dictation would),
     * "fallback" (stt.pow made to fail after its first answer: the rest replays into the on-device recognizer), "down"
     * (stt.pow known down before the start: on-device from the file).
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
            else -> {
                cb.onEngine(GPU)
                GpuSession(++ids, app, false, cb, FileSource(f), failAfterFirst = mode == "fallback").begin()
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

    fun knownDown() = healthy == false && fresh()

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

    /** stt.pow answered, but not 200. A 500 is mostly "no speech in this audio" (its VAD found none), not "down". */
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
                val min = AudioRecord.getMinBufferSize(SttServer.RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                val rec =
                    runCatching {
                        AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, SttServer.RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, 640 * 8))
                    }.getOrNull()
                if (rec == null || rec.state != AudioRecord.STATE_INITIALIZED) {
                    Log.w("speech", "the mic didn't open")
                    rec?.release()
                    return@Thread
                }
                val buf = ByteArray(640)
                try {
                    rec.startRecording()
                    while (running) {
                        val n = rec.read(buf, 0, buf.size)
                        if (n > 0) onPcm(buf, n) else if (n < 0) break
                    }
                } finally {
                    runCatching { rec.stop() }
                    rec.release()
                }
            }, "speech-mic").apply { start() }
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
 * pace, a writer thread keeps the recorder from ever blocking.
 */
internal class AudioFeed(
    backlog: ByteArray,
) {
    private val q = LinkedBlockingQueue<ByteArray>()
    private val eof = ByteArray(0)

    @Volatile private var out: OutputStream? = null

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
                val o = synchronized(this) { out }
                if (o == null) {
                    // Nothing listening yet (between two listens): kept for the next one, in order.
                    synchronized(this) { pendingWhileClosed.add(b) }
                    continue
                }
                try {
                    o.write(b)
                } catch (e: IOException) {
                    synchronized(this) { if (out === o) out = null }
                }
            }
        }, "speech-feed").apply {
            isDaemon = true
            start()
        }
    }

    private val pendingWhileClosed = ArrayList<ByteArray>()

    /** A new pipe for one listen: its read end goes in the intent. */
    fun open(): ParcelFileDescriptor {
        val (r, w) = ParcelFileDescriptor.createPipe()
        synchronized(this) {
            runCatching { out?.close() }
            val o = ParcelFileDescriptor.AutoCloseOutputStream(w)
            // What came while no listen was reading, first.
            runCatching { for (b in pendingWhileClosed) o.write(b) }
            pendingWhileClosed.clear()
            out = o
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
 * Falls back to Android's recognizer FOR THIS SESSION when stt.pow is down (the health check), errs, or is slow (no
 * answer within [FIRST_ANSWER_MS] of the first voice, or a request over its timeout): what wasn't transcribed yet -
 * from the first unfinished segment's start - replays into it from the recording, then live, so nothing said is lost.
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
        private const val FIRST_ANSWER_MS = 1500L
        private const val PARTIAL_READ_MS = 1500
        private const val FINAL_READ_MS = 4000
        private const val BYTES_PER_MS = 32
        private const val PAUSE_MS = 700L
        private const val MIN_SEGMENT_MS = 1200L
        private const val MAX_SEGMENT_MS = 25_000L
        private const val MIN_NEW_AUDIO_MS = 250L
        private const val MAX_SESSION_MS = 5 * 60_000L
        private const val STOP_GRACE_MS = 4000L
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

    /** stt.pow's 500s in a row (its "no speech" answer, [SttServer.HttpError]); touched on the network thread only. */
    @Volatile private var emptyRuns = 0
    private var inFlight = false
    private var inFlightSince = 0L
    private var partialUpTo = 0
    private var language: String? = null
    private var ended = false
    private var stopAt = 0L

    /** After a fallback: Android's recognizer, fed from the recording. */
    private var inner: SpeechSession? = null
    private var feed: AudioFeed? = null
    private var innerText = ""

    // Voice from loudness: above the room's own floor (tracked slowly upward, at once downward).
    private var floorDb = -60.0

    val text get() = segs.joinToString(" ") { it.text.trim() }.trim().let { if (innerText.isBlank()) it else "$it $innerText".trim() }

    fun begin() {
        Log.i(TAG, "session #$id (gpu): start (${if (d.hold) "hold" else "tap"})")
        if (!SttServer.knownUp()) {
            SttServer.check { ok -> if (!ok && !ended) fallBack("stt.pow didn't answer its health check") }
        }
        source.start { b, n ->
            val db = db(b, n)
            synchronized(pcm) { pcm.write(b, 0, n) }
            feed?.write(b.copyOf(n))
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
        if (inner != null || d.stopping) return
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
        if (inFlight || ended || inner != null) return
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
        // At least 1 s: stt.pow answers 500 to a clip under ~0.5 s (2026-10-21); trailing silence doesn't change the words.
        val audio = slice(s.start, to).let { if (it.size < 1000 * BYTES_PER_MS) it.copyOf(1000 * BYTES_PER_MS) else it }
        val prompt = segs.takeWhile { it !== s }.joinToString(" ") { it.text }
        val lang = language
        inFlight = true
        inFlightSince = SystemClock.elapsedRealtime()
        if (!final) partialUpTo = to
        net.execute {
            val r =
                runCatching {
                    if (failAfterFirst && answers > 0) throw IOException("test: made to fail")
                    try {
                        SttServer.transcribe(audio, lang, prompt, if (final) FINAL_READ_MS else PARTIAL_READ_MS)
                    } catch (e: SttServer.HttpError) {
                        // HACK: stt-batch answers 500 for audio its VAD finds no speech in (silence, a breath) instead
                        // of {"text": ""}. Real fix: return empty text there (gpu-195 stt-batch). Until then a 500 is
                        // "nothing heard" - it's up, it answered - and only three in a row count as failing.
                        if (e.code != 500 || ++emptyRuns >= 3) throw e
                        SttServer.Heard("", null)
                    }
                }
            main.post {
                inFlight = false
                if (ended || inner != null) return@post
                r.onSuccess { h ->
                    if (h.text.isNotEmpty()) emptyRuns = 0
                    answers++
                    SttServer.markUp()
                    if (language == null && audio.size >= 1500 * BYTES_PER_MS) language = h.language
                    if (s.final) return@onSuccess
                    // Whisper's words for silence or noise: nothing.
                    s.text = if (hallucination(h.text)) "" else h.text
                    if (final) s.final = true
                    if (answers == 1) Log.i(TAG, "session #$id (gpu): first words ${SystemClock.elapsedRealtime() - startedAt} ms after the start")
                    cb.onText(text)
                    if (d.stopping && segs.all { it.final || (it === live && it.end < 0 && !it.voiced) }) end(null) else pump()
                }.onFailure {
                    SttServer.markDown("${it.javaClass.simpleName}: ${it.message}")
                    fallBack("stt.pow failed (${it.message})")
                }
            }
        }
    }

    private fun hallucination(t: String) =
        t.trim().lowercase().trimEnd('.', '!').let { it.isEmpty() || it in setOf("thank you", "thanks for watching", "you", "bye") }

    private val watch =
        object : Runnable {
            override fun run() {
                if (ended) return
                val now = SystemClock.elapsedRealtime()
                when {
                    inner != null -> return
                    d.silent() -> {
                        Log.i(TAG, "session #$id (gpu): silence, ending the dictation")
                        stop()
                    }
                    now - startedAt > MAX_SESSION_MS -> {
                        Log.w(TAG, "session #$id (gpu): listened ${MAX_SESSION_MS / 60_000} min, ending the dictation")
                        stop()
                    }
                    answers == 0 && firstVoiceAt > 0 && now - firstVoiceAt > FIRST_ANSWER_MS -> {
                        SttServer.markDown("no answer ${now - firstVoiceAt} ms after the first voice")
                        return fallBack("stt.pow is slow")
                    }
                    inFlight && now - inFlightSince > FINAL_READ_MS + 500 -> return fallBack("a request hung")
                    d.stopping && now - stopAt > STOP_GRACE_MS -> return fallBack("finals didn't come in time")
                }
                if (!ended) main.postDelayed(this, 100)
            }
        }

    /**
     * This session goes on with Android's recognizer, from the first segment stt.pow hasn't finished: that audio
     * replays from the recording, then the live mic follows through the same pipe. What stt.pow finished stays.
     */
    private fun fallBack(why: String) {
        if (ended || inner != null) return
        val from = segs.firstOrNull { !it.final }?.start ?: recorded()
        val kept = segs.filter { it.final }
        val backlog = slice(from, recorded())
        Log.w(TAG, "session #$id (gpu): falling back to on-device ($why), replaying ${backlog.size / BYTES_PER_MS} ms")
        segs.retainAll(kept)
        cb.onEngine(SpeechEngines.ON_DEVICE)
        val f = AudioFeed(backlog)
        feed = f
        val stopping = d.stopping
        if (stopping) {
            // Already let go: the recording is all there is - end of file after it, and the recognizer ends with it.
            source.stop()
            f.finish()
        }
        inner =
            NativeSpeech.start(
                c,
                d.hold,
                SpeechCallbacks(
                    onText = {
                        innerText = it
                        cb.onText(text)
                    },
                    onLevel = cb.onLevel,
                    onEnd = { heard, err ->
                        innerText = heard
                        end(if (text.isBlank()) err else null)
                    },
                ),
                f,
            ).also { if (d.silenceMs != NativeSpeech.TAP_SILENCE_MS) it.quiet(d.silenceMs) }
    }

    override fun stop() {
        if (ended) return
        inner?.let {
            Log.i(TAG, "session #$id (gpu): stop (on-device)")
            source.stop()
            feed?.finish()
            return it.stop()
        }
        if (d.stopping) return
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
        inner?.letGo()
    }

    override fun hold() {
        d.hold = true
        inner?.hold()
    }

    override fun quiet(ms: Long) {
        d.silenceMs = ms.coerceIn(800, 10_000)
        inner?.quiet(ms)
    }

    override fun cancel() {
        if (ended) return
        ended = true
        Log.i(TAG, "session #$id (gpu): cancel")
        main.removeCallbacks(watch)
        source.stop()
        inner?.cancel()
        feed?.close()
    }

    private fun end(why: String?) {
        if (ended) return
        ended = true
        main.removeCallbacks(watch)
        source.stop()
        feed?.close()
        val t = text
        Log.i(TAG, "session #$id (gpu): end (${t.length} chars, ${segs.size} segments${if (why != null) ", $why" else ""})")
        cb.onEnd(t, why)
    }
}
