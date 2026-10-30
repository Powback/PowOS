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
import android.webkit.WebView
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.graphics.asAndroidBitmap
import dev.omalauncher.AgentMail
import dev.omalauncher.PowosAiActivity
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.linux.matches
import dev.omalauncher.system.RunningApps
import kotlin.concurrent.thread
import dev.omalauncher.PowosAiChat
import dev.omalauncher.Runtime
import dev.omalauncher.ui.Palette
import dev.omalauncher.widgets.runtime.MediaListener
import dev.omalauncher.ui.Speech
import dev.omalauncher.linux.Agent
import dev.omalauncher.linux.matches
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
    private val media = ShellMedia(context, runtime, scope, ::emit)
    /** Android apps as home elements (off unless Settings.Global powos_web_windows = 1; home's activity only). */
    private val webWindows by lazy { WebWindows(context, web, ::emit) }

    @Volatile private var webWindowsMade = false

    /**
     * Linux (KWin) windows as web windows (docs/WEB_WINDOWS.md S6): KWin's "open" comes here instead of a
     * PowosWindowActivity task while web windows are on and the home is the wide one. Set by home's bridge only.
     */
    private val linuxWindows =
        object : andro.marchy.WebWindowSource.Host {
            override fun wants() = WebWindows.on(context) && context.resources.configuration.smallestScreenWidthDp >= 600

            override fun open(
                id: Int,
                appId: String,
                title: String,
            ) {
                val app = runtime.linuxApps.firstOrNull { it.matches(appId) }
                val key = "l:${app?.id ?: appId}"
                val label = runtime.displayName(appId, title)
                val icon = app?.let { runtime.linuxIcons[it.id] }?.let { android.graphics.drawable.BitmapDrawable(context.resources, it.asAndroidBitmap()) }
                val offer = WebWindows.LinuxOffer(appId, title, label, icon)
                main.post { webWindows.also { webWindowsMade = true }.linuxOpened(id, key, offer) }
            }

            override fun title(
                id: Int,
                title: String,
            ) {}

            override fun closed(id: Int) {
                main.post { if (webWindowsMade) webWindows.linuxClosed(id) }
            }
        }

    /** An app the system's window menu floated ([SystemFloat]): a web window, as the switcher's "PowOS desktop window". */
    private val systemFloat: (Int) -> Unit = { id -> main.post { toWebWindow(id) } }

    /** The page's web-window geometry, "w.f ..." over its native port ([ShellNative], port thread): [WebWindows.frameCommand]. */
    fun webWindowFrame(rest: String) {
        if (webWindowsMade) webWindows.frameCommand(rest)
    }

    /** "w.area" / "w.theme" over the port: the windows' work area and bar colours. */
    fun webWindowCommand(
        verb: String,
        rest: String,
    ) {
        if (!webWindowsMade) return
        if (verb == "w.area") webWindows.areaCommand(rest) else webWindows.themeCommand(rest)
    }
    /** Speech to text for the bar's mic (the Compose prompt bar's): the page gets its state as it changes. */
    private val speech = Speech(context.applicationContext).also { it.warm() }
    /** The panel's quick settings: what an app may switch, and Android's panels for the rest. */
    private val quick: QuickSettings =
        QuickSettings(context) { main.post { emit("qs.changed", quick.state()) } }.also {
            // A tile opening its activity or dialog: the control center goes, as SystemUI's panel does.
            it.collapse = { main.post { emit("qs.collapse", null) } }
        }

    /** Other apps' Android widgets on home (AppWidgets.kt): their frames and home's changes come to this page. */
    private val appWidgets = AppWidgets.get(context)
    private val appWidgetEvents: (String, Any?) -> Unit = { event, payload -> emit(event, payload) }

    /** The home's own panels (the Agents widget), and this page's view of the agents (AgentsSpool). */
    private val panels = ShellPanels.get(context)

    /** Settings and the screens it opens (style, the stores, Linux, coding agents...): shell/ui/screens.tsx. */
    val screens = ShellScreens(context, activity, runtime, scope, ::emit)
    private val agentsView = dev.omalauncher.AgentsSpool.Viewer(::emit)

    /** Remote input (RemoteInput.kt): the phone as a computer's keyboard and mouse, "remote.*" calls. */
    private val remote = RemoteInput.Client(context, activity, ::emit)

    /** The smart glasses (glasses/Glasses.kt): pairing, connection, their display, input and mic - "glasses.*" calls. */
    private val glasses = dev.omalauncher.glasses.Glasses.Client(context, activity, ::emit)

    /** Health Connect, read-only (HealthConnectBridge.kt): the health central's source, "health.*" calls. */
    val health =
        HealthConnectBridge(context, activity, scope) { status ->
            js("window.dispatchEvent(new CustomEvent('powos:health-granted', { detail: $status }))")
        }

    /** Set by the lock screen's face (PowosLockActivity): unlocking, through Android. */
    var lock: LockSlot? = null

    /** Only the status/frame host assigns this scoped interface. */
    var chrome: ChromeSlot? = null

    /** Set by the assistant's session (its page is the assist screen): the screen it was opened over, closing it. */
    var assist: dev.omalauncher.assist.AssistSlot? = null

    /** Set by the shade host (its page is the shade): the window to put away once the panel is shut. */
    var shade: dev.omalauncher.system.ShadeSlot? = null

    /** Set by an overlay host (Quick Tools, the pull-up panels over apps): its window, put away once the page is shut. */
    var overlay: dev.omalauncher.system.OverlaySlot? = null

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

    /** The wallpaper's picture another one (ShellWallpaper): the page frosts it again. */
    private val wallpaperChanged: () -> Unit = { emit("system.glass", ShellWallpaper.info(context, blurBehind = shade != null || overlay != null, look = false)) }

    /** Android's wallpaper changed (its colors are recomputed for every change), or the theme's background did. */
    private val wallpaperColors = android.app.WallpaperManager.OnColorsChangedListener { _, _ -> ShellWallpaper.refresh(context) }
    private val themeChanged: () -> Unit = { ShellWallpaper.refresh(context) }

    init {
        // Home's bridge: an app the system's own window menu floats becomes a web window (SystemFloat, web windows on).
        if (activity != null) SystemFloat.start(context, systemFloat)
        if (activity != null) andro.marchy.WebWindowSource.host = linuxWindows
        ShellWallpaper.onChange.add(wallpaperChanged)
        runCatching { android.app.WallpaperManager.getInstance(context).addOnColorsChangedListener(wallpaperColors, main) }
        dev.omalauncher.theme.ThemeStore.changeListeners.add(themeChanged)
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
        // Installs, removals, Linux apps, and an app's icon drawn anew or for the first time (ShellIcons names each by
        // its pixels): the page reloads its list. An icon arriving that looks as it did last time changes nothing.
        scope.launch {
            snapshotFlow { listOf(runtime.androidApps.apps.size, runtime.linuxApps.size, ShellIcons.version.intValue) }.drop(1).collect { emit("apps.changed", null) }
        }
        scope.launch { runtime.refreshApps() }
        // An app's task opened or gone, a Linux app's window, or its freeze or thaw: the running dots (ui/running.ts).
        scope.launch {
            snapshotFlow { RunningApps.tasks.value to RunningApps.linux.value }.drop(1).collect { emit("apps.running", running()) }
        }
        // A floating window opened, minimised, brought back or closed: the dock shows the windows again.
        scope.launch { snapshotFlow { dev.omalauncher.system.WindowFrames.running.value }.drop(1).collect { emit("windows.changed", windows()) } }
        // A window kept on screen though home had it on another page (just launched/activated, or full screen:
        // WindowFrames.mayHide): home moves it to the page on screen, as for a window brought back.
        scope.launch {
            snapshotFlow { dev.omalauncher.system.WindowFrames.keptOnPage.value }.drop(1).collect { k -> k?.ids?.forEach { emit("windows.raised", it) } }
        }
        // A window let go at a screen edge: home moves it to the next page (ui/desktops.ts).
        scope.launch {
            snapshotFlow { dev.omalauncher.system.WindowFrames.edges.value }.drop(1).collect { d ->
                if (d != null) emit("windows.edge", mapOf("id" to d.id, "side" to d.side))
            }
        }
        // The home screen changed (here, in the Compose launcher, or a widget file arriving): the page re-reads it.
        scope.launch { snapshotFlow { home.fingerprint() }.drop(1).collect { emit("home.changed", null) } }
        // PowOS AI's conversation (shared with its own app): every item and the busy flag, as they stream in.
        PowosAiChat.load(context.applicationContext)
        appWidgets.listen(appWidgetEvents)
        scope.launch { snapshotFlow { aiChat().toString() }.drop(1).collect { emit("ai.changed", JSONObject(it)) } }
        // Something that needs Linux was asked for without it (a terminal, a Linux widget): home offers to install it.
        if (activity is ShellActivity) {
            scope.launch {
                snapshotFlow { runtime.linuxWanted }.collect { wanted ->
                    if (!wanted) return@collect
                    runtime.linuxWanted = false
                    openScreen(ShellScreens.LINUX)
                }
            }
        }
    }

    /** Health Connect's calls answer later (it is suspend, and its dialog is Android's): not through [dispatch]. */
    private fun callHealth(
        id: Int,
        method: String,
        args: String,
    ) {
        val a = if (args.isBlank()) JSONArray() else JSONArray(args)
        health.call(method, a) { result, err ->
            main.post { if (err == null) respond(id, result) else js(reply("reject($id, ${JSONObject.quote(err)})")) }
        }
    }

    /**
     * The AI page's "works" / "still broken" on a Ready-to-try task ([args]: task id, works): the user's verdict through
     * the board's own CLI in the PowOS session (`powos agents check set` = the reporter-only check_set reducer, a check
     * named "you", PASS or FAIL; works then `powos agents task works`: the slice it tried done, the task closed only
     * when nothing else is open on it - an epic with planned steps stays open, no error). Never `task done`: a works tap
     * isn't a close, and an older CLI copy's `task done` closed the web-windows epic with its W1 step still open
     * (2026-10-30 19:4x - the phone's CLI had no `task works`, so the old `|| task done` fallback ran, without the
     * open-steps rule). A CLI without `task works`: the user PASS is recorded and the task stays for its owner. The
     * page's own database connection isn't a reporter, so it can't call those reducers itself. Off the main thread;
     * answers when the board has it, or rejects with the CLI's last line.
     */
    private fun callVerdict(
        id: Int,
        args: String,
    ) {
        val a = JSONArray(args)
        val task = a.getString(0)
        val works = a.getBoolean(1)
        thread(name = "ai-verdict", isDaemon = true) {
            val err =
                runCatching {
                    require(VERDICT_TASK.matches(task)) { "bad task id: $task" }
                    check(RootedGuest.enabled) { "PowOS isn't running" }
                    val t = dev.omalauncher.linux.shellQuote(task)
                    val job = dev.omalauncher.linux.shellQuote("you-$task-${System.currentTimeMillis()}")
                    // HACK: an older phone CLI copy has no `task works` (unknown verb): the PASS above is the record and
                    // nothing closes. Real fix: the CLI ships with the APK that calls it (one versioned bridge contract).
                    val command =
                        if (works) "powos agents check set $t $job PASS --name you --line 'works: the user tried it' --shipped 1 && { powos agents task works $t || ! powos agents help 2>/dev/null | grep -q 'agents task works'; }"
                        else "powos agents check set $t $job FAIL --name you --line 'still broken: the user tried it' --shipped 1 && powos agents task set $t --status working"
                    val out = ArrayList<String>()
                    val code = RootedGuest.run(command) { out += it }
                    check(code == 0) { out.lastOrNull { it.isNotBlank() } ?: "powos agents failed ($code)" }
                }.exceptionOrNull()
            main.post { if (err == null) respond(id, null) else js(reply("reject($id, ${JSONObject.quote(err.message ?: err.toString())})")) }
        }
    }

    /** One call from the page (PowosHost.postMessage, ShellHost.listen: its top frame at its own origin only). */
    fun call(
        id: Int,
        method: String,
        args: String,
    ) {
        if (method.startsWith("health.")) return callHealth(id, method, args)
        if (method == "ai.verdict") return callVerdict(id, args)
        main.post {
            try {
                val a = if (args.isBlank()) JSONArray() else JSONArray(args)
                respond(id, dispatch(method, a))
            } catch (e: Exception) {
                Log.w(TAG, "$method failed", e)
                js(reply("reject($id, ${JSONObject.quote(e.message ?: e.toString())})"))
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
            "webwindows.enabled" -> activity != null && webWindows.also { webWindowsMade = true }.enabled()
            "webwindows.open" ->
                if (activity == null) -1
                // A Linux window KWin opened ("webwindows.adopt" with its KWin id): its consumer in a web window.
                else if (a.getString(0).startsWith("l:")) webWindows.also { webWindowsMade = true }.openLinux(a.optInt(3, -1), a.getJSONObject(1))
                else android(a.getString(0))?.let { app ->
                    runtime.usage.record(a.getString(0))
                    webWindows.also { webWindowsMade = true }.open(app.component, a.getJSONObject(1), a.optInt(2, -1))
                } ?: -1
            "webwindows.input" -> webWindowsMade && webWindows.input(a.getInt(0), a.getString(1), a.getDouble(2), a.getDouble(3))
            "webwindows.close" -> webWindowsMade && webWindows.close(a.getInt(0))
            "webwindows.fullScreen" -> webWindowsMade && webWindows.fullScreen(a.getInt(0))
            "webwindows.toWindow" -> webWindowsMade && webWindows.toWindow(a.getInt(0))
            "apps.info" -> android(a.getString(0))?.let { runtime.androidApps.openInfo(it) }
            "apps.uninstall" -> android(a.getString(0))?.let { runtime.androidApps.uninstall(it) }
            // App API's "+ add app": the deep links an app opens, read from its manifest - nothing fired (AppLinks.kt).
            "apps.links" -> AppLinks.read(context, a.getString(0))
            "usage.recent" -> JSONArray(installed(runtime.usage.recent).take(a.optInt(0, 5)))
            "store.get" -> store(a.getString(0)).takeIf { it.isFile }?.readText()?.let { RawJson(it) }
            "store.set" -> {
                store(a.getString(0)).writeText(a.get(1).let { if (it is String) JSONObject.quote(it) else it.toString() })
                // The fps meter's switch takes effect in every shell window at once (status bar, home), not on its next poll.
                if (a.getString(0) == "perf.meter") runCatching { JSONObject(a.get(1).toString()).toString() }.getOrNull()?.let { broadcast("perf.meter", it) }
                Unit
            }
            // The main shell's frame samples (fps + new frame times, ~4 Hz) to the other windows' meter: re-parsed, never spliced raw.
            "perf.publish" -> a.getString(0).takeIf { it.length < 8192 }?.let { broadcast("perf.sample", JSONObject(it).toString(), except = this) }
            // Perf trace from the status bar's fps meter: saved where PowOS AI sees it (the shared run dir), the last 20 kept,
            // and mailed to the coordinator (the Mac session running PowOS) so every recording reaches it with its full data.
            "perf.save" -> {
                val dir = java.io.File(context.filesDir, "run/powos-ai-shared").apply { mkdirs() }
                val name = "perf-${System.currentTimeMillis()}.json"
                dir.listFiles { f -> f.name.startsWith("perf-") }?.sortedBy { it.lastModified() }?.dropLast(19)?.forEach { it.delete() }
                val json = a.getString(0)
                java.io.File(dir, name).writeText(json)
                val path = "/run/powos-app/powos-ai-shared/$name"
                sendPerfToCoordinator(json, path)
                path
            }
            "ai.chat" -> aiChat()
            "ai.send" -> {
                PowosAiChat.send(context.applicationContext, a.getString(0))
                // Asked here, it's also an app in the switcher, the same conversation a swipe away. Not from home's
                // PowOS AI page (second arg false): putting the task in recents starts the chat activity for a
                // moment, and its window covered home - a ~1 s black screen on every send. That page is the
                // conversation already, a swipe from home.
                if (a.optBoolean(1, true)) PowosAiActivity.keepInRecents(context) else Unit
            }
            "ai.unqueue" -> PowosAiChat.unqueue(a.getLong(0))
            "ai.open" -> PowosAiActivity.open(context, null)
            // "Create app": PowOS AI in a fresh thread of its own building it (PowosAiChat.newApp); back to the main one.
            "ai.newApp" -> PowosAiChat.newApp(context.applicationContext, a.getString(0))
            "ai.closeThread" -> PowosAiChat.closeThread(context.applicationContext)
            "ai.mail" -> aiMail()
            "ai.mailRead" -> AgentMail.read(context, a.getString(0))
            "ai.mailClear" -> AgentMail.readAll(context)
            "ai.sessions" -> aiSessions()
            "ai.attach" -> aiAttach(a.getString(0))
            "lock.unlock" -> lock?.unlock()
            "lock.mark" -> UnlockLog.mark("page ${a.getString(0)}")
            "qs.destinations" -> SettingsSearch(context).destinations { broadcast("qs.destinations", "null") }
            "qs.state" -> quick.state()
            "qs.toggle" -> quick.toggle(a.getString(0)).let { quick.state() }
            "qs.open" -> quick.open(a.getString(0))
            "qs.set" -> quick.set(a.getString(0), a.getDouble(1)).let { quick.state() }
            "qs.listening" -> quick.listening(a.getBoolean(0))
            // The touch controller overlay (andro.marchy.GamepadOverlay): the control centre's Controller tile.
            "pad.state" -> ControllerPad.shown()
            "pad.overlay" -> ControllerPad.show(context, a.getBoolean(0))
            "pad.edit" -> ControllerPad.edit()
            "media.state" -> media.state()
            "media.control" -> media.control(a.getString(0))
            "media.output" -> media.output(a.optString(0).takeIf { it.isNotEmpty() })
            "chrome.state" -> requireNotNull(chrome) { "not a chrome page" }.state()
            "chrome.ready" -> requireNotNull(chrome) { "not a chrome page" }.ready()
            "chrome.action" -> requireNotNull(chrome) { "not a chrome page" }.action(a.getString(0))
            "chrome.regions" -> requireNotNull(chrome) { "not a chrome page" }.regions(a.getJSONArray(0))
            "shade.closed" -> shade?.closed()
            "shade.expand" -> shade?.expand()
            "shade.peekHeight" -> shade?.peekHeight((a.getDouble(0) * density()).toInt())
            "shade.blur" -> shade?.blur(a.getDouble(0).toFloat())
            // The shade page's openness as it renders it this frame: the blur behind on the same frame.
            "shade.behind" -> shade?.behind(a.getDouble(0).toFloat())
            // Home's page: whether a pull down on it is the shade's now. True: PowOS's shade takes it (on the gesture input).
            "shade.homePull" -> homePull(a.getBoolean(0), a, a.optBoolean(2, false))
            // Home without the gesture input: the shade down, not following the finger.
            "shade.open" -> dev.omalauncher.system.ShadeHost.current?.let { s -> main.post { s.openPanel(control = false) } } ?: notifications(true)
            "overlay.closed", "pull.closed" -> overlay?.closed()
            "pull.launched" -> overlay?.launched()
            // Home's page: the launcher overlay up over home (the pill, the side button's chat) / its lift on home's body.
            "pull.open" -> launcherOpen(a.getString(0), a.optJSONObject(1))
            "pull.homePull" -> launcherHomePull(a.getBoolean(0), a, a.optBoolean(2, false))
            // Which shell panel is open (system/Panels.kt): the bottom-edge home gesture closes it.
            "panels.open" -> dev.omalauncher.system.Panels.set(a.getString(0), this)
            "panels.closed" -> dev.omalauncher.system.Panels.set(null, this)
            // The floating app windows for the dock (system/WindowFrames.kt), and one brought back.
            "windows.list" -> windows()
            "apps.running" -> running()
            // The app menu's close (shell/ui/desktops.ts closeApp): a Steam game or Steam itself closed cleanly.
            "apps.close" -> closeApp(a.getString(0))
            "windows.restore" -> (dev.omalauncher.system.WindowFrames.current?.restore(a.getInt(0)) ?: false).also { if (it) emit("windows.raised", a.getInt(0)) }
            // The dock's tap on the focused window's app (ui/desktops.ts dockTap): it goes, as its minimise button does.
            "windows.minimise" -> dev.omalauncher.system.WindowFrames.current?.let { f -> main.post { f.minimise(a.getInt(0)) }; true } ?: false
            "windows.maximise" -> dev.omalauncher.system.WindowFrames.current?.let { f -> main.post { f.maximise(a.getInt(0)) }; true } ?: false
            // Where home's bottom bar starts (CSS px from the page's top): windows open and maximise above it.
            "windows.area" -> { dev.omalauncher.system.AppWindows.barTop = screenRect(JSONObject().put("left", 0).put("top", a.getDouble(0)).put("width", 0).put("height", 0)).top; true }
            // Home's pages are desktops (ui/desktops.ts): the windows of the pages not on screen, out of sight.
            "windows.desktop" -> dev.omalauncher.system.WindowFrames.current?.desktop(a.getJSONArray(0).let { h -> (0 until h.length()).map { h.getInt(it) }.toSet() }) ?: false
            // A page swipe moves the windows of the pages it shows with them, frame by frame (system/PageSlide.kt).
            "windows.slide" -> dev.omalauncher.system.PageSlide.call(context, a, density())
            "tasks.list" -> tasks()
            "tasks.open" -> openTask(a.getInt(0), a.opt(1))
            "tasks.remove" -> dev.omalauncher.system.Tasks.remove(context, a.getInt(0)).also { appWidgets.heal() }
            "tasks.split" -> dev.omalauncher.system.Tasks.split(a.getInt(0), a.getInt(1))
            "tasks.desktopWindow" -> desktopWindow(a.getInt(0), a.optBoolean(1, true))
            "tasks.float" -> dev.omalauncher.system.Tasks.float(context, a.getInt(0))
            "tasks.toWindow" -> toWebWindow(a.getInt(0)).also { if (it) dev.omalauncher.system.Switcher.hide() }
            "tasks.info" -> dev.omalauncher.system.Tasks.info(context, a.getInt(0))
            "tasks.screenshot" -> dev.omalauncher.system.Tasks.screenshot(context, a.getInt(0))
            // Home's switcher layer (shell/ui/recents.tsx, system/Switcher.kt).
            "recents.slot" -> a.optJSONObject(0)?.let { dev.omalauncher.system.Switcher.slot(this, screenRect(it), it.optDouble("radius", 0.0).toFloat() * density()) }
            "recents.ready" -> dev.omalauncher.system.Switcher.ready(this)
            "recents.closed" -> dev.omalauncher.system.Switcher.closed(context, this)
            "recents.state" -> dev.omalauncher.system.Switcher.state()
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
            "screens.watch" -> screens.watch(a.getString(0))
            "screens.unwatch" -> screens.unwatch(a.getString(0))
            "screens.act" -> screens.act(a.getString(0), a.getString(1), a.opt(2)?.takeIf { it != JSONObject.NULL })
            "agents.default" -> runtime.agents.default?.name
            "agents.newWidget" -> withAgent { newWidgetCommand(it.bin) to "New widget" }
            "agents.newApp" -> withAgent { newAppCommand(it.bin) to "New app" }
            // The Agents view (AgentsSpool): its state while this page is subscribed, one agent's events, the notification's Open.
            "agents.snapshot" -> dev.omalauncher.AgentsSpool.subscribe(agentsView)
            "agents.unsubscribe" -> dev.omalauncher.AgentsSpool.unsubscribe(agentsView)
            "agents.events" -> dev.omalauncher.AgentsSpool.watchEvents(agentsView, a.optString(0).takeIf { it.isNotEmpty() && !a.isNull(0) })
            "agents.takeOpen" -> dev.omalauncher.AgentsSpool.takeOpen()
            "agents.answer" -> dev.omalauncher.AgentsSpool.answer(a.getString(0), a.getString(1), a.optString(2).takeIf { it.isNotEmpty() && !a.isNull(2) })
            "agents.message" -> dev.omalauncher.AgentsSpool.message(a.getString(0), a.getString(1))
            // "Test now" on the AI page: the verify queue's runner (on the Mac) takes that task's phone checks now.
            "verify.go" -> VerifyRun.go(a.getString(0))
            // The runner's state (paused, or its heartbeat stale): the page's "checks paused · resume", as "verify.state".
            "verify.state" -> VerifyRun.state { emit("verify.state", it) }
            // The shade's "tests" control: stop the checks (resume = verify.go "all"); dry = only "this host has it".
            "verify.stop" -> if (a.optBoolean(0)) Unit else VerifyRun.stop()
            "agents.interrupt" -> dev.omalauncher.AgentsSpool.interrupt(a.getString(0))
            "speech.start" -> listen(a.optBoolean(0))
            "speech.stop" -> speech.stop()
            "speech.hold" -> speech.hold()
            "speech.quiet" -> speech.quiet(a.optLong(0, 1500))
            "speech.warm" -> speech.warm()
            "speech.cancel" -> speech.cancel()
            // Tests with recorded audio instead of the mic (GpuSpeech.kt SpeechEngines.test): logged, nothing reaches a page.
            "speech.test" -> dev.omalauncher.ui.SpeechEngines.test(context, a.getString(0), a.optString(1, "gpu"))
            "keyboard.show" -> keyboard(true)
            "keyboard.hide" -> keyboard(false)
            "system.insets" -> lastInsets
            "system.display" -> display()
            "system.notifications" -> notifications(a.optBoolean(0, true))
            "system.battery" -> battery()
            // The pet over apps: on or off (null: just read it) - system/PetOverlay.
            "pet.overlay" -> dev.omalauncher.system.PetOverlay.enabled(context, if (a.length() == 0 || a.isNull(0)) null else a.optBoolean(0))
            // The shade's window blurs what's behind it itself (ShadeHost): its page only tints.
            "system.glass" -> ShellWallpaper.info(context, blurBehind = shade != null || overlay != null)
            "notifications.list" -> notificationList()
            "notifications.open" -> runtime.widgets.notifications.control("open", a.getString(0))
            "notifications.dismiss" -> runtime.widgets.notifications.control("dismiss", a.getString(0))
            "notifications.clearAll" -> runtime.widgets.notifications.clearAll()
            "notifications.action" -> runtime.widgets.notifications.action(a.getString(0), a.getInt(1), a.optString(2).takeIf { !a.isNull(2) && it.isNotEmpty() })
            "notifications.access" -> runtime.widgets.notifications.askAccess()
            // Android widgets are home items too, kept by AppWidgets ("aw:" keys).
            "home.get" -> panels.merge(appWidgets.merge(home.snapshot()))
            "home.place" -> if (panels.owns(a.getString(0))) panels.place(a.getString(0), a.getJSONObject(1), a.getInt(2)).also { emit("home.changed", null) } else if (appWidgets.owns(a.getString(0))) appWidgets.place(a.getString(0), a.getJSONObject(1), a.getInt(2)) else home.place(a.getString(0), a.getJSONObject(1), a.getInt(2))
            "home.add" -> home.add(a.getString(0), a.getInt(1), a.optJSONObject(2))
            "home.remove" -> if (panels.owns(a.getString(0))) panels.remove(a.getString(0)).also { emit("home.changed", null) } else if (appWidgets.owns(a.getString(0))) appWidgets.remove(a.getString(0)) else home.remove(a.getString(0))
            "home.addPanel" -> panels.add(a.getString(0), a.getInt(1), a.getJSONObject(2)).also { emit("home.changed", null) }
            "home.group" -> home.group(a.getString(0), a.getString(1))
            "home.arrange" -> home.arrange(a.getInt(0), a.getInt(1))
            "appwidgets.providers" -> appWidgets.providers()
            "appwidgets.add" -> appWidgets.add(a.getString(0), a.getInt(1), a.getJSONObject(2), a.getDouble(3), a.getDouble(4))
            "appwidgets.watch" -> appWidgets.watch(appWidgetEvents, a.getInt(0), a.getDouble(1), a.getDouble(2))
            "appwidgets.unwatch" -> appWidgets.unwatch(appWidgetEvents, a.getInt(0))
            "appwidgets.watchData" -> appWidgets.watchData(appWidgetEvents, a.getInt(0), a.getBoolean(1))
            "appwidgets.image" -> appWidgets.image(a.getString(0)) ?: JSONObject.NULL
            "appwidgets.touch" -> appWidgets.touch(a.getInt(0), a.getString(1), a.getDouble(2), a.getDouble(3), a.getDouble(4), a.getDouble(5))
            "appwidgets.configure" -> appWidgets.reconfigure(a.getInt(0))
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
            else ->
                when {
                    method.startsWith("remote.") -> remote.call(method.removePrefix("remote."), a)
                    method.startsWith("glasses.") -> glasses.call(method.removePrefix("glasses."), a)
                    else -> throw IllegalArgumentException("no such call: $method")
                }
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
                    .put("system", app.system)
                    // The app library's folders (shell/ui/library.ts): Android's own category, when the app says one.
                    .putOpt("category", app.category.takeIf { it >= 0 }),
            )
        }
        for (app in runtime.linuxApps) {
            list.put(
                JSONObject()
                    .put("key", "l:${app.id}")
                    .put("label", app.name)
                    .put("icon", icon("l:${app.id}"))
                    .put("kind", "linux")
                    .putOpt("categories", app.categories),
            )
        }
        return list
    }

    /** The launcher overlay up at once ([dev.omalauncher.system.PullHost.open]); false: no overlay host (no recents service). */
    private fun launcherOpen(kind: String, how: JSONObject?): Boolean {
        val pull = dev.omalauncher.system.PullHost.current ?: return false
        main.post { pull.open(kind, how) }
        return true
    }

    /** Home's page: whether a swipe up on it is the launcher overlay's now (as [homePull] is the shade's swipe down). */
    private fun launcherHomePull(on: Boolean, args: JSONArray, split: Boolean): Boolean {
        val pull = dev.omalauncher.system.PullHost.current ?: return false
        val shade = dev.omalauncher.system.ShadeHost.current
        main.post {
            pull.homePullExcluded = claimFree(args)
            pull.homeSplit = split
            pull.homePull = on
        }
        // Taken on the gesture input, as the shade's: only while that runs.
        return shade?.monitored == true
    }

    /**
     * Home's claim-free regions (spec G-R: the dock, bottom row or side column with its recents, and every list that
     * scrolls) on the screen: arg 3, a list of page rects; an older page sends only the dock's rect, arg 1.
     */
    private fun claimFree(a: JSONArray): List<android.graphics.Rect> {
        val list = a.optJSONArray(3)
        if (list == null) return listOfNotNull(a.optJSONObject(1)?.let { screenRect(it) })
        return (0 until list.length()).mapNotNull { i -> list.optJSONObject(i)?.let { screenRect(it) } }
    }

    private fun homePull(on: Boolean, args: JSONArray, mainPage: Boolean): Boolean {
        val shade = dev.omalauncher.system.ShadeHost.current ?: return false
        main.post {
            shade.homePullExcluded = claimFree(args)
            shade.homePull = on
            dev.omalauncher.system.Switcher.homeMainPage = mainPage
        }
        return shade.monitored
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
     * Brings task [id] back - from its card at [from] (CSS px, the page's), growing out of it to full screen
     * (ActivityOptions.makeScaleUpAnimation) when given.
     */
    private fun openTask(
        id: Int,
        from: Any?,
    ): Boolean {
        val options =
            when {
                // The page grew the card to the screen already: the app appears at once over its own snapshot.
                from == "instant" -> android.app.ActivityOptions.makeCustomAnimation(context, dev.omalauncher.R.anim.powos_none, dev.omalauncher.R.anim.powos_none)
                from is JSONObject -> {
                    val r = viewRect(from)
                    android.app.ActivityOptions.makeScaleUpAnimation(web, r.left, r.top, r.width(), r.height())
                }
                else -> android.app.ActivityOptions.makeBasic()
            }
        // A web window floating on its display: shown where it was, on its page (home's page does it).
        if (WebWindows.openForTask(context, id)) return true.also { dev.omalauncher.system.Switcher.hide() }
        // Unfolded: a full-screen task comes back as a floating window, like any app opened there.
        val floats = dev.omalauncher.system.AppWindows.floating(context)
        // Its window hidden on another home page: shown there, home goes to that page (openAway).
        val ok = (floats && openAway(id)) || dev.omalauncher.system.Tasks.open(context, id, dev.omalauncher.system.AppWindows.taskOptions(context, id, options))
        // A floating window leaves home in sight, so home never stops and "recents.hide" (Switcher.homeStopped) never
        // comes: the switcher's layer - and the card grown over it - stayed behind the window, a full-screen ghost of
        // the app (2026-10-23). The layer goes once the window is up over its card.
        if (ok && floats) android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ dev.omalauncher.system.Switcher.hide() }, WINDOW_UP_MS)
        return ok
    }

    /**
     * Task [id]'s floating window hidden because it lives on another home page (a page slide took it away): shown again
     * and in front, and home goes to its page ("windows.raised", ui/desktops.ts) - as a dock tap does. Before, a
     * recents card only moved the task to front: its leash stayed hidden, home stayed on the other page, no window and
     * no title bar (2026-10-29, e2e-desktop step 39). False if it isn't such a window.
     */
    private fun openAway(id: Int): Boolean {
        val frames = dev.omalauncher.system.WindowFrames.current ?: return false
        if (!frames.isAway(id) || !frames.restore(id)) return false
        Log.i(TAG, "task $id opened from recents, away on its page: shown, home to its page")
        emit("windows.raised", id)
        return true
    }

    /**
     * Task [id] into a PowOS desktop window ([on]) or back to full screen. A PowOS desktop window is a freeform task under
     * AppWindows' rules (60% x 70% in the windows' area, cascaded, window density, PowOS title bar, a home page's desktop in
     * windows.list) - what any app opened on the unfolded home gets; "Floating window" (Tasks.float) is a bare freeform
     * task at a fixed spot. NOTE: the two are still separate systems (Android freeform vs the web shell's desktop); unify
     * them later so one "window" menu item places every app the same way. Unfolded only (false folded).
     */
    private fun desktopWindow(
        id: Int,
        on: Boolean,
    ): Boolean {
        if (!dev.omalauncher.system.AppWindows.floating(context)) return false
        // Web windows on: a PowOS desktop window IS a web window on home (toWebWindow), the switcher closing onto it.
        if (on && activity != null && WebWindows.on(context)) return toWebWindow(id).also { if (it) dev.omalauncher.system.Switcher.hide() }
        val ok =
            if (on) {
                dev.omalauncher.system.Tasks.open(context, id, dev.omalauncher.system.AppWindows.taskOptions(context, id, android.app.ActivityOptions.makeBasic()))
            } else {
                dev.omalauncher.system.FreeformTasks.setFullScreen(context, id, true, null)
            }
        if (ok) android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ dev.omalauncher.system.Switcher.hide() }, WINDOW_UP_MS)
        return ok
    }

    /**
     * THE way an app's task becomes a PowOS desktop window when web windows are on - the switcher card's "PowOS desktop
     * window" / "Back to window" and the system's own window menu (the "..." app handle's item, WebWindows.watchSystemFloat)
     * all come here. A web window's full-screen app goes back into its window (WebWindows.toWindow); a web window
     * already is shown where it is; any other app gets a new web window on home's current page holding ITS task
     * (moved onto the window's trusted display, never relaunched): at the task's floating bounds when it floats now,
     * else where its window was last put by hand (WindowPlaces), else the page's default centred size. False: not
     * possible here (web windows off, no home activity, the task gone, an app the drawer doesn't list).
     */
    fun toWebWindow(id: Int): Boolean {
        if (WebWindows.toWindowForTask(id)) return true
        if (WebWindows.openForTask(context, id)) return true
        if (activity == null || !WebWindows.on(context)) return false
        return newWebWindow(id)
    }

    /** [toWebWindow] for an app that has no web window: the page told to make one holding task [id] ("webwindows.adopt"). */
    private fun newWebWindow(id: Int): Boolean {
        val component = taskComponent(id) ?: return false.also { Log.w(TAG, "task $id: not running, no web window for it") }
        val app = drawerApp(component) ?: return false.also { Log.w(TAG, "task $id (${component.packageName}): no drawer app, no web window for it") }
        val bounds = lastBounds(id, component.packageName)
        val payload = JSONObject().put("task", id).put("key", "a:${app.key}").put("label", app.label)
        bounds?.let { payload.put("body", pageRect(it)) }
        Log.i(TAG, "task $id (${component.packageName}) to a web window at ${bounds?.toShortString() ?: "the default place"}")
        emit("webwindows.adopt", payload)
        return true
    }

    /** The drawer's app for [component] (that activity, else its package's). */
    private fun drawerApp(component: android.content.ComponentName) =
        runtime.androidApps.apps.firstOrNull { it.component == component }
            ?: runtime.androidApps.apps.firstOrNull { it.component.packageName == component.packageName }

    /** Where task [id] floats now (screen px), else where [pkg]'s window was last put by hand (WindowPlaces), else null. */
    private fun lastBounds(
        id: Int,
        pkg: String,
    ): android.graphics.Rect? =
        dev.omalauncher.system.FreeformTasks.list(context).firstOrNull { it.id == id }?.bounds
            ?: dev.omalauncher.system.WindowPlaces.get(context, dev.omalauncher.system.WindowPlaces.key(context, pkg))

    /** Running task [id]'s app (its base activity), or null: not running. */
    private fun taskComponent(id: Int): android.content.ComponentName? {
        @Suppress("DEPRECATION")
        val tasks = runCatching { context.getSystemService(android.app.ActivityManager::class.java).getRunningTasks(64) }.getOrDefault(emptyList())
        return tasks.firstOrNull { it.taskId == id }?.let { it.baseActivity ?: it.topActivity }
    }

    private fun density() = context.resources.displayMetrics.density

    /** A page rect { left, top, width, height } (CSS px) in the WebView's own px. */
    private fun viewRect(o: JSONObject): android.graphics.Rect {
        val d = density()
        val l = (o.optDouble("left") * d).toInt()
        val t = (o.optDouble("top") * d).toInt()
        return android.graphics.Rect(l, t, l + (o.optDouble("width") * d).toInt(), t + (o.optDouble("height") * d).toInt())
    }

    /** A page rect (CSS px) on the screen (px). */
    private fun screenRect(o: JSONObject): android.graphics.Rect {
        val at = IntArray(2).also(web::getLocationOnScreen)
        return viewRect(o).apply { offset(at[0], at[1]) }
    }

    /** The recent tasks, as the page lists them (the switcher's events carry them). */
    fun recentTasks(): JSONArray = tasks()

    /**
     * The recent tasks (the switcher's): [{ id, label, key, icon, snapshot }] newest first - the app's drawer key and
     * icon when it's in the drawer, its last frame served by ShellHost (/_task/<id>, new each time it's asked).
     */
    private fun tasks(): JSONArray {
        // A snapshot URL per task and per time it was last in front: the page's cache keeps a card's picture till the
        // task was used again (the switcher's own app gets a fresh one when its window lands, Switcher.settle).
        val stamp = System.currentTimeMillis()
        // Unfolded, every task comes back as a floating window ("floats"); one that is a window already comes back where
        // it is ("window", CSS px of this page): its card grows to there, never to the full screen.
        val floats = dev.omalauncher.system.AppWindows.floating(context)
        val windows = if (floats) dev.omalauncher.system.FreeformTasks.list(context).associateBy { it.id } else emptyMap()
        @Suppress("DEPRECATION")
        val running = runCatching { context.getSystemService(android.app.ActivityManager::class.java).getRunningTasks(64) }.getOrDefault(emptyList())
        val list = dev.omalauncher.system.Tasks.list(context).map { t -> taskJson(t, stamp, windows[t.id]?.bounds, running) }
        return JSONArray(linuxCards(stamp) + list)
    }

    /**
     * Linux web windows have no Android task: a card each all the same (WebWindows.linuxCards), so the switcher shows,
     * opens and swipes them away and the app menu's close (ui/desktops.ts closeApp: its tasks by key) closes them -
     * Tasks.remove / tasks.open / the card picture reach WebWindows by the card's id. First: the most recent windows.
     */
    private fun linuxCards(stamp: Long): List<JSONObject> {
        if (!webWindowsMade) return emptyList()
        return webWindows.linuxCards().map { c ->
            val key = c.key.takeIf { it.isNotEmpty() }
            JSONObject()
                .put("id", c.id)
                .put("label", c.label)
                .put("key", key ?: JSONObject.NULL)
                .put("icon", key?.let(::icon) ?: JSONObject.NULL)
                .put("webwindow", c.window)
                .put("snapshot", "${ShellHost.ORIGIN}/_task/${c.id}?v=$stamp")
                .apply { if (dev.omalauncher.system.AppWindows.floating(context)) put("floats", true) }
        }
    }

    /** One recent task as the switcher lists it ([tasks]); [w]: its floating window's bounds, [floats]: unfolded. */
    private fun taskJson(
        t: dev.omalauncher.system.Tasks.Task,
        stamp: Long,
        w: android.graphics.Rect?,
        running: List<android.app.ActivityManager.RunningTaskInfo>,
    ): JSONObject {
        val o = taskBase(t)
        // A window's picture is taken fresh as it's served (ShellHost): its version names its bounds too, so a window
        // resized since is fetched again, not the cached one of its old size.
        val version = webWindowFields(o, t.id, running) ?: t.lastActive.takeIf { it > 0 } ?: stamp
        o.put("snapshot", "${ShellHost.ORIGIN}/_task/${t.id}?v=$version${w?.let { "-${it.width()}x${it.height()}" } ?: ""}")
        if (dev.omalauncher.system.AppWindows.floating(context)) o.put("floats", true)
        if (w != null) o.put("window", pageRect(w))
        return o
    }

    /** Task [t]'s id, label, drawer key and icon. */
    private fun taskBase(t: dev.omalauncher.system.Tasks.Task): JSONObject {
        val (key, name) = taskApp(t)
        return JSONObject()
            .put("id", t.id)
            .put("label", t.label ?: name ?: t.component?.packageName ?: "")
            .put("key", key ?: JSONObject.NULL)
            .put("icon", key?.let(::icon) ?: JSONObject.NULL)
    }

    /**
     * A web window's task (floating on its display, or its full-screen app): which window ("webwindow", "fullScreen")
     * into [o]. A floating one's picture version: now (its lastActive never moves while it stays on screen; its card
     * gets its content as it is). Null: not floating as a web window.
     */
    private fun webWindowFields(
        o: JSONObject,
        id: Int,
        running: List<android.app.ActivityManager.RunningTaskInfo>,
    ): Long? {
        val ww = WebWindowDisplays.windowOf(context, id, running) ?: return null
        o.put("webwindow", ww)
        if (WebWindowDisplays.fullScreenWindow(id) == null) return System.currentTimeMillis()
        o.put("fullScreen", true)
        return null
    }

    /** A screen rect (px) as a rect of this page (CSS px). */
    private fun pageRect(w: android.graphics.Rect): JSONObject {
        val at = IntArray(2).also(web::getLocationOnScreen)
        val d = density()
        return JSONObject().put("left", (w.left - at[0]) / d).put("top", (w.top - at[1]) / d).put("width", w.width() / d).put("height", w.height() / d)
    }

    /**
     * Task [t]'s app in the drawer: (its key, its name), or nulls. A Linux window's task (PowosWindowActivity) and
     * Plasma's desktop (MainActivity) are PowOS's own package, so the package says nothing there: the PowOS app they
     * show, never PowOS's own launcher entry (the generic card the switcher showed for Dolphin before).
     */
    private fun taskApp(t: dev.omalauncher.system.Tasks.Task): Pair<String?, String?> {
        val c = t.component
        if (c?.packageName == context.packageName) {
            val linux =
                if (c.className == andro.marchy.MainActivity::class.java.name) {
                    runtime.linuxApps.firstOrNull { it.exec == dev.omalauncher.linux.PLASMA_COMMAND }
                } else {
                    linuxApp(t.id, c.packageName, t.label)
                }
            if (linux != null || c.className == andro.marchy.PowosWindowActivity::class.java.name) return Pair(linux?.let { "l:${it.id}" }, linux?.name)
        }
        val apps = runtime.androidApps.apps.filter { it.profile == null }
        val app = apps.firstOrNull { it.component == c } ?: apps.firstOrNull { it.component.packageName == c?.packageName }
        return Pair(app?.let { "a:${it.key}" }, app?.label)
    }

    /** Which apps run, key -> "running" | "frozen" (RunningApps). */
    private fun running(): JSONObject = RunningApps.shellMap(runtime.androidApps.apps.map { it.key to it.component.packageName }, runtime.linuxApps)

    /** The notification panel's list: { available, items: [notificationJson] }. */
    private fun notificationList(): JSONObject {
        val n = runtime.widgets.notifications
        return JSONObject().put("available", n.available).put("items", JSONArray(n.items().map(::notificationJson)))
    }

    /**
     * A notification as the page shows it: { key, app, icon, title, text, time, clearable, profile, actions: [{ title,
     * input }], category, pkg, group, conversation } - the panel's (grouped: notifications.tsx), and the shade's
     * heads-up banner's ("shade.peek").
     */
    fun notificationJson(item: dev.omalauncher.widgets.runtime.Notifications.Item): JSONObject {
        // The app's drawer icon (its own profile's, badge and all, when it's from a work or cloned one).
        val app = runtime.androidApps.apps.firstOrNull { it.component.packageName == item.pkg && (item.profile == null) == (it.profile == null) }
        return JSONObject()
            .put("key", item.key)
            .put("app", item.app)
            .put("icon", linuxIcon(item) ?: app?.let { icon("a:${it.key}") } ?: JSONObject.NULL)
            .put("title", item.title)
            .put("text", item.text)
            .put("time", item.time)
            .put("clearable", item.clearable)
            .put("profile", item.profile ?: JSONObject.NULL)
            .put("actions", JSONArray(item.actions.map { JSONObject().put("title", it.title).put("input", it.input) }))
            .put("category", item.category ?: JSONObject.NULL)
            // A Plasma one groups by its Linux app (not with PowOS's own notifications, which share the app's package).
            .put("pkg", item.linuxEntry?.let { "linux:" + it.ifEmpty { item.app } } ?: item.pkg)
            .put("group", item.group ?: JSONObject.NULL)
            .put("conversation", item.conversation)
    }

    /**
     * A Plasma notification's icon (PlasmaBridge): its Linux app's drawer icon - by its desktop entry, else the app
     * whose Icon= it named, else by name - or Plasma's own; null for an Android notification.
     */
    private fun linuxIcon(item: dev.omalauncher.widgets.runtime.Notifications.Item): String? {
        val entry = item.linuxEntry ?: return null
        val apps = runtime.linuxApps
        val app =
            apps.firstOrNull { entry.isNotEmpty() && it.id == entry }
                ?: apps.firstOrNull { !item.linuxIcon.isNullOrEmpty() && it.icon == item.linuxIcon }
                ?: apps.firstOrNull { it.name.equals(item.app, ignoreCase = true) }
                ?: apps.firstOrNull { it.id == "org.powos.plasma" }
        return app?.let { icon("l:${it.id}") }
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
     * A saved fps-meter recording to the coordinator's comms inbox (priority high, so its mail monitor picks it up): the
     * summary inline, the full trace's path in the guest. Off the bridge thread; a failure only logs (the file and the
     * AI chat message still stand).
     * HACK: shells out to `powos comms send` through RootedGuest, as AgentsSpool.message does - the real fix is a comms
     * reducer the app calls directly (Phase 2's SpacetimeDB comms), no guest process per message.
     */
    private fun sendPerfToCoordinator(json: String, path: String) {
        val summary = runCatching { JSONObject(json).optJSONObject("summary")?.toString() }.getOrNull() ?: "{}"
        val text = "Perf recording from the phone's fps meter (record/stop). Full data: $path (on the phone; Android path " +
            "/data/user/0/${context.packageName}/files/run/powos-ai-shared/${path.substringAfterLast('/')}). Summary: $summary"
        Thread({
            runCatching {
                dev.omalauncher.linux.RootedGuest.run(
                    "powos comms send coordinator ${dev.omalauncher.linux.shellQuote(text)} --from shell --priority high",
                )
            }.onFailure { android.util.Log.w("ShellBridge", "perf: can't mail the coordinator", it) }
        }, "perf-send").start()
    }

    /**
     * Runs the default agent on a task (new widget, new app) in a terminal, as the home menu does; without Linux or
     * an agent, opens the screen that sets them up. Returns what it did: "started", "linux" or "agents".
     */
    private fun withAgent(task: (Agent) -> Pair<String, String>): String {
        val agent = runtime.agents.default
        return when {
            !(runtime.bootstrap.isInstalled || runtime.powosSession) -> "linux".also { openScreen(ShellScreens.LINUX) }
            agent == null -> "agents".also { openScreen(ShellScreens.AGENTS_SCREEN) }
            else -> "started".also { task(agent).let { (command, title) -> runtime.terminal(command, title, agent) } }
        }
    }

    /** Opens one of the page's screens (shell/ui/screens.tsx), as if it had been tapped there. */
    private fun openScreen(name: String) = emit("screens.open", JSONObject().put("name", name))

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

    private fun aiMail() =
        JSONArray(AgentMail.recent.map { JSONObject().put("id", it.id).put("from", it.from).put("text", it.text).put("time", it.time).put("priority", it.priority) })

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
        JSONObject()
            .put("busy", PowosAiChat.busy)
            .put("items", JSONArray(PowosAiChat.items.map { it.json() }))
            .put("thread", PowosAiChat.thread?.json() ?: JSONObject.NULL)
            .put("queued", JSONArray(PowosAiChat.queued.map { it.json() }))

    /**
     * [key]'s icon ("a:<key>" / "l:<id>"): its file's URL (ShellIcons), the same until the icon changes. One never
     * drawn yet is asked for by key - a 404 until the catalog has it, when the list comes again with its file.
     */
    private fun icon(key: String): String {
        val bitmap =
            when {
                key.startsWith("a:") -> runtime.androidApps.icons[key.removePrefix("a:")]
                key.startsWith("l:") -> runtime.linuxIcons[key.removePrefix("l:")]
                else -> null
            }
        return ShellIcons.url(key, bitmap) ?: "${ShellHost.ORIGIN}/_icon/${Uri.encode(key)}"
    }

    /** Recent keys still installed, in the page's form ("a:…" / "l:…"). */
    private fun installed(keys: List<String>): List<String> {
        val have = runtime.androidApps.apps.map { "a:${it.key}" }.toSet() + runtime.linuxApps.map { "l:${it.id}" }
        return keys.filter { it in have }
    }

    /**
     * The floating windows, top-most first: { id, pkg, label, minimised, away, app }. app is the shell's key of a PowOS
     * (Linux) app shown in the window (its task is PowOS's own, PowosWindowActivity: pkg says nothing), else absent.
     */
    private fun windows(): JSONArray =
        JSONArray(
            dev.omalauncher.system.WindowFrames.running.value.map {
                val linux = linuxApp(it.id, it.pkg, it.label)
                JSONObject().put("id", it.id).put("pkg", it.pkg ?: "").put("label", linux?.name ?: it.label).put("minimised", it.minimised).put("away", it.away)
                    .apply { if (linux != null) put("app", "l:${linux.id}") }
                    .apply { it.bounds?.let { b -> put("bounds", JSONArray(listOf(b.left, b.top, b.right, b.bottom))) } }
            },
        )

    /**
     * The PowOS app whose window task [id] shows (a task of PowOS's own package only), or null: by the app id KWin
     * gave the window (its desktop file name), else - none given (an X11 app without one) or none matching - by its
     * [caption]'s app name (KDE's captions end in " — <app>").
     */
    private fun linuxApp(
        id: Int,
        pkg: String?,
        caption: String?,
    ): dev.omalauncher.linux.LinuxApp? {
        if (pkg != context.packageName) return null
        val appId = andro.marchy.WindowTasks.appIdOfTask(id) ?: return null
        return runtime.linuxApps.firstOrNull { appId.isNotEmpty() && it.matches(appId) } ?: byCaption(caption)
    }

    /** The PowOS app a window's [caption] names: all of it, or its last " — " / " - " part (Plasma itself left out). */
    private fun byCaption(caption: String?): dev.omalauncher.linux.LinuxApp? {
        val c = caption?.trim().orEmpty()
        if (c.isEmpty()) return null
        val tail = c.substringAfterLast(" — ").substringAfterLast(" - ")
        return runtime.linuxApps.firstOrNull { it.exec != dev.omalauncher.linux.PLASMA_COMMAND && (it.name.equals(c, true) || it.name.equals(tail, true)) }
    }

    /** A PowOS app's floating window, if it has one (shown, minimised or on another page): brought back, its task. */
    private fun restoreLinux(key: String): Int? {
        val w = dev.omalauncher.system.WindowFrames.running.value.firstOrNull { linuxApp(it.id, it.pkg, it.label)?.let { a -> "l:${a.id}" } == key } ?: return null
        return w.id.takeIf { dev.omalauncher.system.WindowFrames.current?.restore(it) == true }
    }

    /**
     * Closes PowOS app [key] cleanly when it is a Steam game (the games tooling's own close, lib/game.sh `powos game
     * <appid> stop`: its launch chain TERMed, wineserver too) or Steam itself (woken if unified sleep froze it, then
     * asked to -shutdown, as `stop --steam` does). False for anything else: the page removes its tasks instead, as a
     * window's close button does. Runs in the PowOS session off the main thread; its result goes to logcat.
     */
    private fun closeApp(key: String): Boolean {
        if (!RootedGuest.enabled) return false
        val app = runtime.linuxApps.firstOrNull { "l:${it.id}" == key } ?: return false
        val game = Regex("""rungameid/(\d+)""").find(app.exec)?.groupValues?.get(1)
        val steam = app.exec.trim().substringBefore(' ').substringAfterLast('/') == "steam"
        val command =
            when {
                game != null -> "timeout 20 powos game $game stop"
                steam ->
                    "timeout 2 dbus-send --session --print-reply=literal --reply-timeout=1500 --dest=dev.powos.Sleep /Gui " +
                        "dev.powos.Sleep.Gui.Wake string:steam >/dev/null 2>&1; timeout -k 1 10 steam -shutdown </dev/null"
                else -> return false
            }
        thread(name = "app-close", isDaemon = true) {
            val code = runCatching { RootedGuest.runOwn(command) { Log.i("PowosShell", "close $key: $it") } }.getOrElse { -1 }
            Log.i("PowosShell", "close $key: exit $code")
        }
        return true
    }

    private fun android(key: String) = runtime.androidApps.apps.firstOrNull { "a:${it.key}" == key }

    private fun launch(key: String) {
        runtime.usage.record(key)
        // Web windows on (unfolded): an app opened from another of PowOS's windows (the launcher overlay, Quick Tools,
        // the AI) opens as a web window on home, as home's own launch does (state.ts launch -> openWebWindow) - never
        // an Android freeform window with the old WindowFrames bar (the Phone app from the launcher, 2026-10-30).
        if (launchOnHome(key)) {
            runtime.usage.settle()
            return
        }
        when {
            // An app with a floating window already (shown or minimised): that window comes back, no second launch.
            key.startsWith("a:") ->
                android(key)?.let { app ->
                    // Brought back: home goes to the page it's on (windows.raised, ui/desktops.ts).
                    val id = dev.omalauncher.system.WindowFrames.current?.restoreApp(app.component.packageName)
                    if (id != null) emit("windows.raised", id) else runtime.androidApps.open(app)
                }
            // A PowOS app's floating window likewise (unfolded: its task floats, WindowTasks), else it opens.
            key.startsWith("l:") ->
                restoreLinux(key)?.let { emit("windows.raised", it) }
                    ?: runtime.linuxApps.firstOrNull { "l:${it.id}" == key }?.let { runtime.launch(it) }
        }
        // The strip shows it first next time home shows (the Compose launcher settles on stop, likewise).
        runtime.usage.settle()
    }

    /** Not home's bridge, web windows on: home's page asked to open [key] as a web window ("webwindows.launch"); false: not so here. */
    private fun launchOnHome(key: String): Boolean {
        if (activity != null || !key.startsWith("a:") || !dev.omalauncher.system.AppWindows.webDesktop(context)) return false
        val home = synchronized(live) { live.firstOrNull { it.activity != null } } ?: return false
        Log.i(TAG, "$key launched from an overlay: a web window on home")
        home.emit("webwindows.launch", JSONObject().put("key", key))
        return true
    }

    /** One of the shell's data files: a plain name, so the page can't reach outside its folder. */
    private fun store(name: String): File {
        require(name.matches(Regex("[A-Za-z0-9_.-]+")) && !name.startsWith(".")) { "bad store name: $name" }
        return File(data, "$name.json")
    }

    private fun keyboard(show: Boolean) {
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        // An overlay's page (the pull-up panel over apps/desktop, Quick Tools): its own window must be the IME target -
        // home's focus (homeTyping below) has nothing to do with it, and lifting home's non-focusable flag from here
        // let WM hand the focus to home under the panel (2026-10-28: no keyboard in the pull-up panel's search).
        overlay?.let { o ->
            overlayKeyboard(o, show, imm)
            return
        }
        // Home is non-focusable while desktop windows show (FreeformTasks.homeFocusable): a text field lifts that.
        dev.omalauncher.system.FreeformTasks.homeTyping(context, show)
        if (show) {
            web.requestFocus()
            if (web.hasWindowFocus()) {
                imm.showSoftInput(web, 0)
                return
            }
            // Desktop mode: a floating task (a terminal, Dolphin, Steam) keeps the input focus while home is tapped, so
            // Android serves the IME to that task and ignores ours - no keyboard. homeTyping above made home focusable
            // and every shown window task non-focusable, so WM's focus update hands the focus to home (the top
            // focusable task); the IME is shown once the window has it. No moveTaskToFront of home: in desktop mode
            // that is a TO_FRONT transition after which WM Shell re-raised the desktop's freeform tasks and the focus
            // went to a floating Linux window (PowosWindowActivity), hiding the IME (2026-10-28).
            Log.i(TAG, "keyboard.show without window focus: waiting for home's focus")
            val listener = object : android.view.ViewTreeObserver.OnWindowFocusChangeListener {
                override fun onWindowFocusChanged(hasFocus: Boolean) {
                    if (!hasFocus) return
                    web.viewTreeObserver.takeIf { it.isAlive }?.removeOnWindowFocusChangeListener(this)
                    web.requestFocus()
                    imm.showSoftInput(web, 0)
                }
            }
            web.viewTreeObserver.addOnWindowFocusChangeListener(listener)
            // Never wait forever: a focus that doesn't come drops the listener.
            main.postDelayed({ web.viewTreeObserver.takeIf { it.isAlive }?.removeOnWindowFocusChangeListener(listener) }, 1500)
            web.windowInsetsController?.show(WindowInsets.Type.ime())
        } else {
            imm.hideSoftInputFromWindow(web.windowToken, 0)
        }
    }

    /** The overlay page's keyboard: its own window becomes the IME target (see keyboard()). */
    private fun overlayKeyboard(o: dev.omalauncher.system.OverlaySlot, show: Boolean, imm: InputMethodManager) {
        val flags = o.typing(show)
        Log.i(TAG, "keyboard.show=$show in an overlay: $flags")
        if (!show) {
            imm.hideSoftInputFromWindow(web.windowToken, 0)
            return
        }
        web.requestFocus()
        if (web.hasWindowFocus()) {
            imm.showSoftInput(web, 0)
            return
        }
        // The window's focus follows its flag change: the IME is asked for once it has it.
        val listener = object : android.view.ViewTreeObserver.OnWindowFocusChangeListener {
            override fun onWindowFocusChanged(hasFocus: Boolean) {
                if (!hasFocus) return
                web.viewTreeObserver.takeIf { it.isAlive }?.removeOnWindowFocusChangeListener(this)
                web.requestFocus()
                imm.showSoftInput(web, 0)
            }
        }
        web.viewTreeObserver.addOnWindowFocusChangeListener(listener)
        main.postDelayed({ web.viewTreeObserver.takeIf { it.isAlive }?.removeOnWindowFocusChangeListener(listener) }, 1500)
        web.windowInsetsController?.show(WindowInsets.Type.ime())
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

    /**
     * The display state the page lays out by (shell/hosts/wide.ts), in dp: the window's size (not the page's, which can
     * lag a fold while hidden), the display id, rotation, and folded (the cover screen: under 600dp wide).
     */
    fun display(): JSONObject {
        val d = context.resources.displayMetrics.density
        val bounds = (activity?.windowManager ?: context.getSystemService(android.view.WindowManager::class.java)).currentWindowMetrics.bounds
        val disp = activity?.display ?: context.display
        return JSONObject()
            .put("widthDp", Math.round(bounds.width() / d))
            .put("heightDp", Math.round(bounds.height() / d))
            .put("displayId", disp?.displayId ?: 0)
            .put("rotation", disp?.rotation ?: 0)
            .put("folded", bounds.width() / d < 600)
    }

    private var lastDisplay = ""

    /** [display] pushed as "system.display" when it changed (or [force]: on resume/visible). */
    fun pushDisplay(force: Boolean = false) {
        val now = runCatching { display() }.getOrNull() ?: return
        if (!force && now.toString() == lastDisplay) return
        if (now.toString() != lastDisplay) Log.i(DISPLAY_TAG, "display $now")
        lastDisplay = now.toString()
        emit("system.display", now)
    }

    /** Fold, unfold, rotation, another display: DisplayManager hears of all of them, hidden or not. */
    private val displayListener =
        object : android.hardware.display.DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) = pushDisplay()

            override fun onDisplayRemoved(displayId: Int) = pushDisplay()

            override fun onDisplayChanged(displayId: Int) = pushDisplay()
        }

    init {
        context.getSystemService(android.hardware.display.DisplayManager::class.java).registerDisplayListener(displayListener, main)
    }

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

    /** [emit] now, on the main thread (a frame's worth of the switcher's drag: no extra hop). */
    fun emitNow(
        event: String,
        payload: String,
    ) {
        js("window.__powosHost && window.__powosHost.emit(${JSONObject.quote(event)}, $payload)")
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
        js(reply("resolve($id, $json)"))
    }

    /**
     * An answer to the page - dropped (counted in window.__powosLate) when the page that asked is gone: a reload with
     * calls in flight answered into the new page before its bridge.ts loaded, "Cannot read properties of undefined
     * (reading 'resolve')" (2026-10-20 01:51:37).
     */
    private fun reply(call: String) =
        "window.__powosHost && window.__powosHost.${call.substringBefore('(')} ? window.__powosHost.$call : (window.__powosLate = (window.__powosLate | 0) + 1)"

    private fun js(code: String) = web.evaluateJavascript(code, null)

    fun close() {
        health.close()
        if (activity != null) SystemFloat.stop(systemFloat)
        if (andro.marchy.WebWindowSource.host === linuxWindows) andro.marchy.WebWindowSource.host = null
        if (webWindowsMade) webWindows.closeAll()
        runCatching { context.getSystemService(android.hardware.display.DisplayManager::class.java).unregisterDisplayListener(displayListener) }
        ShellWallpaper.onChange.remove(wallpaperChanged)
        runCatching { android.app.WallpaperManager.getInstance(context).removeOnColorsChangedListener(wallpaperColors) }
        dev.omalauncher.theme.ThemeStore.changeListeners.remove(themeChanged)
        screens.close()
        appWidgets.unlisten(appWidgetEvents)
        remote.close()
        glasses.close()
        dev.omalauncher.AgentsSpool.forget(agentsView)
        quick.close()
        media.close()
        speech.cancel()
        applyObserver.dispose()
        terminals.closeAll()
        scope.cancel()
    }

    /** Stored JSON, passed through as it is. */
    private class RawJson(
        val text: String,
    )

    init {
        synchronized(live) { live.add(this) }
    }

    private fun broadcast(event: String, json: String, except: ShellBridge? = null) {
        val all = synchronized(live) { live.toList() }
        all.forEach { if (it !== except) it.emit(event, json) }
    }

    companion object {
        /** Every open shell window's bridge (weak: a closed window just drops out), for events meant for all of them. */
        private val live: MutableSet<ShellBridge> = java.util.Collections.newSetFromMap(java.util.WeakHashMap())

        private const val TAG = "PowosShell"

        /** A board task id, as the page's "works" / "still broken" may name one (apps/agents caps ids at 64). */
        private val VERDICT_TASK = Regex("[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}")

        /** logcat tag of every display/fold push (and the page's wide/narrow switch, via its console). */
        private const val DISPLAY_TAG = "PowosDisplay"

        /** A task opened as a floating window is up over its grown card by then: the switcher's layer may go. */
        private const val WINDOW_UP_MS = 150L

        /** ShellActivity's request code for the mic permission. */
        const val MIC_REQUEST = 41
    }
}
