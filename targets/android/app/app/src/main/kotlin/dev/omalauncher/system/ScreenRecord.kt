package dev.omalauncher.system

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.provider.MediaStore
import android.util.Log
import android.view.WindowManager
import dev.omalauncher.R
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max
import kotlin.math.min

/**
 * Screen record without root (the control center's tile on a phone with no recorder app of its own - S25, razr):
 * [ScreenRecordConsentActivity] asks what audio to take (remembered), then Android's own capture consent (once per
 * recording, as stock); [ScreenRecordService] holds the projection as a mediaProjection foreground service and encodes
 * the screen (H.264, the encoder's input surface as the virtual display) plus the chosen audio - the phone's own sound
 * (AudioPlaybackCapture), the microphone, or both mixed (AAC) - into an MP4 in Movies/. Its notification's Stop (or the
 * tile again) ends it; a "saved" notification opens the video.
 */
object ScreenRecord {
    private const val TAG = "PowosScreenRec"
    const val ACTION_START = "com.powos.app.action.SCREEN_RECORD"
    const val ACTION_STOP = "com.powos.app.action.SCREEN_RECORD_STOP"

    /** "none", "internal" (the phone's sound), "mic", "both". */
    const val EXTRA_AUDIO = "audio"
    val AUDIO = listOf("none", "internal", "mic", "both")
    private val AUDIO_LABELS = arrayOf("No audio", "Device audio", "Microphone", "Device audio and microphone")
    private const val PREFS = "powos-screen-record"

    @Volatile internal var service: ScreenRecordService? = null

    /** The consent was given and the service is starting. */
    @Volatile internal var pendingSince = 0L

    /** Recording now (or just granted and starting): the tile's on. */
    fun active(now: Long = System.currentTimeMillis()): Boolean = service != null || (pendingSince > 0 && now - pendingSince < 5_000)

    /** The tile's tap: stops a recording, else asks to start one. */
    fun toggle(context: Context) {
        if (active()) {
            stop(context)
            return
        }
        AppWindows.startActivity(context, Intent(context, ScreenRecordConsentActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun stop(context: Context) {
        pendingSince = 0
        context.startService(Intent(context, ScreenRecordService::class.java).setAction(ACTION_STOP))
    }

    internal fun audio(context: Context): String = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(EXTRA_AUDIO, "none") ?: "none"

    internal fun setAudio(
        context: Context,
        audio: String,
    ) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(EXTRA_AUDIO, audio).apply()

    internal fun labels() = AUDIO_LABELS

    internal fun log(msg: String) = Log.i(TAG, msg)

    internal fun warn(
        msg: String,
        t: Throwable? = null,
    ) = Log.w(TAG, msg, t)
}

/**
 * Asks what audio to record (stock's "Start recording?" sheet), the microphone permission when audio is wanted, then
 * Android's capture consent; the answer starts [ScreenRecordService]. An [ScreenRecord.EXTRA_AUDIO] extra skips the
 * sheet (an intent's start: the shell, a check).
 */
class ScreenRecordConsentActivity : Activity() {
    private var audio = "none"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) {
            audio = savedInstanceState.getString(ScreenRecord.EXTRA_AUDIO, "none")
            return
        }
        val given = intent?.getStringExtra(ScreenRecord.EXTRA_AUDIO)?.takeIf { it in ScreenRecord.AUDIO }
        if (given != null) {
            audio = given
            permit()
            return
        }
        val chosen = intArrayOf(ScreenRecord.AUDIO.indexOf(ScreenRecord.audio(this)).coerceAtLeast(0))
        AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle("Start recording?")
            .setSingleChoiceItems(ScreenRecord.labels(), chosen[0]) { _, i -> chosen[0] = i }
            .setPositiveButton("Start") { _, _ ->
                audio = ScreenRecord.AUDIO[chosen[0]]
                ScreenRecord.setAudio(this, audio)
                permit()
            }
            .setNegativeButton("Cancel") { _, _ -> done() }
            .setOnCancelListener { done() }
            .show()
    }

    // Left (home, another app) before an answer: no recording, nothing left behind in a hidden task.
    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations && !isFinishing) done()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString(ScreenRecord.EXTRA_AUDIO, audio)
    }

    /** The microphone permission (both audio kinds need RECORD_AUDIO), then the capture consent. */
    private fun permit() {
        if (audio != "none" && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC)
        } else {
            consent()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MIC) return
        // Refused: the video still records, silent.
        if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) audio = "none"
        consent()
    }

    private fun consent() {
        val pm = getSystemService(MediaProjectionManager::class.java)
        ScreenRecord.log("consent asked (audio $audio)")
        @Suppress("DEPRECATION")
        startActivityForResult(pm.createScreenCaptureIntent(), CAPTURE)
    }

    @Deprecated("startActivityForResult's answer", ReplaceWith(""))
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == CAPTURE && resultCode == RESULT_OK && data != null) {
            ScreenRecord.pendingSince = System.currentTimeMillis()
            startForegroundService(
                Intent(this, ScreenRecordService::class.java)
                    .setAction(ScreenRecord.ACTION_START)
                    .putExtra(ScreenRecordService.EXTRA_RESULT, data)
                    .putExtra(ScreenRecord.EXTRA_AUDIO, audio),
            )
            ScreenRecord.log("consent granted")
        } else if (requestCode == CAPTURE) {
            ScreenRecord.log("consent declined")
        }
        done()
    }

    private fun done() {
        finish()
        overridePendingTransition(0, 0)
    }

    private companion object {
        const val CAPTURE = 1
        const val MIC = 2
    }
}

/** Holds the projection and the encoders while recording; one recording at a time. */
class ScreenRecordService : Service() {
    private var recording: Recording? = null
    private var thread: HandlerThread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        if (intent?.action == ScreenRecord.ACTION_STOP) {
            finishRecording()
            return START_NOT_STICKY
        }
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Screen recording", NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(NotificationChannel(SAVED_CHANNEL, "Saved screen recordings", NotificationManager.IMPORTANCE_DEFAULT))
        val stop = PendingIntent.getService(this, 0, Intent(this, ScreenRecordService::class.java).setAction(ScreenRecord.ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val note =
            Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Recording the screen")
                .setContentText("Tap to stop")
                .setUsesChronometer(true)
                .setWhen(System.currentTimeMillis())
                .setOngoing(true)
                .setContentIntent(stop)
                .addAction(Notification.Action.Builder(null, "Stop", stop).build())
                .build()
        val audio = intent?.getStringExtra(ScreenRecord.EXTRA_AUDIO) ?: "none"
        val mic = (audio == "mic" || audio == "both") && checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION or (if (mic) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
        runCatching { startForeground(NOTE_ID, note, type) }
            .onFailure {
                ScreenRecord.warn("foreground with the microphone refused, without it", it)
                startForeground(NOTE_ID, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            }
        if (recording != null) return START_NOT_STICKY
        @Suppress("DEPRECATION")
        val data = intent?.getParcelableExtra<Intent>(EXTRA_RESULT)
        val p = data?.let { runCatching { getSystemService(MediaProjectionManager::class.java).getMediaProjection(Activity.RESULT_OK, it) }.getOrNull() }
        if (p == null) {
            ScreenRecord.warn("no projection from the consent")
            ScreenRecord.pendingSince = 0
            stopSelf()
            return START_NOT_STICKY
        }
        val t = HandlerThread("powos-screen-rec").apply { start() }
        thread = t
        val r =
            runCatching { Recording(this, p, audio, Handler(t.looper)) { finishRecording() } }
                .onFailure { ScreenRecord.warn("can't start the recording", it) }
                .getOrNull()
        ScreenRecord.pendingSince = 0
        if (r == null) {
            p.stop()
            stopSelf()
            return START_NOT_STICKY
        }
        recording = r
        ScreenRecord.service = this
        return START_NOT_STICKY
    }

    /** Ends the recording (Stop, the tile, Android ending the projection), saves it, says so. */
    @Synchronized
    private fun finishRecording() {
        val r = recording
        recording = null
        if (ScreenRecord.service === this) ScreenRecord.service = null
        val uri = r?.finish()
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (uri != null) saved(uri)
        stopSelf()
    }

    private fun saved(uri: Uri) {
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "video/mp4").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        val share =
            Intent.createChooser(
                Intent(Intent.ACTION_SEND).setType("video/mp4").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                null,
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val note =
            Notification.Builder(this, SAVED_CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Screen recording saved")
                .setContentText("Tap to view")
                .setAutoCancel(true)
                .setContentIntent(PendingIntent.getActivity(this, 1, view, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
                .addAction(Notification.Action.Builder(null, "Share", PendingIntent.getActivity(this, 2, share, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)).build())
                .build()
        getSystemService(NotificationManager::class.java).notify(SAVED_ID, note)
    }

    override fun onDestroy() {
        recording?.let { finishRecording() }
        if (ScreenRecord.service === this) ScreenRecord.service = null
        thread?.quitSafely()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_RESULT = "result"
        private const val CHANNEL = "powos-screen-record"
        private const val SAVED_CHANNEL = "powos-screen-record-saved"
        private const val NOTE_ID = 0x7372
        private const val SAVED_ID = 0x7373
    }
}

/**
 * One recording: the virtual display drawn into an H.264 encoder's input surface, the audio read, mixed and AAC-encoded
 * on its own thread, both muxed into a pending MediaStore video (Movies/) published on [finish].
 */
private class Recording(
    private val context: Context,
    private val projection: MediaProjection,
    audio: String,
    private val handler: Handler,
    private val ended: () -> Unit,
) {
    private val resolver = context.contentResolver
    private val uri: Uri
    private val pfd: ParcelFileDescriptor
    private val muxer: MediaMuxer
    private val video: MediaCodec
    private val display: VirtualDisplay
    private val audioEncoder: MediaCodec?
    private val sources: List<AudioRecord>
    private val lock = Object()
    private var videoTrack = -1
    private var audioTrack = -1
    private var muxing = false
    private var wrote = false

    @Volatile private var running = true
    private var videoThread: Thread? = null
    private var audioThread: Thread? = null
    private val startNs = System.nanoTime()

    init {
        // Android 14+: the callback before the virtual display.
        projection.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() {
                    if (running) ended()
                }
            },
            handler,
        )
        val bounds = context.getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds
        val (w, h) = size(bounds.width(), bounds.height())
        val dpi = context.resources.displayMetrics.densityDpi
        val name = "Screen_recording_${SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())}.mp4"
        val values =
            ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, name)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
        uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values) ?: error("no MediaStore entry")
        pfd = resolver.openFileDescriptor(uri, "rw") ?: error("can't open $uri")
        muxer = MediaMuxer(pfd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        val vf =
            MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, min(w * h * 6, 20_000_000))
                setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                // Nothing changes on screen, no frame comes: repeat the last so the video keeps its length.
                setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 1_000_000L / FPS * 4)
            }
        video = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        video.configure(vf, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = video.createInputSurface()
        video.start()
        display = projection.createVirtualDisplay("powos-screen-record", w, h, dpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, handler) ?: error("no virtual display")

        sources = audioSources(audio)
        audioEncoder =
            if (sources.isEmpty()) {
                null
            } else {
                MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC).apply {
                    val af =
                        MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, RATE, CHANNELS).apply {
                            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                            setInteger(MediaFormat.KEY_BIT_RATE, 192_000)
                            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, CHUNK * 2)
                        }
                    configure(af, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    start()
                }
            }
        videoThread = Thread({ drainVideo() }, "powos-screen-rec-video").apply { start() }
        audioEncoder?.let { enc ->
            sources.forEach { it.startRecording() }
            audioThread = Thread({ pumpAudio(enc) }, "powos-screen-rec-audio").apply { start() }
        }
        ScreenRecord.log("recording ${w}x$h @$dpi, audio $audio (${sources.size} source(s)) -> $name")
    }

    /** The screen's size, the encoder's way: even, and scaled down until the AVC encoder takes it. */
    private fun size(
        w0: Int,
        h0: Int,
    ): Pair<Int, Int> {
        val caps =
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .firstOrNull { it.isEncoder && MediaFormat.MIMETYPE_VIDEO_AVC in it.supportedTypes.map(String::lowercase) }
                ?.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)?.videoCapabilities
        var scale = 1.0
        while (true) {
            val w = (w0 * scale).toInt() / 16 * 16
            val h = (h0 * scale).toInt() / 16 * 16
            if (caps == null || caps.isSizeSupported(w, h) || w <= 320) return max(w, 16) to max(h, 16)
            scale *= 0.9
        }
    }

    private fun audioSources(audio: String): List<AudioRecord> {
        if (audio == "none" || context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) return emptyList()
        val fmt =
            AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                .build()
        val buf = max(AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT), CHUNK) * 4
        val out = mutableListOf<AudioRecord>()
        if (audio == "internal" || audio == "both") {
            runCatching {
                val cfg =
                    AudioPlaybackCaptureConfiguration.Builder(projection)
                        .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                        .addMatchingUsage(AudioAttributes.USAGE_GAME)
                        .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                        .build()
                @Suppress("MissingPermission")
                AudioRecord.Builder().setAudioFormat(fmt).setBufferSizeInBytes(buf).setAudioPlaybackCaptureConfig(cfg).build()
            }.onSuccess(out::add).onFailure { ScreenRecord.warn("no device audio capture", it) }
        }
        if (audio == "mic" || audio == "both") {
            runCatching {
                @Suppress("MissingPermission")
                AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.MIC).setAudioFormat(fmt).setBufferSizeInBytes(buf).build()
            }.onSuccess(out::add).onFailure { ScreenRecord.warn("no microphone", it) }
        }
        return out.filter { it.state == AudioRecord.STATE_INITIALIZED }.also { ok -> (out - ok.toSet()).forEach(AudioRecord::release) }
    }

    /** Starts the muxer once every track's format is known. */
    private fun addTrack(
        format: MediaFormat,
        isVideo: Boolean,
    ) = synchronized(lock) {
        if (isVideo) videoTrack = muxer.addTrack(format) else audioTrack = muxer.addTrack(format)
        if (videoTrack >= 0 && (audioEncoder == null || audioTrack >= 0)) {
            muxer.start()
            muxing = true
            lock.notifyAll()
        }
    }

    private fun write(
        track: () -> Int,
        codec: MediaCodec,
        index: Int,
        info: MediaCodec.BufferInfo,
    ) {
        synchronized(lock) {
            // The other track's format not known yet: wait for it (briefly), else drop this sample.
            val until = SystemClock.uptimeMillis() + 500
            while (!muxing && running && SystemClock.uptimeMillis() < until) lock.wait(50)
            if (muxing && info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                val buf = codec.getOutputBuffer(index)
                if (buf != null) {
                    buf.position(info.offset).limit(info.offset + info.size)
                    muxer.writeSampleData(track(), buf, info)
                    wrote = true
                }
            }
        }
        codec.releaseOutputBuffer(index, false)
    }

    private fun drainVideo() {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val i = runCatching { video.dequeueOutputBuffer(info, 10_000) }.getOrElse { return }
            when {
                i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> addTrack(video.outputFormat, true)
                i >= 0 -> {
                    write({ videoTrack }, video, i, info)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    /** Reads every source, mixes them (16-bit sum, clamped), feeds the AAC encoder and drains it. */
    private fun pumpAudio(enc: MediaCodec) {
        val shorts = CHUNK / 2
        val mix = ShortArray(shorts)
        val read = ShortArray(shorts)
        val acc = IntArray(shorts)
        val info = MediaCodec.BufferInfo()
        var eos = false
        while (true) {
            if (!eos) {
                acc.fill(0)
                var n = 0
                for (s in sources) {
                    val got = s.read(read, 0, shorts, AudioRecord.READ_BLOCKING)
                    for (k in 0 until max(got, 0)) acc[k] += read[k].toInt()
                    n = max(n, got)
                }
                for (k in 0 until n) mix[k] = acc[k].coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                val idx = runCatching { enc.dequeueInputBuffer(10_000) }.getOrElse { return }
                if (idx >= 0) {
                    val buf = enc.getInputBuffer(idx)!!
                    buf.clear()
                    val bytes = max(n, 0) * 2
                    buf.asShortBuffer().put(mix, 0, max(n, 0))
                    // The surface's clock (System.nanoTime), as the video frames: the muxer lines the tracks up by it.
                    val pts = System.nanoTime() / 1_000
                    if (running) {
                        enc.queueInputBuffer(idx, 0, bytes, pts, 0)
                    } else {
                        enc.queueInputBuffer(idx, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        eos = true
                    }
                }
            }
            while (true) {
                val o = runCatching { enc.dequeueOutputBuffer(info, if (eos) 10_000 else 0) }.getOrElse { return }
                when {
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> addTrack(enc.outputFormat, false)
                    o >= 0 -> {
                        write({ audioTrack }, enc, o, info)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                    }
                    o == MediaCodec.INFO_TRY_AGAIN_LATER && eos -> continue
                    else -> break
                }
            }
        }
    }

    /** Stops everything; the saved video's uri, or null (nothing written: the entry is removed). */
    fun finish(): Uri? {
        if (!running) return null
        running = false
        runCatching { video.signalEndOfInputStream() }
        videoThread?.join(3_000)
        audioThread?.join(3_000)
        sources.forEach {
            runCatching { it.stop() }
            it.release()
        }
        runCatching { display.release() }
        runCatching { projection.stop() }
        runCatching { video.stop() }
        video.release()
        audioEncoder?.let {
            runCatching { it.stop() }
            it.release()
        }
        val ok = synchronized(lock) { muxing && wrote && runCatching { muxer.stop() }.onFailure { ScreenRecord.warn("muxer stop", it) }.isSuccess }
        runCatching { muxer.release() }
        runCatching { pfd.close() }
        val secs = (System.nanoTime() - startNs) / 1_000_000_000
        return if (ok) {
            resolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
            ScreenRecord.log("saved $uri (${secs}s)")
            uri
        } else {
            runCatching { resolver.delete(uri, null, null) }
            ScreenRecord.warn("nothing recorded (${secs}s), entry removed")
            null
        }
    }

    private companion object {
        const val FPS = 60
        const val RATE = 44_100
        const val CHANNELS = 2
        const val CHUNK = 4096
    }
}
