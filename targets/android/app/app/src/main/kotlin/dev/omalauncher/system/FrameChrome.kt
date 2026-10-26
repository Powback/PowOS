package dev.omalauncher.system

import android.content.Context
import android.graphics.RectF
import dev.omalauncher.App
import dev.omalauncher.shell.ChromeSlot
import dev.omalauncher.shell.ShellHost
import org.json.JSONArray
import org.json.JSONObject

/** A frame's web surface. DOM rectangles define hit targets; WindowFrame retains the continuous native drag stream. */
class FrameChrome(context: Context, kind: String, private val app: WindowFrame.App, private val act: (String) -> Unit) : ChromeSlot {
    private val data = JSONObject().put("kind", kind).put("title", app.title ?: "Application").put("maximised", false)
    private val density = context.resources.displayMetrics.density
    private val host = ShellHost(context, null, (context.applicationContext as App).runtime, if (kind == "grip") "windowgrip" else "windowbar")
    val web get() = host.web
    private var targets = emptyList<Button>()

    init { host.bridge.chrome = this }
    override fun state(): JSONObject {
        val runtime = (web.context.applicationContext as App).runtime
        val found = runtime.androidApps.apps.firstOrNull { it.component.packageName == app.pkg }
        val icon = found?.let { dev.omalauncher.shell.ShellIcons.url("a:${it.key}", runtime.androidApps.icons[it.key]) }
        data.put("icon", icon ?: JSONObject.NULL)
        return data
    }
    override fun action(name: String) { if (name in setOf("minimise", "maximise", "close")) act(name) }
    override fun regions(regions: JSONArray) {
        targets = (0 until regions.length()).mapNotNull { i ->
            val r = regions.getJSONObject(i)
            val name = r.optString("action")
            if (name !in setOf("minimise", "maximise", "close")) return@mapNotNull null
            val x = r.getDouble("x").toFloat() * density
            val y = r.getDouble("y").toFloat() * density
            val w = r.getDouble("width").toFloat() * density
            val h = r.getDouble("height").toFloat() * density
            if (!x.isFinite() || !y.isFinite() || !w.isFinite() || !h.isFinite() || w <= 0 || h <= 0) return@mapNotNull null
            Button(name, RectF(x, y, x + w, y + h))
        }
    }
    fun buttonAt(x: Float, y: Float): Pair<Button, () -> Unit>? = targets.firstOrNull { it.rect.contains(x, y) }?.let { it to { action(it.contentDescription) } }
    fun maximised(on: Boolean) {
        if (data.optBoolean("maximised") == on) return
        data.put("maximised", on)
        host.bridge.emit("chrome.changed", data)
    }
    fun destroy() = host.destroy()

    inner class Button(val contentDescription: String, val rect: RectF) {
        val left get() = rect.left
        val right get() = rect.right
        val top get() = rect.top
        val bottom get() = rect.bottom
        var isPressed = false
            set(value) {
                if (field == value) return
                field = value
                data.put("pressed", if (value) contentDescription else JSONObject.NULL)
                host.bridge.emit("chrome.changed", data)
            }
    }
}
