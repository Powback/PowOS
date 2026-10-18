package dev.omalauncher.shell

import android.app.Activity
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.compose.runtime.snapshotFlow
import dev.omalauncher.Runtime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The host API (shell/bridge.d.ts) for the WebView: the page calls `PowosHost.call(id, method, argsJson)` and gets
 * its answer through `window.__powosHost.resolve(id, json)` or `.reject(id, message)`; events go to
 * `window.__powosHost.emit(name, json)`. shell/bridge.js wraps this into window.powos.
 *
 * Everything runs on the main thread: the launcher's state (apps, usage, icons) is Compose state, read and written
 * there, as the Compose launcher does.
 */
class ShellBridge(
    private val activity: Activity,
    private val runtime: Runtime,
    private val web: WebView,
) {
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val data get() = File(activity.filesDir, "shell-data").apply { mkdirs() }
    private val home = ShellHome(runtime)
    private var lastInsets = JSONObject().put("top", 0).put("bottom", 0).put("left", 0).put("right", 0).put("keyboard", 0)

    init {
        // Installs, removals and Linux apps arriving: the page reloads its list.
        scope.launch {
            snapshotFlow { runtime.androidApps.apps.size to runtime.linuxApps.size }.drop(1).collect { emit("apps.changed", null) }
        }
        scope.launch { runtime.refreshApps() }
        // The home screen changed (here, in the Compose launcher, or a widget file arriving): the page re-reads it.
        scope.launch { snapshotFlow { home.fingerprint() }.drop(1).collect { emit("home.changed", null) } }
    }

    @JavascriptInterface
    fun call(
        id: Int,
        method: String,
        args: String,
    ) {
        main.post {
            try {
                val a = if (args.isBlank()) JSONArray() else JSONArray(args)
                respond(id, dispatch(method, a))
            } catch (e: Exception) {
                Log.w(TAG, "$method failed", e)
                js("window.__powosHost.reject($id, ${JSONObject.quote(e.message ?: e.toString())})")
            }
        }
    }

    private fun dispatch(
        method: String,
        a: JSONArray,
    ): Any? =
        when (method) {
            "apps.list" -> apps()
            "apps.launch" -> launch(a.getString(0))
            "apps.info" -> android(a.getString(0))?.let { runtime.androidApps.openInfo(it) }
            "apps.uninstall" -> android(a.getString(0))?.let { runtime.androidApps.uninstall(it) }
            "usage.recent" -> JSONArray(installed(runtime.usage.recent).take(a.optInt(0, 5)))
            "store.get" -> store(a.getString(0)).takeIf { it.isFile }?.readText()?.let { RawJson(it) }
            "store.set" -> store(a.getString(0)).writeText(a.get(1).let { if (it is String) JSONObject.quote(it) else it.toString() })
            "keyboard.show" -> keyboard(true)
            "keyboard.hide" -> keyboard(false)
            "system.insets" -> lastInsets
            "home.get" -> home.snapshot()
            "home.place" -> home.place(a.getString(0), a.getJSONObject(1), a.getInt(2))
            "home.add" -> home.add(a.getString(0), a.getInt(1), a.optJSONObject(2))
            "home.remove" -> home.remove(a.getString(0))
            "home.group" -> home.group(a.getString(0), a.getString(1))
            else -> throw IllegalArgumentException("no such call: $method")
        }

    private fun apps(): JSONArray {
        val list = JSONArray()
        for (app in runtime.androidApps.apps) {
            list.put(
                JSONObject()
                    .put("key", "a:${app.key}")
                    .put("label", app.label)
                    .put("icon", icon("a:${app.key}"))
                    .put("kind", "android")
                    .put("work", app.work)
                    .put("clone", app.clone)
                    .put("system", app.system),
            )
        }
        for (app in runtime.linuxApps) {
            list.put(
                JSONObject()
                    .put("key", "l:${app.id}")
                    .put("label", app.name)
                    .put("icon", icon("l:${app.id}"))
                    .put("kind", "linux"),
            )
        }
        return list
    }

    private fun icon(key: String) = "${ShellActivity.ORIGIN}/_icon/${Uri.encode(key)}"

    /** Recent keys still installed, in the page's form ("a:…" / "l:…"). */
    private fun installed(keys: List<String>): List<String> {
        val have = runtime.androidApps.apps.map { "a:${it.key}" }.toSet() + runtime.linuxApps.map { "l:${it.id}" }
        return keys.filter { it in have }
    }

    private fun android(key: String) = runtime.androidApps.apps.firstOrNull { "a:${it.key}" == key }

    private fun launch(key: String) {
        runtime.usage.record(key)
        when {
            key.startsWith("a:") -> android(key)?.let { runtime.androidApps.open(it) }
            key.startsWith("l:") -> runtime.linuxApps.firstOrNull { "l:${it.id}" == key }?.let { runtime.launch(it) }
        }
        // The strip shows it first next time home shows (the Compose launcher settles on stop, likewise).
        runtime.usage.settle()
    }

    /** One of the shell's data files: a plain name, so the page can't reach outside its folder. */
    private fun store(name: String): File {
        require(name.matches(Regex("[A-Za-z0-9_.-]+")) && !name.startsWith(".")) { "bad store name: $name" }
        return File(data, "$name.json")
    }

    private fun keyboard(show: Boolean) {
        val imm = activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        if (show) {
            web.requestFocus()
            imm.showSoftInput(web, 0)
        } else {
            imm.hideSoftInputFromWindow(web.windowToken, 0)
        }
    }

    /** The window's insets in CSS px, sent as "system.insets" when they change (the keyboard's included). */
    fun insets(w: WindowInsets) {
        val d = activity.resources.displayMetrics.density
        val bars = w.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
        val ime = w.getInsets(WindowInsets.Type.ime())
        val next =
            JSONObject()
                .put("top", bars.top / d)
                .put("bottom", bars.bottom / d)
                .put("left", bars.left / d)
                .put("right", bars.right / d)
                .put("keyboard", ime.bottom / d)
        if (next.toString() == lastInsets.toString()) return
        lastInsets = next
        emit("system.insets", next)
    }

    fun emit(
        event: String,
        payload: Any?,
    ) {
        val json =
            when (payload) {
                null -> "null"
                is Map<*, *> -> JSONObject(payload).toString()
                else -> payload.toString()
            }
        main.post { js("window.__powosHost && window.__powosHost.emit(${JSONObject.quote(event)}, $json)") }
    }

    private fun respond(
        id: Int,
        result: Any?,
    ) {
        val json =
            when (result) {
                null, Unit -> "null"
                is String -> JSONObject.quote(result)
                is RawJson -> result.text
                else -> result.toString()
            }
        js("window.__powosHost.resolve($id, $json)")
    }

    private fun js(code: String) = web.evaluateJavascript(code, null)

    fun close() = scope.cancel()

    /** Stored JSON, passed through as it is. */
    private class RawJson(
        val text: String,
    )

    private companion object {
        const val TAG = "PowosShell"
    }
}
