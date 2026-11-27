package dev.omalauncher.shell

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
 * Off the LAN/VPN the apps stay, shown unreachable - only once nothing on the .pow network answered twice in a row
 * (WebAppSync.Reach), retried within seconds and on every screen-on/network change so the mark clears at once. One the user removes stays removed (webapps-removed.json) until
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

    /**
     * The .pow network answered (true), didn't on [WebAppSync.OFFLINE_AFTER] tries in a row (false: off the LAN/VPN,
     * the hub down - the launcher greys the apps), not tried yet (null). A hub that answers without its catalog is
     * reachable: the sites behind the same Traefik work.
     */
    @Volatile var reachable: Boolean? = null
        private set

    private var reach = WebAppSync.Reach()

    private val io = Executors.newSingleThreadScheduledExecutor { Thread(it, "powos-webapps").apply { isDaemon = true } }
    private var apps: List<App>? = null
    private var removed: MutableSet<String>? = null
    private val icons = HashMap<String, ImageBitmap>()
    private var started = false
    private var pending: ScheduledFuture<*>? = null
    private var pendingAt = 0L
    private var running = false
    private var retry: ScheduledFuture<*>? = null
    private var again = false

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
                // Its site permissions go with it: installed again, it asks again.
                WebAppPermissions.revoke(context, id, null)
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
        // The screen coming on: an offline mark from while it was off (a try during a network change, Wi-Fi asleep)
        // is checked again now, before the user reads the launcher.
        runCatching {
            val f = IntentFilter().apply { addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_USER_PRESENT) }
            val r =
                object : BroadcastReceiver() {
                    override fun onReceive(
                        ctx: Context,
                        intent: Intent,
                    ) = recheck(c)
                }
            if (android.os.Build.VERSION.SDK_INT >= 33) c.registerReceiver(r, f, Context.RECEIVER_NOT_EXPORTED) else c.registerReceiver(r, f)
        }.onFailure { Log.w(TAG, "no screen-on receiver: ${it.message}") }
    }

    /** A try that missed (or an offline mark): try again now. Nothing when the last try answered. */
    fun recheck(context: Context) {
        if (synchronized(this) { reach.misses } > 0) syncSoon(context, 0)
    }

    /**
     * One sync [delaySec] from now; calls before it runs fold into it (a network change fires several callbacks), an
     * earlier one moves it up. A call while a sync is running runs another right after it: a network change mid-try
     * (the VPN coming up while the try on the old network times out) was folded into that failing try and lost, the
     * apps then stayed greyed until the periodic sync.
     */
    fun syncSoon(
        context: Context,
        delaySec: Long,
    ) {
        synchronized(this) {
            if (running) {
                again = true
                return
            }
            val at = System.currentTimeMillis() + delaySec * 1000
            if (pending?.isDone == false) {
                if (pendingAt <= at) return
                pending?.cancel(false)
            }
            pendingAt = at
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
        synchronized(this) {
            running = true
            again = false
        }
        try {
            syncFrom(context, base, why)
        } finally {
            val more =
                synchronized(this) {
                    running = false
                    again.also { again = false }
                }
            if (more) syncSoon(context, 0)
        }
    }

    /** One try at [base]'s catalog: applied, the reachability updated, a retry timed after a miss. */
    private fun syncFrom(
        context: Context,
        base: String,
        why: String,
    ) {
        val (probe, catalog) = fetchCatalog(base, why)
        val (result, changed) = applyCatalog(context, catalog)
        if (changed) Log.i(TAG, "sync ($why): ${result.apps.size} apps, added ${result.added}, removed ${result.removed}")
        val flipped = noteReach(context, probe, why)
        if (changed || flipped) version.intValue++
        for (id in result.iconsToFetch) result.apps.firstOrNull { it.id == id }?.let { fetchIcon(context, it, wake = false) }
    }

    /** [probe] counted ([reachable] per WebAppSync.Reach.shown) and the next retry timed; true: [reachable] changed. */
    private fun noteReach(
        context: Context,
        probe: WebAppSync.Probe,
        why: String,
    ): Boolean {
        val now = synchronized(this) { reach.after(probe).also { reach = it } }
        val ok = now.shown(reachable, probe)
        val flipped = reachable != ok
        reachable = ok
        if (flipped) Log.i(TAG, "sync ($why): .pow apps ${if (ok == false) "unreachable after ${now.misses} tries" else "reachable"} ($probe)")
        // One retry timer at a time (each try replaces the last one's), none once it answered.
        synchronized(this) {
            retry?.cancel(false)
            retry = now.retryInSec()?.let { sec -> io.schedule({ runCatching { syncSoon(context, 0) } }, sec, TimeUnit.SECONDS) }
        }
        return flipped
    }

    /**
     * GET <base>/v1/apps: what it said about the .pow network (WebAppSync.probeOf) and the catalog (null without one:
     * off the LAN/VPN, the hub's catalog service down, a portal page).
     */
    private fun fetchCatalog(
        base: String,
        why: String,
    ): Pair<WebAppSync.Probe, List<App>?> =
        runCatching {
            val c = URL("$base/v1/apps").openConnection() as HttpURLConnection
            c.connectTimeout = 8000
            c.readTimeout = 10000
            c.instanceFollowRedirects = false
            try {
                val code = c.responseCode
                val catalog = if (code == 200) WebAppSync.parse(c.inputStream.bufferedReader().use { it.readText() }) else null
                val probe = WebAppSync.probeOf(code, catalog, c.getHeaderField("Location"))
                if (catalog == null) Log.i(TAG, "sync ($why): $base answered $code without a catalog ($probe)")
                probe to catalog
            } finally {
                c.disconnect()
            }
        }.onFailure { Log.i(TAG, "sync ($why): $base unreachable: ${it.message}") }.getOrElse { WebAppSync.Probe.NO_ANSWER to null }

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
