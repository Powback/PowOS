package dev.omalauncher.shell

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.ConnectivityManager
import android.net.Network
import android.net.Uri
import android.util.Log
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * The fleet's `.pow` web apps as PowOS apps (issue #8). The launcher lists each as "w:<host>" (ShellBridge.apps, with
 * what kind of app it is: an installable PWA, a plain page, a sleeping service, and whether it's reachable now) and
 * opens it in a web window (WebWindows.openWeb -> WebAppActivity, one WebView on the URL).
 *
 * Every `.pow` site is an app, kept in sync with PowStation's catalog (powos-enroll GET /v1/apps). The user, 11-23: "I
 * want all .pow stuff as apps automatically even when new ones gets added or removed maybe with some indicator of
 * whether its pwa or whatever". That replaces the owner decision of 11-09 ("Nothing is added on pairing: only what the
 * user installs"). [sync] runs at app start, on every network/VPN change and every [PERIOD_MIN] minutes: a new host is
 * added, one the catalog no longer lists is removed - only after a successful, non-empty fetch (WebAppSync.apply).
 * Off the LAN/VPN the apps stay, shown unreachable. One the user removes stays removed (webapps-removed.json) until
 * PowApps installs it again. Nothing syncs on a device set up standalone (PowStation.catalogBase).
 *
 * Kept in files/webapps.json, each icon a PNG beside it (webapps/<id>.png), read from the site's manifest/favicon URL
 * when it's new or its icon URL changed - never a sleeping service's favicon before it was opened (that would wake it).
 */
object WebApps {
    private const val TAG = "PowosWebApps"
    private const val PERIOD_MIN = 15L

    /** A web app; [kind] what the catalog says it is. */
    class App(
        val id: String,
        val name: String,
        val url: String,
        val icon: String,
        val theme: String,
        val kind: Kind = Kind(),
    ) {
        val web get() = kind.web
        val category get() = kind.category
    }

    /** [web]: WebAppSync.PWA / PAGE / SLEEPS; [category]: the catalog's ("" none). */
    class Kind(val web: String = WebAppSync.PAGE, val category: String = "")

    /** Moves on every install/uninstall/icon/sync/reachability change: ShellBridge sends the page apps.changed. */
    val version = mutableIntStateOf(0)

    /** The catalog answered on the last try (true), didn't (false: off the LAN/VPN, the hub down), not tried yet (null). */
    @Volatile var reachable: Boolean? = null
        private set

    private val io = Executors.newSingleThreadScheduledExecutor { Thread(it, "powos-webapps").apply { isDaemon = true } }
    private var apps: List<App>? = null
    private var removed: MutableSet<String>? = null
    private val icons = HashMap<String, ImageBitmap>()
    private var started = false
    private var pending: ScheduledFuture<*>? = null

    /** A web app's id from its URL: the host ("powscan.pow"); null: not an http(s) `.pow` URL (nothing else installs). */
    fun idOf(url: String): String? =
        Uri.parse(url).takeIf { (it.scheme == "http" || it.scheme == "https") && WebAppSync.isPowHost(it.host) }?.host

    fun list(context: Context): List<App> = synchronized(this) { apps ?: load(context).also { apps = it } }

    fun get(context: Context, id: String): App? = list(context).firstOrNull { it.id == id }

    fun icon(context: Context, id: String): ImageBitmap? =
        synchronized(this) {
            icons[id] ?: File(dir(context), "$id.png").takeIf { it.isFile }?.let { BitmapFactory.decodeFile(it.path) }?.asImageBitmap()?.also { icons[id] = it }
        }

    /** What PowApps hands over (its catalog entry): name, site URL, icon URL, theme colour. */
    class Request(val name: String, val url: String, val icon: String, val theme: String)

    /** Adds (or updates) [req] as an app (PowApps' Install); its icon is fetched off the caller's thread. False: not a `.pow` URL. */
    fun install(
        context: Context,
        req: Request,
    ): Boolean {
        val id = idOf(req.url) ?: return false.also { Log.w(TAG, "install refused: not a .pow URL: ${req.url}") }
        synchronized(this) {
            val before = list(context)
            val old = before.firstOrNull { it.id == id }
            val app = App(id, req.name.trim().take(60).ifEmpty { id.removeSuffix(".pow") }, req.url, req.icon, req.theme.take(32), old?.kind ?: Kind())
            apps = before.map { if (it.id == id) app else it } + listOfNotNull(app.takeIf { old == null })
            // Installed again by the user: the sync keeps it from now on.
            if (removedSet(context).remove(id)) saveRemoved(context)
            save(context)
            io.execute { fetchIcon(context, app, wake = true) }
        }
        Log.i(TAG, "installed $id (${req.url})")
        version.intValue++
        return true
    }

    /** The user removed [id] (the launcher's menu, PowApps): it goes, and the sync doesn't bring it back. */
    fun uninstall(
        context: Context,
        id: String,
    ): Boolean {
        val had =
            synchronized(this) {
                val before = list(context)
                apps = before.filter { it.id != id }
                icons.remove(id)
                File(dir(context), "$id.png").delete()
                if (removedSet(context).add(id)) saveRemoved(context)
                save(context)
                before.size != apps!!.size
            }
        if (had) version.intValue++
        return had
    }

    /**
     * Starts the catalog sync (App.onCreate, the main process): now, on each network change (a VPN coming up or going
     * changes the default network) and every [PERIOD_MIN] minutes. Idempotent.
     */
    fun start(context: Context) {
        val c = context.applicationContext
        synchronized(this) {
            if (started) return
            started = true
        }
        syncSoon(c, 0)
        io.scheduleWithFixedDelay({ runCatching { sync(c, "periodic") } }, PERIOD_MIN, PERIOD_MIN, TimeUnit.MINUTES)
        runCatching {
            c.getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(
                object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) = syncSoon(c, 2)

                    override fun onLost(network: Network) = syncSoon(c, 2)
                },
            )
        }.onFailure { Log.w(TAG, "no network callback: ${it.message}") }
    }

    /** One sync [delaySec] from now; calls before it runs fold into it (a network change fires several callbacks). */
    fun syncSoon(
        context: Context,
        delaySec: Long,
    ) {
        synchronized(this) {
            if (pending?.isDone == false) return
            pending = io.schedule({ runCatching { sync(context, "soon") } }, delaySec, TimeUnit.SECONDS)
        }
    }

    /** A web app was opened (ShellBridge): a sleeping service with no icon yet gets its favicon once it's awake. */
    fun opened(
        context: Context,
        id: String,
    ) {
        val app = get(context, id) ?: return
        if (app.web != WebAppSync.SLEEPS || File(dir(context), "$id.png").isFile) return
        io.schedule({ fetchIcon(context, app, wake = true) }, 20, TimeUnit.SECONDS)
    }

    /** Fetches the catalog and applies it (on [io]). */
    private fun sync(
        context: Context,
        why: String,
    ) {
        val base = dev.omalauncher.devices.PowStation.catalogBase(context) ?: return
        val catalog = fetchCatalog(base, why)
        val (result, changed) = applyCatalog(context, catalog)
        val flipped = reachable != (catalog != null)
        reachable = catalog != null
        if (changed) Log.i(TAG, "sync ($why): ${result.apps.size} apps, added ${result.added}, removed ${result.removed}")
        if (changed || flipped) version.intValue++
        for (id in result.iconsToFetch) result.apps.firstOrNull { it.id == id }?.let { fetchIcon(context, it, wake = false) }
    }

    /** GET <base>/v1/apps; null when it didn't answer with a catalog (off the LAN/VPN, the hub down, a portal page). */
    private fun fetchCatalog(
        base: String,
        why: String,
    ): List<App>? =
        runCatching {
            val c = URL("$base/v1/apps").openConnection() as HttpURLConnection
            c.connectTimeout = 5000
            c.readTimeout = 10000
            c.instanceFollowRedirects = false
            try {
                if (c.responseCode != 200) null else WebAppSync.parse(c.inputStream.bufferedReader().use { it.readText() })
            } finally {
                c.disconnect()
            }
        }.onFailure { Log.i(TAG, "sync ($why): $base unreachable: ${it.message}") }.getOrNull()

    /** [catalog] applied to the kept list (WebAppSync.apply), saved when something changed; (the result, changed). */
    private fun applyCatalog(
        context: Context,
        catalog: List<App>?,
    ): Pair<WebAppSync.Result, Boolean> =
        synchronized(this) {
            val before = list(context)
            val r = WebAppSync.apply(before, catalog, removedSet(context)) { File(dir(context), "$it.png").isFile }
            val changed = WebAppSync.differ(before, r.apps)
            if (changed) {
                apps = r.apps
                for (id in r.removed) {
                    icons.remove(id)
                    File(dir(context), "$id.png").delete()
                }
                save(context)
            }
            r to changed
        }

    /** The site's icon as a PNG; none (SVG, data:, unreachable): the page draws its letter icon. */
    private fun fetchIcon(
        context: Context,
        app: App,
        wake: Boolean,
    ) {
        // A sleeping service's favicon would wake it: only its declared icon URL unless it's being opened anyway.
        val favicon = Uri.parse(app.url).buildUpon().path("/favicon.ico").clearQuery().build().toString().takeIf { wake || app.web != WebAppSync.SLEEPS }
        val candidates = listOfNotNull(app.icon, favicon).filter { it.startsWith("http") && WebAppSync.isPowHost(WebAppSync.hostOf(it)) }.distinct()
        for (src in candidates) {
            val bitmap =
                runCatching {
                    val c = URL(src).openConnection() as HttpURLConnection
                    c.connectTimeout = 4000
                    c.readTimeout = 4000
                    c.inputStream.use { BitmapFactory.decodeStream(it) }
                }.onFailure { Log.w(TAG, "${app.id}: icon $src: ${it.message}") }.getOrNull() ?: continue
            File(dir(context), "${app.id}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            synchronized(this) { icons.remove(app.id) }
            Log.i(TAG, "${app.id}: icon from $src (${bitmap.width}x${bitmap.height})")
            version.intValue++
            return
        }
    }

    private fun dir(context: Context) = File(context.filesDir, "webapps").apply { mkdirs() }

    private fun file(context: Context) = File(context.filesDir, "webapps.json")

    private fun removedFile(context: Context) = File(context.filesDir, "webapps-removed.json")

    private fun load(context: Context): List<App> =
        runCatching {
            val a = JSONArray(file(context).takeIf { it.isFile }?.readText() ?: "[]")
            (0 until a.length()).map { a.getJSONObject(it) }.map {
                App(it.getString("id"), it.getString("name"), it.getString("url"), it.optString("icon"), it.optString("theme"), Kind(it.optString("web").ifEmpty { WebAppSync.PAGE }, it.optString("category")))
            }
        }.onFailure { Log.w(TAG, "webapps.json unreadable: ${it.message}") }.getOrDefault(emptyList())

    private fun save(context: Context) {
        val a = JSONArray()
        for (app in apps.orEmpty()) {
            a.put(JSONObject().put("id", app.id).put("name", app.name).put("url", app.url).put("icon", app.icon).put("theme", app.theme).put("web", app.web).put("category", app.category))
        }
        val tmp = File(context.filesDir, "webapps.json.tmp")
        tmp.writeText(a.toString())
        tmp.renameTo(file(context))
    }

    private fun removedSet(context: Context): MutableSet<String> =
        removed ?: runCatching {
            val a = JSONArray(removedFile(context).takeIf { it.isFile }?.readText() ?: "[]")
            (0 until a.length()).map { a.getString(it) }.toMutableSet()
        }.getOrDefault(mutableSetOf()).also { removed = it }

    private fun saveRemoved(context: Context) {
        val tmp = File(context.filesDir, "webapps-removed.json.tmp")
        tmp.writeText(JSONArray(removed.orEmpty().sorted()).toString())
        tmp.renameTo(removedFile(context))
    }
}
