package dev.omalauncher.shell

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import dev.omalauncher.Runtime
import dev.omalauncher.widgets.lang.Bool
import dev.omalauncher.widgets.lang.Num
import dev.omalauncher.widgets.lang.Obj
import dev.omalauncher.widgets.lang.Str
import dev.omalauncher.widgets.lang.Value
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
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
    private var listening: Job? = null

    fun state(): JSONObject {
        if (listening == null) listening = scope.launch { media.updates().drop(1).collect { emit("media.changed", json(it)) } }
        return json(media.value())
    }

    /** "toggle", "play", "pause", "next", "previous", "open" (the playing app). */
    fun control(command: String) = media.control(command)

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

    fun close() {
        listening?.cancel()
    }

    private fun json(v: Value): JSONObject {
        val out = JSONObject()
        (v as? Obj)?.fields?.forEach { (k, x) ->
            out.put(
                k,
                when (x) {
                    is Str -> x.v
                    is Num -> x.v.takeIf { it.isFinite() } ?: JSONObject.NULL
                    is Bool -> x.v
                    else -> JSONObject.NULL
                },
            )
        }
        return out
    }

    companion object {
        private const val TAG = "PowosMedia"
        private const val ACTION_OUTPUT = "com.android.systemui.action.LAUNCH_MEDIA_OUTPUT_DIALOG"
    }
}
