package dev.omalauncher.shell

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.PowerManager
import android.util.Log
import dev.omalauncher.Runtime
import dev.omalauncher.widgets.lang.Bool
import dev.omalauncher.widgets.lang.Lst
import dev.omalauncher.widgets.lang.Num
import dev.omalauncher.widgets.lang.Obj
import dev.omalauncher.widgets.lang.Str
import dev.omalauncher.widgets.lang.Value
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/**
 * What's playing, for the control center's media card (shell/ui/control.tsx): the runtime's media session watcher (the
 * widgets' android.media), its controls, and the phone's output picker. Changes reach the page ("media.changed") once it
 * has asked - a page that never shows the card doesn't keep the session's second-by-second ticker running.
 */
class ShellMedia(
    private val context: Context,
    private val runtime: Runtime,
    private val scope: CoroutineScope,
    private val emit: (String, Any?) -> Unit,
) {
    private val media get() = runtime.widgets.media
    private val power = context.getSystemService(PowerManager::class.java)
    private var listening: Job? = null

    /**
     * The session shown (as before), with every active one up to [SESSIONS] under "sessions": the control center's cards
     * (it shows two) and the lock face's (it swipes between them all).
     */
    fun state(): JSONObject {
        if (listening == null) {
            // Screen off, the page isn't told each second's position (the lock face's page stays warm all night); the
            // screen back on, it's told what it missed at once (screenOn), whatever changed meanwhile (a headset's pause).
            listening = scope.launch { media.updates { if (power.isInteractive) read() else null }.drop(1).collect { v -> v?.let { emit("media.changed", json(it)) } } }
            context.registerReceiver(screenOn, IntentFilter(Intent.ACTION_SCREEN_ON))
        }
        return json(read()) as JSONObject
    }

    private fun read(): Value = Obj(((media.value() as? Obj)?.fields ?: emptyMap()) + ("sessions" to media.sessions(SESSIONS)))

    /** "toggle", "play", "pause", "next", "previous", "open" (the playing app); on [pkg]'s session when named. */
    fun control(
        command: String,
        pkg: String? = null,
    ) = media.control(command, pkg)

    /** Moves [pkg]'s session to [seconds] in. */
    fun seek(
        pkg: String?,
        seconds: Double,
    ) = media.seek(pkg, seconds)

    /**
     * The phone's output picker for what's playing (phone speaker, Bluetooth, cast): SystemUI's own dialog.
     * HACK: SystemUI's MediaOutputDialogReceiver is its internal entry (the stock media card's button). Real fix: none
     * public - MediaRouter2's system routes list them, but switching another app's output takes MEDIA_CONTENT_CONTROL.
     */
    fun output(pkg: String?) {
        val intent =
            Intent(ACTION_OUTPUT)
                .setComponent(ComponentName("com.android.systemui", "com.android.systemui.media.dialog.MediaOutputDialogReceiver"))
                .putExtra("package_name", pkg ?: context.packageName)
        runCatching { context.sendBroadcast(intent) }.onFailure { Log.w(TAG, "can't open the output picker", it) }
    }

    private val screenOn =
        object : BroadcastReceiver() {
            override fun onReceive(
                c: Context,
                intent: Intent,
            ) {
                scope.launch { emit("media.changed", json(read())) }
            }
        }

    fun close() {
        if (listening != null) runCatching { context.unregisterReceiver(screenOn) }
        listening?.cancel()
    }

    private fun json(x: Value): Any =
        when (x) {
            is Obj -> JSONObject().also { out -> x.fields.forEach { (k, v) -> out.put(k, json(v)) } }
            is Lst -> JSONArray().also { out -> x.items.forEach { out.put(json(it)) } }
            else -> scalar(x)
        }

    private fun scalar(x: Value): Any =
        when (x) {
            is Str -> x.v
            is Num -> x.v.takeIf { it.isFinite() } ?: JSONObject.NULL
            is Bool -> x.v
            else -> JSONObject.NULL
        }

    companion object {
        private const val TAG = "PowosMedia"
        private const val SESSIONS = 4
        private const val ACTION_OUTPUT = "com.android.systemui.action.LAUNCH_MEDIA_OUTPUT_DIALOG"
    }
}
