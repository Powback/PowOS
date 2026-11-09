package dev.omalauncher.shell

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
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

/**
 * The fleet's `.pow` web apps installed as PowOS apps (issue #8): PowApps lists PowStation's catalog (powos-enroll
 * GET /v1/apps) and hands the one the user picks here (WebAppInstallActivity); the launcher lists it as "w:<host>"
 * (ShellBridge.apps) and opens it in a web window (WebWindows.openWeb -> WebAppActivity, one WebView on the URL).
 * Nothing is added on pairing: only what the user installs (owner 11-09). Kept in files/webapps.json, each icon a
 * PNG beside it (webapps/<id>.png), read once from the site's manifest/favicon URL at install.
 */
object WebApps {
    private const val TAG = "PowosWebApps"

    class App(val id: String, val name: String, val url: String, val icon: String, val theme: String)

    /** Moves on every install/uninstall/icon: ShellBridge sends the page apps.changed. */
    val version = mutableIntStateOf(0)

    private val io = Executors.newSingleThreadExecutor { Thread(it, "powos-webapps").apply { isDaemon = true } }
    private var apps: List<App>? = null
    private val icons = HashMap<String, ImageBitmap>()

    /** A web app's id from its URL: the host ("powscan.pow"); null: not an http(s) `.pow` URL (nothing else installs). */
    fun idOf(url: String): String? =
        Uri.parse(url).takeIf { (it.scheme == "http" || it.scheme == "https") && it.host?.matches(Regex("[a-z0-9.-]+\\.pow")) == true }?.host

    fun list(context: Context): List<App> = synchronized(this) { apps ?: load(context).also { apps = it } }

    fun get(context: Context, id: String): App? = list(context).firstOrNull { it.id == id }

    fun icon(context: Context, id: String): ImageBitmap? =
        synchronized(this) {
            icons[id] ?: File(dir(context), "$id.png").takeIf { it.isFile }?.let { BitmapFactory.decodeFile(it.path) }?.asImageBitmap()?.also { icons[id] = it }
        }

    /** Adds (or updates) [url] as an app; its icon is fetched off the caller's thread. False: not a `.pow` URL. */
    /** What PowApps hands over (its catalog entry): name, site URL, icon URL, theme colour. */
    class Request(val name: String, val url: String, val icon: String, val theme: String)

    fun install(
        context: Context,
        req: Request,
    ): Boolean {
        val id = idOf(req.url) ?: return false.also { Log.w(TAG, "install refused: not a .pow URL: ${req.url}") }
        val app = App(id, req.name.trim().take(60).ifEmpty { id.removeSuffix(".pow") }, req.url, req.icon, req.theme.take(32))
        synchronized(this) {
            apps = list(context).filter { it.id != id } + app
            save(context)
        }
        Log.i(TAG, "installed $id (${req.url})")
        version.intValue++
        io.execute { fetchIcon(context, app) }
        return true
    }

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
                save(context)
                before.size != apps!!.size
            }
        if (had) version.intValue++
        return had
    }

    /** The site's icon as a PNG; none (SVG, data:, unreachable): the page draws its letter icon. */
    private fun fetchIcon(
        context: Context,
        app: App,
    ) {
        val candidates = listOf(app.icon, Uri.parse(app.url).buildUpon().path("/favicon.ico").clearQuery().build().toString()).filter { it.startsWith("http") }.distinct()
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

    private fun load(context: Context): List<App> =
        runCatching {
            val a = JSONArray(file(context).takeIf { it.isFile }?.readText() ?: "[]")
            (0 until a.length()).map { a.getJSONObject(it) }.map { App(it.getString("id"), it.getString("name"), it.getString("url"), it.optString("icon"), it.optString("theme")) }
        }.onFailure { Log.w(TAG, "webapps.json unreadable: ${it.message}") }.getOrDefault(emptyList())

    private fun save(context: Context) {
        val a = JSONArray()
        for (app in apps.orEmpty()) a.put(JSONObject().put("id", app.id).put("name", app.name).put("url", app.url).put("icon", app.icon).put("theme", app.theme))
        val tmp = File(context.filesDir, "webapps.json.tmp")
        tmp.writeText(a.toString())
        tmp.renameTo(file(context))
    }
}
