package dev.omalauncher.shell

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.content.ClipData
import android.content.ClipboardManager
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
import androidx.compose.runtime.snapshots.Snapshot
import dev.omalauncher.PowosAiActivity
import dev.omalauncher.PowosAiChat
import dev.omalauncher.Runtime
import dev.omalauncher.ui.Palette
import dev.omalauncher.ui.Speech
import dev.omalauncher.linux.Agent
import dev.omalauncher.linux.newAppCommand
import dev.omalauncher.widgets.newWidgetCommand
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import dev.omalauncher.ui.PtyTerminal
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
    private val widgets = ShellWidgets(runtime, scope, ::emit)
    private val terminals = ShellTerminals(runtime, scope, ::emit)
    /** Speech to text for the bar's mic (the Compose prompt bar's): the page gets its state as it changes. */
    private val speech = Speech(activity.applicationContext)
    private var lastInsets = JSONObject().put("top", 0).put("bottom", 0).put("left", 0).put("right", 0).put("keyboard", 0)

    /**
     * What Compose's GlobalSnapshotManager does for a composition: state written outside a snapshot (the widget
     * engine's, the app lists, PowOS AI's chat) is applied - and every snapshotFlow here hears of it - on the next
     * main-thread turn. Without a composition nothing applied it but the odd stray frame: a widget's screen opened
     * a second after its tap.
     */
    private var applyPending = false
    private val applyObserver =
        Snapshot.registerGlobalWriteObserver {
            if (!applyPending) {
                applyPending = true
                main.post {
                    applyPending = false
                    Snapshot.sendApplyNotifications()
                }
            }
        }

    init {
        // The theme picked or recolored (here, in the Compose launcher, a theme file edited): the page recolors.
        scope.launch { snapshotFlow { theme().toString() }.drop(1).collect { emit("theme.changed", JSONObject(it)) } }
        // What's heard so far, while listening (and why it failed).
        scope.launch {
            snapshotFlow { JSONObject().put("listening", speech.listening).put("text", speech.text).put("error", speech.error ?: JSONObject.NULL).toString() }
                .drop(1)
                .collect { emit("speech.state", JSONObject(it)) }
        }
        // Installs, removals, Linux apps and icons arriving (they load in the background, after the list): the page
        // reloads its list, whose icon URLs carry the icon count so a missing icon is asked for again.
        scope.launch {
            snapshotFlow { listOf(runtime.androidApps.apps.size, runtime.linuxApps.size, iconCount()) }.drop(1).collect { emit("apps.changed", null) }
        }
        scope.launch { runtime.refreshApps() }
        // The home screen changed (here, in the Compose launcher, or a widget file arriving): the page re-reads it.
        scope.launch { snapshotFlow { home.fingerprint() }.drop(1).collect { emit("home.changed", null) } }
        // PowOS AI's conversation (shared with its own app): every item and the busy flag, as they stream in.
        PowosAiChat.load(activity.applicationContext)
        scope.launch { snapshotFlow { aiChat().toString() }.drop(1).collect { emit("ai.changed", JSONObject(it)) } }
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
            "ai.chat" -> aiChat()
            "ai.send" -> {
                PowosAiChat.send(activity.applicationContext, a.getString(0))
                // Asked here, it's also an app in the switcher, the same conversation a swipe away.
                PowosAiActivity.keepInRecents(activity)
            }
            "ai.open" -> PowosAiActivity.open(activity, null)
            "theme.get" -> theme()
            "theme.list" -> themeList()
            "theme.pick" -> pickTheme(a.getString(0))
            "screens.open" -> ShellScreensActivity.open(activity, a.getString(0))
            "agents.default" -> runtime.agents.default?.name
            "agents.newWidget" -> withAgent { newWidgetCommand(it.bin) to "New widget" }
            "agents.newApp" -> withAgent { newAppCommand(it.bin) to "New app" }
            "speech.start" -> listen(a.optBoolean(0))
            "speech.stop" -> speech.stop()
            "speech.cancel" -> speech.cancel()
            "keyboard.show" -> keyboard(true)
            "keyboard.hide" -> keyboard(false)
            "system.insets" -> lastInsets
            "home.get" -> home.snapshot()
            "home.place" -> home.place(a.getString(0), a.getJSONObject(1), a.getInt(2))
            "home.add" -> home.add(a.getString(0), a.getInt(1), a.optJSONObject(2))
            "home.remove" -> home.remove(a.getString(0))
            "home.group" -> home.group(a.getString(0), a.getString(1))
            "home.arrange" -> home.arrange(a.getInt(0), a.getInt(1))
            "widgets.watch" -> widgets.watch(a.getString(0), a.optBoolean(1))
            "widgets.unwatch" -> widgets.unwatch(a.getString(0), a.optBoolean(1))
            "widgets.fire" ->
                widgets.fire(
                    a.getString(0),
                    a.optBoolean(1),
                    a.getString(2),
                    a.getString(3),
                    a.optJSONArray(4)?.let { l -> List(l.length()) { l.optDouble(it) } }.orEmpty(),
                )
            "widgets.size" -> widgets.size(a.getString(0), a.getInt(1), a.getInt(2), a.getDouble(3), a.getDouble(4))
            "widgets.canvas" -> widgets.canvas(a.getString(0), a.getString(1), a.getDouble(2), a.getDouble(3))
            "widgets.page" -> widgets.page(a.getInt(0))
            "widgets.tap" -> widgets.tap(a.getString(0))
            "widgets.screen" -> widgets.screen()
            "widgets.closeScreen" -> widgets.closeScreen()
            "term.open" -> terminals.open(a.getString(0), a.optStringOrNull(1), a.optStringOrNull(2), a.getInt(3), a.getInt(4), a.optBoolean(5))
            "term.write" -> terminals.write(a.getString(0), a.getString(1))
            "term.resize" -> terminals.resize(a.getString(0), a.getInt(1), a.getInt(2))
            "term.close" -> terminals.close(a.getString(0))
            "term.style" -> terminalStyle(if (a.isNull(0)) null else a.getDouble(0))
            "clipboard.read" -> clipboard().primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(activity)?.toString()
            "clipboard.write" -> clipboard().setPrimaryClip(ClipData.newPlainText("PowOS", a.getString(0)))
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

    /** The colors in use: the launcher's palette as CSS (what the page's tokens follow), and the theme's own by name. */
    private fun theme(): JSONObject {
        val p = Palette.current
        fun c(color: Color) = WidgetTree.cssColor(color.toArgb())
        val css =
            JSONObject()
                .put("background", c(p.background))
                .put("surface", c(p.surface))
                .put("overlay", c(p.overlay))
                .put("foreground", c(p.foreground))
                .put("muted", c(p.muted))
                .put("accent", c(p.accent))
                .put("border", c(p.border))
                .put("red", c(p.red))
                .put("green", c(p.green))
        val named = JSONObject()
        p.named.forEach { (k, v) -> named.put(k, c(v)) }
        return JSONObject().put("name", runtime.themes.picked).put("light", p.isLight).put("css", css).put("colors", named)
    }

    /** The themes to pick from (as the home menu's strip): name, title and the colors a swatch shows. */
    private fun themeList(): JSONArray =
        JSONArray(
            runtime.themes.choices.map { t ->
                val colors = JSONObject()
                for (k in listOf("background", "foreground", "accent", "red", "yellow", "green", "magenta")) t.colors[k]?.let { colors.put(k, it) }
                JSONObject().put("name", t.name).put("title", t.title).put("colors", colors)
            },
        )

    /** Recolors at once, then applies the whole theme (its background, the guest's configs), as the home menu does. */
    private fun pickTheme(name: String) {
        val theme = runtime.themes.choices.firstOrNull { it.name == name } ?: error("no theme $name")
        runtime.themes.pick(theme)
        scope.launch { if (runtime.themes.complete) runtime.themes.applyPicked() else runtime.themes.fetchPicked() }
    }

    /**
     * Runs the default agent on a task (new widget, new app) in a terminal, as the home menu does; without Linux or
     * an agent, opens the screen that sets them up. Returns what it did: "started", "linux" or "agents".
     */
    private fun withAgent(task: (Agent) -> Pair<String, String>): String {
        val agent = runtime.agents.default
        return when {
            !(runtime.bootstrap.isInstalled || runtime.powosSession) -> "linux".also { ShellScreensActivity.open(activity, ShellScreensActivity.LINUX) }
            agent == null -> "agents".also { ShellScreensActivity.open(activity, ShellScreensActivity.AGENTS) }
            else -> "started".also { task(agent).let { (command, title) -> runtime.terminal(command, title, agent) } }
        }
    }

    /**
     * Starts listening ([hold]: across pauses, until speech.stop); the whole text goes to the page as "speech.done".
     * Without the mic permission it asks for it first: "asked" (the answer comes as "speech.permission").
     */
    private fun listen(hold: Boolean): String {
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
            return "asked"
        }
        if (!speech.available) return "unavailable"
        speech.start(hold) { heard -> emit("speech.done", JSONObject().put("text", heard)) }
        return "started"
    }

    /** The answer to the mic permission request ([ShellActivity.onRequestPermissionsResult]). */
    fun micPermission(granted: Boolean) = emit("speech.permission", JSONObject().put("granted", granted))

    private fun aiChat() =
        JSONObject().put("busy", PowosAiChat.busy).put("items", JSONArray(PowosAiChat.items.map { it.json() }))

    private fun iconCount() = runtime.androidApps.icons.size + runtime.linuxIcons.size

    private fun icon(key: String) = "${ShellActivity.ORIGIN}/_icon/${Uri.encode(key)}?v=${iconCount()}"

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

    /**
     * How the launcher's terminals look (PtyTerminal): text of [points] (null: the terminal text size) in CSS px, the
     * pad around it, Android's font scale (for a widget's textSize in sp), and the terminal font family, whose file
     * ShellActivity serves once PowOS's copy is fetched ("font": false until then; "term.style" says when it's there).
     */
    private fun terminalStyle(points: Double?): JSONObject {
        val font = runtime.terminalFont
        val metrics = activity.resources.displayMetrics
        val file = PtyTerminal.fontFile(activity, font.family) { emit("term.style", null) }
        return JSONObject()
            .put("size", font.pixels(points ?: font.size) / metrics.density)
            .put("pad", font.padPixels / metrics.density)
            .put("fontScale", activity.resources.configuration.fontScale)
            .put("family", font.family)
            .put("font", file != null)
    }

    private fun clipboard() = activity.getSystemService(ClipboardManager::class.java)

    private fun JSONArray.optStringOrNull(i: Int) = if (isNull(i)) null else getString(i)

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

    fun close() {
        speech.cancel()
        applyObserver.dispose()
        terminals.closeAll()
        scope.cancel()
    }

    /** Stored JSON, passed through as it is. */
    private class RawJson(
        val text: String,
    )

    companion object {
        private const val TAG = "PowosShell"

        /** ShellActivity's request code for the mic permission. */
        const val MIC_REQUEST = 41
    }
}
