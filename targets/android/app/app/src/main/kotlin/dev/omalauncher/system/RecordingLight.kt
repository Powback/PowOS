package dev.omalauncher.system

import android.app.AppOpsManager
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log

/**
 * The recording light's state (shell/ui/chrome.tsx RecordingRing): which privacy-sensitive ops some app has active
 * right now - the camera, the microphone, the screen - from AppOps' active-op callbacks. Pure: [RecordingWatcher]
 * feeds it, the JVM test drives it.
 */
class RecordingOps {
    /** What the ring shows, in its priority order: the camera's green beats the screen's red beats the mic's orange. */
    enum class Kind(val key: String) { CAMERA("camera"), SCREEN("screen"), MIC("mic") }

    data class State(val kinds: Set<Kind>, val apps: List<String>) {
        /** The one colour the ring takes (null: off) - the first of [Kind]'s order that's active. */
        val ring: Kind? get() = Kind.values().firstOrNull { it in kinds }
    }

    private data class Use(val op: String, val uid: Int, val pkg: String)
    private val active = linkedSetOf<Use>()

    /** One callback: [op] started or stopped for [uid]/[pkg]. True when what the ring shows changed. */
    fun changed(op: String, uid: Int, pkg: String, on: Boolean): Boolean {
        if (kind(op) == null) return false
        val before = state()
        val use = Use(op, uid, pkg)
        if (on) active += use else active -= use
        return state() != before
    }

    fun state() = State(active.mapNotNull { kind(it.op) }.toSet(), active.map { it.pkg }.distinct())

    companion object {
        const val OP_CAMERA = "android:camera" // AppOpsManager.OPSTR_CAMERA
        const val OP_PHONE_CALL_CAMERA = "android:phone_call_camera" // OPSTR_PHONE_CALL_CAMERA
        const val OP_RECORD_AUDIO = "android:record_audio" // OPSTR_RECORD_AUDIO
        const val OP_PHONE_CALL_MICROPHONE = "android:phone_call_microphone" // OPSTR_PHONE_CALL_MICROPHONE
        const val OP_PROJECT_MEDIA = "android:project_media" // hidden OPSTR_PROJECT_MEDIA: screen capture

        /** The ops watched - the ones SystemUI's privacy indicators show, plus screen capture. */
        val WATCHED = listOf(OP_CAMERA, OP_PHONE_CALL_CAMERA, OP_RECORD_AUDIO, OP_PHONE_CALL_MICROPHONE, OP_PROJECT_MEDIA)

        fun kind(op: String): Kind? =
            when (op) {
                OP_CAMERA, OP_PHONE_CALL_CAMERA -> Kind.CAMERA
                OP_RECORD_AUDIO, OP_PHONE_CALL_MICROPHONE -> Kind.MIC
                OP_PROJECT_MEDIA -> Kind.SCREEN
                else -> null
            }
    }
}

/**
 * Every app's camera / mic / screen-capture use, live (AppOpsManager.startWatchingActive). Seeing other apps' ops
 * takes WATCH_APPOPS (signature|privileged: the system module's privapp allowlist); without it Android quietly reports
 * only PowOS's own uid - the ring then lights for PowOS's own mic use only.
 */
class RecordingWatcher(context: Context, private val changed: (RecordingOps.State) -> Unit) {
    private val appOps = context.getSystemService(AppOpsManager::class.java)
    private val ops = RecordingOps()
    private val listeners = mutableListOf<AppOpsManager.OnOpActiveChangedListener>()

    init {
        if (context.checkSelfPermission(WATCH_APPOPS) != PackageManager.PERMISSION_GRANTED)
            Log.w(TAG, "no $WATCH_APPOPS: the recording light sees only PowOS's own camera/mic use")
        // One op, one listener: an op this Android doesn't know (project_media is hidden) throws and mustn't take the
        // rest - and AppOps keeps a listener's first registration only, so each op needs its own.
        for (op in RecordingOps.WATCHED) {
            val listener = AppOpsManager.OnOpActiveChangedListener { o, uid, pkg, on -> if (ops.changed(o, uid, pkg, on)) changed(ops.state()) }
            runCatching { appOps.startWatchingActive(arrayOf(op), context.mainExecutor, listener); listeners += listener }
                .onFailure { Log.w(TAG, "can't watch $op: ${it.message}") }
        }
    }

    fun state() = ops.state()

    fun stop() {
        for (listener in listeners) runCatching { appOps.stopWatchingActive(listener) }
        listeners.clear()
    }

    private companion object {
        const val TAG = "PowOSRecLight"
        const val WATCH_APPOPS = "android.permission.WATCH_APPOPS" // Manifest.permission.WATCH_APPOPS is hidden
    }
}
