package dev.omalauncher.shell

import android.Manifest
import android.annotation.SuppressLint
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
import dev.omalauncher.AgentMail
import dev.omalauncher.PowosAiActivity
import dev.omalauncher.linux.RootedGuest
import kotlin.concurrent.thread
import dev.omalauncher.PowosAiChat
import dev.omalauncher.Runtime
import dev.omalauncher.ui.Palette
import dev.omalauncher.widgets.runtime.MediaListener
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
    /** Where it runs: the launcher's activity, or a system slot's window (a dream, an overlay) - no activity there. */
    private val context: Context,
    /** The activity, when there is one: only asking for a permission needs it. */
    private val activity: Activity?,
    private val runtime: Runtime,
    private val web: WebView,
) {
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val data get() = File(context.filesDir, "shell-data").apply { mkdirs() }
    private val home = ShellHome(runtime)
    private val widgets = ShellWidgets(runtime, scope, ::emit)
    private val terminals = ShellTerminals(runtime, scope, ::emit)
    /** Speech to text for the bar's mic (the Compose prompt bar's): the page gets its state as it changes. */
    private val speech = Speech(context.applicationContext)
    /** The panel's quick settings: what an app may switch, and Android's panels for the rest. */
    private val quick: QuickSettings = QuickSettings(context) { main.post { emit("qs.changed", quick.state()) } }

    /** Set by the lock screen's face (PowosLockActivity): unlocking, through Android. */
    var lock: LockSlot? = null

    /** Set by the assistant's session (its page is the assist screen): the screen it was opened over, closing it. */
    var assist: dev.omalauncher.assist.AssistSlot? = null

    /** Set by the shade host (its page is the shade): the window to put away once the panel is shut. */
    var shade: dev.omalauncher.system.ShadeSlot? = null

    /** Set by the switcher's activity (its page is the switcher): leaving it. */
    var switcher: dev.omalauncher.system.SwitcherSlot? = null

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
        // Live mode on or off (its consent answered, its capture stopped): the assistant's page follows.
        dev.omalauncher.assist.LiveCapture.onChange = { main.post { emit("assist.live", liveState()) } }
        // An agent told the user something: the PowOS AI page lists it.
        scope.launch { snapshotFlow { AgentMail.recent.toList() }.drop(1).collect { emit("ai.mail", aiMail()) } }
        // A notification posted or gone: the panel lists them again.
        scope.launch { MediaListener.changes.collect { emit("notifications.changed", notificationList()) } }
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
        PowosAiChat.load(context.applicationContext)
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
                PowosAiChat.send(context.applicationContext, a.getString(0))
                // Asked here, it's also an app in the switcher, the same conversation a swipe away.
                PowosAiActivity.keepInRecents(context)
            }
            "ai.open" -> PowosAiActivity.open(context, null)
            "ai.mail" -> aiMail()
            "ai.sessions" -> aiSessions()
            "ai.attach" -> aiAttach(a.getString(0))
            "lock.unlock" -> lock?.unlock()
            "qs.state" -> quick.state()
            "qs.toggle" -> quick.toggle(a.getString(0)).let { quick.state() }
            "qs.open" -> quick.open(a.getString(0))
            "shade.closed" -> shade?.closed()
            "tasks.list" -> tasks()
            "tasks.open" -> dev.omalauncher.system.Tasks.open(context, a.getInt(0)).also { if (it) switcher?.close() }
            "tasks.remove" -> dev.omalauncher.system.Tasks.remove(a.getInt(0))
            "switcher.close" -> switcher?.close()
            "switcher.home" -> switcher?.home()
            "assist.screen" -> assist?.screen()
            "assist.close" -> assist?.close()
            "assist.attach" -> assist?.attach(a.optString(0).takeIf { it.isNotEmpty() && it != "null" })
            "assist.touchable" -> assist?.touchable(a.optJSONObject(0)?.let { touchRect(it) })
            "assist.live" -> {
                if (a.optBoolean(0)) dev.omalauncher.assist.LiveCapture.start(context) else dev.omalauncher.assist.LiveCapture.stop(context)
                null
            }
            "assist.liveState" -> liveState()
            "assist.filmstrip" -> dev.omalauncher.assist.LiveCapture.filmstrip(context)
            "theme.get" -> theme()
            "theme.list" -> themeList()
            "theme.pick" -> pickTheme(a.getString(0))
            "screens.open" -> ShellScreensActivity.open(context, a.getString(0))
            "agents.default" -> runtime.agents.default?.name
            "agents.newWidget" -> withAgent { newWidgetCommand(it.bin) to "New widget" }
            "agents.newApp" -> withAgent { newAppCommand(it.bin) to "New app" }
            "speech.start" -> listen(a.optBoolean(0))
            "speech.stop" -> speech.stop()
            "speech.cancel" -> speech.cancel()
            "keyboard.show" -> keyboard(true)
            "keyboard.hide" -> keyboard(false)
            "system.insets" -> lastInsets
            "system.notifications" -> notifications(a.optBoolean(0, true))
            "system.battery" -> battery()
            "notifications.list" -> notificationList()
            "notifications.open" -> runtime.widgets.notifications.control("open", a.getString(0))
            "notifications.dismiss" -> runtime.widgets.notifications.control("dismiss", a.getString(0))
            "notifications.clearAll" -> runtime.widgets.notifications.clearAll()
            "notifications.access" -> runtime.widgets.notifications.askAccess()
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
            "clipboard.read" -> clipboard().primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
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

    /**
     * Pulls the notification shade down ([open]) or puts it away: home's swipe down, and back up in the same swipe, as
     * on a stock launcher. HACK: StatusBarManager's expandNotificationsPanel / collapsePanels aren't public API - every
     * third-party launcher (Lawnchair, Neo) calls them like this, with EXPAND_STATUS_BAR; the supported way, an
     * accessibility service's GLOBAL_ACTION_NOTIFICATIONS, needs the user to turn one on for us, and only opens it.
     * The shade following the finger (as the Pixel launcher's) takes SystemUI's privileged motion proxy.
     */
    @SuppressLint("WrongConstant")
    private fun notifications(open: Boolean): Boolean =
        runCatching {
            // PowOS's shade in SystemUI's place: SystemUI's own panel is lent back to it for this - its control center.
            val shade = dev.omalauncher.system.ShadeHost.current
            if (open && shade != null) return shade.openSystemPanel(settings = true).let { true }
            val bar = context.getSystemService("statusbar")
            bar.javaClass.getMethod(if (open) "expandNotificationsPanel" else "collapsePanels").invoke(bar)
        }.onFailure { Log.w(TAG, "can't ${if (open) "open" else "close"} the notification shade", it) }.isSuccess

    /**
     * The recent tasks (the switcher's): [{ id, label, key, icon, snapshot }] newest first - the app's drawer key and
     * icon when it's in the drawer, its last frame served by ShellHost (/_task/<id>, new each time it's asked).
     */
    private fun tasks(): JSONArray {
        val stamp = System.currentTimeMillis()
        return JSONArray(
            dev.omalauncher.system.Tasks.list(context).map { t ->
                val pkg = t.component?.packageName
                val app = runtime.androidApps.apps.firstOrNull { it.component == t.component && it.profile == null } ?: runtime.androidApps.apps.firstOrNull { it.component.packageName == pkg && it.profile == null }
                JSONObject()
                    .put("id", t.id)
                    .put("label", t.label ?: app?.label ?: pkg ?: "")
                    .put("key", app?.let { "a:${it.key}" } ?: JSONObject.NULL)
                    .put("icon", app?.let { icon("a:${it.key}") } ?: JSONObject.NULL)
                    .put("snapshot", "${ShellHost.ORIGIN}/_task/${t.id}?v=$stamp")
            },
        )
    }

    /** The notification panel's list: { available, items: [{ key, app, icon, title, text, time, clearable, profile }] }. */
    private fun notificationList(): JSONObject {
        val n = runtime.widgets.notifications
        val items =
            n.items().map { item ->
                // The app's drawer icon (its own profile's, badge and all, when it's from a work or cloned one).
                val app = runtime.androidApps.apps.firstOrNull { it.component.packageName == item.pkg && (item.profile == null) == (it.profile == null) }
                JSONObject()
                    .put("key", item.key)
                    .put("app", item.app)
                    .put("icon", app?.let { icon("a:${it.key}") } ?: JSONObject.NULL)
                    .put("title", item.title)
                    .put("text", item.text)
                    .put("time", item.time)
                    .put("clearable", item.clearable)
                    .put("profile", item.profile ?: JSONObject.NULL)
            }
        return JSONObject().put("available", n.available).put("items", JSONArray(items))
    }

    /** Live mode's state for the page: on or not, frames kept. */
    private fun liveState() =
        JSONObject().put("on", dev.omalauncher.assist.LiveCapture.running).put("frames", dev.omalauncher.assist.LiveCapture.count())

    /** A rectangle from the page (CSS px: left, top, width, height) in device px. */
    private fun touchRect(r: JSONObject): android.graphics.Rect {
        val d = context.resources.displayMetrics.density
        val l = (r.getDouble("left") * d).toInt()
        val t = (r.getDouble("top") * d).toInt()
        return android.graphics.Rect(l, t, l + (r.getDouble("width") * d).toInt(), t + (r.getDouble("height") * d).toInt())
    }

    /** The battery: its level (0-100) and whether it's charging, from Android's sticky battery broadcast. */
    private fun battery(): JSONObject {
        val b = context.registerReceiver(null, android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
        val level = b?.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = b?.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, 100) ?: 100
        val status = b?.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == android.os.BatteryManager.BATTERY_STATUS_CHARGING || status == android.os.BatteryManager.BATTERY_STATUS_FULL
        return JSONObject().put("level", if (level < 0) JSONObject.NULL else level * 100 / scale).put("charging", charging)
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
            !(runtime.bootstrap.isInstalled || runtime.powosSession) -> "linux".also { ShellScreensActivity.open(context, ShellScreensActivity.LINUX) }
            agent == null -> "agents".also { ShellScreensActivity.open(context, ShellScreensActivity.AGENTS) }
            else -> "started".also { task(agent).let { (command, title) -> runtime.terminal(command, title, agent) } }
        }
    }

    /**
     * Starts listening ([hold]: across pauses, until speech.stop); the whole text goes to the page as "speech.done".
     * Without the mic permission it asks for it first: "asked" (the answer comes as "speech.permission").
     */
    private fun listen(hold: Boolean): String {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            // Asked from an activity only (a slot's window can't): elsewhere the mic isn't there until it's granted.
            val asker = activity ?: return "unavailable"
            asker.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
            return "asked"
        }
        if (!speech.available) return "unavailable"
        speech.start(hold) { heard -> emit("speech.done", JSONObject().put("text", heard)) }
        return "started"
    }

    /** The answer to the mic permission request ([ShellActivity.onRequestPermissionsResult]). */
    fun micPermission(granted: Boolean) = emit("speech.permission", JSONObject().put("granted", granted))

    private fun aiMail() = JSONArray(AgentMail.recent.map { JSONObject().put("from", it.from).put("text", it.text).put("time", it.time) })

    /**
     * The agents at work: PowOS's tmux sessions (where agents run), listed off the main thread and sent as
     * "ai.sessions" - name, last activity (Unix seconds), attached, and the active pane's title (an agent's current
     * task: Claude Code titles it), folder and command. Only read; nothing is sent to them. Empty off PowOS's session.
     */
    private fun aiSessions() {
        if (!runtime.powosSession) return emit("ai.sessions", JSONArray())
        thread(name = "ai-sessions", isDaemon = true) {
            val format = listOf("session_name", "session_activity", "session_attached", "pane_title", "pane_current_path", "pane_current_command").joinToString("\t") { "#{$it}" }
            val lines = ArrayList<String>()
            runCatching { RootedGuest.run("tmux list-sessions -F '$format' 2>/dev/null") { lines += it } }
            val list =
                JSONArray(
                    lines.mapNotNull { line ->
                        val f = line.split('\t')
                        if (f.size < 6) return@mapNotNull null
                        JSONObject()
                            .put("name", f[0])
                            .put("activity", f[1].toLongOrNull() ?: 0)
                            .put("attached", f[2] != "0")
                            .put("title", f[3])
                            .put("path", f[4])
                            .put("command", f[5])
                    },
                )
            main.post { emit("ai.sessions", list) }
        }
    }

    /** Opens a terminal on tmux session [name] (an agent's), as the tile's picker would. */
    private fun aiAttach(name: String) {
        require(name.matches(Regex("[A-Za-z0-9_.:-]+"))) { "bad session name: $name" }
        runtime.terminal("tmux attach -t '$name'", name)
    }

    private fun aiChat() =
        JSONObject().put("busy", PowosAiChat.busy).put("items", JSONArray(PowosAiChat.items.map { it.json() }))

    private fun iconCount() = runtime.androidApps.icons.size + runtime.linuxIcons.size

    private fun icon(key: String) = "${ShellHost.ORIGIN}/_icon/${Uri.encode(key)}?v=${iconCount()}"

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
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
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
        val metrics = context.resources.displayMetrics
        val file = PtyTerminal.fontFile(context, font.family) { emit("term.style", null) }
        return JSONObject()
            .put("size", font.pixels(points ?: font.size) / metrics.density)
            .put("pad", font.padPixels / metrics.density)
            .put("fontScale", context.resources.configuration.fontScale)
            .put("family", font.family)
            .put("font", file != null)
    }

    private fun clipboard() = context.getSystemService(ClipboardManager::class.java)

    private fun JSONArray.optStringOrNull(i: Int) = if (isNull(i)) null else getString(i)

    /** The window's insets in CSS px, sent as "system.insets" when they change (the keyboard's included). */
    fun insets(w: WindowInsets) {
        val d = context.resources.displayMetrics.density
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
        quick.close()
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
