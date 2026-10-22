package dev.omalauncher

import android.app.ActivityManager
import android.content.ComponentCallbacks
import android.content.Context
import android.content.res.Configuration
import android.content.Intent
import java.io.File
import android.net.Uri
import android.util.Log
import android.view.KeyEvent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import dev.omalauncher.linux.AGENTS
import dev.omalauncher.linux.Agent
import dev.omalauncher.linux.AgentStore
import dev.omalauncher.linux.POWOS
import dev.omalauncher.linux.AudioBridge
import dev.omalauncher.linux.Bootstrap
import dev.omalauncher.linux.FILES_COMMAND
import dev.omalauncher.linux.Gpu
import dev.omalauncher.linux.LinuxApp
import dev.omalauncher.linux.OpenBridge
import dev.omalauncher.linux.Pacman
import dev.omalauncher.linux.Proot
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.linux.LinuxState
import dev.omalauncher.linux.SystemUpdates
import dev.omalauncher.linux.TerminalFont
import dev.omalauncher.linux.bundledIcons
import dev.omalauncher.linux.defaultApps
import dev.omalauncher.linux.loadLinuxApps
import dev.omalauncher.linux.loadPowosApps
import dev.omalauncher.linux.PowosShortcuts
import dev.omalauncher.linux.matches
import dev.omalauncher.linux.resolveLinuxIcon
import dev.omalauncher.linux.run
import dev.omalauncher.linux.shellQuote
import dev.omalauncher.theme.Style
import dev.omalauncher.theme.StyleStore
import dev.omalauncher.theme.ThemeStore
import dev.omalauncher.ui.KeyboardBridge
import dev.omalauncher.ui.TerminalTiles
import dev.omalauncher.ui.WindowManager
import dev.omalauncher.ui.bitmapMask
import dev.omalauncher.ui.decodeIcon
import dev.omalauncher.upgrade.Provisioner
import dev.omalauncher.upgrade.writeAtomically
import dev.omalauncher.wayland.AndroidClipboard
import dev.omalauncher.wayland.OutputInfo
import dev.omalauncher.wayland.WaylandServer
import dev.omalauncher.wayland.XdgToplevel
import dev.omalauncher.widgets.Shortcut
import dev.omalauncher.widgets.WidgetEngine
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.collectLatest
import dev.omalauncher.theme.SystemTheme
import dev.omalauncher.ui.Palette
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/**
 * Process-wide state: the launcher (themes, widgets, Android apps) and the
 * optional Linux system (the rootfs, the Wayland server, the window manager).
 */
class Runtime(
    private val context: Context,
) {
    val proot = Proot(context)
    val wm = WindowManager()
    val server = WaylandServer(proot.waylandSocket.path, wm).also { wm.server = it }
    val keyboard = KeyboardBridge(wm)

    /** For what the launcher draws outside Compose (PtyTerminal: its fonts, the clipboard). */
    val appContext: Context get() = context.applicationContext
    val terminals = TerminalTiles(this)
    val style = StyleStore(context)
    val terminalFont = TerminalFont(proot, style)
    val linuxApps = mutableStateListOf<LinuxApp>()

    /** Icons of [linuxApps] by desktop id; apps without a PNG icon have no entry. */
    val linuxIcons = mutableStateMapOf<String, ImageBitmap>()

    /** Silhouettes of [linuxIcons] for the monochrome icon style. */
    val linuxMasks = mutableStateMapOf<String, ImageBitmap>()
    val androidApps = AndroidAppCatalog(context)
    val usage = AppUsage(context)
    val drawerPins = DrawerPins(context)
    val themes = ThemeStore(context, proot, style, isLinux = { linux }, onConfigChanged = ::syncGuest)
    private val audio = AudioBridge(proot)
    private val openBridge = OpenBridge(context, proot, onOpenFiles = ::openFiles)
    val agents = AgentStore(proot, onChanged = ::syncGuest, powosSession = { powosSession })
    val pacman = Pacman(context, proot)
    val widgets = WidgetEngine(context, proot, this)
    val updates = SystemUpdates(proot, pacman, agents)
    val gpu = Gpu(context, proot)

    /** The launcher's own provided files (default widgets, their docs); see [Provisioner]. */
    private val launcherFiles = Provisioner(proot.filesDir, LauncherData.LAUNCHER_MANIFEST, listOf(widgets::managed, style::managed))

    /** Every launcher-provided file in the guest; synced only while Linux is installed. */
    private val provisioner: Provisioner =
        Provisioner(
            proot.filesDir,
            LauncherData.GUEST_MANIFEST,
            listOf(
                { defaultApps(proot.applications) },
                { bundledIcons(context, proot.home) },
                openBridge::managed,
                pacman::managed,
                agents::managed,
                themes::managed,
                widgets::guestManaged,
            ),
        )
    val bootstrap = Bootstrap(context, proot, agents, pacman, provisioner)

    /** Its jobs write files and start the guest; one that fails (storage full) mustn't take the home screen down. */
    private val scope =
        CoroutineScope(SupervisorJob() + Dispatchers.Main + CoroutineExceptionHandler { _, e -> Log.e(TAG, "background job failed", e) })
    private var started = false
    private var prepared = false

    private val prefs = context.getSharedPreferences("launcher", Context.MODE_PRIVATE)

    /**
     * The first-run screen is done: from then on the home screen shows, with
     * or without Linux. Installs from before Linux was optional count as done.
     */
    var launcherReady by mutableStateOf(prefs.getBoolean(SETUP_DONE, false) || bootstrap.wanted)
        private set

    /** Linux is installed and its services run: guest commands (like the update check) can go. */
    private var linux = false

    /** The Linux install and removal; one at a time. */
    private var linuxJob: Job? = null

    /** Set when something that needs Linux was asked for without it; the home screen opens the install sheet and clears it. */
    var linuxWanted by mutableStateOf(false)

    init {
        // Saved, so removing Linux later doesn't bring the first-run screen back.
        if (launcherReady) prefs.edit().putBoolean(SETUP_DONE, true).apply()
        themes.loadPalette()
        // An agent or the user edited style.toml; the rest of the style is read where it's drawn.
        style.onExternalChange = { old, new ->
            val changed = new.changed(old)
            if (Style.THEME.key in changed || Style.BACKGROUND.key in changed) scope.launch { themes.followStyle() }
        }
        // foot.ini follows the terminal settings, from the Style menu or the file alike.
        scope.launch {
            snapshotFlow { style.style[Style.TERMINAL_FONT] to style.style[Style.TERMINAL_TEXT] }.drop(1).collect { terminalFont.write() }
        }
        androidApps.start()
        // PowOS rooted mode: the theme goes to the PowOS desktop and Android too (SystemTheme); once per change.
        if (RootedGuest.enabled) {
            scope.launch {
                snapshotFlow { if (style.style[Style.SYSTEM_THEME]) Palette.current else null }.collectLatest { palette ->
                    palette ?: return@collectLatest
                    val key = SystemTheme.key(palette).hashCode().toString()
                    if (prefs.getString(SYSTEM_THEME_KEY, null) == key) return@collectLatest
                    if (withContext(Dispatchers.IO) { SystemTheme.apply(palette) }) prefs.edit().putString(SYSTEM_THEME_KEY, key).apply()
                }
            }
        }
        // Omarchy's Super bindings inside Linux windows; the home screen handles its own (see MainActivity).
        keyboard.onShortcut = { code ->
            when (code) {
                KeyEvent.KEYCODE_ENTER -> true.also { terminal(null, "Terminal") }
                KeyEvent.KEYCODE_W -> wm.focused?.let { wm.close(it) } != null
                else -> false
            }
        }
        // A terminal shown again after the text size changed catches up, with foot's own zoom keys.
        wm.created = { window -> if (followsTerminalFont(window.appId)) terminalFont.track(window) }
        wm.focusGained = { window -> wm.zoom(window, terminalFont.catchUp(window)) }
        wm.openAppWindow = { handle ->
            // Recents uses the activity's manifest label, not the task description's; see the aliases in the manifest.
            val window = wm.windowByHandle(handle)
            val name = window?.let { displayName(it.appId, it.title) }
            val activity =
                when (name) {
                    "Terminal" -> "TerminalWindow"
                    "btop" -> "BtopWindow"
                    else -> agentOf(window?.appId.orEmpty(), name)?.windowAlias ?: "LinuxWindowActivity"
                }
            context.startActivity(
                Intent()
                    .setClassName(context, "dev.omalauncher.$activity")
                    .setData(Uri.parse("omarchy://window/$handle"))
                    .addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NEW_DOCUMENT or
                            Intent.FLAG_ACTIVITY_MULTIPLE_TASK,
                    ),
            )
        }
    }

    /** The launcher first (it never waits for Linux), then Linux if it's installed or an install was started. */
    fun start() {
        if (started) return
        started = true
        // The lock screen's face: PowOS's, over Android's (shell/LockFace.kt).
        dev.omalauncher.shell.LockFace.start(context)
        scope.launch {
            withContext(Dispatchers.IO) {
                LauncherData.migrate(context)
                launcherFiles.sync()
                agents.load()
            }
            themes.load()
            style.start()
            widgets.start()
            // On the first-run screen the download is the screen's job, with progress.
            if (launcherReady) scope.launch { themes.ensureRelease() }
            // Rooted PowOS: the terminal tiles' services start too (onRootedReady).
            if (bootstrap.wanted || RootedGuest.enabled) runLinux { bootstrap.run() } else bootstrap.run()
        }
    }

    /** The first-run screen is done; the home screen shows from now on, while the rest of the themes download. */
    fun finishWelcome() {
        prefs.edit().putBoolean(SETUP_DONE, true).apply()
        launcherReady = true
        scope.launch { themes.ensureRelease() }
    }

    /** Installs Linux in the background, with [agents]; progress shows in [Bootstrap.state] and the notification. */
    fun installLinux(agents: List<Agent>) = runLinux { bootstrap.install(agents) }

    /** Continues a failed install, or a failed update of an installed system. */
    fun retryLinux() = runLinux { bootstrap.run() }

    /**
     * PowOS: re-reads whether PowOS is installed. The engine installs it in its own activity, so the home
     * screen checks again whenever it comes back (MainActivity.onResume); otherwise it keeps offering the
     * install. Only the state: Omalauncher's own Linux services (onLinuxReady: its compositor, proot
     * helpers, Linux app scan) target its proot system and stay off until they run on PowOS (phase 2).
     */
    fun refreshLinuxState() {
        if (linuxJob?.isActive == true) return
        scope.launch { bootstrap.run() }
    }

    /** Runs [work] with the foreground service up, so it goes on outside the app; then starts Linux if it's installed. */
    private fun runLinux(work: suspend () -> Unit) {
        if (linuxJob?.isActive == true) return
        linuxJob =
            scope.launch {
                setService(true)
                withContext(Dispatchers.IO) {
                    if (!prepared) {
                        proot.prepare()
                        prepared = true
                    }
                }
                work()
                // PowOS: Omalauncher's own Linux services target its proot system; off until phase 2 (see refreshLinuxState).
                when {
                    bootstrap.isInstalled && !POWOS -> onLinuxReady()
                    // The engine's SessionService keeps the process alive then; no second notification.
                    RootedGuest.enabled -> onRootedReady().also { setService(false) }
                    else -> setService(false)
                }
            }
    }

    /**
     * Deletes Linux: its apps, agents, packages and home. Themes, widgets and
     * the home screen stay; widgets that need Linux turn back into placeholders.
     */
    fun removeLinux() {
        if (!bootstrap.isInstalled || linuxJob?.isActive == true) return
        linuxJob =
            scope.launch {
                linux = false
                widgets.linuxChanged(false)
                audio.stop()
                withContext(Dispatchers.IO) { proot.killAll() }
                bootstrap.remove()
                withContext(Dispatchers.IO) {
                    updates.forget()
                    agents.load()
                }
                gpu.turnOff()
                linuxApps.clear()
                linuxIcons.clear()
                linuxMasks.clear()
                setService(false)
            }
    }

    /** The foreground service keeps the process, and with it Linux, alive; only while Linux is installed or installing. */
    private fun setService(on: Boolean) {
        val intent = Intent(context, LinuxService::class.java)
        // Android 12+ refuses a foreground service started from the background; the work then goes on without it.
        if (on) runCatching { context.startForegroundService(intent) }.onFailure { Log.w(TAG, "cannot start the service", it) } else context.stopService(intent)
    }

    /** Guest configs follow the theme and the installed agents; only while there is a guest. */
    private fun syncGuest() {
        if (linux) provisioner.sync()
    }

    /** Whether the bridges and the Wayland server are up; they run until the process ends, even if Linux is removed. */
    private var servicesStarted = false

    private suspend fun onLinuxReady() {
        if (linux) return
        if (!servicesStarted) {
            startServices()
            withContext(Dispatchers.IO) {
                proot.procShim.start()
                openBridge.start()
            }
        } else {
            // Linux installed again: its new home has no foot-font.ini yet.
            terminalFont.write()
        }
        linux = true
        // The recent apps strip on home lists Linux apps before the app list is ever opened.
        scope.launch { refreshApps() }
        // Themes picked without Linux are written into the guest now.
        themes.renderGuest()
        withContext(Dispatchers.IO) {
            provisioner.sync()
            audio.start()
            synchronized(server) { server.input.setKeymap(proot.keymap.path) }
            agents.load()
        }
        widgets.linuxChanged(true)
        refreshApps()
        withContext(Dispatchers.IO) { updates.load() }
        scope.launch {
            // Update steps that need the network; the home screen doesn't wait for them.
            bootstrap.runBacklog()
            updates.check()
        }
        // Apps render in software until the GPU passed its check on this system build.
        scope.launch { gpu.recheck() }
    }

    /** The Wayland server, its output and the clipboard; once per process (they run until it ends). */
    private suspend fun startServices() {
        if (servicesStarted) return
        servicesStarted = true
        updateOutput()
        synchronized(server) { server.selection.system = AndroidClipboard(context, server::clipboardChanged) }
        context.registerComponentCallbacks(
            object : ComponentCallbacks {
                override fun onConfigurationChanged(newConfig: Configuration) = updateOutput()

                @Deprecated("Deprecated in Java")
                override fun onLowMemory() = Unit
            },
        )
        withContext(Dispatchers.IO) {
            runCatching { server.start() }.onFailure {
                // HACK: rooted, the server's socket can't be made - a priv_app may not create sock_files in its data -
                // and nothing needs it there (PowOS's windows draw on KWin's display, terminals are PtyTerminal), so the
                // rest of the rooted start (the session's shells, every widget that runs in it) goes on without it.
                // Real fix: priv_app sock_file rules in the PowOS system module's sepolicy, or an abstract socket.
                if (!RootedGuest.enabled) throw it
                Log.w(TAG, "Wayland server not started (rooted: not needed)", it)
            }
        }
    }

    /** Terminals run in the PowOS session (rooted mode); see [RootedGuest]. */
    private var rootedTerminals by mutableStateOf(false)

    /** PowOS on a rooted phone is this launcher's Linux: its apps are [linuxApps], its sessions the terminals'. */
    val powosSession: Boolean get() = !linux && rootedTerminals

    /**
     * PowOS on a rooted phone: of Omalauncher's own Linux services only the Wayland server, for the terminal tiles,
     * whose foot runs in the PowOS desktop session (RootedGuest) - Omalauncher's proot system isn't installed, and
     * PowOS's packages and updates are PowOS's (never pacman from here).
     */
    private suspend fun onRootedReady() {
        if (rootedTerminals) return
        startServices()
        withContext(Dispatchers.IO) {
            // The keymap Wayland clients get; PowOS's xkbcommon compiles it, once.
            if (!proot.keymap.exists()) {
                val out = StringBuilder()
                if (RootedGuest.run("xkbcli compile-keymap --layout us 2>/dev/null || /usr/lib/xkbcommon/xkbcli-compile-keymap --layout us") { out.appendLine(it) } == 0) {
                    writeAtomically(proot.keymap, out.toString().toByteArray() + 0)
                }
            }
            synchronized(server) { server.input.setKeymap(proot.keymap.path) }
        }
        rootedTerminals = true
        RootedGuest.runDir = File(context.filesDir, "run")
        widgets.terminalsChanged(true)
        // Widgets' commands, streams and actions run in the PowOS session too (GuestShell, Streams): PowOS is their Linux.
        widgets.linuxChanged(true)
        // PowOS's apps in the drawer, search and Android's shortcuts.
        refreshApps()
    }

    /** Turns GPU acceleration on (installing and checking the driver) or off, for Linux apps started from then on. */
    fun setGpu(on: Boolean) {
        if (!linux) return
        if (on) scope.launch { gpu.turnOn() } else gpu.turnOff()
    }

    /** Runs every pending update (packages and agents); the drawer then lists what changed. */
    fun updateSystem() {
        scope.launch {
            updates.updateAll()
            refreshApps()
        }
    }

    /**
     * Tells Wayland clients the screen's size and scale; they get it again on
     * rotation, a density change or a new Android font size, which also sizes
     * the terminal font.
     */
    private fun updateOutput() {
        val metrics = context.resources.displayMetrics
        val mmPerPx = 25.4f / metrics.xdpi
        val scale = outputScale()
        server.updateOutput(
            OutputInfo(
                metrics.widthPixels,
                metrics.heightPixels,
                scale,
                (metrics.widthPixels * mmPerPx).toInt(),
                (metrics.heightPixels * mmPerPx).toInt(),
            ),
        )
        terminalFont.update(metrics.density, context.resources.configuration.fontScale, scale, metrics.widthPixels)
    }

    /** wl_output scales are integers, so the density rounds down (2.625 -> 2); [TerminalFont] makes up the rest. */
    private fun outputScale() =
        context.resources.displayMetrics.density
            .toInt()
            .coerceIn(1, 4)

    /** Re-runs update steps that failed, e.g. offline; see [Bootstrap.updates]. */
    fun retryUpdates() {
        if (linux) scope.launch { bootstrap.runBacklog() }
    }

    /**
     * Launcher screens showing now: the home screen and Linux windows. Guest
     * helpers that only matter on screen (the /proc stand-ins) pause at zero.
     */
    private var screens = 0

    fun screenStarted() {
        if (screens++ == 0) proot.procShim.setActive(true)
        // Only checks when the last check is hours old; see SystemUpdates.
        if (linux) scope.launch { updates.check() }
    }

    fun screenStopped() {
        screens = (screens - 1).coerceAtLeast(0)
        if (screens == 0) proot.procShim.setActive(false)
    }

    /** Rescans .desktop entries; the list only changes (and recomposes) when entries do. */
    suspend fun refreshApps() {
        // Rooted mode: PowOS's own apps, as its menu has them (powos-apps-export writes them to the run dir).
        val powos = !linux && rootedTerminals
        if (!linux && !powos) return
        val apps =
            withContext(Dispatchers.IO) {
                if (powos) {
                    RootedGuest.run("powos-apps-export")
                    loadPowosApps(File(RootedGuest.runDir ?: return@withContext emptyList(), "powos-apps"))
                } else {
                    loadLinuxApps(proot)
                }
            }
        if (apps != linuxApps.toList()) {
            linuxApps.clear()
            linuxApps += apps
        }
        // And as Android's own shortcuts: the most used on the PowOS icon, pinned ones kept up to date.
        if (powos) withContext(Dispatchers.IO) { PowosShortcuts.publish(context, apps) { usage.score("l:" + it.id) } }
        val ids = apps.mapTo(HashSet()) { it.id }
        linuxIcons.keys.retainAll(ids)
        linuxMasks.keys.retainAll(ids)
        val missing = apps.filter { it.icon != null && it.id !in linuxIcons }
        if (missing.isEmpty()) return
        val size = (52 * context.resources.displayMetrics.density).toInt()
        val loaded =
            withContext(Dispatchers.IO) {
                missing.mapNotNull { app ->
                    val file = (if (powos) File(app.icon!!).takeIf { it.isFile } else resolveLinuxIcon(proot.rootfs, app.icon!!)) ?: return@mapNotNull null
                    decodeIcon(file, size)?.let { Triple(app.id, it.asImageBitmap(), bitmapMask(it).asImageBitmap()) }
                }
            }
        for ((id, icon, mask) in loaded) {
            linuxIcons[id] = icon
            linuxMasks[id] = mask
        }
    }

    /** A pinned app's icon as the drawer shows it, or its silhouette; null until loaded, or if it has none. */
    fun shortcutIcon(
        shortcut: Shortcut,
        mono: Boolean,
    ): ImageBitmap? {
        shortcut.component?.let { androidAppKey(it, shortcut.profile) }?.let { return if (mono) androidApps.masks[it] else androidApps.icons[it] }
        val id = shortcut.linux?.id ?: return null
        return if (mono) linuxMasks[id] else linuxIcons[id]
    }

    /** Wayland app_id -> name for windows we started, so their Android tasks get a proper label. */
    private val launchedNames = ConcurrentHashMap<String, String>()

    /** Wayland app_id -> the agent running in it, for sessions not named after their agent ("New app"). */
    private val launchedAgents = ConcurrentHashMap<String, Agent>()

    /** Whether a window's foot takes its size from foot.ini, as its own terminals, plain foot and most tiles do. */
    private fun followsTerminalFont(appId: String) =
        when {
            appId == "foot" -> true
            launchedNames.containsKey(appId) -> !terminalFont.hasOwnSize(appId)
            appId.startsWith(TerminalTiles.APP_ID_PREFIX) -> !terminals.hasOwnFont(appId)
            else -> false
        }

    /**
     * Opens [command] (or a shell) in a terminal named [name]. Each gets its own
     * foot app_id, so Recents shows "Grok" or "btop" rather than one "foot" per window.
     * An [agent] session gets the agent's logo and Recents entry whatever it's named.
     */
    fun terminal(
        command: String?,
        name: String,
        agent: Agent? = null,
    ) {
        // PowOS rooted mode: a PowOS terminal the launcher draws, as its own task (folded, the desktop isn't there).
        if (!linux && rootedTerminals) {
            PowosTerminalActivity.open(context, command, name)
            return
        }
        if (!linux) {
            linuxWanted = true
            return
        }
        // Per agent, so a Claude and a Grok "New app" don't share an app_id.
        val slug = if (agent == null || agent.name == name) name else "${agent.bin} $name"
        val appId = "omarchy." + slug.lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-')
        launchedNames[appId] = name
        if (agent != null) launchedAgents[appId] = agent
        val args = command?.let { " -e bash -c " + shellQuote(it) }.orEmpty()
        launch("foot --app-id=$appId${terminalFont.optionFor(appId, command)}$args")
    }

    /** Opens a pinned app from the home screen. A Linux one runs its current desktop entry, which an update may have changed. */
    fun open(shortcut: Shortcut) {
        shortcut.linux?.let { pinned -> launch(linuxApps.firstOrNull { it.id == pinned.id } ?: pinned) }
        shortcut.component?.let { androidApps.open(it, shortcut.profile) }
    }

    fun launch(app: LinuxApp) {
        // Our own Files app: open it directly rather than round-tripping through the guest.
        if (app.exec == FILES_COMMAND) return openFiles()
        if (app.terminal) return terminal(app.exec, app.name)
        // PowOS rooted mode: like a phone app, its window as its own Android task (KWin exports it), not the desktop.
        if (!linux && rootedTerminals) return openRooted(app)
        // Like an Android icon: an app that already has a window comes back to it. Single-instance
        // apps would otherwise just exit on a second launch, showing nothing. Quickshell apps (App Finder)
        // all share the app_id org.quickshell, so their window title, which is their name, decides.
        wm.appWindows
            .firstOrNull { (it.appId.isNotEmpty() && app.matches(it.appId)) || it.title.equals(app.name, ignoreCase = true) }
            ?.let { if (bringToFront(it)) return }
        launch(app.exec)
    }

    /**
     * Rooted mode: [app] in its own Android task (RootedGuest.openAsTask) - its window if it has one, else it starts.
     * Where it can't be a task (no window tasks yet, a window KWin doesn't export), the desktop comes up to show it.
     */
    private fun openRooted(app: LinuxApp) {
        Log.i(TAG, "open as task: ${app.id}")
        thread(name = "guest-open", isDaemon = true) {
            val log: (String) -> Unit = { Log.i(TAG, "[${app.id.take(24)}] $it") }
            val code = runCatching { RootedGuest.openAsTask(app.id, app.wmClass, app.exec, ::showDesktop, log) }.getOrElse { -1 }
            Log.i(TAG, "exited $code: ${app.exec}")
        }
    }

    /** Moves [window]'s Android task to the front; false if it has none (yet). */
    private fun bringToFront(window: XdgToplevel): Boolean {
        val handle = wm.handleOf(window) ?: return false
        val task =
            context.getSystemService(ActivityManager::class.java).appTasks.firstOrNull {
                runCatching { it.taskInfo?.baseIntent?.data?.lastPathSegment }.getOrNull() == handle
            } ?: return false
        // The task may have gone since it was listed.
        return runCatching { task.moveToFront() }.isSuccess
    }

    /** The name to show for a Linux window: launch name, then .desktop entry, then its title. */
    fun displayName(
        appId: String,
        title: String,
    ): String {
        launchedNames[appId]?.let { return it }
        linuxApps.firstOrNull { it.matches(appId) }?.let { return it.name }
        return title.ifEmpty { appId.ifEmpty { "Linux" } }
    }

    /** The agent running in a Linux window: one started for it, or one named after it. */
    fun agentOf(
        appId: String,
        name: String?,
    ): Agent? = launchedAgents[appId] ?: AGENTS.firstOrNull { it.name == name }

    /** The drawer icon of the app called [name] (an agent's logo, say); null until loaded, or if it has none. */
    fun iconNamed(name: String): ImageBitmap? = linuxApps.firstOrNull { it.name == name }?.let { linuxIcons[it.id] }

    /** Brings the PowOS desktop to the front, also folded (on the cover screen), to show an app just opened there. */
    fun showDesktop() = andro.marchy.MainActivity.show(context)

    /** Opens the Files app, at [path] (a guest path) if given. */
    fun openFiles(path: String? = null) {
        context.startActivity(
            Intent(context, FilesActivity::class.java)
                .putExtra(FilesActivity.EXTRA_PATH, path)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    /** Starts a command inside the guest; its output goes to logcat. Returns at once; [onExit] runs on the launch thread. */
    fun launch(
        command: String,
        onExit: () -> Unit = {},
    ) {
        val rooted = !linux && rootedTerminals
        if (!linux && !rooted) {
            linuxWanted = true
            onExit()
            return
        }
        Log.i(TAG, "launch: $command")
        // A Steam game (the games widget's steam://rungameid/<appid>), rooted: like the drawer, its window in its own
        // task - powos-open-task resumes a running (maybe frozen) game at once and shows its window, a cold start's
        // window when it comes; the desktop only where it can't be a task.
        val game = if (rooted) STEAM_GAME.find(command)?.groupValues?.get(1) else null
        // Rooted mode: it opens on the PowOS desktop (RootedGuest), which comes to the front to show it.
        if (rooted && game == null) showDesktop()
        thread(name = "guest-launch", isDaemon = true) {
            val log: (String) -> Unit = { Log.i(TAG, "[${command.take(24)}] $it") }
            val code =
                runCatching {
                    when {
                        game != null -> RootedGuest.openAsTask("steam_app_$game", null, command, ::showDesktop, log)
                        rooted -> RootedGuest.runOwn("exec $command", log)
                        else -> proot.run("exec $command", log)
                    }
                }.getOrElse { -1 }
            Log.i(TAG, "exited $code: $command")
            onExit()
        }
    }

    companion object {
        private const val TAG = "runtime"
        private val STEAM_GAME = Regex("""steam://rungameid/(\d+)""")
        private const val SETUP_DONE = "setup_done"
        private const val SYSTEM_THEME_KEY = "system_theme_applied"
    }
}
