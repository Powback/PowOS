package dev.omalauncher.system

import android.app.AppOpsManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.CopyOnWriteArraySet

/**
 * Which privacy-sensitive ops each app has active right now - the camera, the microphone, the screen, location - from
 * AppOps' active-op callbacks. One source for two views: the recording light (shell/ui/chrome.tsx RecordingRing: camera,
 * screen, mic) and the shade's privacy row (shell/ui/privacy.tsx: one chip per app, location too, kept [GRACE_MS] after
 * it stops). Pure: [RecordingWatcher] feeds it, the JVM tests drive it ([clock]: epoch ms, theirs a hand-moved one).
 */
class RecordingOps(private val clock: () -> Long = System::currentTimeMillis) {
    /**
     * What's in use. The ring's colours in its priority order: the camera's green beats the screen's red beats the mic's
     * orange; location lights no ring (only the shade's row names it).
     */
    enum class Kind(val key: String, val ring: Boolean = true) { CAMERA("camera"), SCREEN("screen"), MIC("mic"), LOCATION("location", ring = false) }

    data class State(val kinds: Set<Kind>, val apps: List<String>) {
        /** The one colour the ring takes (null: off) - the first of [Kind]'s order that's active and lights it. */
        val ring: Kind? get() = Kind.values().firstOrNull { it.ring && it in kinds }
    }

    /**
     * One app's chip in the shade's privacy row: what it uses (or used within [GRACE_MS]) in [Kind]'s order, whether any
     * of it is still on, and when the last of it stopped (epoch ms; null while [active]).
     */
    data class Chip(val pkg: String, val uid: Int, val kinds: List<Kind>, val active: Boolean, val ended: Long?)

    private data class Use(val op: String, val uid: Int, val pkg: String)
    private val active = linkedSetOf<Use>()
    /** Uses that stopped, and when: the row keeps them, greyed, for [GRACE_MS]. */
    private val ended = linkedMapOf<Use, Long>()
    /**
     * Live mic captures Android names no app for - the non-root path ([captures]): without WATCH_APPOPS AppOps reports
     * PowOS's own uid only, but AudioManager's recording callback still reports every app's capture (uid and package
     * blanked). They light the ring (no app named) and add no chip.
     */
    private var anonymousMic = 0
    /**
     * AudioManager's recordings have been reported at least once ([captures]): from then on an app's RECORD_AUDIO op lights
     * the ring only while a capture really runs. AppOps keeps the op started for a client Android silences (a background
     * app fed zeros) or one stuck between start and stop - the ring was on with the mic at rest (board task "mic/recording
     * glow shows on when the mic isn't actually capturing"); SystemUI's own indicator filters it the same way.
     */
    private var recordingsKnown = false

    /** One callback: [op] started or stopped for [uid]/[pkg] (now). True when anything either view shows changed. */
    fun changed(op: String, uid: Int, pkg: String, on: Boolean): Boolean {
        if (kind(op) == null) return false
        val use = Use(op, uid, pkg)
        if (on) {
            ended -= use
            return active.add(use)
        }
        if (!active.remove(use)) return false
        ended[use] = clock()
        return true
    }

    /**
     * AudioManager's current recordings, as (audio source, silenced) - the whole list each time it calls. Only the ones
     * really capturing count ([capturing]): a silenced client (Android feeds a background app zeros) or the hotword
     * detector is not the mic in use, and lights no ring - the same rule as Android's own mic indicator. True when
     * whether any such capture runs changed.
     */
    fun captures(recordings: List<Pair<Int, Boolean>>): Boolean {
        val was = anonymousMic > 0
        val before = state()
        recordingsKnown = true
        anonymousMic = recordings.count { (source, silenced) -> capturing(source, silenced) }
        return was != (anonymousMic > 0) || state() != before
    }

    /**
     * A use the ring shows now: an app's RECORD_AUDIO only while a real capture runs ([recordingsKnown]); a phone call's
     * mic, the camera, the screen and location as AppOps says.
     */
    private fun lit(use: Use) = use.op != OP_RECORD_AUDIO || !recordingsKnown || anonymousMic > 0

    /** The ring's view: what's on now. Its apps: the ones using what lights it (location alone names no one there). */
    fun state(): State {
        val on = active.filter(::lit)
        return State(
            on.mapNotNull { kind(it.op) }.toSet() + (if (anonymousMic > 0) setOf(Kind.MIC) else emptySet()),
            on.filter { kind(it.op)?.ring == true }.map { it.pkg }.distinct(),
        )
    }

    /**
     * The row's view at [now]: one chip per app (package and uid), the ones still using something first (in the order
     * they started), then the recently stopped, the latest first. A stop older than [GRACE_MS] is gone.
     */
    fun chips(now: Long = clock()): List<Chip> {
        ended.entries.removeAll { now - it.value >= GRACE_MS }
        val apps = linkedMapOf<Pair<String, Int>, MutableList<Use>>()
        for (use in active + ended.keys) apps.getOrPut(use.pkg to use.uid) { mutableListOf() } += use
        return apps.map { (app, uses) ->
            val on = uses.any { it in active }
            val kinds = uses.mapNotNull { kind(it.op) }.toSet()
            Chip(app.first, app.second, Kind.values().filter { it in kinds }, on, if (on) null else uses.maxOf { ended[it] ?: 0L })
        }.sortedWith(compareBy<Chip> { !it.active }.thenByDescending { it.ended ?: 0L })
    }

    /** When the next recently-stopped chip leaves the row (epoch ms), or null when none waits. */
    fun nextExpiry(): Long? = ended.values.minOrNull()?.plus(GRACE_MS)

    companion object {
        /** How long a stopped use stays in the shade's row, greyed ("Xs ago") - long enough to see who it was. */
        const val GRACE_MS = 15_000L

        const val OP_CAMERA = "android:camera" // AppOpsManager.OPSTR_CAMERA
        const val OP_PHONE_CALL_CAMERA = "android:phone_call_camera" // OPSTR_PHONE_CALL_CAMERA
        const val OP_RECORD_AUDIO = "android:record_audio" // OPSTR_RECORD_AUDIO
        const val OP_PHONE_CALL_MICROPHONE = "android:phone_call_microphone" // OPSTR_PHONE_CALL_MICROPHONE
        const val OP_PROJECT_MEDIA = "android:project_media" // hidden OPSTR_PROJECT_MEDIA: screen capture
        const val OP_FINE_LOCATION = "android:fine_location" // OPSTR_FINE_LOCATION
        const val OP_COARSE_LOCATION = "android:coarse_location" // OPSTR_COARSE_LOCATION
        /**
         * Hidden OPSTR_MONITOR_HIGH_POWER_LOCATION: started for as long as an app holds a high-accuracy (GPS) location
         * request - the active op a navigation or tracking app keeps on. Fine/coarse are mostly noted per fix rather than
         * started, so this is what makes a long location use show; the low-power monitor op is left out (Play services
         * holds it nearly always, it would never leave the row).
         */
        const val OP_MONITOR_HIGH_POWER_LOCATION = "android:monitor_location_high_power"

        /** The ops watched - the ones SystemUI's privacy indicators show, plus screen capture. */
        val WATCHED =
            listOf(
                OP_CAMERA, OP_PHONE_CALL_CAMERA, OP_RECORD_AUDIO, OP_PHONE_CALL_MICROPHONE, OP_PROJECT_MEDIA,
                OP_FINE_LOCATION, OP_COARSE_LOCATION, OP_MONITOR_HIGH_POWER_LOCATION,
            )

        /** MediaRecorder.AudioSource.HOTWORD (hidden): an always-on wake-word detector, not the mic in use. */
        const val SOURCE_HOTWORD = 1999

        /** One recording AudioManager reports: does it light the mic? Not when silenced, not the hotword detector. */
        fun capturing(source: Int, silenced: Boolean) = !silenced && source != SOURCE_HOTWORD

        fun kind(op: String): Kind? =
            when (op) {
                OP_CAMERA, OP_PHONE_CALL_CAMERA -> Kind.CAMERA
                OP_RECORD_AUDIO, OP_PHONE_CALL_MICROPHONE -> Kind.MIC
                OP_PROJECT_MEDIA -> Kind.SCREEN
                OP_FINE_LOCATION, OP_COARSE_LOCATION, OP_MONITOR_HIGH_POWER_LOCATION -> Kind.LOCATION
                else -> null
            }
    }
}

/**
 * Every app's camera / mic / screen-capture / location use, live (AppOpsManager.startWatchingActive) - ONE watch for the
 * whole app ([shared]): the status bar's recording light and every page's privacy row ("privacy.changed", ShellBridge)
 * read the same [RecordingOps]. Seeing other apps' ops takes WATCH_APPOPS (signature|privileged: the system module's
 * privapp allowlist); without it Android quietly reports only PowOS's own uid - then (non-root: no module) the mic comes
 * from AudioManager's recording callback instead, which reports every app's capture to any app, uid and package blanked:
 * the ring lights, naming no one.
 */
class RecordingWatcher private constructor(context: Context) {
    private val appOps = context.getSystemService(AppOpsManager::class.java)
    private val ops = RecordingOps()
    private val listeners = mutableListOf<AppOpsManager.OnOpActiveChangedListener>()
    private val watchers = CopyOnWriteArraySet<() -> Unit>()
    private val main = Handler(Looper.getMainLooper())
    private val audio = context.getSystemService(AudioManager::class.java)
    /** The non-root mic source (no WATCH_APPOPS): every app's capture, anonymous - see [RecordingOps.captures]. */
    private val recordingCallback =
        object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: List<AudioRecordingConfiguration>) = recordings(configs)
        }
    /** A stopped use's chip leaving the row once its grace is up: the views hear it then, not at the next op. */
    private val expire = Runnable { tell() }

    init {
        if (context.checkSelfPermission(WATCH_APPOPS) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "no $WATCH_APPOPS: other apps' mic from AudioManager's recording callback (no app named), camera/screen PowOS's own only")
        }
        // Always (with WATCH_APPOPS too): the mic lights only while a capture really runs ([RecordingOps.captures]) -
        // an app's RECORD_AUDIO op alone stays started for a silenced client.
        runCatching {
            audio.registerAudioRecordingCallback(recordingCallback, main)
            recordings(audio.activeRecordingConfigurations)
        }.onFailure { Log.w(TAG, "can't watch recordings: ${it.message}") }
        // One op, one listener: an op this Android doesn't know (project_media is hidden) throws and mustn't take the
        // rest - and AppOps keeps a listener's first registration only, so each op needs its own.
        for (op in RecordingOps.WATCHED) {
            val listener = AppOpsManager.OnOpActiveChangedListener { o, uid, pkg, on -> if (ops.changed(o, uid, pkg, on)) tell() }
            runCatching { appOps.startWatchingActive(arrayOf(op), context.mainExecutor, listener); listeners += listener }
                .onFailure { Log.w(TAG, "can't watch $op: ${it.message}") }
        }
    }

    /** On the main thread (AppOps' callbacks and [expire] both run there), like every read of [ops]. */
    private fun tell() {
        main.removeCallbacks(expire)
        ops.chips() // drops the expired ones before nextExpiry
        ops.nextExpiry()?.let { main.postDelayed(expire, maxOf(0L, it - System.currentTimeMillis())) }
        for (w in watchers) w()
    }

    /** Main thread: the callback's handler is [main], the first read is in init (shared() is made on the main thread). */
    private fun recordings(configs: List<AudioRecordingConfiguration>) {
        if (ops.captures(configs.map { it.clientAudioSource to it.isClientSilenced })) tell()
    }

    fun state() = ops.state()

    fun chips() = ops.chips()

    /** [changed] runs (main thread) whenever the ring's or the row's view changed; [unwatch] with the same function. */
    fun watch(changed: () -> Unit) { watchers += changed }

    fun unwatch(changed: () -> Unit) { watchers -= changed }

    companion object {
        private const val TAG = "PowOSRecLight"
        private const val WATCH_APPOPS = "android.permission.WATCH_APPOPS" // Manifest.permission.WATCH_APPOPS is hidden
        @Volatile private var instance: RecordingWatcher? = null

        /** The app's one watch, made on first use (main thread) and kept for the process: AppOps calls cost nothing idle. */
        fun shared(context: Context): RecordingWatcher =
            instance ?: synchronized(this) { instance ?: RecordingWatcher(context.applicationContext).also { instance = it } }
    }
}
