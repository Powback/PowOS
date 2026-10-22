package dev.omalauncher.shell

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import dev.omalauncher.Runtime
import dev.omalauncher.linux.AGENTS
import dev.omalauncher.linux.JobState
import dev.omalauncher.linux.LinuxState
import dev.omalauncher.linux.Package
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.linux.Stage
import dev.omalauncher.linux.TerminalFont
import dev.omalauncher.linux.TerminalText
import dev.omalauncher.theme.Setting
import dev.omalauncher.theme.Style
import dev.omalauncher.theme.StyleStore
import dev.omalauncher.theme.ThemeDirs
import dev.omalauncher.theme.ThemeDownload
import dev.omalauncher.theme.ThemeInstall
import dev.omalauncher.ui.decodeSampled
import dev.omalauncher.widgets.market.Catalog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes

/**
 * The launcher's own screens for the web shell (shell/ui/screens.tsx): settings and what it opens - style, the
 * community themes, the widget store, Linux, coding agents, packages (pacman and the AUR), licenses. Each screen is
 * its [state] (JSON), sent again as "screens.state" ({ name, state }) while the page watches it, and what the page
 * asks of it ([act]). The work itself is the runtime's - ThemeStore, Market, Pacman, AgentStore, Bootstrap, Gpu,
 * SystemUpdates, as the Compose screens used it; what those screens kept in composables (the package search, the
 * disk usage, the style steppers) is here. Images are served by ShellHost (/_screens/<kind>/<id>, [image]).
 */
class ShellScreens(
    private val context: Context,
    private val activity: Activity?,
    private val runtime: Runtime,
    private val scope: CoroutineScope,
    private val emit: (String, Any?) -> Unit,
) {
    private val watching = HashMap<String, Job>()

    /** The packages screen's search ("" lists what's installed) and its last result, for the query it answered. */
    private var packageQuery by mutableStateOf("")
    private var packages by mutableStateOf<Pair<String, List<Package>>?>(null)
    private var search: Job? = null

    /** The Linux system's size on disk, measured when its screen opens. */
    private var linuxSize by mutableStateOf<Long?>(null)

    /** What the last store install said went wrong (by widget id). */
    private var storeMessage by mutableStateOf<Pair<String, String>?>(null)

    /** What the page shows of [name] now. */
    fun state(name: String): JSONObject =
        when (name) {
            SETTINGS -> settings()
            STYLE -> style()
            THEMES -> themes()
            STORE -> store()
            LINUX -> linux()
            AGENTS_SCREEN -> agents()
            AUR -> packages()
            LICENSES -> licenses()
            else -> throw IllegalArgumentException("no screen $name")
        }

    /** The page shows [name]: its state now, and again on every change until [unwatch]. Opening also refreshes it. */
    fun watch(name: String): JSONObject {
        val now = state(name)
        watching.remove(name)?.cancel()
        watching[name] =
            scope.launch {
                // Compose state (ThemeStore, Market, ...), and Bootstrap's flows, which snapshots don't see.
                merge(snapshotFlow { state(name).toString() }, runtime.bootstrap.state.map { state(name).toString() }, runtime.bootstrap.updates.map { state(name).toString() })
                    .distinctUntilChanged()
                    .drop(1)
                    .collect { emit("screens.state", JSONObject().put("name", name).put("state", JSONObject(it))) }
            }
        opened(name)
        return now
    }

    fun unwatch(name: String) {
        watching.remove(name)?.cancel()
    }

    /** What a screen does as it opens, as each Compose screen's LaunchedEffect did. */
    private fun opened(name: String) {
        val themes = runtime.themes
        when (name) {
            SETTINGS -> if (runtime.bootstrap.isInstalled) scope.launch { runtime.updates.check() }
            STYLE -> {
                if (themes.loaded) scope.launch { themes.rescan() }
                if (runtime.bootstrap.isInstalled) scope.launch { runtime.terminalFont.refreshFamilies() }
            }
            THEMES -> {
                scope.launch { themes.catalog.refresh() }
                if (themes.loaded) scope.launch { themes.rescan() }
            }
            STORE -> scope.launch { runtime.widgets.market.refresh() }
            AUR -> if (packages == null) query(packageQuery)
            LINUX ->
                if (runtime.bootstrap.isInstalled) {
                    scope.launch { linuxSize = withContext(Dispatchers.IO) { diskUsage(runtime.proot.rootfs) } }
                }
        }
    }

    /** Something tapped on screen [name]: [action], with its argument (a name, a number, a list). */
    fun act(
        name: String,
        action: String,
        arg: Any?,
    ): Any? {
        val text = (arg as? String).orEmpty()
        val result: Any? = when ("$name.$action") {
            "settings.check" -> scope.launch { runtime.updates.check(force = true) }.let { null }
            "settings.update" -> runtime.updateSystem()
            "settings.retryUpdates" -> runtime.retryUpdates()
            "settings.android" -> start(Intent(Settings.ACTION_SETTINGS))
            "style.apply" -> theme(text)?.let { scope.launch { runtime.themes.apply(it) } }.let { null }
            "style.download" -> scope.launch { runtime.themes.ensureRelease() }.let { null }
            "style.install" -> installTheme(text)
            "style.update" -> theme(text)?.let { scope.launch { runtime.themes.update(it) } }.let { null }
            "style.remove" -> theme(text)?.let { scope.launch { runtime.themes.remove(it) } }.let { null }
            "style.clearError" -> runtime.themes.clearInstallError()
            "style.background" ->
                runtime.themes.current?.backgrounds()?.firstOrNull { it.name == text }?.let { scope.launch { runtime.themes.setBackground(it) } }.let { null }
            "style.addImage" -> pickImage()
            "style.liveWallpaper" -> start(runtime.themes.liveWallpaperIntent())
            "style.flag" -> flag(arg as JSONArray)
            "style.font" -> runtime.style.update { it.with(Style.TERMINAL_FONT, text) }
            "style.text" -> runtime.style.update { it.with(Style.TERMINAL_TEXT, (arg as Number).toDouble()) }
            "themes.install" -> installTheme(text)
            "themes.refresh" -> scope.launch { runtime.themes.catalog.refresh() }.let { null }
            "themes.page" -> start(Intent(Intent.ACTION_VIEW, Uri.parse(dev.omalauncher.theme.ThemeCatalog.PAGE)))
            "store.refresh" -> scope.launch { runtime.widgets.market.refresh() }.let { null }
            "store.install" -> installWidget(text)
            "store.terminal" -> scope.launch { runtime.widgets.addTerminalWidget(runtime.widgets.activePage) }.let { null }
            "store.agent" -> agent(text)?.let { scope.launch { runtime.widgets.addAgentWidget(it, runtime.widgets.activePage) } }.let { null }
            "linux.install" -> installLinux(arg as? JSONArray)
            "linux.retry" -> runtime.retryLinux()
            "linux.remove" -> runtime.removeLinux()
            "linux.gpu" -> runtime.setGpu(arg == true)
            "agents.install" -> agent(text)?.let { scope.launch { runtime.agents.install(it) } }.let { null }
            "agents.remove" -> agent(text)?.let { scope.launch { runtime.agents.remove(it) } }.let { null }
            "agents.choose" -> agent(text)?.let(runtime.agents::choose)
            "agents.open" -> agent(text)?.let { runtime.terminal(it.bin, it.name, it) }
            "aur.query" -> query(text)
            // New or removed .desktop files show up in the drawer right away; the list is read again.
            "aur.install" -> pkg(text)?.let { p -> scope.launch { if (runtime.pacman.install(p)) runtime.refreshApps(); query(packageQuery) } }.let { null }
            "aur.remove" -> scope.launch { if (runtime.pacman.remove(text)) runtime.refreshApps(); query(packageQuery) }.let { null }
            "licenses.text" -> licenseText(text)
            "licenses.open" -> start(Intent(Intent.ACTION_VIEW, Uri.parse(text)))
            else -> throw IllegalArgumentException("no such action: $name.$action")
        }
        // Only what the page reads back (a license's text); the rest (Unit, a Job) is no answer.
        return result as? String
    }

    // --- settings

    private fun settings(): JSONObject {
        val installed = runtime.bootstrap.isInstalled
        return JSONObject()
            .put("theme", runtime.themes.current?.title ?: JSONObject.NULL)
            .put("linux", linuxState())
            .put("powos", runtime.powosSession)
            .put("agent", runtime.agents.default?.name ?: JSONObject.NULL)
            .put("updates", if (installed) updates() else JSONObject.NULL)
            .put("setup", job(runtime.bootstrap.updates.value).takeIf { it != JSONObject.NULL && installed } ?: JSONObject.NULL)
            .put("version", dev.omalauncher.AppVersion.name(context))
    }

    /** Pending pacman and agent updates, from the last check; "update all" runs them as one job. */
    private fun updates(): JSONObject {
        val u = runtime.updates
        val pending = u.pending
        return JSONObject()
            .put("checking", u.checking)
            .put("checked", pending?.checkedAt ?: JSONObject.NULL)
            .put("error", pending?.error ?: JSONObject.NULL)
            .put("packages", JSONArray(pending?.packages.orEmpty()))
            .put("tools", JSONArray(pending?.tools.orEmpty().map { "${it.name} ${it.current} → ${it.latest}" }))
            .put("job", job(u.job))
    }

    // --- linux

    private fun linuxState(): JSONObject =
        when (val s = runtime.bootstrap.state.value) {
            LinuxState.Checking -> JSONObject().put("state", "checking")
            LinuxState.NotInstalled -> JSONObject().put("state", "none")
            is LinuxState.Installing ->
                JSONObject().put("state", "installing").put("stage", s.stage.ordinal).put("step", s.step)
                    .put("progress", s.progress?.toDouble() ?: JSONObject.NULL).put("log", JSONArray(s.log.takeLast(LOG_LINES)))
            is LinuxState.Failed ->
                JSONObject().put("state", "failed").put("stage", s.stage.ordinal).put("step", s.message).put("log", JSONArray(s.log.takeLast(LOG_LINES)))
            LinuxState.Installed -> JSONObject().put("state", "installed")
            LinuxState.Removing -> JSONObject().put("state", "removing")
        }

    private fun linux(): JSONObject {
        val gpu = runtime.gpu
        val chosen = runtime.bootstrap.chosenAgents
        return JSONObject()
            .put("linux", linuxState())
            .put("powos", runtime.powosSession)
            .put("stages", JSONArray(Stage.entries.filter { it != Stage.Agents || chosen.isNotEmpty() }.map { if (it == Stage.Agents) "install ${chosen.joinToString { a -> a.name }}" else it.label }))
            .put("agentsStage", Stage.Agents.ordinal)
            .put("size", linuxSize ?: JSONObject.NULL)
            .put("agents", agentList())
            .put(
                "gpu",
                if (!gpu.supported) {
                    JSONObject.NULL
                } else {
                    JSONObject().put("wanted", gpu.wanted).put("active", gpu.active).put("device", gpu.device ?: JSONObject.NULL).put("job", job(gpu.state))
                },
            )
    }

    /**
     * Starts the Linux install with the agents picked ([bins]) and asks (Android 13+) to post notifications: the
     * foreground service's notification shows its progress. The install doesn't wait for the answer.
     */
    private fun installLinux(bins: JSONArray?) {
        val picked = (0 until (bins?.length() ?: 0)).map { bins!!.getString(it) }.toSet()
        runtime.installLinux(AGENTS.filter { it.bin in picked })
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            activity?.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATIONS_REQUEST)
        }
    }

    // --- coding agents

    private fun agentList(): JSONArray {
        val store = runtime.agents
        val installed = store.installed.map { it.bin }.toSet()
        return JSONArray(
            AGENTS.map { a ->
                JSONObject()
                    .put("bin", a.bin)
                    .put("name", a.name)
                    .put("description", a.description)
                    .put("installed", a.bin in installed)
                    .put("job", job(store.states[a.bin] ?: JobState.Idle))
            },
        )
    }

    private fun agents(): JSONObject =
        JSONObject()
            .put("linux", linuxState())
            .put("default", runtime.agents.default?.bin ?: JSONObject.NULL)
            .put("agents", agentList())

    private fun agent(bin: String) = AGENTS.firstOrNull { it.bin == bin }

    // --- packages

    /** Searches Arch Linux ARM's repos and the AUR for [q] (debounced while typing); empty lists what's installed. */
    private fun query(q: String) {
        packageQuery = q
        search?.cancel()
        search =
            scope.launch {
                val trimmed = q.trim()
                if (trimmed.isNotEmpty()) delay(350)
                val pacman = runtime.pacman
                packages = trimmed to runCatching { if (trimmed.isEmpty()) pacman.installed() else pacman.search(trimmed) }.getOrDefault(emptyList())
            }
    }

    private fun pkg(name: String) = packages?.second?.firstOrNull { it.name == name }

    private fun packages(): JSONObject {
        val pacman = runtime.pacman
        val loaded = packages
        val list = loaded?.second.orEmpty()
        return JSONObject()
            .put("linux", linuxState())
            .put("query", packageQuery)
            .put("searching", loaded?.first != packageQuery.trim())
            .put(
                "packages",
                JSONArray(
                    list.map { p ->
                        JSONObject()
                            .put("name", p.name)
                            .put("version", p.version)
                            .put("description", p.description)
                            .put("repo", p.repo ?: JSONObject.NULL)
                            .put("installed", p.installed)
                            .put("core", p.name in pacman.core)
                            .put("job", job(pacman.states[p.name] ?: JobState.Idle))
                    },
                ),
            )
    }

    // --- style

    private fun theme(name: String) = runtime.themes.themes.firstOrNull { it.name == name }

    private fun installTheme(url: String) {
        runtime.themes.clearInstallError()
        scope.launch { runtime.themes.install(url) }
    }

    private fun style(): JSONObject {
        val store = runtime.themes
        val current = store.current
        val style = runtime.style
        val source = current?.takeIf { it.own != null }?.let { ThemeDirs.sourceOf(it) }
        val stamp = store.themes.size
        val themes =
            JSONArray(
                store.themes.map { t ->
                    val colors = JSONObject()
                    for (k in listOf("background", "foreground", "accent", "red", "green", "yellow")) t.colors[k]?.let { colors.put(k, it) }
                    JSONObject().put("name", t.name).put("title", t.title).put("colors", colors).put("preview", image("theme", t.name, stamp))
                },
            )
        val backgrounds =
            JSONArray(
                current?.backgrounds().orEmpty().map { f ->
                    JSONObject().put("name", f.name).put("image", image("bg", "${current!!.name}/${f.name}", f.lastModified()))
                },
            )
        val font = runtime.terminalFont
        val metrics = context.resources.displayMetrics
        val flags = JSONArray()
        fun flag(
            key: Setting.Flag,
            label: String,
            on: String,
            off: String,
        ) = flags.put(JSONObject().put("key", key.key).put("label", label).put("on", on).put("off", off).put("value", style.style[key]))
        flag(Style.MONOCHROME_ICONS, "icons", "monochrome", "colored")
        flag(Style.THEMED_ICONS, "icon colors", "theme", "original")
        if (RootedGuest.enabled) flag(Style.SYSTEM_THEME, "system colors", "theme", "own")
        flag(Style.LIVE_BLUR, "glass", "live blur", "still picture")
        flag(Style.LIQUID_GLASS, "glass edges", "liquid", "plain")
        return JSONObject()
            .put("current", current?.name ?: JSONObject.NULL)
            .put("themes", themes)
            .put("complete", store.complete)
            .put("download", download(store.download, store.themes.isNotEmpty()))
            .put("installing", installing(store.installing))
            .put("source", source?.label ?: JSONObject.NULL)
            .put("own", current?.own != null)
            .put("builtIn", (current?.dirs?.size ?: 0) > 1)
            .put("background", store.background?.name ?: JSONObject.NULL)
            .put("backgrounds", backgrounds)
            .put("liveWallpaper", store.liveWallpaperActive)
            .put("flags", flags)
            .put(
                "terminal",
                if (!(runtime.bootstrap.isInstalled || runtime.powosSession)) {
                    JSONObject.NULL
                } else {
                    JSONObject()
                        .put("families", JSONArray(font.families))
                        .put("family", font.family)
                        .put("text", style.style[Style.TERMINAL_TEXT])
                        .put("presets", JSONArray(TerminalText.entries.map { JSONObject().put("label", it.label).put("value", it.em.toDouble()) }))
                        .put("size", TerminalFont.format(font.size).removeSuffix(".0"))
                        .put("columns", font.columns(minOf(metrics.widthPixels, metrics.heightPixels)))
                },
            ).put("styleFile", "~/${StyleStore.GUEST_DIR}/style.toml")
    }

    private fun download(
        d: ThemeDownload,
        partial: Boolean,
    ): JSONObject =
        when (d) {
            is ThemeDownload.Running -> JSONObject().put("state", "running").put("megabytes", d.megabytes)
            is ThemeDownload.Failed -> JSONObject().put("state", "failed").put("message", d.message)
            ThemeDownload.Idle -> JSONObject().put("state", "idle")
        }.put("partial", partial)

    private fun installing(i: ThemeInstall): Any =
        when (i) {
            is ThemeInstall.Running -> JSONObject().put("state", "running").put("name", i.name).put("megabytes", i.megabytes)
            is ThemeInstall.Failed -> JSONObject().put("state", "failed").put("message", i.message)
            ThemeInstall.Idle -> JSONObject.NULL
        }

    /** One of the style flags the page offers, as [key, on]. */
    private fun flag(a: JSONArray) {
        val setting = FLAGS.firstOrNull { it.key == a.getString(0) } ?: error("no flag ${a.getString(0)}")
        runtime.style.update { it.with(setting, a.getBoolean(1)) }
    }

    /** Android's photo picker, for a background of one's own (the answer comes to [imagePicked]). */
    private fun pickImage() {
        val asker = activity ?: error("no activity to pick an image from")
        asker.startActivityForResult(Intent(MediaStore.ACTION_PICK_IMAGES).setType("image/*"), PICK_IMAGE_REQUEST)
    }

    /** ShellActivity's photo picker answered: the image goes into the current theme's backgrounds and shows. */
    fun imagePicked(uri: Uri?) {
        if (uri != null) scope.launch { runtime.themes.addBackground(uri) }
    }

    // --- community themes

    private fun themes(): JSONObject {
        val store = runtime.themes
        val catalog = store.catalog
        // Which repos are installed, by github.com/owner/repo: their source markers.
        val installedFrom = store.themes.mapNotNull { t -> ThemeDirs.sourceOf(t)?.let { it.label.lowercase() to t.name } }.toMap()
        val running = (store.installing as? ThemeInstall.Running)?.name
        return JSONObject()
            .put("loading", catalog.loading)
            .put("error", catalog.error ?: JSONObject.NULL)
            .put("installing", installing(store.installing))
            .put(
                "entries",
                JSONArray(
                    catalog.entries.map { t ->
                        val as_ = installedFrom[t.repo.label.lowercase()]
                        val existing = store.themes.firstOrNull { it.name == t.repo.themeName }
                        JSONObject()
                            .put("title", t.title)
                            .put("repo", t.repo.label)
                            .put("url", t.repo.url)
                            .put("image", image("catalog", t.repo.label, 0))
                            .put("installedAs", as_ ?: JSONObject.NULL)
                            .put("inUse", as_ != null && as_ == store.current?.name)
                            .put("running", running == t.repo.themeName)
                            .put("replaces", existing?.let { if (it.own != null) "own:${it.title}" else "omarchy:${it.title}" } ?: JSONObject.NULL)
                    },
                ),
            )
    }

    // --- widget store

    private fun store(): JSONObject {
        val engine = runtime.widgets
        val market = engine.market
        val theme = runtime.themes.picked
        return JSONObject()
            .put("page", engine.activePage)
            .put("linux", engine.linux)
            .put("repo", dev.omalauncher.widgets.Market.REPO)
            .put("loading", market.loading)
            .put("error", market.error ?: JSONObject.NULL)
            .put("categories", JSONArray(Catalog.CATEGORIES))
            .put("message", storeMessage?.let { JSONObject().put("id", it.first).put("text", it.second) } ?: JSONObject.NULL)
            .put(
                "builtIn",
                JSONArray(
                    runtime.agents.installed.map { a ->
                        JSONObject().put("bin", a.bin).put("name", a.name).put("description", a.description).put("added", engine.hasAgentWidget(a))
                    },
                ),
            ).put(
                "entries",
                JSONArray(
                    market.entries.map { e ->
                        val installed = market.installedVersion(e)
                        JSONObject()
                            .put("id", e.id)
                            .put("name", e.name)
                            .put("author", e.author)
                            .put("version", e.version)
                            .put("license", e.license)
                            .put("description", e.description)
                            .put("category", e.category ?: JSONObject.NULL)
                            .put("size", e.size?.let { "${it.first}x${it.second}" } ?: JSONObject.NULL)
                            .put("owl", e.owl)
                            .put("supported", e.supported)
                            .put("needsLinux", e.needsLinux)
                            .put("installed", installed?.version ?: JSONObject.NULL)
                            .put("update", market.hasUpdate(e))
                            .put("changed", market.changedSinceApproval(e))
                            .put("busy", market.busy[e.id] ?: JSONObject.NULL)
                            .put("requires", e.requires.entries.joinToString("; ") { (m, l) -> "$m: ${l.joinToString(", ")}" })
                            .put("commands", JSONArray(e.commands.map { it.trimEnd() }))
                            .put("preview", if (e.previewFor(theme) != null) image("market", e.id, theme) else JSONObject.NULL)
                    },
                ),
            )
    }

    /** Installs widget [id] on the page showing; the page closes the store unless there's an error to show. */
    private fun installWidget(id: String) {
        val market = runtime.widgets.market
        val e = market.entries.firstOrNull { it.id == id } ?: error("no widget $id")
        storeMessage = null
        scope.launch {
            val message = market.install(e, runtime.widgets.activePage)
            if (message != null) storeMessage = id to message else emit("screens.done", JSONObject().put("name", STORE).put("id", id))
        }
    }

    // --- licenses

    private fun licenses(): JSONObject =
        JSONObject()
            .put("version", dev.omalauncher.AppVersion.name(context))
            .put("components", JSONArray(Licenses.COMPONENTS.map { c -> JSONObject().put("name", c.name).put("use", c.use).put("license", c.license).put("notice", c.notice).put("url", c.url).put("source", c.source ?: JSONObject.NULL) }))

    /** A license's text (the LGPL with the GPL 3.0 it adds to); null for the public domain. */
    private fun licenseText(license: String): String? {
        if (license == "public-domain") return null
        require(license.matches(Regex("[a-z0-9.-]+"))) { "bad license $license" }
        fun read(name: String) = context.assets.open("licenses/$name.txt").bufferedReader().use { it.readText() }
        return if (license == "lgpl-3.0") read(license) + "\n\n" + read("gpl-3.0") else read(license)
    }

    // --- images, for ShellHost

    /**
     * An image a screen shows, as ShellHost serves /_screens/<kind>/<id>: a theme's preview, a background, a community
     * theme's screenshot or a store widget's preview - scaled down, as JPEG (a store preview as the PNG it is). On the
     * WebView's loader thread: downloads block it, not the main thread.
     */
    fun image(
        kind: String,
        id: String,
    ): Pair<String, ByteArray>? =
        runCatching {
            when (kind) {
                "theme" -> theme(id)?.preview?.let { jpeg(it, 480) }
                "bg" -> {
                    val name = id.substringBefore('/')
                    runtime.themes.themes.firstOrNull { it.name == name }?.backgrounds()?.firstOrNull { it.name == id.substringAfter('/') }?.let { jpeg(it, 480) }
                }
                "catalog" -> {
                    val t = runtime.themes.catalog.entries.firstOrNull { it.repo.label == id } ?: return null
                    runBlocking { runtime.themes.catalog.image(t) }?.let { jpeg(it, 400) }
                }
                "market" -> {
                    val e = runtime.widgets.market.entries.firstOrNull { it.id == id } ?: return null
                    runBlocking { runtime.widgets.market.preview(e, runtime.themes.picked) }?.let { "image/png" to it }
                }
                else -> null
            }
        }.onFailure { Log.w(TAG, "no image $kind/$id", it) }.getOrNull()

    private fun jpeg(
        file: File,
        width: Int,
    ): Pair<String, ByteArray>? {
        val bitmap = decodeSampled(file, width, 0) ?: return null
        return "image/jpeg" to ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray().also { bitmap.recycle() }
    }

    /** An image's URL; [stamp] changes it when what it shows may have (a theme rescanned, the theme for previews). */
    private fun image(
        kind: String,
        id: String,
        stamp: Any,
    ) = "${ShellHost.ORIGIN}/_screens/$kind/${Uri.encode(id)}?v=${Uri.encode(stamp.toString())}"

    // ---

    private fun job(state: JobState): Any =
        when (state) {
            is JobState.Working -> JSONObject().put("state", "working").put("action", state.action).put("log", JSONArray(state.log.takeLast(LOG_LINES)))
            is JobState.Failed -> JSONObject().put("state", "failed").put("log", JSONArray(state.log.takeLast(LOG_LINES)))
            JobState.Idle -> JSONObject.NULL
        }

    private fun start(intent: Intent) {
        // runCatching: there may be no browser, no live wallpaper picker (Android Go).
        runCatching { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), dev.omalauncher.system.AppWindows.bundle(context)) }.onFailure { Log.w(TAG, "can't open $intent", it) }
    }

    fun close() {
        watching.values.forEach { it.cancel() }
        watching.clear()
        search?.cancel()
    }

    companion object {
        private const val TAG = "PowosScreens"
        const val SETTINGS = "settings"
        const val STYLE = "style"
        const val THEMES = "themes"
        const val STORE = "store"
        const val LINUX = "linux"
        const val AGENTS_SCREEN = "coding"
        const val AUR = "aur"
        const val LICENSES = "licenses"

        /** ShellActivity's request codes: the photo picker's, the notification permission's. */
        const val PICK_IMAGE_REQUEST = 42
        const val NOTIFICATIONS_REQUEST = 43

        private const val LOG_LINES = 4

        private val FLAGS = listOf(Style.MONOCHROME_ICONS, Style.THEMED_ICONS, Style.SYSTEM_THEME, Style.LIVE_BLUR, Style.LIQUID_GLASS)

        /** Bytes in [dir], without following symlinks (the rootfs is full of absolute guest links). */
        private fun diskUsage(dir: File): Long {
            var total = 0L
            runCatching {
                Files.walkFileTree(
                    dir.toPath(),
                    object : SimpleFileVisitor<Path>() {
                        override fun visitFile(
                            file: Path,
                            attrs: BasicFileAttributes,
                        ): FileVisitResult {
                            if (attrs.isRegularFile) total += attrs.size()
                            return FileVisitResult.CONTINUE
                        }

                        override fun visitFileFailed(
                            file: Path,
                            exc: IOException,
                        ) = FileVisitResult.CONTINUE
                    },
                )
            }
            return total
        }
    }
}
