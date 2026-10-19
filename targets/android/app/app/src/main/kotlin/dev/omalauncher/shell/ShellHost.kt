package dev.omalauncher.shell

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowInsets
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.ui.graphics.asAndroidBitmap
import dev.omalauncher.R
import dev.omalauncher.Runtime
import dev.omalauncher.ui.PtyTerminal
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.URLDecoder

/**
 * The web shell (the repo's shell/, see shell/DESIGN.md) in a WebView, for whatever shows it: the launcher
 * ([ShellActivity]) and the system slots PowOS fills (the screen-off display, ...: docs/NATIVE-SYSTEM-UI.md). Each is
 * a thin host - its window, its role - around one of these; what it shows is the shell, the same code everywhere,
 * with the host API as window.powos ([ShellBridge]). [mode] tells the page which screen it is (index.html?mode=).
 *
 * The page is served from [ORIGIN], a name that never reaches the network: each file comes from the override folder
 * ([overrides], where the user or an agent changes the shell - a file there wins over the shipped one) or the copy
 * the APK ships (assets/shell). Saving a file in the override folder hot-reloads it (files.changed), in every host.
 *
 * Working on the shell from a computer: a URL in [devUrlFile] (a LAN dev server) is loaded instead. Only that file
 * names it, never an intent - the bridge can launch and uninstall apps, so no other app may point it at a page.
 */
class ShellHost(
    private val context: Context,
    activity: Activity?,
    private val runtime: Runtime,
    private val mode: String? = null,
) {
    private val main = Handler(Looper.getMainLooper())
    private val overrides get() = File(context.filesDir, "shell")

    /** Where the override folder is (HotReload watches it). */
    internal val filesDir: File get() = context.filesDir
    private val devUrlFile get() = File(context.filesDir, "shell-dev-url")

    @SuppressLint("SetJavaScriptEnabled")
    val web: WebView =
        WebView(context).apply {
            setBackgroundColor(Color.TRANSPARENT)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            webViewClient = Client()
            webChromeClient =
                object : WebChromeClient() {
                    override fun onConsoleMessage(m: ConsoleMessage): Boolean {
                        Log.i(TAG, "${mode ?: "home"} ${m.messageLevel()} ${m.sourceId().substringAfterLast('/')}:${m.lineNumber()} ${m.message()}")
                        return true
                    }
                }
        }

    val bridge = ShellBridge(context, activity, runtime, web)

    init {
        overrides.mkdirs()
        web.addJavascriptInterface(bridge, "PowosHost")
        // Insets to the page (CSS px), as they change: the bar sits above the navigation bar, the drawer clears
        // the status bar, the keyboard's height lifts the bar.
        web.setOnApplyWindowInsetsListener { v, insets ->
            bridge.insets(insets)
            v.onApplyWindowInsets(insets)
            WindowInsets.CONSUMED
        }
        HotReload.add(this)
        val page = devUrl() ?: "$ORIGIN/index.html"
        web.loadUrl(mode?.let { "$page?mode=$it" } ?: page)
    }

    fun destroy() {
        HotReload.remove(this)
        bridge.close()
        web.destroy()
    }

    private fun devUrl(): String? =
        devUrlFile.takeIf { it.isFile }?.readText()?.trim()?.takeIf { it.startsWith("http://") || it.startsWith("https://") }

    /** Serves [ORIGIN]: the shell's files, and app icons at /_icon/<key>. */
    private inner class Client : WebViewClient() {
        override fun shouldInterceptRequest(
            view: WebView,
            request: WebResourceRequest,
        ): WebResourceResponse? {
            val url = request.url
            if ("${url.scheme}://${url.host}" != ORIGIN) return null
            val path = url.path.orEmpty().trimStart('/').ifEmpty { "index.html" }
            if (path.startsWith("_icon/")) return icon(URLDecoder.decode(path.removePrefix("_icon/"), "UTF-8"))
            if (path.startsWith("_wimg/")) {
                val rest = path.removePrefix("_wimg/")
                return widgetImage(URLDecoder.decode(rest.substringBefore('/'), "UTF-8"), URLDecoder.decode(rest.substringAfter('/'), "UTF-8"))
            }
            if (path.startsWith("_font/")) return font(path.removePrefix("_font/"))
            // What's playing's album art, for the control center's media card (its id from media.state).
            if (path.startsWith("_media/")) {
                val bitmap = runtime.widgets.media.art(URLDecoder.decode(path.removePrefix("_media/"), "UTF-8")) ?: return notFound()
                val png = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
                return WebResourceResponse("image/png", null, ByteArrayInputStream(png)).apply { responseHeaders = mapOf("Cache-Control" to "no-store") }
            }
            // The assistant's screenshot of the screen it was opened over (PowosAssistSession writes it).
            if (path.startsWith("_assist/")) {
                val file = File(File(context.cacheDir, "assist"), path.removePrefix("_assist/").substringAfterLast('/'))
                return if (file.isFile) WebResourceResponse("image/jpeg", null, file.inputStream()).apply { responseHeaders = mapOf("Cache-Control" to "no-store") } else notFound()
            }
            // A recent task's last frame, for the switcher (on the WebView's loader thread: the snapshot is a binder call).
            if (path.startsWith("_task/")) {
                val jpeg = path.removePrefix("_task/").toIntOrNull()?.let { dev.omalauncher.system.Tasks.snapshot(it) } ?: return notFound()
                return WebResourceResponse("image/jpeg", null, ByteArrayInputStream(jpeg)).apply { responseHeaders = mapOf("Cache-Control" to "no-store") }
            }
            if (".." in path.split('/')) return notFound()
            val stream = open(path) ?: return notFound()
            return WebResourceResponse(mime(path), "utf-8", stream).apply {
                // Always the file as it is now: an edit must show on the next load, not a cached copy.
                responseHeaders = mapOf("Cache-Control" to "no-store", "Access-Control-Allow-Origin" to ORIGIN)
            }
        }

        /**
         * The shell's own pages load (its reload, for hot reload, counts as a navigation: refusing it left every edit
         * unshown); anything else doesn't - links go nowhere from home.
         */
        override fun shouldOverrideUrlLoading(
            view: WebView,
            request: WebResourceRequest,
        ) = "${request.url.scheme}://${request.url.host}" != ORIGIN
    }

    /** The override folder's file, else the shipped one. */
    private fun open(path: String): InputStream? {
        File(overrides, path).takeIf { it.isFile }?.let { return it.inputStream() }
        return runCatching { context.assets.open("shell/$path") }.getOrNull()
    }

    private fun icon(key: String): WebResourceResponse {
        val bitmap =
            when {
                key.startsWith("a:") -> runtime.androidApps.icons[key.removePrefix("a:")]
                key.startsWith("l:") -> runtime.linuxIcons[key.removePrefix("l:")]
                else -> null
            } ?: return notFound()
        val png = ByteArrayOutputStream().also { bitmap.asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        return WebResourceResponse("image/png", null, ByteArrayInputStream(png)).apply {
            responseHeaders = mapOf("Cache-Control" to "max-age=3600")
        }
    }

    /** A widget's Image src (a file, media: art, an icon), as its instance loads it for the Compose tile. */
    private fun widgetImage(
        key: String,
        src: String,
    ): WebResourceResponse {
        val engine = runtime.widgets
        val inst = engine.specs.firstOrNull { it.file.name == key }?.let(engine::instance) ?: return notFound()
        val bitmap = inst.image(src) ?: return notFound()
        val png = ByteArrayOutputStream().also { bitmap.asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        return WebResourceResponse("image/png", null, ByteArrayInputStream(png)).apply { responseHeaders = mapOf("Cache-Control" to "no-store") }
    }

    /**
     * The terminal font (PtyTerminal's copy of PowOS's file for the family named, "terminal/<family>") or the Nerd
     * Font symbols ("symbols"), for the page's terminals.
     */
    private fun font(name: String): WebResourceResponse {
        val stream =
            when {
                name == "symbols" -> context.resources.openRawResource(R.font.nerd_symbols)
                name.startsWith("terminal/") ->
                    PtyTerminal.fontFile(context, URLDecoder.decode(name.removePrefix("terminal/"), "UTF-8")) {}?.inputStream()
                else -> null
            } ?: return notFound()
        return WebResourceResponse("font/ttf", null, stream).apply { responseHeaders = mapOf("Cache-Control" to "max-age=3600", "Access-Control-Allow-Origin" to ORIGIN) }
    }

    private fun notFound() = WebResourceResponse("text/plain", "utf-8", 404, "Not Found", emptyMap(), ByteArrayInputStream(ByteArray(0)))

    private fun mime(path: String) =
        when (path.substringAfterLast('.').lowercase()) {
            "html" -> "text/html"
            "js", "mjs" -> "text/javascript"
            // TypeScript: the page transpiles it itself (index.html's loader).
            "ts", "tsx" -> "text/plain"
            "css" -> "text/css"
            "json" -> "application/json"
            "svg" -> "image/svg+xml"
            "png" -> "image/png"
            "webp" -> "image/webp"
            "woff2" -> "font/woff2"
            "ttf" -> "font/ttf"
            else -> "application/octet-stream"
        }

    companion object {
        private const val TAG = "PowosShell"

        /** Where the page lives: never resolved, every request is answered from the app. */
        const val ORIGIN = "https://shell.powos"
    }
}

/**
 * Hot reload, for every page the process shows (home, the shade, the lock screen, the switcher, the assistant): one
 * watcher on the override folder, its changes to each [ShellHost] ("files.changed"). One, not one per page: FileObserver
 * keeps a single inotify watch per path in a process, so a second observer on the folder took the events from the
 * first - only the page made last reloaded.
 */
private object HotReload {
    private val main = Handler(Looper.getMainLooper())
    private val hosts = mutableSetOf<ShellHost>()
    private val watchers = mutableListOf<FileObserver>()
    private var overrides: File? = null

    fun add(host: ShellHost) {
        hosts += host
        if (overrides != null) return
        val dir = File(host.filesDir, "shell").also { overrides = it }
        watch(dir)
        // The override folder deleted and made again (a reset): watch the new one - the old watchers went with it.
        watchers +=
            object : FileObserver(host.filesDir, CREATE or MOVED_TO) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    if (path == dir.name) main.post { watch(dir) }
                }
            }.also { it.startWatching() }
    }

    fun remove(host: ShellHost) {
        hosts -= host
    }

    /** Every directory of the override folder, since FileObserver isn't recursive. */
    private fun watch(dir: File) {
        val observer =
            object : FileObserver(dir, CLOSE_WRITE or MOVED_TO or DELETE or CREATE) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    val file = File(dir, path ?: return)
                    if (event and CREATE != 0 && file.isDirectory) {
                        main.post {
                            watch(file)
                            // Written before its watcher started (a push making the folder, then a file in it at once):
                            // those changes, which no watcher saw.
                            file.walkTopDown().filter { it.isFile }.forEach(::changed)
                        }
                    }
                    if (event and (CLOSE_WRITE or MOVED_TO or DELETE) != 0) main.post { changed(file) }
                }
            }
        observer.startWatching()
        watchers += observer
        dir.listFiles()?.filter { it.isDirectory }?.forEach(::watch)
    }

    private fun changed(file: File) {
        val path = file.relativeTo(overrides ?: return).path
        Log.i(TAG, "changed: $path (${hosts.size} pages)")
        for (h in hosts.toList()) h.bridge.emit("files.changed", mapOf("path" to path))
    }

    private const val TAG = "PowosShell"
}
